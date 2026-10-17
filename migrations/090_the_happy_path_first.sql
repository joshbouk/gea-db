-- 090 The happy path first.
--
-- A funnel reads as a route to a win. The outcomes were ordered among
-- themselves by when they happened, which on a client whose newer
-- pipeline numbers none of them put Closed Lost above Closed Won. Every
-- rate beside it then reads as the wrong thing: a reader following the
-- shape downwards meets the loss first and takes it for the destination.
--
-- So the win comes first among the outcomes, and the ways a deal leaks
-- out of the pipeline follow it, commonest first.

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
         'closed_won', s.is_closed_won, 'closed_lost', s.is_closed_lost,
         'from_column', s.source_column, 'date_is', s.date_kind)
         -- The working stages in order, then the win, then the rest.
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
  'Each pipeline the client runs: the working stages in order with the '
  'conversion into each, then the win, then the ways a deal leaks out.';

insert into gea_migration (filename, note) values
  ('090_the_happy_path_first.sql',
   'The win is the first outcome. A loss drawn above it makes every rate '
   'beside it read as the wrong thing.');
