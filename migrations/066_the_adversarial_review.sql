-- 066 Arguing against the scorecard, automatically.
--
-- GEA-P17 exists and nothing runs it. Its instruction is unusually blunt:
-- argue against every score, do not confirm any of them, do not suggest
-- report wording. Run before the client sees anything, it catches the two
-- failures that matter — a four or five awarded on evidence that does not
-- meet the anchor, and a zero or one that confuses an absence of the thing
-- with an absence of evidence about the thing.
--
-- It is not an analysis in the sense the other thirteen are. It reads no
-- client export: it reads the scorecard Blend has just written, which makes
-- it the one place where the assessment is turned on itself.
--
-- The output is a list of challenges, and challenges already have a home.
-- So the run raises them and a person defends or concedes each one, exactly
-- as if a colleague had raised them. Nothing it produces is binding.

-- What the review needs to see --------------------------------------------
-- The scorecard as written, with the anchor the score claims and what it
-- rests on. Anything less and the review is guessing at what it argues with.

create or replace function gea_scorecard_for_review(p_engagement uuid)
returns table (element_ref text, element_name text, why_assessed text,
               value integer, not_evidenced boolean, ne_reason text,
               confidence text, scoring_note text, cap_applied integer,
               anchor_claimed text, anchor_below text, anchor_above text,
               citations jsonb)
language sql stable security definer set search_path = public as $fn$
  select e.ref, e.name, e.why_assessed,
         s.value, s.not_evidenced, s.ne_reason,
         s.confidence::text, s.scoring_note, s.cap_applied,
         (select a.descriptor from anchor a
           where a.element_id = e.id and a.level = s.value),
         (select a.descriptor from anchor a
           where a.element_id = e.id and a.level = s.value - 1),
         (select a.descriptor from anchor a
           where a.element_id = e.id and a.level = s.value + 1),
         (select jsonb_agg(jsonb_build_object(
                   'what', case
                     when c.analysis_run_id is not null
                       then 'the ' || replace(split_part(r.job_type, ':', 2), '_', ' ')
                            || ' analysis'
                     when c.artefact_id is not null
                       then 'the file ' || a2.original_filename
                     else 'an interview' end,
                   'note', c.note))
            from score_citation c
            left join analysis_run r on r.id = c.analysis_run_id
            left join artefact a2 on a2.id = c.artefact_id
           where c.score_id = s.id)
    from score s
    join element e on e.id = s.element_id
   where s.engagement_id = p_engagement
     and s.state <> 'unscored'
   order by e.ref;
$fn$;

comment on function gea_scorecard_for_review is
  'The scorecard as written, with the anchor each score claims, the anchors '
  'either side of it, and what it rests on. What the adversarial review '
  'argues against.';

-- Recording what it found ---------------------------------------------------

create or replace function gea_record_challenges(
  p_run uuid, p_challenges jsonb)
returns table (raised integer, skipped integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_run  record;
  v_el   uuid;
  v_n    integer := 0;
  v_skip integer := 0;
  r      jsonb;
begin
  select * into v_run from analysis_run where id = p_run;
  if v_run.id is null then
    raise exception 'that run is not on record' using errcode = 'check_violation';
  end if;

  if not app_is_member(v_run.engagement_id) and not app_is_service() then
    raise exception
      'you are not on this engagement''s team, so nothing was raised'
      using errcode = 'insufficient_privilege';
  end if;

  if (select score_frozen_at from engagement where id = v_run.engagement_id)
     is not null then
    raise exception
      'the scorecard is frozen, so a challenge could not change anything'
      using errcode = 'check_violation';
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_challenges, '[]'::jsonb))
  loop
    select e.id into v_el
      from element e
      join engagement en on en.id = v_run.engagement_id
                        and en.instrument_version_id = e.instrument_version_id
     where e.ref = r ->> 'element_ref';

    -- A challenge against an element that is not on the instrument, or with
    -- nothing actually argued, is not recorded. Both are signs the review
    -- wandered off, and the count of what was skipped is reported so nobody
    -- reads a short list as a clean scorecard.
    if v_el is null
       or coalesce(btrim(r ->> 'challenge'), '') = '' then
      v_skip := v_skip + 1;
      continue;
    end if;

    insert into challenge (engagement_id, element_id, analysis_run_id,
                           challenge_text, weakness_type)
         values (v_run.engagement_id, v_el, p_run,
                 btrim(r ->> 'challenge'),
                 nullif(btrim(r ->> 'weakness_type'), ''));
    v_n := v_n + 1;
  end loop;

  raised := v_n;
  skipped := v_skip;
  return next;
end $fn$;

comment on function gea_record_challenges is
  'Record what the adversarial review argued. A challenge against an unknown '
  'element, or with nothing argued, is skipped and counted.';

-- What a person works through ------------------------------------------------

create or replace view challenge_board
with (security_invoker = true) as
select c.engagement_id, c.id as challenge_id, e.ref as element_ref,
       e.name as element_name, c.challenge_text, c.weakness_type,
       c.disposition, c.response_note, c.created_at,
       u.display_name as resolved_by_name,
       c.analysis_run_id is not null as raised_by_the_review,
       s.id as score_id, s.value, s.not_evidenced, s.state,
       (select count(*) from score_citation sc where sc.score_id = s.id)
         as citations
  from challenge c
  join element e on e.id = c.element_id
  left join score s on s.element_id = c.element_id
                   and s.engagement_id = c.engagement_id
  left join app_user u on u.id = c.resolved_by;

comment on view challenge_board is
  'Every challenge on an engagement with the score it argues against, so a '
  'person can defend or concede without going to look the score up.';

insert into gea_migration (filename, note) values
  ('066_the_adversarial_review.sql',
   'The scorecard can be read for review, the review''s challenges recorded, '
   'and the whole set worked through from one board.');
