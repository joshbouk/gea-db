-- 007 Zone A additions.
--
-- Five changes, all needed before the reference workbooks can be loaded:
--
--   1. R1 did not cover export_line_element, interview_question or
--      interview_question_element. All three were writable against an
--      activated instrument version. Proven by insert, not by reading.
--   2. Cap levels had nowhere to live. cap_element_refs is a text[] and
--      cap_rule is prose, so a field capping two elements at two different
--      levels could not be expressed.
--   3. The analysis field requirements had no reference table at all, so the
--      per-engagement capability verdict had nothing to compute against.
--   4. canonical_field held no display name, priority or served-element list.
--   5. measurement_definition_template dropped two columns the workbook carries.
--
-- Hand-written. Reviewed before running. A later migration that weakens any
-- rule here is rejected regardless of what prompted it.

-- 1. Extend the immutability trigger to the three tables it missed ----------

create or replace function trg_reference_draft_only() returns trigger
language plpgsql as $fn$
declare
  v_id uuid;
  v_status instrument_status;
  rec jsonb;
begin
  rec := to_jsonb(coalesce(new, old));

  if tg_table_name = 'instrument_version' then
    v_id := (rec ->> 'id')::uuid;

  elsif tg_table_name = 'anchor' then
    select instrument_version_id into v_id
      from element where id = (rec ->> 'element_id')::uuid;

  elsif tg_table_name = 'export_line_element' then
    select instrument_version_id into v_id
      from export_line where id = (rec ->> 'export_line_id')::uuid;

  elsif tg_table_name = 'interview_question' then
    select instrument_version_id into v_id
      from interview_guide where id = (rec ->> 'interview_guide_id')::uuid;

  elsif tg_table_name = 'interview_question_element' then
    select g.instrument_version_id into v_id
      from interview_question q
      join interview_guide g on g.id = q.interview_guide_id
     where q.id = (rec ->> 'interview_question_id')::uuid;

  elsif tg_table_name = 'canonical_field_cap' then
    select instrument_version_id into v_id
      from canonical_field where id = (rec ->> 'canonical_field_id')::uuid;

  else
    v_id := (rec ->> 'instrument_version_id')::uuid;
  end if;

  if v_id is null then
    return coalesce(new, old);
  end if;

  select status into v_status from instrument_version where id = v_id;

  -- The version row's own lifecycle transitions are the permitted exception.
  if tg_table_name = 'instrument_version' and tg_op = 'UPDATE' then
    if (to_jsonb(old) ->> 'status') = 'draft' then
      return new;
    end if;
    if (to_jsonb(old) ->> 'status') = 'active'
       and (to_jsonb(new) ->> 'status') = 'retired'
       and (to_jsonb(old) ->> 'label') is not distinct from (to_jsonb(new) ->> 'label') then
      return new;
    end if;
  end if;

  if v_status <> 'draft' then
    raise exception
      'instrument version % is % and is immutable: % on % rejected',
      v_id, v_status, tg_op, tg_table_name
      using errcode = 'check_violation';
  end if;

  return coalesce(new, old);
end $fn$;

do $do$
declare t text;
begin
  foreach t in array array[
    'export_line_element','interview_question','interview_question_element'
  ] loop
    execute format(
      'create trigger %I before insert or update or delete on %I
         for each row execute function trg_reference_draft_only()',
      t || '_draft_only', t);
  end loop;
end $do$;

-- 2. Cap levels, one row per field and element ------------------------------
-- A field may cap more than one element at more than one level. contact_role
-- caps 2.2 at 3 and 5.3 at 2, which a shared text[] cannot express.

create table canonical_field_cap (
  id                 uuid primary key default gen_random_uuid(),
  canonical_field_id uuid not null references canonical_field(id) on delete cascade,
  element_id         uuid not null references element(id) on delete cascade,
  cap_level          smallint not null check (cap_level between 0 and 5),
  condition          text not null check (length(btrim(condition)) > 0),
  created_at         timestamptz not null default now(),
  unique (canonical_field_id, element_id)
);

create trigger canonical_field_cap_draft_only
  before insert or update or delete on canonical_field_cap
  for each row execute function trg_reference_draft_only();

-- RULE: a cap belongs only to a field marked cap-bearing. Without this the
-- always-review behaviour and the cap behaviour can drift apart, which is how
-- three fields ended up flagged with no rule and one rule ended up with no
-- level.
create or replace function trg_cap_requires_cap_bearing() returns trigger
language plpgsql as $fn$
declare v_bearing boolean; v_key text;
begin
  select is_cap_bearing, key into v_bearing, v_key
    from canonical_field where id = new.canonical_field_id;
  if not v_bearing then
    raise exception 'canonical field % is not cap-bearing and cannot carry a cap rule', v_key
      using errcode = 'check_violation';
  end if;
  return new;
end $fn$;

create trigger cap_requires_cap_bearing
  before insert or update on canonical_field_cap
  for each row execute function trg_cap_requires_cap_bearing();

-- The array and the prose are superseded. They hold no data and leaving them
-- would give caps two sources of truth.
alter table canonical_field drop column cap_element_refs;
alter table canonical_field drop column cap_rule;

-- 3. Which canonical fields each analysis needs -----------------------------
-- The reference declaration behind analysis_capability. An analysis with no
-- rows here computes as supported with nothing supporting it.

create table analysis_field_requirement (
  id                    uuid primary key default gen_random_uuid(),
  instrument_version_id uuid not null references instrument_version(id) on delete cascade,
  analysis_key          text not null,
  canonical_field_id    uuid not null references canonical_field(id) on delete cascade,
  is_required           boolean not null,
  created_at            timestamptz not null default now(),
  unique (instrument_version_id, analysis_key, canonical_field_id)
);

create trigger analysis_field_requirement_draft_only
  before insert or update or delete on analysis_field_requirement
  for each row execute function trg_reference_draft_only();

-- 4. canonical_field: display name, priority, served elements ---------------

create type field_priority as enum ('core','supporting');

alter table canonical_field add column name text;
alter table canonical_field add column priority field_priority;
alter table canonical_field add column element_refs text[];

-- 5. measurement_definition_template: the two text columns it was missing ---

alter table measurement_definition_template add column why_it_matters text;
alter table measurement_definition_template add column computability_note text;
