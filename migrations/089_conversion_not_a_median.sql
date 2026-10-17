-- 089 A conversion rate, and outcomes that are not stages.
--
-- Two things the first funnel got wrong, both visible the moment it was
-- drawn on a real client.
--
--   It showed a median date per stage. Those dates come only from the
--   records the client kept, and on a pipeline where most records were
--   inferred that is a small, biased and differently-biased sample at
--   every stage. The medians ran backwards: the first stage's median was
--   February 2026 and the third stage's was July 2025, which no deal
--   could have done. A median of a biased sample is not a smaller truth,
--   it is a different one.
--
--   It drew Closed Won, Closed Lost, Qualified Out and Closed Cancelled
--   in sequence, as though a deal passed through all four. They are four
--   answers to the same question and a deal reaches exactly one.
--
-- What the funnel is for is the conversion from one stage to the next,
-- which is what it now carries.

alter table pipeline_stage
  add column is_outcome boolean not null default false,
  add column conversion_from_previous numeric;

comment on column pipeline_stage.is_outcome is
  'Where a deal ends rather than somewhere it passes through. An outcome '
  'is not the stage after the one before it.';

comment on column pipeline_stage.conversion_from_previous is
  'Of the deals that reached the previous stage, the share that reached '
  'this one. For an outcome, the share of deals that got to the end of '
  'the pipeline and ended this way.';

drop view if exists pipeline_board;
create view pipeline_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.segment_field,
       p.segment_fields, p.segment_values, p.era, p.era_from, p.era_to,
       p.era_label, p.deals, p.deals_with_any_stage_date,
       p.stage_records_inferred,
       p.confirmed_at, u.display_name as confirmed_by_name,
       count(s.id) filter (where not s.is_outcome) as stages,
       jsonb_agg(jsonb_build_object(
         'stage', s.stage_name, 'position', s.position,
         'deals_entered', s.deals_entered,
         'deals_recorded', s.deals_recorded,
         'conversion_from_previous', s.conversion_from_previous,
         'is_outcome', s.is_outcome,
         'from_column', s.source_column,
         'date_is', s.date_kind,
         'closed_won', s.is_closed_won, 'closed_lost', s.is_closed_lost)
         order by s.is_outcome, s.position) filter (where s.id is not null)
         as stage_detail,
       (select count(*) from deal_stage_entry d
         where d.engagement_id = p.engagement_id and d.segment = p.segment
           and d.era = p.era) as entries
  from pipeline p
  left join pipeline_stage s on s.pipeline_id = p.id
  left join app_user u on u.id = p.confirmed_by
 group by p.id, u.display_name;

comment on view pipeline_board is
  'Each pipeline the client runs, its stages in order with the conversion '
  'into each, and its outcomes separately. The stage count excludes the '
  'outcomes, because a pipeline with six stages and five ways to end is '
  'a six-stage pipeline.';

insert into gea_migration (filename, note) values
  ('089_conversion_not_a_median.sql',
   'A stage carries the conversion into it rather than a median date, and '
   'an outcome is not the stage after the one before it.');
