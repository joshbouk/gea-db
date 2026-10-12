-- 063 Scoring.
--
-- Everything before this gathered evidence. This is the judgement, and it is
-- the only part a client will argue with, so it has to be defensible line by
-- line: what the score is, which anchor it matches, and what it rests on.
--
-- The database already refuses the mistakes that matter. A final score needs
-- a citation. A citation needs an accepted run. Not evidenced is only
-- available where the element permits it. The evidence tier sets a ceiling.
-- Nothing moves after the freeze.
--
-- What was missing is the way to set one at all, and three things that go
-- with it.
--
--   Changing a score that was already settled records what it was, what it
--   became and why. A scorecard that moved without a trace is a scorecard
--   nobody can defend in a readout, and the challenge pass at step 3.3
--   exists precisely to move scores.
--
--   A score above its cap is refused with the reason for the cap, not with
--   a constraint name. The cap is a finding about the client's data, and
--   the person scoring needs to read it rather than look it up.
--
--   Citing evidence is checked against what the element is actually served
--   by. Citing an analysis that has nothing to do with the element is not a
--   citation, it is a number with a footnote.

create or replace function gea_set_score(
  p_engagement uuid, p_element_ref text,
  p_value integer default null,
  p_not_evidenced boolean default false,
  p_reason text default null,            -- why not evidenced, or why changed
  p_confidence confidence_flag default null,
  p_note text default null,
  p_state score_state default 'provisional')
returns table (score_id uuid, previous text, now_reads text, revision_recorded boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me       uuid;
  v_score    record;
  v_element  record;
  v_cap      integer;
  v_cap_why  text;
  v_was      text;
  v_revised  boolean := false;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was scored'
      using errcode = 'insufficient_privilege';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  select e.* into v_element
    from element e
    join engagement en on en.id = p_engagement
                      and en.instrument_version_id = e.instrument_version_id
   where e.ref = p_element_ref;
  if v_element.id is null then
    raise exception 'there is no element % in this engagement''s instrument',
      p_element_ref using errcode = 'check_violation';
  end if;

  select * into v_score from score
   where engagement_id = p_engagement and element_id = v_element.id;
  if v_score.id is null then
    raise exception 'this engagement has no scorecard row for %', p_element_ref
      using errcode = 'check_violation';
  end if;

  if (p_value is null) = (p_not_evidenced is not true) then
    raise exception
      'give a score or say it is not evidenced, not both and not neither'
      using errcode = 'check_violation';
  end if;

  -- The cap, read back to the person rather than enforced silently.
  v_cap := v_score.cap_applied;
  v_cap_why := v_score.cap_reason;
  if p_value is not null and v_cap is not null and p_value > v_cap then
    raise exception
      '% cannot go above %. %', p_element_ref, v_cap,
      coalesce(v_cap_why, 'The evidence behind it is capped.')
      using errcode = 'check_violation';
  end if;

  v_was := case
    when v_score.state = 'unscored' then 'unscored'
    when v_score.not_evidenced then 'not evidenced'
    else v_score.value::text end;

  -- A settled score that changes leaves a trace. What it was, what it became
  -- and why: a scorecard that moved without one cannot be defended, and the
  -- challenge pass exists to move scores.
  if v_score.state <> 'unscored'
     and (v_score.value is distinct from p_value
          or v_score.not_evidenced is distinct from coalesce(p_not_evidenced, false)) then
    if p_reason is null or length(btrim(p_reason)) = 0 then
      raise exception
        '% already reads %. Say why it is changing', p_element_ref, v_was
        using errcode = 'check_violation';
    end if;
    insert into score_revision (score_id, previous_value, new_value,
                                previous_ne, new_ne, reason, changed_by)
         values (v_score.id, v_score.value, p_value, v_score.not_evidenced,
                 coalesce(p_not_evidenced, false), btrim(p_reason), v_me);
    v_revised := true;
  end if;

  update score
     set value = p_value,
         not_evidenced = coalesce(p_not_evidenced, false),
         ne_reason = case when p_not_evidenced then btrim(p_reason) end,
         confidence = p_confidence,
         scoring_note = coalesce(btrim(p_note), scoring_note),
         state = p_state,
         scored_by = v_me,
         scored_at = now(),
         row_version = row_version + 1
   where id = v_score.id;

  score_id := v_score.id;
  previous := v_was;
  now_reads := case when coalesce(p_not_evidenced, false)
                    then 'not evidenced' else p_value::text end;
  revision_recorded := v_revised;
  return next;
end $fn$;

comment on function gea_set_score is
  'Set or change one element''s score. A change to a settled score records '
  'what it was and why it moved. A value above the cap is refused with the '
  'reason for the cap.';

-- Citing ---------------------------------------------------------------------

create or replace function gea_cite_score(
  p_score uuid, p_run uuid default null, p_artefact uuid default null,
  p_interview uuid default null, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_score record; v_serves boolean;
begin
  select s.*, e.ref as element_ref into v_score
    from score s join element e on e.id = s.element_id where s.id = p_score;
  if v_score.id is null then
    raise exception 'that score is not on record' using errcode = 'check_violation';
  end if;

  if not app_is_member(v_score.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so nothing was cited'
      using errcode = 'insufficient_privilege';
  end if;

  if num_nonnulls(p_run, p_artefact, p_interview) <> 1 then
    raise exception
      'cite one thing: a run, a file, or an interview'
      using errcode = 'check_violation';
  end if;

  -- An analysis that has nothing to do with the element is not a citation,
  -- it is a number with a footnote. The instrument already says which
  -- analyses serve which elements.
  if p_run is not null then
    select exists (
      select 1 from analysis_run r
        join engagement e on e.id = r.engagement_id
        join evidence_requirement evr
          on evr.instrument_version_id = e.instrument_version_id
         and evr.element_id = v_score.element_id
         and evr.source_kind = 'analysis'
         and evr.analysis_key = split_part(r.job_type, ':', 2)
       where r.id = p_run and r.engagement_id = v_score.engagement_id)
      into v_serves;
    if not v_serves then
      raise exception
        'that run does not serve %. Cite one the instrument says supports '
        'this element, or cite the file or interview it rests on instead',
        v_score.element_ref
        using errcode = 'check_violation';
    end if;
  end if;

  insert into score_citation (score_id, analysis_run_id, artefact_id,
                              interview_id, note)
       values (p_score, p_run, p_artefact, p_interview, nullif(btrim(p_note), ''))
  on conflict do nothing;
end $fn$;

comment on function gea_cite_score is
  'Record what a score rests on. A run must be one the instrument says '
  'serves that element.';

-- What a person needs in front of them to score ------------------------------

create or replace view element_scoring_surface
with (security_invoker = true) as
select s.engagement_id,
       e.ref, e.name, e.kind, e.stage_code, ls.name as stage_name,
       e.why_assessed, e.ne_permitted,
       s.id as score_id, s.value, s.not_evidenced, s.ne_reason,
       s.confidence, s.scoring_note, s.state, s.cap_applied, s.cap_reason,
       (select jsonb_agg(jsonb_build_object('level', a.level,
                                            'descriptor', a.descriptor)
                         order by a.level)
          from anchor a where a.element_id = e.id) as anchors,
       (select count(*) from score_citation c where c.score_id = s.id)
         as citations,
       (select count(*) from engagement_requirement er
          join evidence_requirement evr on evr.id = er.evidence_requirement_id
         where er.engagement_id = s.engagement_id
           and evr.element_id = e.id and er.state = 'outstanding')
         as evidence_outstanding,
       (select count(*) from engagement_requirement er
          join evidence_requirement evr on evr.id = er.evidence_requirement_id
         where er.engagement_id = s.engagement_id
           and evr.element_id = e.id and er.state = 'waived')
         as evidence_waived,
       (select jsonb_agg(distinct evr.analysis_key)
          from evidence_requirement evr
         where evr.element_id = e.id and evr.analysis_key is not null)
         as analyses_that_serve_it
  from score s
  join element e on e.id = s.element_id
  left join lifecycle_stage ls on ls.code = e.stage_code;

comment on view element_scoring_surface is
  'One row per element on an engagement: the anchors to read, the score as '
  'it stands, the cap if there is one, and whether its evidence is in.';

insert into gea_migration (filename, note) values
  ('063_scoring.sql',
   'Setting a score, citing what it rests on, and the surface a person needs '
   'in front of them to do it.');
