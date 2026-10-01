-- 004 Zone D (scoring) and Zone E (output)

create type score_state       as enum ('unscored','provisional','final');
create type confidence_flag   as enum ('low','medium');
create type comparability     as enum ('comparable','recomputable','not_comparable');
create type challenge_state   as enum ('open','defended','conceded');
create type change_type       as enum ('unchanged','wording','threshold','substantive');
create type deliverable_kind  as enum ('effectiveness_report','handoff_annexe','roadmap','tco_model','measurement_set','readout_deck');
create type deliverable_state as enum ('draft','internal_review','sponsor_review','final','delivered');
create type feedback_class    as enum ('factual_correction','disagreement','scope_reopen');
create type owner_side        as enum ('client','blend','joint');

create table score (
  id             uuid primary key default gen_random_uuid(),
  engagement_id  uuid not null references engagement(id) on delete cascade,
  element_id     uuid not null references element(id),
  value          smallint check (value between 0 and 5),
  not_evidenced  boolean not null default false,
  ne_reason      text,
  confidence     confidence_flag,
  scoring_note   text,
  cap_applied    smallint check (cap_applied between 0 and 5),
  cap_reason     text,
  state          score_state not null default 'unscored',
  comparability  comparability,
  row_version    integer not null default 1,
  scored_by      uuid references app_user(id),
  scored_at      timestamptz,
  created_at     timestamptz not null default now(),
  unique (engagement_id, element_id),
  -- RULE: a score carries either a value or Not Evidenced, never both.
  constraint score_value_xor_ne
    check (not (value is not null and not_evidenced)),
  -- RULE: Not Evidenced states its reason.
  constraint score_ne_needs_reason
    check (not_evidenced = false or (ne_reason is not null and length(btrim(ne_reason)) > 0)),
  -- RULE: a score may not exceed a cap applied to it.
  constraint score_within_cap
    check (cap_applied is null or value is null or value <= cap_applied),
  -- RULE: a cap states its reason.
  constraint score_cap_needs_reason
    check (cap_applied is null or (cap_reason is not null and length(btrim(cap_reason)) > 0))
);

create table score_citation (
  id              uuid primary key default gen_random_uuid(),
  score_id        uuid not null references score(id) on delete cascade,
  analysis_run_id uuid references analysis_run(id),
  artefact_id     uuid references artefact(id),
  interview_id    uuid references interview(id),
  note            text,
  created_at      timestamptz not null default now(),
  -- RULE: a citation points at something retrievable.
  constraint citation_needs_a_source
    check (num_nonnulls(analysis_run_id, artefact_id, interview_id) >= 1)
);

create table challenge (
  id              uuid primary key default gen_random_uuid(),
  engagement_id   uuid not null references engagement(id) on delete cascade,
  element_id      uuid not null references element(id),
  analysis_run_id uuid references analysis_run(id),
  challenge_text  text not null,
  weakness_type   text,
  disposition     challenge_state not null default 'open',
  response_note   text,
  resolved_by     uuid references app_user(id),
  created_at      timestamptz not null default now(),
  constraint challenge_resolution_needs_note
    check (disposition = 'open' or (response_note is not null and length(btrim(response_note)) > 0))
);

create table score_revision (
  id             uuid primary key default gen_random_uuid(),
  score_id       uuid not null references score(id) on delete cascade,
  previous_value smallint,
  new_value      smallint,
  previous_ne    boolean,
  new_ne         boolean,
  reason         text not null,
  challenge_id   uuid references challenge(id),
  changed_by     uuid references app_user(id),
  created_at     timestamptz not null default now()
);

create table honesty_test (
  id                      uuid primary key default gen_random_uuid(),
  engagement_id           uuid not null unique references engagement(id) on delete cascade,
  question_one_answer     text not null check (length(btrim(question_one_answer)) > 0),
  question_two_answer     text not null check (length(btrim(question_two_answer)) > 0),
  recommendations_removed jsonb,
  completed_by            uuid references app_user(id),
  completed_at            timestamptz not null default now()
);

create table element_version_change (
  id                         uuid primary key default gen_random_uuid(),
  from_instrument_version_id uuid not null references instrument_version(id),
  to_instrument_version_id   uuid not null references instrument_version(id),
  element_ref                text not null,
  change_type                change_type not null,
  threshold_metric_key       text,
  note                       text,
  created_at                 timestamptz not null default now(),
  unique (from_instrument_version_id, to_instrument_version_id, element_ref),
  -- RULE: a threshold change names the metric that will be recompared.
  constraint change_threshold_needs_metric
    check (change_type <> 'threshold' or threshold_metric_key is not null)
);

-- Zone E -------------------------------------------------------------------

create table intervention (
  id                      uuid primary key default gen_random_uuid(),
  engagement_id           uuid not null references engagement(id) on delete cascade,
  title                   text not null,
  description             text,
  element_refs            text[] not null,
  consequence             text,
  downstream_stages_taxed text[],
  value_rating            smallint,
  effort_rating           smallint,
  priority_rank           smallint,
  source_run_id           uuid references analysis_run(id),
  created_at              timestamptz not null default now(),
  constraint intervention_needs_elements
    check (array_length(element_refs, 1) > 0)
);

create table roadmap_item (
  id                  uuid primary key default gen_random_uuid(),
  engagement_id       uuid not null references engagement(id) on delete cascade,
  intervention_id     uuid references intervention(id),
  title               text not null,
  phase               text,
  sequence_position   smallint,
  dependency          text not null,
  dependency_item_ids uuid[],
  duration_weeks      smallint,
  owner_side          owner_side,
  constraint_note     text,
  source_run_id       uuid references analysis_run(id),
  created_at          timestamptz not null default now()
);

create table tco_line (
  id                  uuid primary key default gen_random_uuid(),
  engagement_id       uuid not null references engagement(id) on delete cascade,
  category            text not null,
  vendor              text,
  item                text,
  year                smallint,
  annual_cost         numeric,
  seat_count          integer,
  source_artefact_id  uuid references artefact(id),
  is_open_input       boolean not null default false,
  buys_capability     boolean,
  note                text,
  created_at          timestamptz not null default now(),
  -- RULE: a populated cost traces to a source document, or it is an open input.
  constraint tco_cost_needs_source
    check (annual_cost is null or is_open_input or source_artefact_id is not null)
);

create table measurement_definition (
  id                   uuid primary key default gen_random_uuid(),
  engagement_id        uuid not null references engagement(id) on delete cascade,
  template_id          uuid references measurement_definition_template(id),
  metric_key           text not null,
  name                 text not null,
  definition           text,
  source_system        text,
  source_object        text,
  source_fields        text[],
  owning_function      text,
  cadence              text,
  is_computable        boolean not null,
  blocker_note         text,
  created_at           timestamptz not null default now(),
  unique (engagement_id, metric_key),
  -- RULE: a metric that is not computable names its blocker.
  constraint measurement_blocker_required
    check (is_computable or (blocker_note is not null and length(btrim(blocker_note)) > 0)),
  -- RULE: a computable metric names its source fields.
  constraint measurement_computable_needs_fields
    check (not is_computable or (source_fields is not null and array_length(source_fields,1) > 0))
);

create table deliverable (
  id             uuid primary key default gen_random_uuid(),
  engagement_id  uuid not null references engagement(id) on delete cascade,
  kind           deliverable_kind not null,
  version        text not null,
  artefact_id    uuid references artefact(id),
  source_run_ids uuid[],
  brand_record_id text,
  status         deliverable_state not null default 'draft',
  generated_at   timestamptz,
  delivered_at   timestamptz,
  created_at     timestamptz not null default now()
);

create table feedback_item (
  id                     uuid primary key default gen_random_uuid(),
  engagement_id          uuid not null references engagement(id) on delete cascade,
  source                 text not null,
  relates_to_score_id    uuid references score(id),
  relates_to_deliverable_id uuid references deliverable(id),
  body                   text not null,
  classification         feedback_class,
  action_taken           text,
  round_number           smallint,
  received_at            timestamptz not null default now()
);

create table library_record (
  id                        uuid primary key default gen_random_uuid(),
  engagement_id             uuid not null unique references engagement(id),
  instrument_version_id     uuid not null references instrument_version(id),
  segment_attributes        jsonb not null,
  ges                       numeric,
  handoff_integrity         smallint,
  ne_count                  smallint,
  low_confidence_count      smallint,
  icp_variance_rate         numeric,
  evidence_tier             text,
  snapshot                  jsonb not null,
  contains_identifiable_data boolean not null default false,
  created_at                timestamptz not null default now(),
  -- RULE: the permanent record carries no identifiable data.
  constraint library_no_identifiable_data
    check (contains_identifiable_data = false)
);

alter table delivered_intervention
  add constraint delivered_roadmap_fk
  foreign key (parent_roadmap_item_id) references roadmap_item(id);
