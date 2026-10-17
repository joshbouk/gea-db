-- 092 A roll-up is the evidence it read.
--
-- The roll-up was queued with no parameters at all, so every roll-up an
-- engagement ever asked for had the same key. The first one succeeded in
-- two seconds and has been returned to every press since, which the
-- screen reported as "already running" and which would have gone on
-- for ever.
--
-- That came from fixing the opposite fault an hour earlier: proposing
-- mappings carried a timestamp in its parameters, so no two calls could
-- ever match and three files produced three identical runs. Stripping the
-- parameters fixed that one and broke this one.
--
-- Neither extreme is right. A job's key should be what the job is about.
-- A roll-up is about the analyses it reads, so two roll-ups over the same
-- results are the same job and should collapse into one; a roll-up after
-- a new analysis is a different job and should run.
--
-- So the key carries a fingerprint of the evidence: how many analyses
-- have usable results and when the newest of them finished. Press it
-- twice and the second press finds the first. Run an analysis and press
-- it again and it works something new out.

create or replace function gea_enqueue_rollup(p_engagement uuid)
returns table (run_id uuid, was_created boolean, evidence_changed boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_count integer;
  v_newest timestamptz;
  v_params jsonb;
  v_existing uuid;
begin
  if not app_is_member(p_engagement) then
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

  -- Whether this is new work or work already done, which is what the
  -- screen needs to say the right thing.
  select id into v_existing from analysis_run
   where engagement_id = p_engagement and job_type = 'roll_up'
     and parameters = v_params
     and status not in ('failed', 'discarded') and not is_stale;

  return query
    select e.run_id, e.was_created, v_existing is null
      from gea_enqueue_run(p_engagement, 'roll_up', null, null, null, null,
                           v_params) e;
end $fn$;

comment on function gea_enqueue_rollup is
  'Queue a roll-up, keyed on the evidence it will read. Two presses over '
  'the same analysis results are the same job; a press after a new '
  'analysis is a different one. evidence_changed says which, so the '
  'screen can tell somebody their findings are already up to date rather '
  'than that something is still running.';

insert into gea_migration (filename, note) values
  ('092_a_rollup_is_its_evidence.sql',
   'A roll-up is keyed on the analyses it reads, so it collapses when '
   'nothing changed and runs again when something did.');
