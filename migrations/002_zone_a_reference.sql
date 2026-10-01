-- 002 Zone A: methodology reference. Versioned as a set, pinned per engagement.

create type instrument_status as enum ('draft','active','retired');
create type element_kind      as enum ('element','handoff');
create type owner_role        as enum ('GC','GA');
create type execution_mode    as enum ('compute','hybrid','model','upload');
create type prompt_status     as enum ('draft','active','retired');
create type req_source_kind   as enum ('export','analysis','client_document','public_surface','external_upload','observation','interview');
create type response_lag      as enum ('immediate','one_quarter','one_sales_cycle','one_onboarding_cycle','one_renewal_cycle');

create table instrument_version (
  id             uuid primary key default gen_random_uuid(),
  label          text not null unique,
  runbook_label  text,
  status         instrument_status not null default 'draft',
  activated_at   timestamptz,
  retired_at     timestamptz,
  notes          text,
  created_by     uuid,
  created_at     timestamptz not null default now()
);

create table element (
  id                     uuid primary key default gen_random_uuid(),
  instrument_version_id  uuid not null references instrument_version(id) on delete cascade,
  ref                    text not null,
  kind                   element_kind not null,
  stage_code             text,
  from_stage             text,
  to_stage               text,
  name                   text not null,
  why_assessed           text,
  evidence_required      text,
  method                 text,
  owner_role             owner_role,
  support_role           text,
  fallback_rule          text,
  ne_permitted           boolean not null default true,
  tier_dependent         boolean not null default false,
  evidence_decays        boolean not null default false,
  has_retrievability_test boolean not null default false,
  sort_order             integer,
  created_at             timestamptz not null default now(),
  unique (instrument_version_id, ref),
  -- RULE: Not Evidenced is never permitted on a handoff.
  constraint element_handoff_no_ne check (kind <> 'handoff' or ne_permitted = false)
);

create table anchor (
  id          uuid primary key default gen_random_uuid(),
  element_id  uuid not null references element(id) on delete cascade,
  level       smallint not null check (level between 0 and 5),
  descriptor  text not null,
  created_at  timestamptz not null default now(),
  unique (element_id, level)
);

create table canonical_field (
  id                    uuid primary key default gen_random_uuid(),
  instrument_version_id uuid not null references instrument_version(id) on delete cascade,
  key                   text not null,
  description           text,
  expected_type         text,
  expected_domain       text,
  source_export_refs    text[],
  is_cap_bearing        boolean not null default false,
  cap_element_refs      text[],
  cap_rule              text,
  created_at            timestamptz not null default now(),
  unique (instrument_version_id, key)
);

create table export_line (
  id                    uuid primary key default gen_random_uuid(),
  instrument_version_id uuid not null references instrument_version(id) on delete cascade,
  tier                  smallint not null check (tier between 1 and 3),
  ref                   text not null,
  title                 text not null,
  hubspot_guidance      text,
  salesforce_guidance   text,
  scope_notes           text,
  default_included      boolean not null default true,
  created_at            timestamptz not null default now(),
  unique (instrument_version_id, ref)
);

create table export_line_element (
  id             uuid primary key default gen_random_uuid(),
  export_line_id uuid not null references export_line(id) on delete cascade,
  element_id     uuid not null references element(id) on delete cascade,
  created_at     timestamptz not null default now(),
  unique (export_line_id, element_id)
);

create table interview_guide (
  id                    uuid primary key default gen_random_uuid(),
  instrument_version_id uuid not null references instrument_version(id) on delete cascade,
  ref                   smallint not null,
  function_name         text not null,
  duration_minutes      smallint,
  preamble              text,
  is_rescore_set        boolean not null default false,
  created_at            timestamptz not null default now(),
  unique (instrument_version_id, ref, is_rescore_set)
);

create table interview_question (
  id                  uuid primary key default gen_random_uuid(),
  interview_guide_id  uuid not null references interview_guide(id) on delete cascade,
  section_title       text,
  sort_order          integer not null,
  question_text       text not null,
  is_closing          boolean not null default false,
  created_at          timestamptz not null default now()
);

create table interview_question_element (
  id                     uuid primary key default gen_random_uuid(),
  interview_question_id  uuid not null references interview_question(id) on delete cascade,
  element_id             uuid not null references element(id) on delete cascade,
  created_at             timestamptz not null default now(),
  unique (interview_question_id, element_id)
);

create table evidence_requirement (
  id                    uuid primary key default gen_random_uuid(),
  instrument_version_id uuid not null references instrument_version(id) on delete cascade,
  element_id            uuid not null references element(id) on delete cascade,
  ref                   text not null,
  source_kind           req_source_kind not null,
  export_line_refs      text[],
  interview_guide_id    uuid references interview_guide(id) on delete set null,
  analysis_key          text,
  description           text not null,
  is_mandatory          boolean not null default true,
  waiver_consequence    text not null,
  created_at            timestamptz not null default now(),
  unique (instrument_version_id, ref)
);

create table prompt_version (
  id                  uuid primary key default gen_random_uuid(),
  ref                 text not null,
  version             text not null,
  title               text not null,
  purpose             text,
  inputs_required     text,
  template            text not null,
  slots               text[],
  execution_mode      execution_mode not null,
  output_contract     jsonb not null default '{}'::jsonb,
  discard_conditions  jsonb not null default '[]'::jsonb,
  step_ref            text,
  owner_role          text,
  status              prompt_status not null default 'draft',
  created_at          timestamptz not null default now(),
  unique (ref, version)
);

create table aeo_prompt_template (
  id                    uuid primary key default gen_random_uuid(),
  instrument_version_id uuid not null references instrument_version(id) on delete cascade,
  ref                   text not null,
  category              text,
  buyer_intent          text,
  template              text not null,
  slots                 text[],
  created_at            timestamptz not null default now(),
  unique (instrument_version_id, ref)
);

create table measurement_definition_template (
  id                    uuid primary key default gen_random_uuid(),
  instrument_version_id uuid not null references instrument_version(id) on delete cascade,
  metric_key            text not null,
  name                  text not null,
  definition            text,
  formula               text,
  required_fields       text[],
  owning_function       text,
  cadence               text,
  lag                   response_lag not null,
  created_at            timestamptz not null default now(),
  unique (instrument_version_id, metric_key)
);
