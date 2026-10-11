-- 043 Readiness, and names for the stages.
--
-- Two figures, never merged. Evidence readiness asks whether the evidence
-- exists. Scoring progress asks whether the judgement has been made. Collapsing
-- them into one number hides the week-four failure where everything has been
-- gathered and nothing has been scored, and that is the failure worth seeing.
--
-- Readiness counts requirements, not elements, because a requirement is the
-- thing somebody chases. An element with four requirements and three satisfied
-- is not three-quarters ready to score: it is not ready, and the fourth is the
-- phone call to make.
--
-- Waived counts as resolved. Without that the figure would stall below a
-- hundred on nearly every engagement — a refused export and a declined
-- interview are normal — and a number that never reaches its top is a number
-- people stop reading.
--
-- The eight lifecycle stages have codes in the element table and no names.
-- "Stage 05" on a readiness chart tells a consultant nothing, so the names
-- come in here. They live outside the instrument version, like the step
-- catalogue, because they are labels rather than methodology: an instrument
-- version is immutable and renaming a stage should not require a new one.

create table lifecycle_stage (
  code       text primary key check (code ~ '^[0-9]{2}$'),
  name       text not null,
  sort_order integer not null
);

comment on table lifecycle_stage is
  'Names for the eight lifecycle stages. Outside the instrument version '
  'because they are labels, not methodology.';

alter table lifecycle_stage enable row level security;
create policy lifecycle_stage_read on lifecycle_stage
  for select to authenticated using (app_is_blend_user());

insert into lifecycle_stage (code, name, sort_order) values
  ('01', 'Product-market fit and ICP clarity', 10),
  ('02', 'Messaging resonance',                20),
  ('03', 'Distribution',                       30),
  ('04', 'Engagement',                         40),
  ('05', 'Sales execution',                    50),
  ('06', 'Customer delivery',                  60),
  ('07', 'Customer excitement',                70),
  ('08', 'Expansion',                          80);

-- Readiness by stage ---------------------------------------------------------
-- Eight stages and a ninth row for the handoffs, which belong to no stage and
-- are where most engagements are weakest.

create or replace view engagement_stage_readiness
with (security_invoker = true) as
select er.engagement_id,
       coalesce(e.stage_code, 'H') as stage_code,
       coalesce(ls.name, 'Handoffs between stages') as stage_name,
       coalesce(ls.sort_order, 90) as sort_order,
       count(*)                                        as requirements,
       count(*) filter (where er.state = 'satisfied')   as satisfied,
       count(*) filter (where er.state = 'waived')      as waived,
       count(*) filter (where er.state = 'outstanding') as outstanding,
       round(100.0 * count(*) filter (where er.state <> 'outstanding')
             / nullif(count(*), 0)) as ready_percent,
       count(distinct e.id)                             as elements,
       count(distinct e.id) filter (where s.state = 'final')  as elements_final,
       count(distinct e.id) filter (where s.state <> 'unscored') as elements_scored
  from engagement_requirement er
  join evidence_requirement evr on evr.id = er.evidence_requirement_id
  join element e on e.id = evr.element_id
  left join lifecycle_stage ls on ls.code = e.stage_code
  left join score s on s.element_id = e.id and s.engagement_id = er.engagement_id
 group by er.engagement_id, e.stage_code, ls.name, ls.sort_order;

comment on view engagement_stage_readiness is
  'Evidence readiness and scoring progress per lifecycle stage, with a ninth '
  'row for the handoffs. Two separate figures: never add them together.';

-- Readiness by where the evidence comes from ---------------------------------
-- Four different chase activities with four different owners. A consultant
-- looking at 60 per cent needs to know whether the missing 40 is an export
-- nobody has sent or an interview nobody has booked.

create or replace view engagement_source_readiness
with (security_invoker = true) as
select er.engagement_id,
       evr.source_kind,
       count(*)                                        as requirements,
       count(*) filter (where er.state = 'satisfied')   as satisfied,
       count(*) filter (where er.state = 'waived')      as waived,
       count(*) filter (where er.state = 'outstanding') as outstanding,
       round(100.0 * count(*) filter (where er.state <> 'outstanding')
             / nullif(count(*), 0)) as ready_percent
  from engagement_requirement er
  join evidence_requirement evr on evr.id = er.evidence_requirement_id
 group by er.engagement_id, evr.source_kind;

-- The headline ---------------------------------------------------------------

create or replace view engagement_readiness
with (security_invoker = true) as
select e.id as engagement_id,
       r.requirements,
       r.satisfied,
       r.waived,
       r.outstanding,
       round(100.0 * (r.satisfied + r.waived) / nullif(r.requirements, 0))
         as evidence_ready_percent,
       s.elements,
       s.provisional,
       s.final,
       s.not_evidenced,
       -- Provisional counts. The judgement has been made; it is not yet
       -- final because the evidence is still moving. Counting only final
       -- scores would leave this at zero through all of provisional scoring,
       -- which is most of week four.
       round(100.0 * (s.provisional + s.final) / nullif(s.elements, 0))
         as scored_percent,
       round(100.0 * s.final / nullif(s.elements, 0)) as final_percent
  from engagement e
  left join lateral (
    select count(*) as requirements,
           count(*) filter (where state = 'satisfied') as satisfied,
           count(*) filter (where state = 'waived') as waived,
           count(*) filter (where state = 'outstanding') as outstanding
      from engagement_requirement where engagement_id = e.id) r on true
  left join lateral (
    select count(*) as elements,
           count(*) filter (where state = 'provisional') as provisional,
           count(*) filter (where state = 'final') as final,
           count(*) filter (where not_evidenced) as not_evidenced
      from score where engagement_id = e.id) s on true;

comment on view engagement_readiness is
  'The two headline figures for an engagement. evidence_ready_percent is how '
  'much of the evidence has arrived; scored_percent is how much judgement has '
  'been made. They answer different questions and are never combined.';

insert into gea_migration (filename, note) values
  ('043_readiness.sql',
   'Readiness by stage and by evidence source, the two headline figures, and '
   'names for the eight lifecycle stages.');
