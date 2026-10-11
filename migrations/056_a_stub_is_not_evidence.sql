-- 056 A stub is not evidence.
--
-- 055 gave a consultant a Run control. The analyses behind it are still stubs:
-- the service records a plausible-looking compute_output with model_name
-- 'stub' and no client data behind it.
--
-- So the path now exists to run an analysis, read a fabricated figure, accept
-- it, and have it satisfy an evidence requirement — which then counts towards
-- readiness and, later, towards a score. Nothing stopped that.
--
-- This is the worst class of defect in the whole system: not a wrong answer,
-- but an invented one wearing the clothes of a real one. The database refuses
-- it.
--
-- The check is on acceptance rather than on running. Running a stub is useful
-- while the service is being built; accepting one is never useful.

create or replace function gea_accept_run(p_run uuid, p_note text default null)
returns table (requirements_satisfied integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me  uuid;
  v_run record;
  v_key text;
  n     integer := 0;
begin
  select * into v_run from analysis_run where id = p_run;
  if v_run.id is null then
    raise exception 'that run is not on record' using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;
  if v_me is null and not app_is_service() then
    raise exception 'only an active Blend user can accept a run'
      using errcode = 'insufficient_privilege';
  end if;

  if not app_is_member(v_run.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so the run was not accepted'
      using errcode = 'insufficient_privilege';
  end if;

  if v_run.status <> 'succeeded' then
    raise exception
      'only a run that succeeded can be accepted. This one is %', v_run.status
      using errcode = 'check_violation';
  end if;

  if v_run.accepted_at is not null then
    raise exception 'that run was already accepted'
      using errcode = 'check_violation';
  end if;

  -- The one that matters. A stub produced no figure from the client's data,
  -- and accepting it would make an invented number into evidence.
  if v_run.model_name = 'stub' then
    raise exception
      'this analysis has not been built yet. The run produced a placeholder, '
      'not a result, and accepting it would turn an invented figure into '
      'evidence'
      using errcode = 'check_violation';
  end if;

  update analysis_run
     set accepted_by = v_me, accepted_at = now(),
         review_note = coalesce(p_note, review_note)
   where id = p_run;

  if v_run.job_type like 'analysis:%' or v_run.job_type like 'classify:%' then
    v_key := split_part(v_run.job_type, ':', 2);

    update engagement_requirement er
       set state = 'satisfied', satisfied_by_run_id = p_run
      from evidence_requirement evr, engagement e
     where er.evidence_requirement_id = evr.id
       and e.id = er.engagement_id
       and er.engagement_id = v_run.engagement_id
       and er.state = 'outstanding'
       and evr.instrument_version_id = e.instrument_version_id
       and evr.source_kind = 'analysis'
       and evr.analysis_key = v_key;
    get diagnostics n = row_count;
  end if;

  requirements_satisfied := n;
  return next;
end $fn$;

comment on function gea_accept_run is
  'A person has read the records behind a run and accepts it. Refused for a '
  'stub: a placeholder is not a result, and accepting one would make an '
  'invented figure into evidence.';

insert into gea_migration (filename, note) values
  ('056_a_stub_is_not_evidence.sql',
   'A run from an analysis that has not been built cannot be accepted.');
