-- 055 Starting an analysis.
--
-- Steps 2.1, 2.2 and 2.3 wait on analysis runs being accepted. Nothing in the
-- application could start one. The runs screen once had a control, removed
-- deliberately — choosing a job type from a dropdown is not work a consultant
-- should be doing — and nothing replaced it for the analyses a person really
-- does decide to run.
--
-- So the instruction said "run the public surface audit, then accept it" with
-- nowhere to do it.
--
-- Starting one is a decision, and it has conditions. An analysis the client's
-- data cannot support must never be launched: it would either fail or, worse,
-- quietly produce a figure from a field that is empty. And a second copy of a
-- run already in flight is waste, not reassurance.

create or replace function gea_start_analysis(
  p_engagement uuid, p_analysis_key text)
returns table (run_id uuid, was_created boolean)
language plpgsql security definer set search_path = public as $fn$
declare v_verdict capability_verdict; v_reason text; v_existing uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was started'
      using errcode = 'insufficient_privilege';
  end if;

  select verdict, reason into v_verdict, v_reason
    from analysis_capability
   where engagement_id = p_engagement and analysis_key = p_analysis_key;

  -- Capability governs the analyses that consume the client's exported
  -- fields. Some do not: the public surface audit reads the client's own
  -- website and the answer engines, and needs nothing from their CRM. Those
  -- have no field requirements and no capability verdict, and refusing them
  -- for want of one would block work that has nothing to wait for.
  if v_verdict is null then
    if exists (select 1 from analysis_field_requirement r
                join engagement e on e.id = p_engagement
                                 and e.instrument_version_id = r.instrument_version_id
               where r.analysis_key = p_analysis_key) then
      raise exception
        'whether the data supports % has not been worked out. Recompute the '
        'capability table first', p_analysis_key
        using errcode = 'check_violation';
    end if;
  end if;

  if v_verdict = 'not_supported'::capability_verdict then
    raise exception
      'the data cannot support %. %', p_analysis_key, coalesce(v_reason, '')
      using errcode = 'check_violation';
  end if;

  -- One at a time. A second copy of a run in flight tells nobody anything.
  select id into v_existing from analysis_run
   where engagement_id = p_engagement
     and job_type = 'analysis:' || p_analysis_key
     and status in ('queued','running');
  if v_existing is not null then
    run_id := v_existing;
    was_created := false;
    return next;
    return;
  end if;

  return query
  select * from gea_enqueue_run(
    p_engagement, ('analysis:' || p_analysis_key)::text, null, null, null, null,
    jsonb_build_object('started_at',
                       to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS.US')));
end $fn$;

comment on function gea_start_analysis is
  'Start an analysis the client''s data supports. Refused where capability '
  'says it cannot run, because the result would be a figure computed from a '
  'field that is empty.';

-- What a step can start -------------------------------------------------------
-- A step that waits on analyses should be able to show them and launch them,
-- without the screen having to know which analyses belong to which step.

create or replace function gea_step_analyses(p_engagement uuid, p_step_ref text)
returns table (analysis_key text, verdict capability_verdict, reason text,
               run_status text, accepted boolean, run_id uuid)
language sql stable as $fn$
  with wanted as (
    select c.value as key
      from step_completion c
      join methodology_step s on s.ref = c.step_ref
                             and s.runbook_version = c.runbook_version
     where s.ref = p_step_ref and c.kind = 'analysis_accepted'
    union
    -- a step that waits on every analysis the data supports
    select cap.analysis_key
      from step_completion c
      join methodology_step s on s.ref = c.step_ref
                             and s.runbook_version = c.runbook_version
      join analysis_capability cap on cap.engagement_id = p_engagement
     where s.ref = p_step_ref and c.kind = 'supported_analyses_done'
       and cap.verdict in ('supported','partial')
  )
  select w.key, cap.verdict, cap.reason,
         r.status::text, r.accepted_at is not null, r.id
    from wanted w
    left join analysis_capability cap on cap.engagement_id = p_engagement
                                     and cap.analysis_key = w.key
    left join lateral (
      select id, status, accepted_at from analysis_run
       where engagement_id = p_engagement
         and job_type = 'analysis:' || w.key
         and status <> 'discarded'
       order by created_at desc limit 1) r on true
   order by w.key;
$fn$;

comment on function gea_step_analyses is
  'The analyses a step waits on, with what the data says about each and where '
  'its latest run has got to.';

insert into gea_migration (filename, note) values
  ('055_starting_an_analysis.sql',
   'An analysis the data supports can be started from the step that needs it, '
   'and a step can list the analyses it waits on.');
