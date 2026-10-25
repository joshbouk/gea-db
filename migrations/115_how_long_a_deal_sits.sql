-- 115 How long a deal sits.
--
-- The pipeline knows how many deals reached each stage and says nothing
-- about how long they stayed. A stage that converts at ninety-nine per
-- cent and holds deals for a hundred days is a different problem from
-- one that converts at ninety-nine per cent in a week, and the screen
-- cannot tell them apart.
--
-- The duration is computed where a deal has a dated record at this
-- stage and a dated record at the next. That is far fewer deals than
-- reached the stage, because a stage filled in by inference carries no
-- date — a deal certainly passed through it on a day nobody wrote down,
-- which supports a conversion rate and supports no duration at all.
--
-- So the count behind the figure is stored beside it. A median from
-- eleven deals and a median from four hundred are both medians and only
-- one is worth reading, and the only way to tell is to say.

alter table pipeline_stage
  add column median_days_here numeric,
  add column days_measured_on integer;

comment on column pipeline_stage.median_days_here is
  'Median days between arriving at this stage and arriving at the next, '
  'for the deals where both were dated.';

comment on column pipeline_stage.days_measured_on is
  'How many deals that median rests on. Far fewer than reached the '
  'stage, because an inferred stage record has no date. A median from '
  'eleven deals is not the same claim as one from four hundred.';

drop view if exists pipeline_board;
create view pipeline_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.segment_field,
       p.segment_fields, p.segment_values, p.era, p.era_from, p.era_to,
       p.era_label, p.deals, p.deals_with_any_stage_date,
       p.stage_records_inferred, p.enters_at_the_top, p.is_a_funnel,
       p.confirmed_at, u.display_name as confirmed_by_name,
       count(s.id) filter (where not s.is_outcome) as stages,
       jsonb_agg(jsonb_build_object(
         'stage', s.stage_name, 'position', s.position,
         'deals_entered', s.deals_entered,
         'deals_recorded', s.deals_recorded,
         'conversion_from_previous', s.conversion_from_previous,
         'median_days_here', s.median_days_here,
         'days_measured_on', s.days_measured_on,
         'is_outcome', s.is_outcome,
         'closed_won', s.is_closed_won, 'closed_lost', s.is_closed_lost,
         'from_column', s.source_column, 'date_is', s.date_kind)
         order by s.is_outcome, s.is_closed_won desc, s.position)
         filter (where s.id is not null) as stage_detail,
       (select count(*) from deal_stage_entry d
         where d.engagement_id = p.engagement_id and d.segment = p.segment
           and d.era = p.era) as entries
  from pipeline p
  left join pipeline_stage s on s.pipeline_id = p.id
  left join app_user u on u.id = p.confirmed_by
 group by p.id, u.display_name;

comment on view pipeline_board is
  'Each pipeline the client runs: the working stages in order with how '
  'many reached each and how long they stayed, then the win, then the '
  'ways a deal leaks out.';

insert into gea_migration (filename, note) values
  ('115_how_long_a_deal_sits.sql',
   'A stage records how long deals stayed, and how many deals that '
   'figure rests on.')
on conflict do nothing;
