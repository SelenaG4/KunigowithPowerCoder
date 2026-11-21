-- =====================================================================
-- Excel import pipeline
--
-- Flow:
--   1. Admin uploads an .xlsx in the admin area. The browser reads it with
--      SheetJS (XLSX.utils.sheet_to_json(ws, {header: 1, raw: false}))
--      and calls  rpc('import_stage_sheet', {p_file_name, p_sheet_name, p_rows}).
--   2. The database finds the header row, maps columns via
--      import_column_aliases, keeps every raw row, and parses each row into
--      the platform structure (organisation, service, category, contact,
--      cost, coverage, eligibility rules). Unclear rows get status
--      'needs_review' with the reasons in `issues`.
--   3. Admin checks / edits rows (edit `parsed`, set status 'approved').
--   4. rpc('import_publish_batch', {p_batch_id, p_activate}) creates the
--      organisations, services, categories, municipalities and rules.
--
-- All parsing is deterministic SQL – no AI involved.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Extra service fields that the source lists contain
-- ---------------------------------------------------------------------
alter table public.services
  add column if not exists eligibility_notes text,   -- original "Voraussetzung" text, always shown to users
  add column if not exists cost_notes        text,   -- original "Kosten" text
  add column if not exists external_ref      text,   -- e.g. "Nr." from a partner list
  add column if not exists has_flyer         boolean;

-- ---------------------------------------------------------------------
-- 1. Eligibility: city residents also count as canton residents,
--    and the new 'municipality' rule type is supported.
--    Profile example: {"place_of_residence":"city_of_lucerne","municipality":"luzern"}
-- ---------------------------------------------------------------------
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
  matched as (
    select r.*,
           person_value is not null and (
             lower(person_value) = lower(value)
             or (rule_type = 'place_of_residence'
                 and lower(value) = 'canton_of_lucerne'
                 and lower(person_value) = 'city_of_lucerne')
           ) as hit
    from rules r
  ),
  excl as (
    select explanation from matched where condition = 'excludes' and hit
  ),
  req as (
    select rule_type,
           bool_or(hit)                             as ok,
           max(person_value) is null                as missing,
           string_agg(distinct explanation, ' / ')  as explanation
    from matched
    where condition = 'requires'
    group by rule_type
  )
  select
    not exists (select 1 from excl)
      and not exists (select 1 from req where not missing and not ok) as eligible,
    exists (select 1 from req where missing)
      or exists (select 1 from matched where condition = 'excludes' and person_value is null) as unknown,
    coalesce(array(
      select explanation from excl
      union all
      select explanation from req where not missing and not ok
      union all
      select explanation from matched where person_value is null
    ), '{}') as reasons;
$$;

-- ---------------------------------------------------------------------
-- 2. Types
-- ---------------------------------------------------------------------
create type public.import_batch_status as enum ('staged', 'partly_published', 'published', 'discarded');

create type public.import_row_status as enum (
  'section',       -- a heading row (e.g. "Sozialberatung"), used as category hint
  'note',          -- a one-cell row that was merged into the row above
  'ready',         -- parsed cleanly, can be published
  'needs_review',  -- parsed, but an admin should check the issues
  'approved',      -- checked by an admin, can be published
  'duplicate',     -- same offer already in this file or in the database
  'skipped',       -- not an offer (empty / no name)
  'published'      -- turned into a service
);

-- ---------------------------------------------------------------------
-- 3. Configuration tables (editable by admins, no code change needed)
-- ---------------------------------------------------------------------

-- Spreadsheet header -> platform field. Matching ignores case, accents and spaces.
create table public.import_column_aliases (
  alias         text primary key,
  target_field  text not null check (target_field in (
    'section', 'external_ref', 'coverage_text', 'organisation_name', 'service_name',
    'description', 'contact_text', 'website', 'has_flyer', 'eligibility_text',
    'cost_text', 'opening_hours', 'address', 'postal_city'
  ))
);

insert into public.import_column_aliases (alias, target_field) values
  ('Art des Angebots', 'section'), ('Kategorie', 'section'), ('Bereich', 'section'), ('Rubrik', 'section'),
  ('Nr.', 'external_ref'), ('Nr', 'external_ref'), ('Nummer', 'external_ref'), ('ID', 'external_ref'),
  ('Ort/Zuständigkeit', 'coverage_text'), ('Zuständigkeit', 'coverage_text'), ('Ort', 'coverage_text'),
  ('Region', 'coverage_text'), ('Gebiet', 'coverage_text'), ('Einzugsgebiet', 'coverage_text'),
  ('Name', 'organisation_name'), ('Organisation', 'organisation_name'), ('Institution', 'organisation_name'),
  ('Anbieter', 'organisation_name'), ('Stelle', 'organisation_name'), ('Organisation / Institution', 'organisation_name'),
  ('Angebot', 'service_name'), ('Angebotsname', 'service_name'), ('Dienstleistung', 'service_name'),
  ('Kurzbeschreibung', 'description'), ('Beschreibung', 'description'), ('Thema', 'description'), ('Inhalt', 'description'),
  ('Kontakt', 'contact_text'), ('Kontakt/Website', 'contact_text'), ('Kontaktangaben', 'contact_text'),
  ('Telefon', 'contact_text'), ('E-Mail', 'contact_text'),
  ('Internet', 'website'), ('Website', 'website'), ('Webseite', 'website'), ('Homepage', 'website'),
  ('Link', 'website'), ('URL', 'website'),
  ('Flyer', 'has_flyer'),
  ('Voraussetzung', 'eligibility_text'), ('Voraussetzungen', 'eligibility_text'), ('Zielgruppe', 'eligibility_text'),
  ('Für wen', 'eligibility_text'), ('Zugang', 'eligibility_text'),
  ('Kosten', 'cost_text'), ('Preis', 'cost_text'), ('Gebühr', 'cost_text'),
  ('Öffnungszeiten / Zeiten Angebot', 'opening_hours'), ('Öffnungszeiten', 'opening_hours'),
  ('Zeiten', 'opening_hours'), ('Sprechzeiten', 'opening_hours'),
  ('Postadresse', 'address'), ('Adresse', 'address'), ('Strasse', 'address'),
  ('PLZ', 'postal_city'), ('PLZ/Ort', 'postal_city'), ('PLZ Ort', 'postal_city');

-- Section heading in a source list -> platform category
create table public.import_category_mappings (
  source_label   text primary key,
  category_slug  text not null references public.categories (slug) on update cascade on delete cascade
);
create index import_category_mappings_cat_idx on public.import_category_mappings (category_slug);

insert into public.import_category_mappings (source_label, category_slug) values
  -- Fabia Triageliste
  ('Allgemeine Hilfsangebote', 'counselling'),
  ('Sozialberatung', 'counselling'),
  ('Kirchliche Sozialberatung', 'counselling'),
  ('Sozial- und Rechtsberatung', 'counselling'),
  ('Rechtsberatung', 'counselling'),
  ('Sozialberatung Asyl', 'counselling'),
  ('Integrationsberatung', 'counselling'),
  ('Lese- und Schreibdienst', 'counselling'),
  ('Spezialisierte Beratung', 'counselling'),
  ('Selbsthilfe', 'health'),
  ('Schuldenberatung', 'finances'),
  ('Übersetzungsbüro', 'counselling'),
  ('Ombudsstelle', 'counselling'),
  ('Ärzte', 'health'),
  ('Finanzierung Deutschkurse', 'german-courses'),
  ('Stiftung', 'finances'),
  -- Sentitreff Institutionentabelle
  ('Bildung, Deutsch lernen und Austausch/Treffen', 'german-courses'),
  ('Schreibdienste und Beratungsstellen', 'counselling'),
  ('Familie & Kinder', 'family'),
  ('Gewalt', 'counselling');

-- Richer keywords so rows without a mapped heading still get a category
update public.categories set keywords = '{deutsch,german,deutschkurs,sprachkurs,sprachcafe,sprache,language}'
  where slug = 'german-courses';
update public.categories set keywords = keywords || '{religi,kultur,gemeinschaft,community,cafe,treff,begegnung,moschee,kirche,frauen,musik,chor,kunst,tanz}'
  where slug = 'community';
update public.categories set keywords = keywords || '{gewalt,opfer,schreibdienst,briefe,formular,ombuds,anlaufstelle,rechtsauskunft}'
  where slug = 'counselling';
update public.categories set keywords = keywords || '{eltern,jugend,mutter,vater,baby,spielgruppe,kesb}'
  where slug = 'family';
update public.categories set keywords = keywords || '{stellensuch,bewerbung,erwerbslos,arbeitslos,lebenslauf,selbstandig}'
  where slug = 'work';
update public.categories set keywords = keywords || '{sucht,psychisch,beeintrachtigung,behinderung,arzt,praxis}'
  where slug = 'health';
update public.categories set keywords = keywords || '{schulden,finanz,kultur-legi,kulturlegi,gutschein,stiftung}'
  where slug = 'finances';
update public.categories set keywords = keywords || '{migrationsamt,asyl,fluchtling,aufenthalt}'
  where slug = 'permits';

-- ---------------------------------------------------------------------
-- 4. Staging tables
-- ---------------------------------------------------------------------
create table public.import_batches (
  id            uuid primary key default gen_random_uuid(),
  file_name     text not null,
  sheet_name    text,
  storage_path  text,                          -- original file in the private 'imports' bucket
  header_row    int,
  column_map    jsonb not null default '{}'::jsonb,  -- {"0":"section","3":"organisation_name",...}
  status        public.import_batch_status not null default 'staged',
  source_id     uuid references public.sources (id) on delete set null,
  uploaded_by   uuid references auth.users (id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now(),
  published_at  timestamptz
);
create index import_batches_source_idx on public.import_batches (source_id);
create index import_batches_uploaded_by_idx on public.import_batches (uploaded_by);

create table public.import_rows (
  id               uuid primary key default gen_random_uuid(),
  batch_id         uuid not null references public.import_batches (id) on delete cascade,
  row_number       int not null,                -- row number in the spreadsheet (1-based)
  section          text,                        -- current section heading
  raw              jsonb not null,              -- {"<header>": "<cell>", ...} exactly as in the file
  fields           jsonb not null default '{}'::jsonb,  -- mapped by alias: {"organisation_name": ..., ...}
  parsed           jsonb not null default '{}'::jsonb,  -- platform structure, editable by admins
  status           public.import_row_status not null default 'needs_review',
  issues           text[] not null default '{}',        -- "review: ..." blocks publishing, "info: ..." does not
  organisation_id  uuid references public.organisations (id) on delete set null,
  service_id       uuid references public.services (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (batch_id, row_number)
);
create index import_rows_status_idx on public.import_rows (batch_id, status);
create index import_rows_org_idx on public.import_rows (organisation_id);
create index import_rows_service_idx on public.import_rows (service_id);

create trigger import_rows_updated_at before update on public.import_rows
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- 5. Private helper functions (not exposed through the API)
-- ---------------------------------------------------------------------
create or replace function private.assert_admin()
returns void
language plpgsql
stable
set search_path = public
as $$
begin
  if not (private.is_admin() or current_user in ('postgres', 'service_role', 'supabase_admin')) then
    raise exception 'Only administrators can import data' using errcode = '42501';
  end if;
end;
$$;

-- lower-case, no accents, single spaces
create or replace function private.norm(t text)
returns text
language sql
stable
set search_path = public, extensions
as $$
  select nullif(trim(regexp_replace(lower(extensions.unaccent(coalesce(t, ''))), '\s+', ' ', 'g')), '');
$$;

-- text cleanup: trim lines, drop empty lines, join with ", " (or keep newlines)
create or replace function private.clean(t text, p_sep text default ', ')
returns text
language sql
immutable
as $$
  select nullif(array_to_string(array(
    select trim(both from x) from regexp_split_to_table(coalesce(t, ''), '\s*\n\s*') x
    where trim(both from x) not in ('', '–', '-', '|')
  ), p_sep), '');
$$;

create or replace function private.slugify(t text)
returns text
language sql
stable
set search_path = public, extensions
as $$
  select left(trim(both '-' from regexp_replace(
           lower(extensions.unaccent(coalesce(t, ''))), '[^a-z0-9]+', '-', 'g')), 60);
$$;

create or replace function private.extract_emails(t text)
returns text[]
language sql
immutable
as $$
  select coalesce(array_agg(distinct lower(m[1])), '{}')
  from regexp_matches(coalesce(t, ''), '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})', 'g') m;
$$;

create or replace function private.extract_urls(t text)
returns text[]
language sql
immutable
as $$
  select coalesce(array_agg(u order by pos), '{}') from (
    select distinct on (u) u, pos from (
      select case when m[1] ~* '^https?://' then m[1] else 'https://' || m[1] end as u,
             row_number() over () as pos
      from regexp_matches(coalesce(t, ''),
             '((?:https?://|www\.)[^\s,;<>"]+|(?<![@A-Za-z0-9._-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:ch|com|org|net|info|swiss|lu|de|it)(?:/[^\s,;<>"]*)?)',
             'g') m
    ) x
    order by u, pos
  ) y;
$$;

create or replace function private.extract_phones(t text)
returns text[]
language sql
immutable
as $$
  select coalesce(array_agg(distinct regexp_replace(trim(m[1]), '\s+', ' ', 'g')), '{}')
  from regexp_matches(coalesce(t, ''),
         '((?:\+41|0041)\s?(?:\(0\)\s?)?\d{2}\s?\d{3}\s?\d{2}\s?\d{2}|0800\s?\d{3}\s?\d{3}|0\d{2}[\s-]?\d{3}[\s-]?\d{2}[\s-]?\d{2})',
         'g') m;
$$;

-- "Musterstrasse 3, 6003 Luzern" from free text
create or replace function private.extract_address(t text)
returns text
language sql
immutable
as $$
  select nullif(concat_ws(', ',
    substring(coalesce(t, '') from '([A-ZÄÖÜ][A-Za-zÄÖÜäöüéèß.\- ]*(?:strasse|str\.|weg|platz|quai|gasse|hof|matte|halde|rain|ring|allee|graben|berg|zentrum)\s*\d+[A-Za-z]?)'),
    substring(coalesce(t, '') from '(\m\d{4}\s+[A-ZÄÖÜ][A-Za-zÄÖÜäöüéè.\-]+(?:\s[A-ZÄÖÜ0-9][A-Za-zÄÖÜäöüéè.\-]*)?)')
  ), '');
$$;

-- cost text -> cost_type (+ issue)
create or replace function private.import_parse_cost(t text, out cost_type public.cost_type, out issue text)
language plpgsql
stable
as $$
declare
  n text := private.norm(t);
  v_free boolean; v_paid boolean; v_member boolean; v_varies boolean;
begin
  if n is null then
    cost_type := null; issue := 'info: no cost information'; return;
  end if;
  v_free   := n ~ '(kostenlos|gratis|unentgeltlich|\mfrei\M|^keine?\M)';
  v_paid   := n ~ '(\d+\s*(chf|fr\.|\.-|-)|\mchf\M|kostenpflichtig|unkostenbeitrag|unkostenbetrag|preis)';
  v_member := n ~ 'mitglied';
  v_varies := n ~ '(je nach|einkommen|unterschiedlich|gutschein|reduziert|verschieden)';
  cost_type := case
    when v_free and not (v_paid or v_member or v_varies) then 'free'
    when v_free then 'varies'
    when v_varies or v_member then 'varies'
    when v_paid then 'paid'
    else 'varies' end::public.cost_type;
  if n ~ '\?' or not (v_free or v_paid or v_member or v_varies) then
    issue := 'review: cost unclear ("' || left(t, 60) || '")';
  end if;
end;
$$;

-- coverage text -> geographical_coverage + municipality list
create or replace function private.import_parse_coverage(
  t text, out coverage public.geographical_coverage, out municipalities text[], out issue text)
language plpgsql
stable
as $$
declare
  n text := private.norm(t);
  tok text[];
begin
  municipalities := '{}';
  if n is null then
    coverage := 'canton_of_lucerne'; issue := 'info: area not given, assumed Canton of Lucerne'; return;
  end if;
  if n ~ 'online' then coverage := 'online';
  elsif n ~ '(zentralschweiz)' or (n ~ 'kanton' and n ~ '(nidwalden|obwalden|\mzug\M|\muri\M|schwyz)') then
    coverage := 'central_switzerland';
  elsif n ~ '^(stadt luzern|luzern)$' then coverage := 'city_of_lucerne';
  elsif n ~ '^kanton luzern$' then coverage := 'canton_of_lucerne';
  elsif n ~ 'kanton (zurich|bern|zug|aargau|basel|st\. ?gallen)' then
    coverage := 'switzerland'; issue := 'review: offer is based outside Lucerne ("' || t || '")';
  elsif n ~ 'schweiz' then coverage := 'switzerland';
  else
    tok := array(
      select initcap(trim(x)) from regexp_split_to_table(n, '\s*(,|/|\mund\M)\s*') x
      where trim(x) <> '' and trim(x) !~ '^(offen|region|bezirk)$'
    );
    if n ~ '\moffen\M' then
      coverage := 'canton_of_lucerne';
      issue := 'info: open to everyone, located in ' || array_to_string(tok, ', ');
    else
      coverage := 'specific_municipalities';
      municipalities := tok;
      issue := 'info: limited to ' || array_to_string(tok, ', ');
      if exists (select 1 from unnest(tok) x where private.norm(x) in ('bern', 'zurch', 'zurich', 'basel')) then
        issue := 'review: area includes places outside Lucerne ("' || t || '")';
      end if;
    end if;
  end if;
end;
$$;

-- eligibility text -> rules (deterministic patterns, conservative)
create or replace function private.import_parse_eligibility(t text, out rules jsonb, out issues text[])
language plpgsql
stable
as $$
declare
  n text := private.norm(t);
  v_open boolean;
  v_family boolean;
  v_cap text;
  v_letters text[];
  v_cond text;
  v_tok text[];
  v_place text;
  r jsonb := '[]'::jsonb;
  iss text[] := '{}';
begin
  rules := '[]'::jsonb; issues := '{}';
  if n is null then return; end if;

  v_open   := n ~ '^(keine|fur alle|offen fur alle|alle\M)';
  v_family := n ~ '(famil|eltern)';

  -- residence permits, e.g. "Ausweis N, F, B", "Aufenthaltsbewilligungen B, C, L und F", "(B- und F-Status)"
  v_cap := coalesce(
    substring(n from '(?:ausweis|status|aufenthaltsbewilligung(?:en)?|aufenthaltsstatus|bewilligung(?:en)?)\s*((?:\m[bcflnsg]\M(?:-?fl\.?)?\s*(?:,|/|und|oder)?\s*)+)'),
    substring(n from '((?:\m[bcflnsg]\M-?\s*(?:,|/|und|oder)?\s*)+)-?status'));
  if v_cap is not null then
    v_letters := array(select distinct upper(m[1]) from regexp_matches(v_cap, '\m([bcflnsg])\M', 'g') m order by 1);
    if array_length(v_letters, 1) > 0 then
      v_cond := case when n ~ '(keine personen|ausgeschlossen|nicht fur|nicht offen)[^.]{0,40}(ausweis|status|bewillig)'
                     then 'excludes' else 'requires' end;
      select r || jsonb_agg(jsonb_build_object(
               'rule_type', 'residence_status', 'condition', v_cond, 'value', l,
               'explanation', case when v_cond = 'excludes'
                                   then 'Nicht für Personen mit Ausweis ' || array_to_string(v_letters, ', ')
                                   else 'Nur für Personen mit Ausweis ' || array_to_string(v_letters, ', ') end))
        into r from unnest(v_letters) l;
      if v_cond = 'excludes' or n ~ '\d+ jahr' or n ~ '\mch\M' then
        iss := iss || ('review: check residence-permit rule (' || v_cond || ' ' || array_to_string(v_letters, ', ') || ')');
      end if;
    end if;
  end if;

  -- place of residence
  v_cap := substring(n from '(?:wohnsitz|wohnhaft|einwohner\w*|bewohner\w*|aus dem)\s*(?:in|im|der|des|von|dem)?\s*(?:der|dem|den)?\s*([^.(!|;]+)');
  if v_cap is not null then
    v_cap := regexp_replace(v_cap, '\m(mehr|siehe|genugend|deren|die|mit|ausgeschlossen|keine|vorprufung|wahrend)\M.*$', '');
    v_cap := regexp_replace(v_cap, '\m(kirchgemeinden?|gemeinden?|bezirk|stadt|einwohner\w*|bewohner\w*|der|dem|den|des)\M', '', 'g');
    v_cap := trim(regexp_replace(regexp_replace(v_cap, '\s+', ' ', 'g'), '^(und|in|im|,)\s*', ''));
    v_cap := trim(both ' ,' from v_cap);
    if v_cap ~ '^kanton\s*(luzern)?$' then
      v_place := 'canton_of_lucerne';
    elsif v_cap ~ '^kanton' then
      iss := iss || ('info: residence in several cantons ("' || left(t, 80) || '")');
    elsif v_cap ~ '^(luzern|stadtluzern|stadluzern)$' and n ~ '(stadt ?luzern|stadluzern)' then
      v_place := 'city_of_lucerne';
    else
      v_tok := array(
        select distinct case when trim(x) in ('stadtluzern', 'stadluzern') then 'luzern' else trim(x) end
        from regexp_split_to_table(v_cap, '\s*(,|/|\mund\M)\s*') x
        where trim(x) ~ '^[a-z][a-z .-]{1,30}$' and trim(x) !~ '\m(personen|alle|menschen)\M');
      if array_length(v_tok, 1) > 0 then
        select r || jsonb_agg(jsonb_build_object(
                 'rule_type', 'municipality', 'condition', 'requires', 'value', m,
                 'explanation', 'Nur für Personen mit Wohnsitz in: ' || array_to_string(array(select initcap(x) from unnest(v_tok) x), ', ')))
          into r from unnest(v_tok) m;
        if array_length(v_tok, 1) > 1 or v_tok = '{luzern}'
           or exists (select 1 from unnest(v_tok) x where x !~ '^[a-z]+( [a-z]+)?$') then
          iss := iss || ('review: check municipality list (' || array_to_string(v_tok, ', ') || ')');
        end if;
      end if;
    end if;
    if v_place is not null then
      r := r || jsonb_build_array(jsonb_build_object(
             'rule_type', 'place_of_residence', 'condition', 'requires', 'value', v_place,
             'explanation', case v_place when 'city_of_lucerne' then 'Nur für Personen mit Wohnsitz in der Stadt Luzern'
                                         else 'Nur für Personen mit Wohnsitz im Kanton Luzern' end));
    end if;
  end if;

  -- gender
  if not v_family then
    if n ~ '\m(frauen|migrantinnen|schwangere)\M' and n !~ '\m(manner|vater)\M' and n !~ 'alle religionen|frauen und manner' then
      r := r || jsonb_build_array(jsonb_build_object('rule_type', 'gender', 'condition', 'requires',
             'value', 'female', 'explanation', 'Angebot für Frauen'));
    elsif n ~ '\m(manner|vater)\M' and n !~ '\mfrauen\M' then
      r := r || jsonb_build_array(jsonb_build_object('rule_type', 'gender', 'condition', 'requires',
             'value', 'male', 'explanation', 'Angebot für Männer'));
    end if;
  end if;

  -- age
  if not v_family and n !~ 'vor dem ahv' then
    if n ~ '(ab 18|altersjahr 18|\merwachsene|volljahrig)' and n !~ 'kinder' then
      r := r || jsonb_build_array(jsonb_build_object('rule_type', 'age_group', 'condition', 'requires',
             'value', 'adult', 'explanation', 'Nur für Erwachsene (ab 18)'));
    elsif n ~ '(^fur kinder|^kinder\M|kinder ab|kinder und jugendliche)' then
      r := r || jsonb_build_array(jsonb_build_object('rule_type', 'age_group', 'condition', 'requires',
             'value', 'child', 'explanation', 'Angebot für Kinder'));
    elsif n ~ '(ab 60|senior|altere menschen|ab ahv)' then
      r := r || jsonb_build_array(jsonb_build_object('rule_type', 'age_group', 'condition', 'requires',
             'value', 'senior', 'explanation', 'Angebot für ältere Menschen'));
    end if;
  end if;

  -- no residence permit (sans-papiers)
  if n ~ '(ohne (gultige )?aufenthalts|sans.?papiers|ohne aufenthaltsrecht)' then
    r := r || jsonb_build_array(jsonb_build_object('rule_type', 'residence_status', 'condition', 'requires',
           'value', 'none', 'explanation', 'Für Menschen ohne gültige Aufenthaltsbewilligung'));
  end if;

  -- social assistance provider
  if n ~ '(werden an (die )?daf verwiesen|nicht fur personen.*daf)' then
    r := r || jsonb_build_array(jsonb_build_object('rule_type', 'social_assistance_provider', 'condition', 'excludes',
           'value', 'daf', 'explanation', 'Nicht für Personen, die von der DAF betreut werden (Verweis an DAF)'));
    iss := iss || 'review: check DAF exclusion'::text;
  elsif n ~ '(uber die dienststelle asyl|zuweisung durch sozialdienst des daf|betreut sind)' then
    r := r || jsonb_build_array(jsonb_build_object('rule_type', 'social_assistance_provider', 'condition', 'requires',
           'value', 'daf', 'explanation', 'Nur für Personen, die von der DAF betreut werden'));
    iss := iss || 'review: check DAF requirement'::text;
  end if;
  if n ~ '(ohne wsh|ohne (wirtschaftliche )?sozialhilfe)' then
    r := r || jsonb_build_array(jsonb_build_object('rule_type', 'social_assistance_provider', 'condition', 'excludes',
           'value', 'municipal', 'explanation', 'Nicht für Personen mit wirtschaftlicher Sozialhilfe der Gemeinde'));
    iss := iss || 'review: check social-assistance exclusion'::text;
  end if;

  -- other exclusions we cannot turn into rules
  if n ~ '(ausgeschlossen|ausgenommen|keine personen|nicht fur)' and not exists (
       select 1 from jsonb_array_elements(r) e where e->>'condition' = 'excludes') then
    iss := iss || 'review: text mentions an exclusion that is not a rule yet'::text;
  end if;
  if n ~ 'mitgliedschaft' then
    iss := iss || 'info: membership required'::text;
  end if;
  if jsonb_array_length(r) = 0 and not v_open then
    iss := iss || 'info: target group kept as text only'::text;
  end if;

  rules := r; issues := iss;
end;
$$;

-- category: section mapping first, keywords second
create or replace function private.import_guess_category(
  p_section text, p_text text, out category_slug text, out extra_slugs text[])
language plpgsql
stable
set search_path = public
as $$
declare
  n text := private.norm(concat_ws(' ', p_section, p_text));
begin
  select m.category_slug into category_slug
  from public.import_category_mappings m
  where private.norm(m.source_label) = private.norm(p_section);

  extra_slugs := array(
    select c.slug from public.categories c
    cross join lateral (
      -- longer (more specific) keywords weigh more
      select coalesce(sum(length(private.norm(k))), 0) as hits from unnest(c.keywords) k
      where n like '%' || private.norm(k) || '%'
    ) s
    where s.hits > 0
    order by s.hits desc, c.sort_order
  );
  if category_slug is null then
    category_slug := extra_slugs[1];
  end if;
  extra_slugs := array(select x from unnest(extra_slugs) x where x is distinct from category_slug limit 2);
end;
$$;

-- one row: mapped fields -> parsed platform structure
create or replace function private.import_parse_row(p_fields jsonb, p_section text, out parsed jsonb, out issues text[])
language plpgsql
stable
set search_path = public
as $$
declare
  f_org      text := private.clean(p_fields->>'organisation_name', ' ');
  f_service  text := private.clean(p_fields->>'service_name', ' ');
  f_desc     text := private.clean(concat_ws(E'\n', p_fields->>'description', p_fields->>'notes'), ' ');
  f_contact  text := p_fields->>'contact_text';
  f_web      text := p_fields->>'website';
  f_addr     text := p_fields->>'address';
  f_plz      text := p_fields->>'postal_city';
  f_hours    text := p_fields->>'opening_hours';
  f_elig     text := private.clean(p_fields->>'eligibility_text', ' ');
  f_all      text;
  v_cost     record;
  v_cov      record;
  v_elig     record;
  v_cat      record;
  v_urls     text[];
  v_address  text;
  iss        text[] := '{}';
begin
  -- name
  if f_org is null and f_service is not null then f_org := f_service; end if;
  if f_org is null then
    iss := iss || 'review: no organisation name'::text;
  end if;

  -- columns that look shifted (contact data in the opening hours / address column)
  if f_hours ~* '(@|https?://|www\.)' then
    iss := iss || 'review: opening hours column contains contact data (columns shifted?)'::text;
  end if;
  if f_plz is not null and f_plz !~ '^\s*\d{4}' then
    iss := iss || ('review: postcode column looks wrong ("' || left(f_plz, 40) || '")');
  end if;

  -- contact data
  f_all  := concat_ws(E'\n', f_contact, f_web, f_addr, f_plz, f_hours);
  v_urls := private.extract_urls(concat_ws(E'\n', f_web, f_contact));
  if f_addr is not null and private.norm(f_addr) !~ '^(internetseite|siehe webs?ite|je nach( dem)?|-|–)$' and f_addr !~* '(https?://|www\.|@)' then
    v_address := concat_ws(', ', private.clean(f_addr), private.clean(f_plz));
  else
    v_address := private.extract_address(concat_ws(E'\n', f_contact, f_addr, f_plz));
  end if;
  if coalesce(array_length(v_urls, 1), 0) = 0
     and coalesce(array_length(private.extract_emails(f_all), 1), 0) = 0
     and coalesce(array_length(private.extract_phones(f_all), 1), 0) = 0 then
    iss := iss || 'review: no website, email or phone found'::text;
  end if;
  if f_web is not null and coalesce(array_length(private.extract_urls(f_web), 1), 0) = 0 then
    iss := iss || ('info: website column is not a link ("' || left(f_web, 40) || '")');
  end if;

  -- cost, coverage, eligibility, category
  if p_fields ? 'cost_text' then
    select * into v_cost from private.import_parse_cost(p_fields->>'cost_text');
  else
    -- no cost column: only take a clear statement from the description
    select * into v_cost from private.import_parse_cost(
      substring(private.norm(f_desc) from '(kostenlos|gratis|unentgeltlich|kostenpflichtig)'));
    v_cost.issue := null;
  end if;
  select * into v_cov  from private.import_parse_coverage(p_fields->>'coverage_text');
  select * into v_elig from private.import_parse_eligibility(
    coalesce(f_elig, case when private.norm(f_desc) ~ '(voraussetzung|nur fur|wohnhaft in|ausgeschlossen)' then f_desc end));
  select * into v_cat  from private.import_guess_category(p_section, concat_ws(' ', f_org, f_service, f_desc, f_elig));

  -- no area column: derive the area from residence rules
  if p_fields->>'coverage_text' is null then
    if exists (select 1 from jsonb_array_elements(v_elig.rules) e
               where e->>'rule_type' = 'place_of_residence' and e->>'value' = 'city_of_lucerne') then
      v_cov.coverage := 'city_of_lucerne'; v_cov.issue := null;
    elsif exists (select 1 from jsonb_array_elements(v_elig.rules) e where e->>'rule_type' = 'municipality') then
      v_cov.coverage := 'specific_municipalities'; v_cov.issue := null;
      v_cov.municipalities := array(select initcap(e->>'value') from jsonb_array_elements(v_elig.rules) e
                                    where e->>'rule_type' = 'municipality');
    end if;
  end if;

  if v_cost.issue is not null then iss := iss || v_cost.issue; end if;
  if v_cov.issue  is not null then iss := iss || v_cov.issue;  end if;
  iss := iss || v_elig.issues;
  if v_cat.category_slug is null then
    iss := iss || 'review: no category found'::text;
  end if;

  parsed := jsonb_strip_nulls(jsonb_build_object(
    'organisation_name',  f_org,
    'service_name',       coalesce(f_service, f_org),
    'short_description',  case when length(f_desc) > 280
                               then left(f_desc, 277) || '…' else f_desc end,
    'full_description',   case when length(f_desc) > 280 then f_desc end,
    'category_slug',      v_cat.category_slug,
    'extra_category_slugs', to_jsonb(v_cat.extra_slugs),
    'website',            v_urls[1],
    'emails',             to_jsonb(private.extract_emails(f_all)),
    'phones',             to_jsonb(private.extract_phones(f_all)),
    'address',            v_address,
    'opening_hours',      private.clean(f_hours, '; '),
    'cost_type',          v_cost.cost_type,
    'cost_notes',         private.clean(p_fields->>'cost_text', ' '),
    'geographical_coverage', v_cov.coverage,
    'municipalities',     to_jsonb(v_cov.municipalities),
    'eligibility_notes',  f_elig,
    'rules',              v_elig.rules,
    'has_flyer',          case when private.norm(p_fields->>'has_flyer') ~ '^(ja|yes|x)' then true
                               when private.norm(p_fields->>'has_flyer') ~ '^(nein|no)' then false end,
    'external_ref',       private.clean(p_fields->>'external_ref', ' ')
  ));
  issues := iss;
end;
$$;

-- whole batch: parse, de-duplicate, name services, set status
create or replace function private.import_parse_batch(p_batch_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  r record;
  p record;
  v_seen text[] := '{}';
  v_key text;
  v_dup uuid;
begin
  for r in
    select * from public.import_rows
    where batch_id = p_batch_id and status in ('ready', 'needs_review', 'duplicate', 'skipped')
    order by row_number
  loop
    select * into p from private.import_parse_row(r.fields, r.section);

    -- nothing usable at all
    if p.parsed->>'organisation_name' is null and p.parsed->>'short_description' is null
       and p.parsed->>'website' is null and coalesce(jsonb_array_length(p.parsed->'phones'), 0) = 0 then
      update public.import_rows set parsed = p.parsed, issues = p.issues, status = 'skipped' where id = r.id;
      continue;
    end if;

    -- duplicates inside the file
    v_key := coalesce(private.norm(p.parsed->>'organisation_name'), '') || '|' ||
             coalesce(private.norm(p.parsed->>'short_description'), '');
    if v_key = any (v_seen) then
      update public.import_rows set parsed = p.parsed,
             issues = p.issues || 'info: same offer appears earlier in this file'::text,
             status = 'duplicate' where id = r.id;
      continue;
    end if;
    v_seen := v_seen || v_key;

    -- duplicates already in the database
    select s.id into v_dup
    from public.services s join public.organisations o on o.id = s.organisation_id
    where private.norm(o.name) = private.norm(p.parsed->>'organisation_name')
      and coalesce(private.norm(s.short_description), '') = coalesce(private.norm(p.parsed->>'short_description'), '')
    limit 1;
    if v_dup is not null then
      update public.import_rows set parsed = p.parsed, service_id = v_dup,
             issues = p.issues || 'info: this offer already exists in the database'::text,
             status = 'duplicate' where id = r.id;
      continue;
    end if;

    update public.import_rows set
      parsed = p.parsed,
      issues = p.issues,
      status = case when exists (select 1 from unnest(p.issues) i where i like 'review:%')
                    then 'needs_review' else 'ready' end::public.import_row_status
    where id = r.id;
  end loop;

  -- same organisation with several offers in one file -> give each a distinct service name
  -- use the section when it tells the offers apart, otherwise the first words of the description
  update public.import_rows ir set parsed = jsonb_set(ir.parsed, '{service_name}', to_jsonb(
           (ir.parsed->>'organisation_name') || ' – ' ||
           case when d.sections = d.n and ir.section is not null then ir.section
                else coalesce(left(split_part(ir.parsed->>'short_description', '.', 1), 60), ir.section) end))
  from (
    select private.norm(parsed->>'organisation_name') as org,
           count(*) as n, count(distinct section) as sections
    from public.import_rows
    where batch_id = p_batch_id and status in ('ready', 'needs_review')
    group by 1 having count(*) > 1
  ) d
  where ir.batch_id = p_batch_id
    and ir.status in ('ready', 'needs_review')
    and private.norm(ir.parsed->>'organisation_name') = d.org
    and ir.parsed->>'service_name' = ir.parsed->>'organisation_name';
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Public API (admins only)
-- ---------------------------------------------------------------------

-- p_rows: JSON array of rows, each row an array of cell values (strings or null),
-- exactly what SheetJS returns with {header: 1, raw: false, defval: null}.
create or replace function public.import_stage_sheet(
  p_file_name    text,
  p_sheet_name   text,
  p_rows         jsonb,
  p_storage_path text default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_batch      uuid;
  v_header     int;
  v_best       int := 0;
  v_hits       int;
  v_map        jsonb := '{}'::jsonb;
  v_headers    text[];
  v_field      text;
  v_cell       text;
  v_row        jsonb;
  v_raw        jsonb;
  v_fields     jsonb;
  v_section    text;
  v_nonempty   int;
  v_prev       uuid;
  v_only       text;
  v_ncols      int;
  i int; j int;
begin
  perform private.assert_admin();

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'p_rows must be a non-empty array of rows';
  end if;

  -- 1. find the header row (most known column names in the first 15 rows)
  for i in 0 .. least(jsonb_array_length(p_rows), 15) - 1 loop
    select count(distinct a.target_field) into v_hits
    from jsonb_array_elements_text(p_rows -> i) e(v)
    join public.import_column_aliases a on private.norm(a.alias) = private.norm(e.v);
    if v_hits > v_best then v_best := v_hits; v_header := i; end if;
  end loop;
  if v_best < 3 then
    raise exception 'No header row found. Add your column names to import_column_aliases (e.g. Name, Kontakt, Website).';
  end if;

  -- 2. column map
  v_ncols := (select max(jsonb_array_length(x)) from jsonb_array_elements(p_rows) x);
  for j in 0 .. v_ncols - 1 loop
    v_cell := nullif(trim(p_rows -> v_header ->> j), '');
    v_headers[j + 1] := coalesce(v_cell, 'col_' || (j + 1));
    select a.target_field into v_field
    from public.import_column_aliases a where private.norm(a.alias) = private.norm(v_cell) limit 1;
    if v_field is not null and not exists (select 1 from jsonb_each_text(v_map) e where e.value = v_field) then
      v_map := v_map || jsonb_build_object(j::text, v_field);
    end if;
    v_field := null;
  end loop;
  -- an unnamed first column holds section headings
  if not exists (select 1 from jsonb_each_text(v_map) e where e.value = 'section')
     and nullif(trim(p_rows -> v_header ->> 0), '') is null then
    v_map := v_map || jsonb_build_object('0', 'section');
  end if;

  insert into public.import_batches (file_name, sheet_name, storage_path, header_row, column_map)
  values (p_file_name, p_sheet_name, p_storage_path, v_header + 1, v_map)
  returning id into v_batch;

  -- 3. data rows
  for i in v_header + 1 .. jsonb_array_length(p_rows) - 1 loop
    v_row := p_rows -> i;
    v_raw := '{}'::jsonb; v_fields := '{}'::jsonb; v_nonempty := 0; v_only := null;

    for j in 0 .. jsonb_array_length(v_row) - 1 loop
      v_cell := nullif(trim(v_row ->> j), '');
      if v_cell is not null then
        v_nonempty := v_nonempty + 1;
        v_only := v_cell;
        v_raw := v_raw || jsonb_build_object(coalesce(v_headers[j + 1], 'col_' || (j + 1)), v_cell);
        if v_map ? j::text then
          v_fields := v_fields || jsonb_build_object(v_map ->> j::text, v_cell);
        end if;
      end if;
    end loop;

    continue when v_nonempty = 0;

    -- section heading (alone) or section value carried down
    if v_fields ? 'section' then
      v_section := private.clean(v_fields ->> 'section', ' ');
      if v_nonempty = 1 then
        insert into public.import_rows (batch_id, row_number, section, raw, fields, status)
        values (v_batch, i + 1, v_section, v_raw, v_fields, 'section');
        continue;
      end if;
    end if;

    -- loose cells without a name (e.g. an extra phone number or opening time):
    -- a note that belongs to the row above
    if v_prev is not null and (v_nonempty = 1 or (
         v_nonempty <= 2 and not (v_fields ? 'organisation_name' or v_fields ? 'service_name'))) then
      update public.import_rows
      set fields = jsonb_set(fields, '{notes}', to_jsonb(concat_ws(E'\n', fields ->> 'notes',
                     (select string_agg(value, ' ') from jsonb_each_text(v_raw)))))
      where id = v_prev;
      insert into public.import_rows (batch_id, row_number, section, raw, fields, status)
      values (v_batch, i + 1, v_section, v_raw, v_fields, 'note');
      continue;
    end if;

    insert into public.import_rows (batch_id, row_number, section, raw, fields, status)
    values (v_batch, i + 1, v_section, v_raw, v_fields, 'needs_review')
    returning id into v_prev;
  end loop;

  perform private.import_parse_batch(v_batch);
  return v_batch;
end;
$$;

-- Re-run parsing after an admin edited `fields`, aliases or category mappings.
-- Rows already 'approved' or 'published' are left alone.
create or replace function public.import_reparse_batch(p_batch_id uuid)
returns void
language plpgsql
set search_path = public
as $$
begin
  perform private.assert_admin();
  perform private.import_parse_batch(p_batch_id);
end;
$$;

-- Overview for the admin screen
create or replace function public.import_batch_summary(p_batch_id uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'batch', to_jsonb(b) - 'column_map',
    'column_map', b.column_map,
    'counts', (select jsonb_object_agg(status, n) from (
                 select status, count(*) n from public.import_rows where batch_id = b.id group by status) s),
    'top_issues', (select jsonb_agg(x) from (
                 select regexp_replace(i, ' \(.*$|"[^"]*"', '') as issue, count(*) as n
                 from public.import_rows, unnest(issues) i
                 where batch_id = b.id and status in ('needs_review', 'ready')
                 group by 1 order by 2 desc limit 10) x)
  )
  from public.import_batches b where b.id = p_batch_id;
$$;

-- Create organisations, services, categories, municipalities and rules
-- from all rows with status 'ready' or 'approved'.
--   p_activate = false (default): services are created as 'draft' for a final check
--   p_activate = true: services go live immediately
create or replace function public.import_publish_batch(p_batch_id uuid, p_activate boolean default false)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  b        public.import_batches;
  r        record;
  v_org    uuid;
  v_svc    uuid;
  v_cat    uuid;
  v_muni   uuid;
  v_slug   text;
  v_name   text;
  v_orgs_created int := 0;
  v_services int := 0;
  v_rules  int := 0;
  x        text;
  rule     jsonb;
begin
  perform private.assert_admin();

  select * into b from public.import_batches where id = p_batch_id for update;
  if b.id is null then raise exception 'Import batch % not found', p_batch_id; end if;

  if b.source_id is null then
    insert into public.sources (source_name, source_type, import_date, last_checked_at)
    values (b.file_name, 'partner_import', now(), now())
    returning id into b.source_id;
    update public.import_batches set source_id = b.source_id where id = b.id;
  end if;

  for r in
    select * from public.import_rows
    where batch_id = p_batch_id and status in ('ready', 'approved')
    order by row_number
  loop
    v_name := r.parsed ->> 'organisation_name';
    if v_name is null then continue; end if;

    -- organisation: reuse when the name already exists
    select id into v_org from public.organisations
    where private.norm(name) = private.norm(v_name) limit 1;
    if v_org is null then
      insert into public.organisations (name, website, address, phone, email, organisation_type, verification_status)
      values (v_name, r.parsed ->> 'website', r.parsed ->> 'address',
              r.parsed -> 'phones' ->> 0, r.parsed -> 'emails' ->> 0,
              case when private.norm(v_name) ~ '(stadt luzern|gemeinde|sozialdienst [a-z]+$)' then 'city_service'
                   when private.norm(v_name) ~ '(kanton|dienststelle|\mdaf\M|amt fur)' then 'cantonal_service'
                   when private.norm(v_name) ~ '(kirch|pfarr|pastoral|seelsorge|moschee|dzemat)' then 'church'
                   when private.norm(v_name) ~ '(verein|association)' then 'association'
                   else 'other' end::public.organisation_type,
              'verified')
      returning id into v_org;
      v_orgs_created := v_orgs_created + 1;
    end if;

    select id into v_cat from public.categories where slug = r.parsed ->> 'category_slug';

    v_slug := private.slugify(r.parsed ->> 'service_name') || '-' || left(md5(r.id::text), 6);

    insert into public.services (
      slug, organisation_id, name, short_description, full_description, category_id,
      direct_url, contact_details, cost_type, appointment_required, available_languages,
      geographical_coverage, service_status, source_id, eligibility_notes, cost_notes,
      external_ref, has_flyer)
    values (
      v_slug, v_org, r.parsed ->> 'service_name', r.parsed ->> 'short_description',
      r.parsed ->> 'full_description', v_cat, r.parsed ->> 'website',
      jsonb_strip_nulls(jsonb_build_object(
        'phone', r.parsed -> 'phones' ->> 0, 'email', r.parsed -> 'emails' ->> 0,
        'phones', r.parsed -> 'phones', 'emails', r.parsed -> 'emails',
        'address', r.parsed ->> 'address', 'opening_hours', r.parsed ->> 'opening_hours')),
      coalesce((r.parsed ->> 'cost_type')::public.cost_type, 'varies'),
      coalesce(private.norm(concat_ws(' ', r.parsed ->> 'short_description', r.parsed ->> 'opening_hours'))
        ~ '(terminvereinbarung|voranmeldung|nach vereinbarung|anmeldung)', false),
      '{de}',
      coalesce((r.parsed ->> 'geographical_coverage')::public.geographical_coverage, 'canton_of_lucerne'),
      (case when p_activate then 'active' else 'draft' end)::public.service_status,
      b.source_id, r.parsed ->> 'eligibility_notes', r.parsed ->> 'cost_notes',
      r.parsed ->> 'external_ref', (r.parsed ->> 'has_flyer')::boolean)
    returning id into v_svc;
    v_services := v_services + 1;

    -- extra categories
    insert into public.service_categories (service_id, category_id)
    select v_svc, c.id from public.categories c
    where c.slug in (select jsonb_array_elements_text(coalesce(r.parsed -> 'extra_category_slugs', '[]')))
      and c.id is distinct from v_cat
    on conflict do nothing;

    -- municipalities
    for x in select jsonb_array_elements_text(coalesce(r.parsed -> 'municipalities', '[]')) loop
      select id into v_muni from public.municipalities where private.norm(municipality_name) = private.norm(x) limit 1;
      if v_muni is null then
        insert into public.municipalities (municipality_name, canton) values (initcap(x), 'LU')
        on conflict (municipality_name, canton) do update set municipality_name = excluded.municipality_name
        returning id into v_muni;
      end if;
      insert into public.service_municipalities (service_id, municipality_id) values (v_svc, v_muni)
      on conflict do nothing;
      v_muni := null;
    end loop;

    -- eligibility rules
    for rule in select jsonb_array_elements(coalesce(r.parsed -> 'rules', '[]')) loop
      insert into public.eligibility_rules (service_id, rule_type, condition, value, explanation, source_id, verified_at)
      values (v_svc, (rule ->> 'rule_type')::public.eligibility_rule_type,
              (rule ->> 'condition')::public.eligibility_condition,
              rule ->> 'value', rule ->> 'explanation', b.source_id,
              case when r.status = 'approved' then now() end)
      on conflict do nothing;
      v_rules := v_rules + 1;
    end loop;

    update public.import_rows set status = 'published', organisation_id = v_org, service_id = v_svc
    where id = r.id;
    v_org := null; v_cat := null;
  end loop;

  update public.import_batches set
    status = case when exists (select 1 from public.import_rows
                               where batch_id = p_batch_id and status in ('ready', 'approved', 'needs_review'))
                  then 'partly_published' else 'published' end::public.import_batch_status,
    published_at = now()
  where id = p_batch_id;

  return jsonb_build_object(
    'services_created', v_services,
    'organisations_created', v_orgs_created,
    'rules_created', v_rules,
    'still_needs_review', (select count(*) from public.import_rows
                           where batch_id = p_batch_id and status = 'needs_review'),
    'service_status', case when p_activate then 'active' else 'draft' end);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Security: import data is for admins only
-- ---------------------------------------------------------------------
alter table public.import_column_aliases    enable row level security;
alter table public.import_category_mappings enable row level security;
alter table public.import_batches           enable row level security;
alter table public.import_rows              enable row level security;

create policy "admins manage column aliases"    on public.import_column_aliases    for all to authenticated using (private.is_admin()) with check (private.is_admin());
create policy "admins manage category mappings" on public.import_category_mappings for all to authenticated using (private.is_admin()) with check (private.is_admin());
create policy "admins manage import batches"    on public.import_batches           for all to authenticated using (private.is_admin()) with check (private.is_admin());
create policy "admins manage import rows"       on public.import_rows              for all to authenticated using (private.is_admin()) with check (private.is_admin());

revoke execute on function public.import_stage_sheet(text, text, jsonb, text) from public, anon;
revoke execute on function public.import_reparse_batch(uuid)                 from public, anon;
revoke execute on function public.import_batch_summary(uuid)                 from public, anon;
revoke execute on function public.import_publish_batch(uuid, boolean)        from public, anon;
grant  execute on function public.import_stage_sheet(text, text, jsonb, text) to authenticated;
grant  execute on function public.import_reparse_batch(uuid)                 to authenticated;
grant  execute on function public.import_batch_summary(uuid)                 to authenticated;
grant  execute on function public.import_publish_batch(uuid, boolean)        to authenticated;

grant usage on schema private to authenticated;
grant execute on all functions in schema private to authenticated;
revoke execute on all functions in schema private from anon;
grant execute on function private.is_admin() to anon;

-- Private bucket for the original Excel files
insert into storage.buckets (id, name, public)
values ('imports', 'imports', false)
on conflict (id) do nothing;

create policy "admins read imports"   on storage.objects for select to authenticated using (bucket_id = 'imports' and private.is_admin());
create policy "admins upload imports" on storage.objects for insert to authenticated with check (bucket_id = 'imports' and private.is_admin());
create policy "admins delete imports" on storage.objects for delete to authenticated using (bucket_id = 'imports' and private.is_admin());
