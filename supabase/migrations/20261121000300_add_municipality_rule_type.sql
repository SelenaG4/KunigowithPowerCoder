-- Separate migration: a new enum value must be committed before it is used.
alter type public.eligibility_rule_type add value if not exists 'municipality';
