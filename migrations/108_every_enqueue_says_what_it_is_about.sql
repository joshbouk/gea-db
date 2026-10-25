-- 108 Every enqueue says what it is about.
--
-- The same mistake has now been made three times in three places, in
-- both directions. A timestamp in the key means no two requests ever
-- match, so three files produce three identical runs. No key at all
-- means every request matches the first one ever made, so a job runs
-- once and never again. Both look like the job is broken and neither
-- fails.
--
-- The rule is simple enough to state and has been forgotten anyway: a
-- job's key is what the job is about. Proposing mappings is about the
-- files that have been placed; a roll-up is about the analyses it
-- reads; identifying files is about the files nobody has placed.
--
-- A rule that depends on remembering is a rule that will be forgotten.
-- So two things here. Every enqueue moves behind a function that works
-- out its own key, including the last one that was written inline in
-- the service. And a check refuses any future function that calls the
-- enqueue without either a key or a guard against a run already in
-- flight.

create or replace function gea_enqueue_identification(p_engagement uuid)
returns table (run_id uuid, was_created boolean, files_waiting integer)
language plpgsql security definer set search_path = public as $fn$
declare v_unplaced integer; v_existing uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was started'
      using errcode = 'insufficient_privilege';
  end if;

  select count(*) into v_unplaced
    from artefact a
    join dataset d on d.artefact_id = a.id
   where a.engagement_id = p_engagement
     and a.purged_at is null
     and a.export_request_line_id is null
     and d.parse_status = 'parsed';

  files_waiting := v_unplaced;
  if v_unplaced = 0 then
    run_id := null; was_created := false; return next; return;
  end if;

  -- A run already waiting will see whatever arrived since, so there is
  -- nothing to add. Six files read together queue one identification.
  select id into v_existing from analysis_run
   where engagement_id = p_engagement and job_type = 'identify_files'
     and status in ('queued', 'running');
  if v_existing is not null then
    run_id := v_existing; was_created := false; return next; return;
  end if;

  return query
    select e.run_id, e.was_created, v_unplaced
      from gea_enqueue_run(p_engagement, 'identify_files', null, null, null,
                           null,
                           jsonb_build_object('unplaced', v_unplaced)) e;
end $fn$;

comment on function gea_enqueue_identification is
  'Queue the identification of every unplaced file, keyed on how many '
  'there are. A run already waiting sees whatever arrived since.';

insert into gea_migration (filename, note) values
  ('108_every_enqueue_says_what_it_is_about.sql',
   'Identification gets its own keyed enqueue, so every caller of '
   'gea_enqueue_run is a function the suite can check.')
on conflict do nothing;
