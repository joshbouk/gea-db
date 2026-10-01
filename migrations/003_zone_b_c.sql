-- 003 Zone B (engagement) and Zone C (evidence)

create type org_role          as enum ('gc','ga','admin');
create type engagement_role   as enum ('lead_consultant','consultant','lead_architect','architect','observer');
create type engagement_status as enum ('setup','evidence','scoring','roadmap','delivered','closed','abandoned');
create type task_type         as enum ('setup','request','intake','mapping','analysis','interview','scoring','review','deliverable','closeout');
create type task_status       as enum ('blocked','ready','in_progress','needs_review','complete','waived');
create type requirement_state as enum ('outstanding','satisfied','waived');
create type export_req_status as enum ('not_requested','requested','received','partial','refused','absent','substituted');
create type interview_status  as enum ('scheduled','held','cancelled','declined');
create type evidence_tier_t   as enum ('A','B','C','D');
create type tier_verdict      as enum ('pass','fail','not_applicable');
create type artefact_kind     as enum ('raw_export','transcript','client_document','surface_capture','aeo_output','prompt_output','generated_deliverable');
create type parse_status      as enum ('queued','parsed','failed');
create type mapping_confidence as enum ('high','medium','medium_low','low');
create type mapping_status    as enum ('proposed','auto_accepted','confirmed','corrected','unmapped');
create type capability_verdict as enum ('supported','partial','not_supported');
create type run_status        as enum ('queued','running','succeeded','failed','discarded');
create type validation_verdict as enum ('trust','retry','abandon');
create type metric_unit       as enum ('count','rate','currency','days','ratio');
create type delivered_by      as enum ('client','blend','joint');

create table app_user (
  id            uuid primary key default gen_random_uuid(),
  auth_subject  uuid not null unique,
  email         text not null unique,
  display_name  text not null,
  org_role      org_role not null,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

create table client (
  id             uuid primary key default gen_random_uuid(),
  company_name   text not null,
  tla            text,
  primary_domain text,
  country        text,
  created_at     timestamptz not null default now()
);

create table engagement (
  id                        uuid primary key default gen_random_uuid(),
  client_id                 uuid not null references client(id),
  instrument_version_id     uuid not null references instrument_version(id),
  parent_engagement_id      uuid references engagement(id),
  name                      text not null,
  motion_in_scope           text not null,
  window_start              date not null,
  window_end                date not null,
  sponsor_name              text,
  sponsor_role              text,
  current_stage             smallint not null default 1 check (current_stage between 1 and 4),
  status                    engagement_status not null default 'setup',
  kickoff_date              date,
  target_readout_date       date,
  score_frozen_at           timestamptz,
  frozen_by                 uuid references app_user(id),
  storage_prefix            text not null,
  locale                    text not null default 'en-GB',
  created_at                timestamptz not null default now(),
  constraint engagement_window_order check (window_end > window_start)
);

create table engagement_member (
  id                uuid primary key default gen_random_uuid(),
  engagement_id     uuid not null references engagement(id) on delete cascade,
  app_user_id       uuid not null references app_user(id),
  engagement_role   engagement_role not null,
  can_view_raw_data boolean not null default true,
  from_date         date not null default current_date,
  to_date           date,
  added_by          uuid references app_user(id),
  created_at        timestamptz not null default now()
);

-- RULE: at most one active lead consultant per engagement.
create unique index engagement_one_lead_consultant
  on engagement_member (engagement_id)
  where engagement_role = 'lead_consultant' and to_date is null;

create table delivered_intervention (
  id                     uuid primary key default gen_random_uuid(),
  engagement_id          uuid not null references engagement(id) on delete cascade,
  parent_roadmap_item_id uuid,
  title                  text not null,
  delivered_on           date not null,
  delivered_by           delivered_by not null,
  evidence_note          text,
  element_refs           text[],
  created_at             timestamptz not null default now()
);

create table task (
  id                    uuid primary key default gen_random_uuid(),
  engagement_id         uuid not null references engagement(id) on delete cascade,
  step_ref              text,
  title                 text not null,
  purpose               text,
  task_type             task_type not null,
  owner_engagement_role engagement_role,
  assignee_user_id      uuid references app_user(id),
  status                task_status not null default 'blocked',
  status_is_derived     boolean not null default true,
  element_refs          text[],
  analysis_key          text,
  blocking_reasons      jsonb not null default '[]'::jsonb,
  completed_at          timestamptz,
  completed_by          uuid references app_user(id),
  created_at            timestamptz not null default now()
);

create table population_count (
  id             uuid primary key default gen_random_uuid(),
  engagement_id  uuid not null references engagement(id) on delete cascade,
  key            text not null,
  value          integer not null check (value >= 0),
  -- RULE: an exclusion is never applied without being stated.
  exclusion_rule text not null check (length(btrim(exclusion_rule)) > 0),
  source_run_id  uuid,
  set_by         uuid references app_user(id),
  created_at     timestamptz not null default now(),
  unique (engagement_id, key)
);

create table evidence_tier (
  id                   uuid primary key default gen_random_uuid(),
  engagement_id        uuid not null unique references engagement(id) on delete cascade,
  tier                 evidence_tier_t not null,
  verdict              tier_verdict not null,
  coverage_rate_won    numeric,
  coverage_rate_lost   numeric,
  structure_consistent boolean,
  content_rates        jsonb,
  contemporaneity_rate numeric,
  score_ceiling        smallint not null check (score_ceiling between 0 and 5),
  source_run_id        uuid,
  determined_at        timestamptz not null default now()
);

create table export_request_line (
  id                 uuid primary key default gen_random_uuid(),
  engagement_id      uuid not null references engagement(id) on delete cascade,
  export_line_id     uuid not null references export_line(id),
  included           boolean not null default true,
  exclusion_reason   text,
  client_owner_name  text,
  client_owner_email text,
  due_date           date,
  status             export_req_status not null default 'not_requested',
  received_at        timestamptz,
  note               text,
  substitution_note  text,
  created_at         timestamptz not null default now(),
  unique (engagement_id, export_line_id)
);

create table interview (
  id                    uuid primary key default gen_random_uuid(),
  engagement_id         uuid not null references engagement(id) on delete cascade,
  interview_guide_id    uuid not null references interview_guide(id),
  interviewee_name      text,
  interviewee_role      text,
  scheduled_at          timestamptz,
  held_at               timestamptz,
  status                interview_status not null default 'scheduled',
  transcript_artefact_id uuid,
  synthesis_run_id      uuid,
  notes                 text,
  created_at            timestamptz not null default now()
);

-- Zone C -------------------------------------------------------------------

create table artefact (
  id                     uuid primary key default gen_random_uuid(),
  engagement_id          uuid not null references engagement(id) on delete cascade,
  kind                   artefact_kind not null,
  export_request_line_id uuid references export_request_line(id),
  original_filename      text not null,
  storage_path           text not null,
  content_type           text,
  byte_size              bigint,
  sha256                 text not null,
  row_count              integer,
  column_count           integer,
  is_row_data            boolean not null default false,
  purged_at              timestamptz,
  uploaded_by            uuid references app_user(id),
  created_at             timestamptz not null default now(),
  unique (engagement_id, sha256)
);

create table dataset (
  id                   uuid primary key default gen_random_uuid(),
  artefact_id          uuid not null unique references artefact(id) on delete cascade,
  parquet_object_path  text,
  row_count            integer,
  column_count         integer,
  primary_date_field   text,
  date_min             date,
  date_max             date,
  malformed_rows       integer not null default 0,
  parse_status         parse_status not null default 'queued',
  parse_errors         jsonb,
  created_at           timestamptz not null default now()
);

create table dataset_field_profile (
  id              uuid primary key default gen_random_uuid(),
  dataset_id      uuid not null references dataset(id) on delete cascade,
  field_name      text not null,
  inferred_type   text,
  populated_count integer not null,
  populated_rate  numeric not null,
  distinct_count  integer,
  top_value       text,
  top_value_share numeric,
  is_free_text    boolean not null default false,
  flags           text[],
  created_at      timestamptz not null default now(),
  unique (dataset_id, field_name)
);

create table field_mapping (
  id                    uuid primary key default gen_random_uuid(),
  engagement_id         uuid not null references engagement(id) on delete cascade,
  canonical_field_id    uuid not null references canonical_field(id),
  dataset_id            uuid references dataset(id),
  proposed_field_name   text,
  confirmed_field_name  text,
  confidence            mapping_confidence,
  evidence_note         text,
  candidate_alternatives jsonb,
  status                mapping_status not null default 'proposed',
  proposed_by_run_id    uuid,
  confirmed_by          uuid references app_user(id),
  confirmed_at          timestamptz,
  created_at            timestamptz not null default now(),
  unique (engagement_id, canonical_field_id)
);

create table analysis_run (
  id                   uuid primary key default gen_random_uuid(),
  engagement_id        uuid not null references engagement(id) on delete cascade,
  prompt_version_id    uuid references prompt_version(id),
  job_type             text not null,
  step_ref             text,
  input_artefact_ids   uuid[],
  input_hashes         text[],
  parameters           jsonb not null default '{}'::jsonb,
  population_count_id  uuid references population_count(id),
  status               run_status not null default 'queued',
  progress_done        integer,
  progress_total       integer,
  heartbeat_at         timestamptz,
  compute_output       jsonb,
  model_output_text    text,
  model_output_parsed  jsonb,
  model_name           text,
  model_version        text,
  input_tokens         integer,
  output_tokens        integer,
  cost_usd             numeric,
  validator_results    jsonb,
  validator_passed     boolean,
  is_stale             boolean not null default false,
  override_reason      text,
  overridden_by        uuid references app_user(id),
  idempotency_key      text unique,
  started_at           timestamptz,
  finished_at          timestamptz,
  error                text,
  accepted_by          uuid references app_user(id),
  accepted_at          timestamptz,
  discarded_reason     text,
  superseded_by_run_id uuid references analysis_run(id),
  created_at           timestamptz not null default now()
);

create table analysis_capability (
  id                uuid primary key default gen_random_uuid(),
  engagement_id     uuid not null references engagement(id) on delete cascade,
  analysis_key      text not null,
  verdict           capability_verdict not null,
  reason            text,
  supporting_fields text[],
  source_run_id     uuid references analysis_run(id),
  signed_off_by     uuid references app_user(id),
  created_at        timestamptz not null default now(),
  unique (engagement_id, analysis_key),
  -- RULE: an analysis is never marked supported without naming the fields.
  constraint capability_supported_needs_fields
    check (verdict <> 'supported' or (supporting_fields is not null and array_length(supporting_fields,1) > 0))
);

create table validation_set (
  id               uuid primary key default gen_random_uuid(),
  analysis_run_id  uuid not null references analysis_run(id) on delete cascade,
  records_reviewed integer not null check (records_reviewed > 0),
  human_labels     jsonb,
  model_labels     jsonb,
  agreement_rate   numeric,
  verdict          validation_verdict not null,
  reviewed_by      uuid references app_user(id),
  created_at       timestamptz not null default now()
);

create table metric (
  id                        uuid primary key default gen_random_uuid(),
  engagement_id             uuid not null references engagement(id) on delete cascade,
  metric_key                text not null,
  value                     numeric not null,
  unit                      metric_unit not null,
  denominator_population_id uuid references population_count(id),
  denominator_value         integer,
  source_run_id             uuid references analysis_run(id),
  element_refs              text[],
  created_at                timestamptz not null default now(),
  unique (engagement_id, metric_key),
  -- RULE: every rate states its denominator.
  constraint metric_rate_needs_denominator
    check (unit <> 'rate' or denominator_population_id is not null or denominator_value is not null)
);

create table engagement_requirement (
  id                        uuid primary key default gen_random_uuid(),
  engagement_id             uuid not null references engagement(id) on delete cascade,
  evidence_requirement_id   uuid not null references evidence_requirement(id),
  state                     requirement_state not null default 'outstanding',
  satisfied_by_run_id       uuid references analysis_run(id),
  satisfied_by_artefact_id  uuid references artefact(id),
  satisfied_by_interview_id uuid references interview(id),
  waiver_reason             text,
  waiver_consequence        text,
  waived_by                 uuid references app_user(id),
  waived_at                 timestamptz,
  created_at                timestamptz not null default now(),
  unique (engagement_id, evidence_requirement_id),
  constraint requirement_waiver_needs_reason
    check (state <> 'waived' or (waiver_reason is not null and length(btrim(waiver_reason)) > 0))
);

alter table interview
  add constraint interview_transcript_fk
  foreign key (transcript_artefact_id) references artefact(id),
  add constraint interview_synthesis_fk
  foreign key (synthesis_run_id) references analysis_run(id);

alter table population_count
  add constraint population_source_run_fk
  foreign key (source_run_id) references analysis_run(id);

alter table evidence_tier
  add constraint tier_source_run_fk
  foreign key (source_run_id) references analysis_run(id);

alter table field_mapping
  add constraint mapping_proposed_run_fk
  foreign key (proposed_by_run_id) references analysis_run(id);
