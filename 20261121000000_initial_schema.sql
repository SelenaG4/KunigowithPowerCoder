-- =====================================================================
-- mira Wegweiser Luzern – initial database schema
-- Supabase / PostgreSQL
--
-- Principles:
--   * Public users need no account: they can READ published data only.
--   * Administrators (listed in public.admin_users) can manage everything.
--   * Eligibility matching is deterministic and done in SQL (no AI).
--   * Search starts with PostgreSQL full-text search; an embedding
--     column is prepared for later semantic search.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------
create extension if not exists pg_trgm  with schema extensions;
create extension if not exists unaccent with schema extensions;
create extension if not exists vector   with schema extensions;

-- ---------------------------------------------------------------------
-- 1. Enum types
-- ---------------------------------------------------------------------
create type public.organisation_type as enum (
  'association', 'ngo', 'city_service', 'cantonal_service',
  'federal_service', 'church', 'private', 'other'
);

create type public.verification_status as enum (
  'pending', 'verified', 'rejected', 'archived'
);

create type public.cost_type as enum (
  'free', 'reduced', 'paid', 'varies'
);

create type public.service_status as enum (
  'draft', 'active', 'paused', 'archived'
);

create type public.geographical_coverage as enum (
  'city_of_lucerne', 'canton_of_lucerne', 'central_switzerland',
  'switzerland', 'online', 'specific_municipalities'
);

-- Which personal attribute a rule looks at
create type public.eligibility_rule_type as enum (
  'residence_status',            -- B, C, F, N, S, L, G, Ci, none ...
  'place_of_residence',          -- city_of_lucerne, canton_of_lucerne, outside_canton
  'citizenship',                 -- eu_efta, non_eu_efta
  'social_assistance_provider',  -- daf, municipal, none
  'arrival_stage',               -- planning, recently_arrived, already_living
  'age_group',                   -- child, youth, adult, senior
  'gender',
  'other'
);

-- How the rule is applied
create type public.eligibility_condition as enum (
  'requires',   -- the person's value must be one of the "requires" values
  'excludes'    -- the offer cannot be used if the person's value matches
);

create type public.translation_status as enum (
  'machine', 'draft', 'reviewed', 'published'
);

create type public.source_type as enum (
  'website', 'pdf', 'phone', 'email', 'partner_import',
  'community_submission', 'other'
);

create type public.change_type as enum (
  'created', 'updated', 'verified', 'status_changed', 'deleted'
);

create type public.submission_status as enum (
  'new', 'in_review', 'accepted', 'rejected'
);

-- ---------------------------------------------------------------------
-- 2. Helper: admin users + is_admin()
-- ---------------------------------------------------------------------
create table public.admin_users (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  full_name   text,
  role        text not null default 'editor' check (role in ('editor', 'owner')),
  created_at  timestamptz not null default now()
);

comment on table public.admin_users is
  'Supabase Auth users who may manage content. Public users have no account.';

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admin_users where user_id = auth.uid()
  );
$$;

-- Generic updated_at trigger
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Reference tables
-- ---------------------------------------------------------------------
create table public.categories (
  id                  uuid primary key default gen_random_uuid(),
  slug                text not null unique,
  name                text not null,                       -- default (German)
  name_i18n           jsonb not null default '{}'::jsonb,  -- {"en":"Housing","fr":"Logement",...}
  parent_category_id  uuid references public.categories (id) on delete set null,
  keywords            text[] not null default '{}',
  icon                text,
  sort_order          int not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table public.municipalities (
  id                 uuid primary key default gen_random_uuid(),
  municipality_name  text not null,
  canton             char(2) not null default 'LU',
  bfs_number         int unique,           -- official Swiss municipality number
  created_at         timestamptz not null default now(),
  unique (municipality_name, canton)
);

create table public.sources (
  id               uuid primary key default gen_random_uuid(),
  source_name      text not null,
  source_url       text,
  source_type      public.source_type not null default 'website',
  import_date      timestamptz not null default now(),
  last_checked_at  timestamptz,
  created_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. Organisations
-- ---------------------------------------------------------------------
create table public.organisations (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null,
  description          text,
  website              text,
  address              text,
  phone                text,
  email                text,
  organisation_type    public.organisation_type not null default 'other',
  verification_status  public.verification_status not null default 'pending',
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index organisations_name_trgm_idx
  on public.organisations using gin (name extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------
-- 5. Services (the offers)
-- ---------------------------------------------------------------------
create table public.services (
  id                     uuid primary key default gen_random_uuid(),
  slug                   text not null unique,   -- permanent URL: /service/<slug>
  organisation_id        uuid not null references public.organisations (id) on delete restrict,
  name                   text not null,
  short_description      text,
  full_description       text,
  category_id            uuid references public.categories (id) on delete set null,
  direct_url             text,
  contact_details        jsonb not null default '{}'::jsonb,  -- {"phone":"","email":"","address":"","opening_hours":""}
  cost_type              public.cost_type not null default 'free',
  appointment_required   boolean not null default false,
  available_languages    text[] not null default '{de}',     -- ISO 639-1 codes
  geographical_coverage  public.geographical_coverage not null default 'canton_of_lucerne',
  service_status         public.service_status not null default 'draft',
  source_id              uuid references public.sources (id) on delete set null,
  last_verified_at       timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  -- Full-text search over the default-language content
  search_vector tsvector generated always as (
    setweight(to_tsvector('simple', coalesce(name, '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(short_description, '')), 'B') ||
    setweight(to_tsvector('simple', coalesce(full_description, '')), 'C')
  ) stored,

  -- Prepared for later semantic search (multilingual embedding model, 384 dims
  -- e.g. multilingual-e5-small / paraphrase-multilingual-MiniLM-L12-v2)
  embedding extensions.vector(384)
);

create index services_search_idx       on public.services using gin (search_vector);
create index services_category_idx     on public.services (category_id);
create index services_organisation_idx on public.services (organisation_id);
create index services_status_idx       on public.services (service_status);
create index services_languages_idx    on public.services using gin (available_languages);
create index services_name_trgm_idx    on public.services using gin (name extensions.gin_trgm_ops);
create index services_source_idx       on public.services (source_id);

-- Services can belong to more than one category (optional extra categories)
create table public.service_categories (
  service_id   uuid not null references public.services (id) on delete cascade,
  category_id  uuid not null references public.categories (id) on delete cascade,
  primary key (service_id, category_id)
);
create index service_categories_category_idx on public.service_categories (category_id);

-- For geographical_coverage = 'specific_municipalities'
create table public.service_municipalities (
  service_id       uuid not null references public.services (id) on delete cascade,
  municipality_id  uuid not null references public.municipalities (id) on delete cascade,
  primary key (service_id, municipality_id)
);
create index service_municipalities_muni_idx on public.service_municipalities (municipality_id);

-- ---------------------------------------------------------------------
-- 6. Eligibility rules (deterministic & transparent)
-- ---------------------------------------------------------------------
create table public.eligibility_rules (
  id           uuid primary key default gen_random_uuid(),
  service_id   uuid not null references public.services (id) on delete cascade,
  rule_type    public.eligibility_rule_type not null,
  condition    public.eligibility_condition not null,
  value        text not null,
  explanation  text not null,       -- shown to users, e.g. "Not available for people receiving social assistance from DAF"
  source_id    uuid references public.sources (id) on delete set null,
  verified_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (service_id, rule_type, condition, value)
);

create index eligibility_rules_service_idx on public.eligibility_rules (service_id);
create index eligibility_rules_source_idx on public.eligibility_rules (source_id);

comment on table public.eligibility_rules is
  'requires: person value must be one of the listed values for that rule_type. '
  'excludes: offer not usable if the person value matches.';

-- ---------------------------------------------------------------------
-- 7. Translations
-- ---------------------------------------------------------------------
create table public.translations (
  id                      uuid primary key default gen_random_uuid(),
  service_id              uuid not null references public.services (id) on delete cascade,
  language                text not null check (language ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  translated_name         text not null,
  translated_short_description text,
  translated_description  text,
  translation_status      public.translation_status not null default 'draft',
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  search_vector tsvector generated always as (
    setweight(to_tsvector('simple', coalesce(translated_name, '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(translated_short_description, '')), 'B') ||
    setweight(to_tsvector('simple', coalesce(translated_description, '')), 'C')
  ) stored,
  unique (service_id, language)
);

create index translations_search_idx on public.translations using gin (search_vector);

-- ---------------------------------------------------------------------
-- 8. Change log (audit trail, filled automatically)
-- ---------------------------------------------------------------------
create table public.change_log (
  id           uuid primary key default gen_random_uuid(),
  service_id   uuid references public.services (id) on delete set null,
  changed_by   uuid references auth.users (id) on delete set null,
  change_type  public.change_type not null,
  details      jsonb,
  changed_at   timestamptz not null default now()
);

create index change_log_service_idx on public.change_log (service_id, changed_at desc);
create index change_log_changed_by_idx on public.change_log (changed_by);

create or replace function public.log_service_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type public.change_type;
begin
  if tg_op = 'INSERT' then
    v_type := 'created';
  elsif tg_op = 'DELETE' then
    insert into public.change_log (service_id, changed_by, change_type, details)
    values (null, auth.uid(), 'deleted', jsonb_build_object('id', old.id, 'name', old.name));
    return old;
  elsif new.service_status is distinct from old.service_status then
    v_type := 'status_changed';
  elsif new.last_verified_at is distinct from old.last_verified_at then
    v_type := 'verified';
  else
    v_type := 'updated';
  end if;

  insert into public.change_log (service_id, changed_by, change_type, details)
  values (
    new.id, auth.uid(), v_type,
    case when tg_op = 'UPDATE'
      then jsonb_build_object('old_status', old.service_status, 'new_status', new.service_status)
    end
  );
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Community submissions (public can submit, admins review)
-- ---------------------------------------------------------------------
create table public.service_submissions (
  id                  uuid primary key default gen_random_uuid(),
  organisation_name   text not null,
  service_name        text not null,
  description         text,
  category_id         uuid references public.categories (id) on delete set null,
  website             text,
  contact_details     jsonb not null default '{}'::jsonb,
  eligibility_notes   text,
  languages           text[] not null default '{}',
  submitter_note      text,
  status              public.submission_status not null default 'new',
  reviewed_by         uuid references auth.users (id) on delete set null,
  reviewed_at         timestamptz,
  created_service_id  uuid references public.services (id) on delete set null,
  created_at          timestamptz not null default now()
);
create index service_submissions_category_idx on public.service_submissions (category_id);
create index service_submissions_reviewed_by_idx on public.service_submissions (reviewed_by);
create index service_submissions_service_idx on public.service_submissions (created_service_id);

-- ---------------------------------------------------------------------
-- 10. Shared guides (permanent short links / QR codes, no personal data)
-- ---------------------------------------------------------------------
create table public.shared_guides (
  code        text primary key default substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
  language    text not null default 'de',
  filters     jsonb not null default '{}'::jsonb,  -- {"residence_status":"B","place_of_residence":"city_of_lucerne","categories":["housing"]}
  service_ids uuid[] not null default '{}',
  created_at  timestamptz not null default now()
);

comment on table public.shared_guides is
  'Anonymous, permanent links for QR codes. Stores only filter choices, never names or contact details.';

-- ---------------------------------------------------------------------
-- 11. Triggers
-- ---------------------------------------------------------------------
create trigger categories_updated_at        before update on public.categories        for each row execute function public.set_updated_at();
create trigger organisations_updated_at     before update on public.organisations     for each row execute function public.set_updated_at();
create trigger services_updated_at          before update on public.services          for each row execute function public.set_updated_at();
create trigger eligibility_rules_updated_at before update on public.eligibility_rules for each row execute function public.set_updated_at();
create trigger translations_updated_at      before update on public.translations      for each row execute function public.set_updated_at();

create trigger services_change_log
  after insert or update or delete on public.services
  for each row execute function public.log_service_change();

-- ---------------------------------------------------------------------
-- 12. Eligibility matching + search functions
-- ---------------------------------------------------------------------

-- Returns whether a person profile may use a service, plus readable reasons.
-- profile example:
--   {"residence_status":"F","place_of_residence":"city_of_lucerne","social_assistance_provider":"daf"}
-- Attributes missing from the profile never exclude a service (status "unknown"
-- is reported in reasons instead), so users are not wrongly hidden from offers.
create or replace function public.check_eligibility(p_service_id uuid, p_profile jsonb)
returns table (eligible boolean, unknown boolean, reasons text[])
language sql
stable
set search_path = public
as $$
  with rules as (
    select r.*, p_profile ->> r.rule_type::text as person_value
    from public.eligibility_rules r
    where r.service_id = p_service_id
  ),
  -- excludes: hit when the person's value matches
  excl as (
    select explanation from rules
    where condition = 'excludes' and person_value is not null
      and lower(person_value) = lower(value)
  ),
  -- requires: grouped per rule_type, fail when the value is not in the list
  req as (
    select rule_type,
           bool_or(lower(person_value) = lower(value)) as ok,
           max(person_value) is null                  as missing,
           string_agg(distinct explanation, ' / ')    as explanation
    from rules
    where condition = 'requires'
    group by rule_type
  )
  select
    not exists (select 1 from excl)
      and not exists (select 1 from req where not missing and not ok) as eligible,
    exists (select 1 from req where missing)
      or exists (select 1 from rules where condition = 'excludes' and person_value is null) as unknown,
    coalesce(array(
      select explanation from excl
      union all
      select explanation from req where not missing and not ok
      union all
      select explanation from rules where person_value is null
    ), '{}') as reasons;
$$;

-- Main public search.
--   p_query     free text (any language); null/'' = list all
--   p_language  UI language, used to return translated texts
--   p_category  category slug (includes sub-categories and extra categories)
--   p_profile   person profile for eligibility (see check_eligibility)
--   p_only_eligible  true = hide services the person is excluded from
create or replace function public.search_services(
  p_query          text    default null,
  p_language       text    default 'de',
  p_category       text    default null,
  p_profile        jsonb   default '{}'::jsonb,
  p_only_eligible  boolean default false,
  p_limit          int     default 50,
  p_offset         int     default 0
)
returns table (
  id                   uuid,
  slug                 text,
  name                 text,
  short_description    text,
  organisation_name    text,
  category_slug        text,
  direct_url           text,
  cost_type            public.cost_type,
  appointment_required boolean,
  available_languages  text[],
  geographical_coverage public.geographical_coverage,
  eligible             boolean,
  eligibility_unknown  boolean,
  eligibility_reasons  text[],
  rank                 real
)
language sql
stable
set search_path = public, extensions
as $$
  with q as (
    select case when coalesce(trim(p_query), '') = '' then null
                else websearch_to_tsquery('simple', unaccent(p_query)) end as tsq
  ),
  cat as (
    -- selected category and its direct children
    select c.id from public.categories c
    where p_category is not null
      and (c.slug = p_category
           or c.parent_category_id = (select id from public.categories where slug = p_category))
  ),
  base as (
    select s.*,
           o.name as org_name,
           c.slug as cat_slug,
           t.translated_name,
           t.translated_short_description,
           greatest(
             coalesce(ts_rank(s.search_vector, q.tsq), 0),
             coalesce(ts_rank(t.search_vector, q.tsq), 0),
             coalesce(ts_rank(ta.search_vector, q.tsq), 0)
           ) as rnk
    from public.services s
    join public.organisations o on o.id = s.organisation_id
    left join public.categories c on c.id = s.category_id
    left join public.translations t
           on t.service_id = s.id and t.language = p_language
          and t.translation_status in ('reviewed', 'published', 'machine')
    cross join q
    -- match against any language's translation, not only the UI language
    left join lateral (
      select tt.search_vector from public.translations tt
      where tt.service_id = s.id and q.tsq is not null and tt.search_vector @@ q.tsq
      limit 1
    ) ta on true
    where s.service_status = 'active'
      and (q.tsq is null
           or s.search_vector @@ q.tsq
           or ta.search_vector is not null
           or o.name ilike '%' || p_query || '%'
           or exists (select 1 from public.categories kc
                      where kc.id = s.category_id
                        and exists (select 1 from unnest(kc.keywords) k
                                    where k ilike '%' || p_query || '%')))
      and (p_category is null
           or s.category_id in (select id from cat)
           or exists (select 1 from public.service_categories sc
                      where sc.service_id = s.id and sc.category_id in (select id from cat)))
  )
  select b.id, b.slug,
         coalesce(b.translated_name, b.name),
         coalesce(b.translated_short_description, b.short_description),
         b.org_name, b.cat_slug, b.direct_url, b.cost_type, b.appointment_required,
         b.available_languages, b.geographical_coverage,
         e.eligible, e.unknown, e.reasons,
         b.rnk::real
  from base b
  cross join lateral public.check_eligibility(b.id, coalesce(p_profile, '{}'::jsonb)) e
  where not p_only_eligible or e.eligible
  order by e.eligible desc, b.rnk desc, coalesce(b.translated_name, b.name)
  limit greatest(least(p_limit, 200), 1) offset greatest(p_offset, 0);
$$;

-- Create a permanent share link (for QR codes) without storing personal data
create or replace function public.create_shared_guide(
  p_language text, p_filters jsonb, p_service_ids uuid[]
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  -- strip anything that is not a known filter key
  p_filters := (
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from jsonb_each(coalesce(p_filters, '{}'::jsonb))
    where key in ('residence_status', 'place_of_residence', 'citizenship',
                  'social_assistance_provider', 'arrival_stage', 'age_group',
                  'categories', 'query')
  );
  insert into public.shared_guides (language, filters, service_ids)
  values (coalesce(p_language, 'de'), p_filters,
          coalesce(p_service_ids[1:50], '{}'))
  returning code into v_code;
  return v_code;
end;
$$;

-- ---------------------------------------------------------------------
-- 13. Row-level security
-- ---------------------------------------------------------------------
alter table public.admin_users           enable row level security;
alter table public.categories            enable row level security;
alter table public.municipalities        enable row level security;
alter table public.sources               enable row level security;
alter table public.organisations         enable row level security;
alter table public.services              enable row level security;
alter table public.service_categories    enable row level security;
alter table public.service_municipalities enable row level security;
alter table public.eligibility_rules     enable row level security;
alter table public.translations          enable row level security;
alter table public.change_log            enable row level security;
alter table public.service_submissions   enable row level security;
alter table public.shared_guides         enable row level security;

-- Admin users: admins can see the list; managed by owners via SQL/dashboard
create policy "admins read admin list" on public.admin_users
  for select to authenticated using (public.is_admin());

-- Public read policies -------------------------------------------------
create policy "public read categories" on public.categories
  for select to anon, authenticated using (true);

create policy "public read municipalities" on public.municipalities
  for select to anon, authenticated using (true);

create policy "public read sources" on public.sources
  for select to anon, authenticated using (true);

create policy "public read verified organisations" on public.organisations
  for select to anon, authenticated
  using (verification_status = 'verified' or public.is_admin());

create policy "public read active services" on public.services
  for select to anon, authenticated
  using (service_status = 'active' or public.is_admin());

create policy "public read service categories" on public.service_categories
  for select to anon, authenticated
  using (exists (select 1 from public.services s
                 where s.id = service_id and (s.service_status = 'active' or public.is_admin())));

create policy "public read service municipalities" on public.service_municipalities
  for select to anon, authenticated
  using (exists (select 1 from public.services s
                 where s.id = service_id and (s.service_status = 'active' or public.is_admin())));

create policy "public read eligibility rules" on public.eligibility_rules
  for select to anon, authenticated
  using (exists (select 1 from public.services s
                 where s.id = service_id and (s.service_status = 'active' or public.is_admin())));

create policy "public read translations" on public.translations
  for select to anon, authenticated
  using (
    public.is_admin() or (
      translation_status in ('reviewed', 'published', 'machine')
      and exists (select 1 from public.services s
                  where s.id = service_id and s.service_status = 'active')
    )
  );

create policy "public read shared guides" on public.shared_guides
  for select to anon, authenticated using (true);

-- Public submissions: insert only, cannot read anything back
create policy "public submit offers" on public.service_submissions
  for insert to anon, authenticated
  with check (status = 'new' and reviewed_by is null and created_service_id is null);

-- Admin write policies -------------------------------------------------
create policy "admins manage categories"        on public.categories             for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage municipalities"    on public.municipalities         for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage sources"           on public.sources                for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage organisations"     on public.organisations          for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage services"          on public.services               for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage service cats"      on public.service_categories     for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage service munis"     on public.service_municipalities for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage eligibility rules" on public.eligibility_rules      for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage translations"      on public.translations           for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins read change log"          on public.change_log             for select to authenticated using (public.is_admin());
create policy "admins manage submissions"       on public.service_submissions    for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins delete shared guides"     on public.shared_guides          for delete to authenticated using (public.is_admin());

-- Function permissions
revoke execute on function public.create_shared_guide(text, jsonb, uuid[]) from public;
grant  execute on function public.create_shared_guide(text, jsonb, uuid[]) to anon, authenticated;
grant  execute on function public.search_services(text, text, text, jsonb, boolean, int, int) to anon, authenticated;
grant  execute on function public.check_eligibility(uuid, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 14. Storage bucket for documents (flyers, PDFs)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('documents', 'documents', true)
on conflict (id) do nothing;

-- Public bucket: files are served via public URLs, no listing policy needed.
create policy "admins upload documents" on storage.objects
  for insert to authenticated with check (bucket_id = 'documents' and public.is_admin());

create policy "admins update documents" on storage.objects
  for update to authenticated using (bucket_id = 'documents' and public.is_admin());

create policy "admins delete documents" on storage.objects
  for delete to authenticated using (bucket_id = 'documents' and public.is_admin());

-- ---------------------------------------------------------------------
-- 15. Seed data: categories
-- ---------------------------------------------------------------------
insert into public.categories (slug, name, name_i18n, keywords, icon, sort_order) values
  ('german-courses', 'Deutschkurse',
   '{"en":"German courses","fr":"Cours d''allemand","es":"Cursos de alemán","ar":"دورات اللغة الألمانية","uk":"Курси німецької мови","pt":"Cursos de alemão","tr":"Almanca kursları"}',
   '{deutsch,german,sprache,language,kurs,course,integration}', 'languages', 10),
  ('health-insurance', 'Krankenversicherung',
   '{"en":"Health insurance","fr":"Assurance maladie","es":"Seguro médico","ar":"التأمين الصحي","uk":"Медичне страхування","pt":"Seguro de saúde","tr":"Sağlık sigortası"}',
   '{krankenkasse,krankenversicherung,health,insurance,prämie,prämienverbilligung}', 'heart', 20),
  ('health', 'Gesundheit',
   '{"en":"Health","fr":"Santé","es":"Salud","ar":"الصحة","uk":"Здоров''я","pt":"Saúde","tr":"Sağlık"}',
   '{arzt,doctor,gesundheit,health,spital,hospital}', 'stethoscope', 25),
  ('housing', 'Wohnen',
   '{"en":"Housing","fr":"Logement","es":"Vivienda","ar":"السكن","uk":"Житло","pt":"Habitação","tr":"Konut"}',
   '{wohnung,wohnen,housing,apartment,miete,rent}', 'home', 30),
  ('work', 'Arbeit & Beruf',
   '{"en":"Work & employment","fr":"Travail & emploi","es":"Trabajo y empleo","ar":"العمل والتوظيف","uk":"Робота та працевлаштування","pt":"Trabalho e emprego","tr":"İş ve istihdam"}',
   '{arbeit,job,work,stelle,beruf,anerkennung,diplom}', 'briefcase', 40),
  ('community', 'Gemeinschaft & Freizeit',
   '{"en":"Community & leisure","fr":"Communauté & loisirs","es":"Comunidad y ocio","ar":"المجتمع والترفيه","uk":"Спільнота та дозвілля","pt":"Comunidade e lazer","tr":"Topluluk ve boş zaman"}',
   '{freizeit,leisure,nachbarschaft,neighbourhood,verein,club,sport,treffpunkt}', 'users', 50),
  ('permits', 'Bewilligungen & Behörden',
   '{"en":"Permits & administration","fr":"Permis & administration","es":"Permisos y administración","ar":"التصاريح والإدارة","uk":"Дозволи та адміністрація","pt":"Autorizações e administração","tr":"İzinler ve idare"}',
   '{bewilligung,ausweis,permit,aufenthalt,residence,einwohnerdienste,anmeldung}', 'file-text', 60),
  ('family', 'Familie & Kinder',
   '{"en":"Family & children","fr":"Famille & enfants","es":"Familia e hijos","ar":"الأسرة والأطفال","uk":"Сім''я та діти","pt":"Família e crianças","tr":"Aile ve çocuklar"}',
   '{familie,family,kinder,children,kita,schule,school}', 'baby', 70),
  ('counselling', 'Beratung & Rechtliches',
   '{"en":"Counselling & legal advice","fr":"Conseil & droit","es":"Asesoramiento y asuntos legales","ar":"الاستشارات والشؤون القانونية","uk":"Консультації та правові питання","pt":"Aconselhamento e jurídico","tr":"Danışmanlık ve hukuk"}',
   '{beratung,counselling,recht,legal,sozial,schulden,debt}', 'message-circle', 80),
  ('finances', 'Finanzen & Sozialhilfe',
   '{"en":"Money & social support","fr":"Finances & aide sociale","es":"Finanzas y ayuda social","ar":"المال والدعم الاجتماعي","uk":"Фінанси та соціальна допомога","pt":"Finanças e apoio social","tr":"Finans ve sosyal yardım"}',
   '{geld,money,sozialhilfe,steuern,tax,budget}', 'wallet', 90);

insert into public.municipalities (municipality_name, canton, bfs_number)
values ('Luzern', 'LU', 1061)
on conflict do nothing;
