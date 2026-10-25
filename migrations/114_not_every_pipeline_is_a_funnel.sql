-- 114 Not every pipeline is a funnel.
--
-- A renewals book is not a pipeline with a leak. An auto-renewal is
-- created at Signature and never passes through Discover, so the deals
-- pile up wherever they belong and a later stage holds more than an
-- earlier one. Drawn as a funnel on a real client, that produced
-- conversion rates of eight hundred per cent and a shape that invited
-- the reader to ask how deals were appearing from nowhere.
--
-- They were not appearing. They were starting there.
--
-- So a pipeline records whether its deals arrive at the top, and the
-- screen and the report can stop drawing a funnel over something that
-- is not one.

alter table pipeline
  add column enters_at_the_top numeric,
  add column is_a_funnel boolean not null default true;

comment on column pipeline.enters_at_the_top is
  'The share of this segment''s deals that start at its first stage. '
  'Low means they are created partway down, which a renewals book does '
  'by design.';

comment on column pipeline.is_a_funnel is
  'Whether stage-to-stage conversion means anything here. Where deals '
  'enter partway it does not, and none is computed.';

drop view if exists pipeline_board;
create view pipeline_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.segment_field,
       p.segment_fields, p.segment_values, p.era, p.era_from, p.era_to,
       p.era_label, p.deals, p.deals_with_any_stage_date,
       p.stage_records_inferred,
       p.enters_at_the_top, p.is_a_funnel,
       p.confirmed_at, u.display_name as confirmed_by_name,
       count(s.id) filter (where not s.is_outcome) as stages,
       jsonb_agg(jsonb_build_object(
         'stage', s.stage_name, 'position', s.position,
         'deals_entered', s.deals_entered,
         'deals_recorded', s.deals_recorded,
         'conversion_from_previous', s.conversion_from_previous,
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
  'Each pipeline the client runs: the working stages in order, then the '
  'win, then the ways a deal leaks out. Where is_a_funnel is false the '
  'deals enter partway and there is no conversion to read.';

insert into gea_migration (filename, note) values
  ('114_not_every_pipeline_is_a_funnel.sql',
   'A segment whose deals are created partway down is not a funnel, and '
   'conversion is not computed for it.')
on conflict do nothing;
