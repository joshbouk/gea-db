-- 037 Reading a file leads to proposing its mappings.
--
-- Uploading is the decision. Everything after it is consequence, and a
-- consultant should not have to know that "propose_mappings" is a thing that
-- exists, let alone pick it from a list.
--
-- So when a file finishes being read, the mapping proposals are queued. The
-- chaining lives here rather than in the application because a file can arrive
-- more than one way, and the consequence should not depend on which screen
-- someone used.
--
-- The run carries the dataset that caused it in its parameters. Without that,
-- the idempotency rule would treat the second file's proposal run as identical
-- to the first file's and quietly skip it — so the deals export would land and
-- nothing would be proposed for it.

create or replace function trg_parsed_dataset_proposes_mappings() returns trigger
language plpgsql as $fn$
declare v_engagement uuid;
begin
  if new.parse_status <> 'parsed' then
    return null;
  end if;

  select a.engagement_id into v_engagement
    from artefact a where a.id = new.artefact_id and a.purged_at is null;

  if v_engagement is null then
    return null;  -- the file went away between reading and recording
  end if;

  perform gea_enqueue_run(
    v_engagement, 'propose_mappings', null, null, null, null,
    jsonb_build_object('after_dataset', new.id));

  return null;
end $fn$;

create trigger parsed_dataset_proposes_mappings
  after insert on dataset
  for each row execute function trg_parsed_dataset_proposes_mappings();

comment on function trg_parsed_dataset_proposes_mappings is
  'A file that has been read leads to its mappings being proposed. Carries the '
  'dataset in the run parameters so each file gets its own proposal run.';

insert into gea_migration (filename, note) values
  ('037_reading_leads_to_mapping.sql',
   'Reading a client file queues the mapping proposals, so uploading is the '
   'only decision a consultant makes.');
