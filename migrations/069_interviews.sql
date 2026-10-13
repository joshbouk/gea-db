-- 069 Interviews.
--
-- Sixty of the hundred and seventy-one evidence requirements come from the
-- seven conversations, which makes them the largest single source in the
-- assessment and the only one that cannot be re-run. An export can be
-- requested again; a sponsor's forty minutes cannot.
--
-- Three things here.
--
--   Holding one, or not. A declined interview is a finding with a
--   consequence, not an absence, and recording the decline is what applies
--   the consequence. An interview that never happened and was never
--   recorded as declined is the worst case: it looks like work not yet
--   done, for ever.
--
--   The transcript. Attaching it is what lets anything be read from the
--   conversation afterwards, and without it the only record is whatever
--   somebody typed from memory.
--
--   What the synthesis is for. It extracts what was said against the
--   guide's own questions, with the words that were said. It does not
--   propose a score. The elements an interview serves are scored by a
--   person who read it, and the synthesis is there so they can find the
--   part that matters in forty minutes of talk.

create or replace function gea_schedule_interview(
  p_engagement uuid, p_guide_ref text, p_name text, p_role text,
  p_when timestamptz default null)
returns table (interview_id uuid)
language plpgsql security definer set search_path = public as $fn$
declare v_guide uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was scheduled'
      using errcode = 'insufficient_privilege';
  end if;

  select g.id into v_guide
    from interview_guide g
    join engagement e on e.id = p_engagement
                     and e.instrument_version_id = g.instrument_version_id
   where g.ref = p_guide_ref;
  if v_guide is null then
    raise exception 'there is no interview guide % in this instrument',
      p_guide_ref using errcode = 'check_violation';
  end if;

  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception
      'say who is being interviewed. An interview with nobody named cannot '
      'be cited'
      using errcode = 'check_violation';
  end if;

  insert into interview (engagement_id, interview_guide_id, interviewee_name,
                         interviewee_role, scheduled_at, status)
       values (p_engagement, v_guide, btrim(p_name), nullif(btrim(p_role), ''),
               p_when, 'scheduled')
    returning id into interview_id;
  return next;
end $fn$;

comment on function gea_schedule_interview is
  'Put one of the seven conversations in the diary, against its guide.';

create or replace function gea_record_interview_held(
  p_interview uuid, p_held_at timestamptz default null,
  p_transcript uuid default null, p_notes text default null,
  p_name text default null, p_role text default null)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_iv record;
begin
  select * into v_iv from interview where id = p_interview;
  if v_iv.id is null then
    raise exception 'that interview is not on record'
      using errcode = 'check_violation';
  end if;
  if not app_is_member(v_iv.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  -- An engagement seeds its seven conversations with nobody named, because
  -- nobody is named yet. Holding one without saying who was in it produces
  -- evidence that cannot be attributed, and a quotation nobody can place is
  -- not a citation.
  if coalesce(nullif(btrim(coalesce(p_name, '')), ''),
              nullif(btrim(coalesce(v_iv.interviewee_name, '')), '')) is null then
    raise exception
      'say who was interviewed. A conversation with nobody named cannot be '
      'cited, and the elements it serves would rest on a quotation nobody '
      'can place'
      using errcode = 'check_violation';
  end if;

  if p_transcript is not null
     and not exists (select 1 from artefact a
                      where a.id = p_transcript
                        and a.engagement_id = v_iv.engagement_id
                        and a.purged_at is null) then
    raise exception
      'that transcript is not a file on this engagement'
      using errcode = 'check_violation';
  end if;

  update interview
     set status = 'held',
         held_at = coalesce(p_held_at, held_at, now()),
         transcript_artefact_id = coalesce(p_transcript, transcript_artefact_id),
         interviewee_name = coalesce(nullif(btrim(p_name), ''), interviewee_name),
         interviewee_role = coalesce(nullif(btrim(p_role), ''), interviewee_role),
         notes = coalesce(nullif(btrim(p_notes), ''), notes)
   where id = p_interview;
end $fn$;

comment on function gea_record_interview_held is
  'Record that a conversation happened, and attach its transcript. Without '
  'the transcript the only record is what somebody typed from memory.';

create or replace function gea_decline_interview(
  p_interview uuid, p_reason text, p_cancelled boolean default false)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_iv record;
begin
  select * into v_iv from interview where id = p_interview;
  if v_iv.id is null then
    raise exception 'that interview is not on record'
      using errcode = 'check_violation';
  end if;
  if not app_is_member(v_iv.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception
      'say why it is not happening. A declined conversation is a finding, '
      'and the reason is what reaches the report'
      using errcode = 'check_violation';
  end if;

  update interview
     set status = (case when p_cancelled then 'cancelled'
                        else 'declined' end)::interview_status,
         notes = btrim(p_reason)
   where id = p_interview;
end $fn$;

comment on function gea_decline_interview is
  'A conversation that will not happen. Declined is a finding with a '
  'consequence; cancelled is a diary problem. Both need a reason, because '
  'an interview that simply never happened looks like work not yet done for '
  'ever.';

-- What the synthesis has to read ---------------------------------------------

create or replace function gea_interview_guide_questions(p_interview uuid)
returns table (question_ref text, section_title text, question_text text,
               elements text[])
language sql stable security definer set search_path = public as $fn$
  select q.id::text, q.section_title, q.question_text,
         array(select e.ref from interview_question_element x
                 join element e on e.id = x.element_id
                where x.interview_question_id = q.id order by e.ref)
    from interview i
    join interview_question q on q.interview_guide_id = i.interview_guide_id
   where i.id = p_interview
   order by q.sort_order;
$fn$;

comment on function gea_interview_guide_questions is
  'The questions this interview was meant to cover, and which elements each '
  'one serves.';

-- The board ------------------------------------------------------------------

create or replace view interview_board
with (security_invoker = true) as
select i.id as interview_id, i.engagement_id,
       g.ref as guide_ref, g.function_name,
       i.interviewee_name, i.interviewee_role,
       i.scheduled_at, i.held_at, i.status::text, i.notes,
       i.transcript_artefact_id is not null as has_transcript,
       a.original_filename as transcript_filename,
       i.synthesis_run_id,
       r.status::text as synthesis_status,
       r.accepted_at as synthesis_accepted_at,
       (select count(*) from interview_question q
         where q.interview_guide_id = i.interview_guide_id) as questions,
       (select count(*) from evidence_requirement evr
          join engagement e on e.id = i.engagement_id
         where evr.instrument_version_id = e.instrument_version_id
           and evr.interview_guide_id = i.interview_guide_id)
         as evidence_requirements
  from interview i
  join interview_guide g on g.id = i.interview_guide_id
  left join artefact a on a.id = i.transcript_artefact_id
  left join analysis_run r on r.id = i.synthesis_run_id;

comment on view interview_board is
  'The seven conversations on an engagement: where each has got to, whether '
  'its transcript is here, and how much of the assessment waits on it.';

insert into gea_migration (filename, note) values
  ('069_interviews.sql',
   'Scheduling, holding, declining and transcribing the seven conversations, '
   'and the questions a synthesis has to read against.');

-- Accepting a synthesis -------------------------------------------------------
--
-- gea_accept_run satisfied requirements whose source is an analysis. An
-- interview's requirements name a guide instead, so accepting a synthesis
-- satisfied nothing and the sixty interview requirements stayed outstanding
-- however many conversations were held.

create or replace function gea_satisfy_interview_requirements(
  p_run uuid)
returns integer
language plpgsql security definer set search_path = public as $fn$
declare v_run record; v_guide uuid; n integer := 0;
begin
  select * into v_run from analysis_run where id = p_run;
  select interview_guide_id into v_guide
    from interview where synthesis_run_id = p_run;
  if v_guide is null then
    return 0;
  end if;

  update engagement_requirement er
     set state = 'satisfied', satisfied_by_run_id = p_run
    from evidence_requirement evr, engagement e
   where er.evidence_requirement_id = evr.id
     and e.id = er.engagement_id
     and er.engagement_id = v_run.engagement_id
     and er.state = 'outstanding'
     and evr.instrument_version_id = e.instrument_version_id
     and evr.source_kind = 'interview'
     and evr.interview_guide_id = v_guide;
  get diagnostics n = row_count;
  return n;
end $fn$;

comment on function gea_satisfy_interview_requirements is
  'An accepted synthesis satisfies the requirements its guide serves. '
  'Without this the sixty interview requirements stayed outstanding however '
  'many conversations were held.';

create or replace function gea_accept_run(p_run uuid, p_note text default null)
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

  if v_run.job_type = 'synthesise_interview' then
    n := n + gea_satisfy_interview_requirements(p_run);
  end if;

  requirements_satisfied := n;
  challenges_raised := 0;
  challenges_skipped := 0;

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
  'the adversarial review records its challenges in the same breath; '
  'accepting an interview synthesis satisfies what that conversation was '
  'meant to evidence.';
