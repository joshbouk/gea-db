-- 067 Only a finding can be accepted.
--
-- Accepting a run means a person has read the records behind a figure and
-- is willing to stand behind it. Two job types have no figure behind them.
--
-- A parse run read a file. There is nothing to agree or disagree with: the
-- file either parsed or it did not, and what it found is in the field
-- profile for anyone to look at.
--
-- A propose_mappings run suggested columns. Those are accepted one at a
-- time on the mapping screen, where the person can see the column and its
-- values. Accepting the run as a whole agrees to nothing in particular.
--
-- Both were accepted happily and satisfied no evidence requirement, so the
-- control appeared to work and did nothing. An action that looks like it
-- worked is worse than one that is refused, because nobody goes looking for
-- the thing that did not happen.

create or replace function gea_accept_run(p_run uuid, p_note text default null)
returns table (requirements_satisfied integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me  uuid;
  v_run record;
  v_key text;
  v_val record;
  n     integer := 0;
begin
  select * into v_run from analysis_run where id = p_run;
  if v_run.id is null then
    raise exception 'that run is not on record' using errcode = 'check_violation';
  end if;

  -- The jobs that keep the engagement running are not findings.
  if v_run.job_type not like 'analysis:%' and v_run.job_type not like 'classify:%'
     and v_run.job_type not like 'generate:%'
     and v_run.job_type <> 'synthesise_interview' then
    raise exception
      '% is not a finding, so there is nothing to accept. %',
      v_run.job_type,
      case v_run.job_type
        when 'parse' then
          'It read a client file; what it found is in that file''s profile.'
        when 'propose_mappings' then
          'It suggested columns, and those are accepted one at a time on the '
          'field mapping screen where the values can be seen.'
        when 'profile' then
          'It described the columns of a file, and the description is on the '
          'file.'
        else 'It is part of running the engagement rather than evidence in it.'
      end
      using errcode = 'check_violation';
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

  if v_run.model_name = 'stub' then
    raise exception
      'this analysis has not been built yet. The run produced a placeholder, '
      'not a result, and accepting it would turn an invented figure into '
      'evidence'
      using errcode = 'check_violation';
  end if;

  if v_run.compute_output ? 'to_check_by_hand' then
    select * into v_val from validation_set where analysis_run_id = p_run;
    if v_val.id is null then
      raise exception
        'read the ten records this run set aside before accepting it. A '
        'classification nobody checked is a figure nobody can defend'
        using errcode = 'check_violation';
    end if;
    if v_val.verdict <> 'trust' then
      raise exception
        'the records were read and the agreement was %. The verdict was %, '
        'not trust, so this classification cannot be used as evidence',
        to_char(v_val.agreement_rate * 100, 'FM999') || '%', v_val.verdict
        using errcode = 'check_violation';
    end if;
  end if;

  if coalesce((v_run.compute_output ->> 'census_complete')::boolean, true) is false then
    raise exception
      'this was meant to read every record and did not. Redo it, or accept '
      'that the rates describe only part of the client'
      using errcode = 'check_violation';
  end if;

  update analysis_run
     set accepted_by = v_me, accepted_at = now(),
         review_note = coalesce(p_note, review_note)
   where id = p_run;

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

  requirements_satisfied := n;
  return next;
end $fn$;

comment on function gea_accept_run is
  'A person has read the records behind a finding and accepts it. Refused '
  'for the jobs that keep the engagement running — parsing a file, proposing '
  'mappings — because there is no figure behind them to stand behind.';

-- Which runs are a person's to review ---------------------------------------

create or replace view run_review_board
with (security_invoker = true) as
select r.id as run_id, r.engagement_id, r.job_type, r.status::text,
       r.created_at, r.finished_at, r.error, r.model_name,
       r.accepted_at, r.accepted_by, r.review_note, r.discarded_reason,
       r.progress_done, r.progress_total,
       (r.job_type like 'analysis:%' or r.job_type like 'classify:%'
        or r.job_type like 'generate:%'
        or r.job_type = 'synthesise_interview') as is_a_finding,
       (r.compute_output ? 'to_check_by_hand') as needs_records_read,
       coalesce((r.compute_output ->> 'census_complete')::boolean, true)
         as census_complete
  from analysis_run r;

comment on view run_review_board is
  'Every run, with whether it is a finding somebody reviews or a job that '
  'keeps the engagement running. Only the first kind can be accepted.';

insert into gea_migration (filename, note) values
  ('067_only_findings_are_accepted.sql',
   'Parsing a file and proposing mappings cannot be accepted: there is no '
   'figure behind them. They were accepted happily and satisfied nothing.');
