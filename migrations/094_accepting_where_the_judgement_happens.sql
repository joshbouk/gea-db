-- 094 Accepting where the judgement happens.
--
-- Three runs sit in the review queue whose result a person already judges
-- somewhere better.
--
--   detect_pipeline writes the client's stages, and a consultant confirms
--   those on the pipeline screen, where the stages and their order are in
--   front of them. Accepting the run afterwards is a second approval of
--   the same thing in a worse place to make it.
--
--   The adversarial review becomes challenges, each of which gets a
--   written defence or a concession on the challenge board.
--
--   Interview synthesis is accepted from the interview screen.
--
-- Taking them out of the queue is not enough on its own. A task waits for
-- every supported analysis to be accepted, so a run that leaves the queue
-- without its approval moving somewhere would leave that task unable to
-- close. So the approval moves rather than disappearing: confirming the
-- pipeline accepts the run that produced it.
--
-- And a reviewer needs to know what they are agreeing to. The queue asked
-- for a judgement and showed only the result, so "accept" meant "this
-- looks fine". It should mean "I am willing to have a score and a
-- client-facing sentence rest on this", and it should say what would make
-- the figure wrong.

alter table analysis_run
  add column judged_elsewhere text;

comment on column analysis_run.judged_elsewhere is
  'Where this run''s result is judged, for runs whose output a person '
  'confirms on a screen built for it. Such a run is accepted by that '
  'confirmation rather than by a second pass through the review queue.';

-- A column is added in the middle, so the view goes first.
drop view if exists run_review_board;
create view run_review_board
with (security_invoker = true) as
 SELECT id AS run_id,
    engagement_id,
    job_type,
    (status)::text AS status,
    created_at,
    finished_at,
    error,
    model_name,
    accepted_at,
    accepted_by,
    review_note,
    discarded_reason,
    progress_done,
    progress_total,
    -- A finding is a result nobody judges anywhere else.
    (((job_type ~~ 'analysis:%'::text) OR (job_type ~~ 'classify:%'::text)
      OR (job_type ~~ 'generate:%'::text)
      OR (job_type = 'synthesise_interview'::text))
     AND judged_elsewhere IS NULL) AS is_a_finding,
    judged_elsewhere,
    (compute_output ? 'to_check_by_hand'::text) AS needs_records_read,
    COALESCE(((compute_output ->> 'census_complete'::text))::boolean, true)
      AS census_complete
   FROM analysis_run r;

comment on view run_review_board is
  'Every run, and whether it is a finding somebody has to accept. A run '
  'whose result is confirmed on a screen built for it is not: it is '
  'accepted there.';

-- Runs whose judgement belongs somewhere else --------------------------------

create or replace function trg_judged_elsewhere() returns trigger
language plpgsql as $fn$
begin
  new.judged_elsewhere := case
    when new.job_type = 'analysis:detect_pipeline'
      then 'the pipeline screen, where the stages are confirmed'
    when new.job_type = 'analysis:adversarial_score_review'
      then 'the challenge board, where each challenge is answered'
    when new.job_type = 'synthesise_interview'
      then 'the interview screen, where the synthesis is read'
    else null end;
  return new;
end $fn$;

create trigger judged_elsewhere
  before insert on analysis_run
  for each row execute function trg_judged_elsewhere();

update analysis_run
   set judged_elsewhere = case
     when job_type = 'analysis:detect_pipeline'
       then 'the pipeline screen, where the stages are confirmed'
     when job_type = 'analysis:adversarial_score_review'
       then 'the challenge board, where each challenge is answered'
     when job_type = 'synthesise_interview'
       then 'the interview screen, where the synthesis is read'
     else null end
 where job_type in ('analysis:detect_pipeline',
                    'analysis:adversarial_score_review',
                    'synthesise_interview');

-- Confirming the pipeline accepts the run that produced it -------------------

-- A column is added to what it returns, so the old one goes first.
drop function if exists gea_confirm_pipeline(uuid, jsonb);

create function gea_confirm_pipeline(
  p_pipeline uuid, p_stages jsonb default null)
returns table (segment text, stages integer, run_accepted boolean)
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; v_eng uuid; r jsonb; n integer; v_run uuid;
begin
  select engagement_id into v_eng from pipeline where id = p_pipeline;
  if v_eng is null then
    raise exception 'that pipeline is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  if p_stages is not null then
    for r in select * from jsonb_array_elements(p_stages) loop
      update pipeline_stage
         set position = (r ->> 'position')::integer
       where pipeline_id = p_pipeline and stage_name = r ->> 'stage_name';
    end loop;
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;
  update pipeline set confirmed_at = now(), confirmed_by = v_me
   where id = p_pipeline;

  -- The approval is here, not in the review queue. A person who has just
  -- read the stages and their order has judged the run; asking them again
  -- somewhere with less in front of them would add nothing.
  select r2.id into v_run
    from analysis_run r2
   where r2.engagement_id = v_eng
     and r2.job_type = 'analysis:detect_pipeline'
     and r2.status = 'succeeded' and not r2.is_stale
     and r2.accepted_at is null
   order by r2.finished_at desc limit 1;
  if v_run is not null then
    update analysis_run
       set accepted_at = now(), accepted_by = v_me,
           review_note = 'Accepted by confirming the pipeline.'
     where id = v_run;
  end if;

  select p.segment, count(*) into segment, n
    from pipeline p join pipeline_stage s on s.pipeline_id = p.id
   where p.id = p_pipeline group by p.segment;
  stages := n;
  run_accepted := v_run is not null;
  return next;
end $fn$;

comment on function gea_confirm_pipeline is
  'A person has looked at the stages found in the client''s data and says '
  'they are right, optionally correcting the order. This is also where '
  'the run that found them is accepted: the judgement happens here, with '
  'the stages in front of them, and not again in a queue.';

insert into gea_migration (filename, note) values
  ('094_accepting_where_the_judgement_happens.sql',
   'A run whose result is confirmed on its own screen is accepted there, '
   'not a second time in the review queue.');

-- What a reviewer is agreeing to -------------------------------------------
--
-- The queue asked for a judgement and showed only the result, so
-- "accept" meant "this looks fine". It should mean "I am willing to have
-- a score and a client-facing sentence rest on this".
--
-- Two things make that possible. What would make the figure wrong, which
-- is different for every analysis and is the thing a reviewer cannot work
-- out from the output alone: a win rate of eighty-eight per cent looks
-- fine until somebody says that unrecognised outcome values show up as
-- still-open deals. And what accepting commits them to, which is the
-- elements it will support and the findings it will produce.

create table analysis_guidance (
  instrument_version_id uuid not null references instrument_version(id)
                        on delete cascade,
  analysis_key  text not null,
  what_to_check text not null,
  goes_wrong    text not null,
  primary key (instrument_version_id, analysis_key)
);

comment on table analysis_guidance is
  'What a reviewer should look at before accepting each analysis, and how '
  'it characteristically goes wrong. Reference data: it changes with the '
  'methodology, not with an engagement.';

comment on column analysis_guidance.what_to_check is
  'The one check worth doing, in a sentence a reviewer can act on without '
  'opening the data.';

alter table analysis_guidance enable row level security;
create policy analysis_guidance_read on analysis_guidance
  for select to authenticated using (true);

create or replace view run_review_guidance
with (security_invoker = true) as
select r.id as run_id, r.engagement_id, g.analysis_key,
       g.what_to_check, g.goes_wrong,
       -- What accepting this commits them to.
       coalesce((select array_agg(distinct e.ref order by e.ref)
                   from evidence_requirement er
                   join element e on e.id = er.element_id
                  where er.instrument_version_id = ev.instrument_version_id
                    and er.analysis_key = g.analysis_key),
                array[]::text[]) as elements_it_supports
  from analysis_run r
  join engagement ev on ev.id = r.engagement_id
  join analysis_guidance g
    on g.instrument_version_id = ev.instrument_version_id
   and g.analysis_key = replace(r.job_type, 'analysis:', '');

comment on view run_review_guidance is
  'For one run: the check worth doing before accepting it, how this '
  'analysis goes wrong, and which elements will rest on it afterwards.';
