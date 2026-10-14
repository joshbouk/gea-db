-- 083 Stages named by number, and dates that are exits.
--
-- Written after looking at a real Salesforce export rather than a made-up
-- one, which found two conventions the first version missed entirely.
--
--   The stages are numbered. "1 - Discover & Qualify", "2 - Propose", and
--   the columns holding their dates are "Stage 1 Exit Date", "Stage 2 Exit
--   Date". Nothing in the column names the stage: the join is the number.
--   Matching on the name found one stage out of eleven.
--
--   The dates are exits, not entries. When a deal left a stage, not when
--   it arrived. Recording an exit as an entry would shift every stage by
--   one and quietly invent a duration.
--
-- Both are ordinary in Salesforce, so neither is a special case.

alter table deal_stage_entry
  add column exited_at date,
  alter column entered_at drop not null;

alter table deal_stage_entry
  add constraint deal_stage_entry_has_a_date
  check (entered_at is not null or exited_at is not null);

comment on column deal_stage_entry.entered_at is
  'When the deal arrived in this stage, where the client records it.';
comment on column deal_stage_entry.exited_at is
  'When it left. Several CRMs record only this, and an exit read as an '
  'entry shifts every stage by one and invents a duration.';

alter table pipeline_stage
  add column stage_number integer,
  add column date_kind text;

comment on column pipeline_stage.stage_number is
  'The number in the stage''s own name, where it has one. "2 - Propose" '
  'is 2, and its dates live in a column naming that number rather than '
  'the words.';
comment on column pipeline_stage.date_kind is
  'entered or exited, from what the column calls itself.';

alter table pipeline
  add column deals_with_any_stage_date integer not null default 0;

comment on column pipeline.deals_with_any_stage_date is
  'How many of the deals carry a date for any stage at all. On the first '
  'real export this was two hundred of fifteen hundred: the pipeline '
  'exists and almost nothing is timestamped, which is a finding about how '
  'it is managed rather than a gap in the export.';

insert into gea_migration (filename, note) values
  ('083_stages_by_number_and_by_exit.sql',
   'Stages joined by their number, and dates recorded as exits where that '
   'is what the client holds.');
