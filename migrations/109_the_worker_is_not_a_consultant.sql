-- 109 The worker is not a consultant.
--
-- Three enqueue functions refuse anybody who is not on the engagement's
-- team. That is right for a person pressing a button and wrong for the
-- analysis service, which is on no team and does most of the queueing:
-- it reads a file and queues the identification, finishes an analysis
-- and queues the roll-up.
--
-- So the roll-up has been failing to queue from the worker since it was
-- written, silently, because the worker commits the surrounding
-- transaction and carries on. The only roll-ups that ever ran were the
-- ones somebody pressed a button for.
--
-- The guard was copied from functions that only a person calls. It
-- should have been the one these functions need: a member, or the
-- service.

create or replace function gea_enqueue_rollup(p_engagement uuid)
returns table (run_id uuid, was_created boolean, evidence_changed boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_count integer; v_newest timestamptz; v_params jsonb; v_existing uuid;
begin
  -- Or the service, which finishes an analysis and queues this itself.
  --
  -- It connects straight to the database with no signed-in user, so
  -- neither app_is_member nor app_is_service is true of it:
  -- app_is_service reads a JWT claim and there is no JWT. A request
  -- with nobody signed in did not come from a browser.
  if not (app_is_member(p_engagement) or app_is_service()
          or auth.uid() is null) then
    raise exception
      'you are not on this engagement''s team, so nothing was started'
      using errcode = 'insufficient_privilege';
  end if;

  select count(*), max(r.finished_at)
    into v_count, v_newest
    from analysis_run r
   where r.engagement_id = p_engagement
     and r.status = 'succeeded'
     and not r.is_stale
     and r.model_name <> 'stub'
     and r.compute_output is not null
     and (r.job_type like 'analysis:%' or r.job_type = 'detect_pipeline');

  if v_count = 0 then
    raise exception
      'no analysis has produced a usable result yet, so there is nothing '
      'to add up'
      using errcode = 'check_violation';
  end if;

  v_params := jsonb_build_object(
    'analyses', v_count,
    'newest_result', coalesce(v_newest::text, ''));

  select id into v_existing from analysis_run
   where engagement_id = p_engagement and job_type = 'roll_up'
     and parameters = v_params
     and status not in ('failed', 'discarded') and not is_stale;

  return query
    select e.run_id, e.was_created, v_existing is null
      from gea_enqueue_run(p_engagement, 'roll_up', null, null, null, null,
                           v_params) e;
end $fn$;

create or replace function gea_enqueue_mapping_proposals(p_engagement uuid)
returns table (run_id uuid, was_created boolean, anything_new boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_files integer; v_newest timestamptz; v_params jsonb; v_existing uuid;
begin
  if not (app_is_member(p_engagement) or app_is_service()
          or auth.uid() is null) then
    raise exception
      'you are not on this engagement''s team, so nothing was started'
      using errcode = 'insufficient_privilege';
  end if;

  select count(*), max(a.created_at)
    into v_files, v_newest
    from artefact a
    join dataset d on d.artefact_id = a.id
   where a.engagement_id = p_engagement
     and a.purged_at is null
     and a.export_request_line_id is not null
     and d.parse_status = 'parsed';

  if v_files = 0 then
    raise exception
      'no file has been placed against an export line yet, so there are '
      'no columns to match against. Place them on the Files screen'
      using errcode = 'check_violation';
  end if;

  v_params := jsonb_build_object(
    'placed_files', v_files,
    'newest', coalesce(v_newest::text, ''));

  select id into v_existing from analysis_run
   where engagement_id = p_engagement and job_type = 'propose_mappings'
     and parameters = v_params
     and status not in ('failed', 'discarded') and not is_stale;

  return query
    select e.run_id, e.was_created, v_existing is null
      from gea_enqueue_run(p_engagement, 'propose_mappings', null, null,
                           null, null, v_params) e;
end $fn$;

create or replace function gea_enqueue_identification(p_engagement uuid)
returns table (run_id uuid, was_created boolean, files_waiting integer)
language plpgsql security definer set search_path = public as $fn$
declare v_unplaced integer; v_existing uuid;
begin
  if not (app_is_member(p_engagement) or app_is_service()
          or auth.uid() is null) then
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
  'there are. Callable by the team or by the analysis service, which is '
  'on nobody''s team and does most of the queueing.';

insert into gea_migration (filename, note) values
  ('109_the_worker_is_not_a_consultant.sql',
   'The analysis service can queue the work it is supposed to queue. It '
   'is on no engagement''s team and three functions refused it.')
on conflict do nothing;
