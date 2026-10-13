-- 071 What the score is out of.
--
-- The runbook says to record a Growth Effectiveness Score out of 100 and
-- Handoff Integrity out of 40. Forty elements at nought to five is two
-- hundred, halved. Eight handoffs at nought to five is forty. What it never
-- said is what happens when an element cannot be scored, and the answer
-- decides what the headline number means.
--
-- Not evidenced was the existing state and it conflated two different
-- things.
--
--   Not applicable. The element has nothing to measure in this business.
--   This is a statement about the client's model.
--
--   Not assessed. No export arrived, no interview touched it, no document
--   covered it. This is a statement about the engagement — a Blend process
--   failure or a client refusal — and it should be uncomfortable to record.
--
-- Both reduce the base rather than scoring nought. Scoring a client nought
-- because an export request failed is exactly the error the adversarial
-- review exists to catch: an absence of evidence read as an absence of the
-- thing. And a level nought anchor describes an evidenced state — "no
-- channel plan, and interviews produce different accounts of why money sits
-- where it does" — so defaulting to nought assigns a score the anchor does
-- not support.
--
-- The base travels with the figure, as every rate in this system does.
-- "Fifty-two out of a hundred, from thirty-eight of forty elements."
--
-- Not applicable is refused where it would take a third element out of one
-- stage. Every business has all eight stages. A consultant excluding most
-- of a stage has misread the stage, not found a gap in the client.

create type scoring_exclusion as enum ('not_applicable', 'not_assessed');

comment on type scoring_exclusion is
  'Why an element carries no score. Not applicable is about the client; not '
  'assessed is about the engagement.';

alter table score
  add column excluded scoring_exclusion,
  add column exclusion_reason text,
  add column excluded_by uuid references app_user(id),
  add column excluded_at timestamptz;

comment on column score.excluded is
  'Set where the element is deliberately out of the base. Both kinds reduce '
  'the denominator; neither scores nought.';

alter table score add constraint score_excluded_needs_a_reason
  check (excluded is null
         or (exclusion_reason is not null
             and length(btrim(exclusion_reason)) >= 20));

alter table score add constraint score_excluded_has_no_value
  check (excluded is null or (value is null and not not_evidenced));

-- Excluding one ---------------------------------------------------------------

create or replace function gea_exclude_element(
  p_engagement uuid, p_element_ref text, p_kind scoring_exclusion,
  p_reason text)
returns table (element_ref text, kind text, stage_excluded integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me    uuid;
  v_el    record;
  v_score record;
  n       integer;
  total   integer;
begin
  if not app_is_engagement_lead(p_engagement) then
    raise exception
      'taking an element out of the score is the lead''s call. It changes '
      'what the headline figure is out of'
      using errcode = 'insufficient_privilege';
  end if;

  if (select score_frozen_at from engagement where id = p_engagement) is not null then
    raise exception 'this scorecard is frozen'
      using errcode = 'check_violation';
  end if;

  select e.* into v_el
    from element e
    join engagement en on en.id = p_engagement
                      and en.instrument_version_id = e.instrument_version_id
   where e.ref = p_element_ref;
  if v_el.id is null then
    raise exception 'there is no element % in this engagement''s instrument',
      p_element_ref using errcode = 'check_violation';
  end if;

  if p_reason is null or length(btrim(p_reason)) < 20 then
    raise exception
      'write the justification the client will read. It appears verbatim in '
      'the report''s limitations, and a sentence you would not put in front '
      'of the sponsor is not a reason to exclude an element'
      using errcode = 'check_violation';
  end if;

  -- Not applicable says the absence tells you nothing about their growth
  -- engine. Most absences tell you a great deal: a client with no list
  -- price is not unmeasurable on pricing, they are a custom-pricing shop,
  -- and that is the finding.
  if p_kind = 'not_applicable' and v_el.stage_code is not null then
    select count(*) into n from score s
      join element e2 on e2.id = s.element_id
     where s.engagement_id = p_engagement
       and e2.stage_code = v_el.stage_code
       and s.excluded = 'not_applicable'
       and e2.ref <> p_element_ref;
    select count(*) into total from element e2
      join engagement en on en.id = p_engagement
                        and en.instrument_version_id = e2.instrument_version_id
     where e2.stage_code = v_el.stage_code;
    if n + 1 >= 3 then
      raise exception
        'that would be % of % elements in stage % marked not applicable. '
        'Every business has every stage. Most of a stage not applying means '
        'the stage has been misread, and the elements below it are low '
        'scores rather than exclusions',
        n + 1, total, v_el.stage_code
        using errcode = 'check_violation';
    end if;
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  select * into v_score from score
   where engagement_id = p_engagement and element_id = v_el.id;

  -- A score that existed is being taken out, so the change is recorded the
  -- same way any other change to a settled score is.
  if v_score.state <> 'unscored' then
    insert into score_revision (score_id, previous_value, new_value,
                                previous_ne, new_ne, reason, changed_by)
         values (v_score.id, v_score.value, null, v_score.not_evidenced,
                 false,
                 format('Taken out of the score as %s. %s',
                        replace(p_kind::text, '_', ' '), btrim(p_reason)),
                 v_me);
    delete from score_citation where score_id = v_score.id;
  end if;

  update score
     set value = null, not_evidenced = false, ne_reason = null,
         confidence = null, state = 'unscored',
         excluded = p_kind, exclusion_reason = btrim(p_reason),
         excluded_by = v_me, excluded_at = now(),
         row_version = row_version + 1
   where id = v_score.id;

  element_ref := p_element_ref;
  kind := replace(p_kind::text, '_', ' ');
  stage_excluded := coalesce(n, 0) + 1;
  return next;
end $fn$;

comment on function gea_exclude_element is
  'Take one element out of the base, as not applicable to this business or '
  'not assessed in this engagement. Refused where it would take a third '
  'element out of one stage.';

create or replace function gea_restore_element(
  p_engagement uuid, p_element_ref text)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_el uuid;
begin
  if not app_is_engagement_lead(p_engagement) then
    raise exception 'putting an element back is the lead''s call'
      using errcode = 'insufficient_privilege';
  end if;
  select e.id into v_el
    from element e
    join engagement en on en.id = p_engagement
                      and en.instrument_version_id = e.instrument_version_id
   where e.ref = p_element_ref;
  update score
     set excluded = null, exclusion_reason = null, excluded_by = null,
         excluded_at = null, row_version = row_version + 1
   where engagement_id = p_engagement and element_id = v_el;
end $fn$;

comment on function gea_restore_element is
  'Put an excluded element back into the base, to be scored.';

insert into gea_migration (filename, note) values
  ('071_what_a_score_is_out_of.sql',
   'An element can be not applicable to the business or not assessed in the '
   'engagement. Both reduce the base; neither scores nought.');

-- The two numbers, and what they are out of ----------------------------------

create or replace view engagement_score
with (security_invoker = true) as
with scored as (
  select s.engagement_id, e.kind, e.stage_code, s.value, s.excluded,
         s.state, s.not_evidenced
    from score s join element e on e.id = s.element_id
)
select engagement_id,
       -- Forty elements at nought to five is two hundred, expressed out of
       -- a hundred. Where elements are out of the base, the rest are
       -- expressed out of a hundred just the same, and the base is stated
       -- beside it.
       case when count(*) filter (where kind = 'element' and value is not null) = 0
            then null
            else round(
              100.0 * sum(value) filter (where kind = 'element' and value is not null)
              / (5 * count(*) filter (where kind = 'element' and value is not null)))
       end as growth_effectiveness,
       count(*) filter (where kind = 'element' and value is not null)
         as elements_scored,
       count(*) filter (where kind = 'element') as elements_total,
       count(*) filter (where kind = 'element' and excluded = 'not_applicable')
         as elements_not_applicable,
       count(*) filter (where kind = 'element' and excluded = 'not_assessed')
         as elements_not_assessed,
       count(*) filter (where kind = 'element' and value is null
                        and excluded is null) as elements_still_to_score,
       case when count(*) filter (where kind = 'handoff' and value is not null) = 0
            then null
            else round(
              40.0 * sum(value) filter (where kind = 'handoff' and value is not null)
              / (5 * count(*) filter (where kind = 'handoff' and value is not null)))
       end as handoff_integrity,
       count(*) filter (where kind = 'handoff' and value is not null)
         as handoffs_scored,
       count(*) filter (where kind = 'handoff') as handoffs_total
  from scored
 group by engagement_id;

comment on view engagement_score is
  'The two headline figures with the base each rests on. A figure without '
  'its base is not reportable: an engagement where half the elements were '
  'never assessed can produce a flattering number.';

create or replace view engagement_stage_score
with (security_invoker = true) as
select s.engagement_id, e.stage_code, ls.name as stage_name,
       round(avg(s.value) filter (where s.value is not null), 2) as average,
       count(*) filter (where s.value is not null) as scored,
       count(*) as elements,
       count(*) filter (where s.excluded is not null) as excluded,
       jsonb_agg(jsonb_build_object('ref', e.ref, 'name', e.name,
                                    'value', s.value,
                                    'excluded', s.excluded,
                                    'reason', s.exclusion_reason)
                 order by e.ref) as detail
  from score s
  join element e on e.id = s.element_id and e.kind = 'element'
  left join lifecycle_stage ls on ls.code = e.stage_code
 where e.stage_code is not null
 group by s.engagement_id, e.stage_code, ls.name;

comment on view engagement_stage_score is
  'One row per lifecycle stage: the average of the elements that carry a '
  'score, and how many were taken out of the base.';

-- A stage with nothing in it --------------------------------------------------
--
-- Not applicable is limited to two elements per stage, because every
-- business has every stage. Not assessed is not limited the same way: an
-- export that never arrives is a fact, not a misreading, and capping it
-- would only push somebody into calling it not applicable instead.
--
-- But a stage where nothing at all was scored is not a scorecard with a
-- gap. It is an assessment that did not happen in that part of the
-- business, and freezing it would publish a Growth Effectiveness Score
-- covering seven stages as though it covered eight.

create or replace function gea_freeze_scores(p_engagement uuid)
returns table (frozen_at timestamptz, elements integer, reported_as_absent integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me      uuid;
  v_unmet   text[] := array[]::text[];
  n         integer;
  v_total   integer;
  v_ne      integer;
  v_stages  text;
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
   where engagement_id = p_engagement and state <> 'final' and excluded is null;
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s element%s not final yet.', n, case when n = 1 then ' is' else 's are' end);
  end if;

  select count(*) into n from score
   where engagement_id = p_engagement and not_evidenced
     and (ne_reason is null or length(btrim(ne_reason)) = 0);
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s element%s marked not evidenced with no reason given.',
      n, case when n = 1 then '' else 's' end);
  end if;

  select count(*) into n from score s
   where s.engagement_id = p_engagement and s.excluded is null
     and not exists (select 1 from score_citation c where c.score_id = s.id);
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s score%s with nothing cited.', n, case when n = 1 then '' else 's' end);
  end if;

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

  -- A stage with no scored element at all.
  select string_agg(stage_code, ', ' order by stage_code) into v_stages
    from engagement_stage_score
   where engagement_id = p_engagement and scored = 0;
  if v_stages is not null then
    v_unmet := v_unmet || format(
      'Nothing was scored in stage %s. A score covering seven stages cannot '
      'be published as though it covered eight.', v_stages);
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

  select count(*), count(*) filter (where excluded is not null)
    into v_total, v_ne
    from score where engagement_id = p_engagement;

  frozen_at := (select score_frozen_at from engagement where id = p_engagement);
  elements := v_total;
  reported_as_absent := v_ne;
  return next;
end $fn$;

comment on function gea_freeze_scores is
  'Freeze the scorecard, which is gate G3. Every unmet condition is named, '
  'including a stage where nothing was scored at all.';
