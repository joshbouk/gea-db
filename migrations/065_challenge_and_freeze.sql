-- 065 Arguing with the scores, then stopping.
--
-- Three steps, and they belong together because each one only means
-- something if the next follows it.
--
-- 3.3 is the internal challenge. Somebody argues against every score before
-- the client sees it, and the two worth catching are a four or five awarded
-- on evidence that does not support it, and a zero or one that confuses an
-- absence of the thing with an absence of evidence about the thing. A
-- challenge is defended with a citation or conceded, and a concession moves
-- the score — which is why score_revision exists.
--
-- 3.7 is the honesty test: what would make this assessment wrong, and what
-- have we recommended that we would not pay for ourselves. Two questions, in
-- writing, not delegated.
--
-- 3.8 freezes the scorecard. Roadmap work has a way of reshaping the scores
-- that produced it, and freezing first keeps the diagnosis independent of
-- the recommendation. Afterwards nothing moves: the trigger already refuses
-- it, and this is what sets the date that trigger reads.

-- Raising one ----------------------------------------------------------------

create or replace function gea_raise_challenge(
  p_engagement uuid, p_element_ref text, p_challenge text,
  p_weakness text default null, p_run uuid default null)
returns table (challenge_id uuid)
language plpgsql security definer set search_path = public as $fn$
declare v_element uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was raised'
      using errcode = 'insufficient_privilege';
  end if;

  if (select score_frozen_at from engagement where id = p_engagement) is not null then
    raise exception
      'the scorecard is frozen. A challenge raised now could not change '
      'anything, which is the point of freezing it'
      using errcode = 'check_violation';
  end if;

  select e.id into v_element
    from element e
    join engagement en on en.id = p_engagement
                      and en.instrument_version_id = e.instrument_version_id
   where e.ref = p_element_ref;
  if v_element is null then
    raise exception 'there is no element % in this engagement''s instrument',
      p_element_ref using errcode = 'check_violation';
  end if;

  if p_challenge is null or length(btrim(p_challenge)) = 0 then
    raise exception
      'say what is wrong with the score. A challenge with no argument cannot '
      'be defended or conceded'
      using errcode = 'check_violation';
  end if;

  insert into challenge (engagement_id, element_id, analysis_run_id,
                         challenge_text, weakness_type)
       values (p_engagement, v_element, p_run, btrim(p_challenge),
               nullif(btrim(p_weakness), ''))
    returning id into challenge_id;
  return next;
end $fn$;

comment on function gea_raise_challenge is
  'Argue against one score. Refused once the scorecard is frozen, because a '
  'challenge that cannot change anything is not a challenge.';

-- Answering it ---------------------------------------------------------------

create or replace function gea_dispose_challenge(
  p_challenge uuid, p_defended boolean, p_response text)
returns table (disposition text, score_now text)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me  uuid;
  v_ch  record;
  v_sc  record;
begin
  select c.*, e.ref as element_ref into v_ch
    from challenge c join element e on e.id = c.element_id
   where c.id = p_challenge;
  if v_ch.id is null then
    raise exception 'that challenge is not on record'
      using errcode = 'check_violation';
  end if;

  if not app_is_member(v_ch.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  if v_ch.disposition <> 'open' then
    raise exception 'that challenge was already %', v_ch.disposition
      using errcode = 'check_violation';
  end if;

  if p_response is null or length(btrim(p_response)) = 0 then
    raise exception
      'answer the challenge in writing. Defending a score without saying why '
      'is not a defence'
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  select * into v_sc from score
   where engagement_id = v_ch.engagement_id and element_id = v_ch.element_id;

  -- Defending a score means pointing at what supports it. A defence on a
  -- score with nothing cited is the challenge restated as a conclusion.
  if p_defended then
    if (select count(*) from score_citation where score_id = v_sc.id) = 0 then
      raise exception
        'nothing is cited on %, so there is nothing to defend it with. Cite '
        'the evidence, or concede and change the score', v_ch.element_ref
        using errcode = 'check_violation';
    end if;
  end if;

  update challenge
     set disposition = (case when p_defended then 'defended' else 'conceded' end)::challenge_state,
         response_note = btrim(p_response),
         resolved_by = v_me
   where id = p_challenge;

  disposition := case when p_defended then 'defended' else 'conceded' end;
  score_now := case
    when v_sc.state = 'unscored' then 'unscored'
    when v_sc.not_evidenced then 'not evidenced'
    else v_sc.value::text end;
  return next;
end $fn$;

comment on function gea_dispose_challenge is
  'Defend a score with its citation, or concede it. Conceding does not move '
  'the score by itself: the change goes through gea_set_score so the reason '
  'and the revision are recorded together.';

-- The honesty test -----------------------------------------------------------

create or replace function gea_record_honesty_test(
  p_engagement uuid, p_what_would_make_this_wrong text,
  p_what_we_would_not_pay_for text,
  -- What came out of the roadmap as a result of answering question two.
  -- A list, because it is a list.
  p_recommendations_removed text[] default null)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid;
begin
  if not app_is_engagement_lead(p_engagement) then
    raise exception
      'the honesty test is the lead''s to answer. It is not delegated'
      using errcode = 'insufficient_privilege';
  end if;

  if p_what_would_make_this_wrong is null
     or length(btrim(p_what_would_make_this_wrong)) < 20
     or p_what_we_would_not_pay_for is null
     or length(btrim(p_what_we_would_not_pay_for)) < 20 then
    raise exception
      'both questions need a real answer. What would make this assessment '
      'wrong, and what have we recommended that we would not pay for '
      'ourselves'
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  insert into honesty_test (engagement_id, question_one_answer,
                            question_two_answer, recommendations_removed,
                            completed_by, completed_at)
       values (p_engagement, btrim(p_what_would_make_this_wrong),
               btrim(p_what_we_would_not_pay_for),
               case when p_recommendations_removed is null
                    or array_length(p_recommendations_removed, 1) is null
                    then null else to_jsonb(p_recommendations_removed) end,
               v_me, now())
  on conflict (engagement_id) do update
    set question_one_answer = excluded.question_one_answer,
        question_two_answer = excluded.question_two_answer,
        recommendations_removed = excluded.recommendations_removed,
        completed_by = excluded.completed_by,
        completed_at = excluded.completed_at;
end $fn$;

comment on function gea_record_honesty_test is
  'The two questions a lead answers in writing before the scores freeze.';

create unique index if not exists honesty_test_one_per_engagement
  on honesty_test (engagement_id);

insert into gea_migration (filename, note) values
  ('065_challenge_and_freeze.sql',
   'Raising and answering a challenge, and the honesty test. A defence needs '
   'a citation; a challenge after the freeze is refused.');

-- Freezing -------------------------------------------------------------------
--
-- Gate G3 in one function, because freezing is the gate. Every condition is
-- named when it is not met: a refusal saying "the scorecard is not ready"
-- sends somebody hunting through forty-eight elements.

create or replace function gea_freeze_scores(p_engagement uuid)
returns table (frozen_at timestamptz, elements integer, reported_as_absent integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me      uuid;
  v_unmet   text[] := array[]::text[];
  n         integer;
  v_total   integer;
  v_ne      integer;
begin
  if not app_is_engagement_lead(p_engagement) then
    raise exception
      'only a lead consultant or lead architect can freeze the scorecard'
      using errcode = 'insufficient_privilege';
  end if;

  if (select score_frozen_at from engagement where id = p_engagement) is not null then
    raise exception 'this scorecard was already frozen'
      using errcode = 'check_violation';
  end if;

  select count(*) into n from score
   where engagement_id = p_engagement and state <> 'final';
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s element%s not final yet.', n, case when n = 1 then ' is' else 's are' end);
  end if;

  -- Not evidenced is a legitimate answer and it needs its reason, because
  -- that reason is what reaches the report as a limitation.
  select count(*) into n from score
   where engagement_id = p_engagement and not_evidenced
     and (ne_reason is null or length(btrim(ne_reason)) = 0);
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s element%s marked not evidenced with no reason given.',
      n, case when n = 1 then '' else 's' end);
  end if;

  select count(*) into n from score s
   where s.engagement_id = p_engagement
     and not exists (select 1 from score_citation c where c.score_id = s.id);
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s score%s with nothing cited.', n, case when n = 1 then '' else 's' end);
  end if;

  -- A citation on a run that was later superseded points at a figure nobody
  -- can reproduce.
  select count(*) into n
    from score_citation c
    join score s on s.id = c.score_id
    join analysis_run r on r.id = c.analysis_run_id
   where s.engagement_id = p_engagement and r.is_stale;
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s citation%s pointing at a run that has been superseded.',
      n, case when n = 1 then '' else 's' end);
  end if;

  select count(*) into n from challenge
   where engagement_id = p_engagement and disposition = 'open';
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s challenge%s still open.', n, case when n = 1 then ' is' else 's are' end);
  end if;

  if not exists (select 1 from honesty_test where engagement_id = p_engagement) then
    v_unmet := v_unmet || 'The honesty test has not been answered.'::text;
  end if;

  if array_length(v_unmet, 1) is not null then
    raise exception 'the scorecard is not ready to freeze. %',
      array_to_string(v_unmet, ' ')
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  update engagement
     set score_frozen_at = now(), frozen_by = v_me
   where id = p_engagement;

  insert into gate_passage (engagement_id, gate_ref, passed_by)
       values (p_engagement, 'G3', v_me)
  on conflict do nothing;

  select count(*), count(*) filter (where not_evidenced) into v_total, v_ne
    from score where engagement_id = p_engagement;

  frozen_at := (select score_frozen_at from engagement where id = p_engagement);
  elements := v_total;
  reported_as_absent := v_ne;
  return next;
end $fn$;

comment on function gea_freeze_scores is
  'Freeze the scorecard, which is gate G3. Every unmet condition is named: a '
  'refusal that does not say what is wrong sends somebody hunting through '
  'forty-eight elements.';
