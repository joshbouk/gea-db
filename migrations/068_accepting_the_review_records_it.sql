-- 068 Accepting the review is recording its challenges.
--
-- The challenges the adversarial review found were recorded by the
-- application, in a second call straight after accepting the run. Two calls
-- where one thing happens: if the second failed, the run was accepted with
-- nothing recorded, and the only sign was a sentence in a toast nobody could
-- act on.
--
-- Worse, the scorecard would then look clean. An engagement with no open
-- challenges reads as one that survived the review, and nobody goes looking
-- for the challenges that were never written down.
--
-- Accepting the review and recording what it found are the same act, so
-- they happen in the same transaction. Either both or neither.

-- The returned columns change, so the old one goes first. Dropping a
-- function the application calls is safe only because the new one takes the
-- same arguments and returns a superset: an existing caller reading
-- requirements_satisfied still finds it.
drop function if exists gea_accept_run(uuid, text);

create function gea_accept_run(p_run uuid, p_note text default null)
returns table (requirements_satisfied integer, challenges_raised integer,
               challenges_skipped integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me  uuid;
  v_run record;
  v_key text;
  v_val record;
  v_ch  record;
  n     integer := 0;
begin
  select * into v_run from analysis_run where id = p_run;
  if v_run.id is null then
    raise exception 'that run is not on record' using errcode = 'check_violation';
  end if;

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
  challenges_raised := 0;
  challenges_skipped := 0;

  -- The review's whole output is its challenges. Accepting it without them
  -- would leave a scorecard that looks as though it survived a review it
  -- never had.
  if v_key = 'adversarial_score_review' then
    select * into v_ch
      from gea_record_challenges(p_run, v_run.compute_output -> 'challenges');
    challenges_raised := v_ch.raised;
    challenges_skipped := v_ch.skipped;
  end if;

  return next;
end $fn$;

comment on function gea_accept_run is
  'A person has read the records behind a finding and accepts it. Accepting '
  'the adversarial review records its challenges in the same breath: either '
  'both happen or neither does.';

insert into gea_migration (filename, note) values
  ('068_accepting_the_review_records_it.sql',
   'Accepting the adversarial review records its challenges in the same '
   'transaction, so a scorecard cannot look as if it survived a review that '
   'was never written down.');
