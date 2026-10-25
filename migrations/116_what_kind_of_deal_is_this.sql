-- 116 What kind of deal is this.
--
-- A client's opportunity table holds more than one thing. There are
-- deals that work their way down a sales process, and there are records
-- created near the end of it: auto-renewals written straight into
-- Contract, add-ons booked at Propose, a migration that loaded closed
-- business wherever it finished.
--
-- Measured together they produce a shape that is nobody's pipeline.
-- Counts that rise at late stages, conversion above a hundred per cent,
-- and a drawing that invites the reader to ask how deals appeared from
-- nowhere. Several attempts were made to patch that at the point of
-- display, and each broke a segment it was not aimed at, because the
-- problem was never in the display.
--
-- Every deal is now labelled before anything is measured, and the
-- funnel is computed over the deals that went through one. The rest are
-- counted and named here, because a hundred and fifteen auto-renewals
-- is a fact about how this client's revenue arrives and not a defect.

alter table pipeline
  add column walked_the_pipeline integer,
  add column created_partway_down integer,
  add column too_little_recorded integer,
  add column created_at_detail jsonb not null default '[]'::jsonb;

comment on column pipeline.walked_the_pipeline is
  'Deals with enough recorded stages to have travelled from the top to '
  'where they got. The funnel is these deals and only these.';

comment on column pipeline.created_partway_down is
  'Deals whose first record is well down the process with too few moves '
  'to have reached it. An auto-renewal written into Contract.';

comment on column pipeline.too_little_recorded is
  'Deals where one record early on fits either story. Held apart rather '
  'than guessed at, so a client whose tracking is too thin can be told '
  'so instead of shown a confident figure.';

comment on column pipeline.created_at_detail is
  'Where the deals created partway down were created, and how many at '
  'each. The shape of the renewals book.';

drop view if exists pipeline_board;
create view pipeline_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.segment_field,
       p.segment_fields, p.segment_values, p.era, p.era_from, p.era_to,
       p.era_label, p.deals, p.deals_with_any_stage_date,
       p.stage_records_inferred, p.enters_at_the_top, p.is_a_funnel,
       p.walked_the_pipeline, p.created_partway_down,
       p.too_little_recorded, p.created_at_detail,
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
  'Each pipeline the client runs. The working stages are measured over '
  'the deals that walked them; the deals created partway down are '
  'counted beside, with where they were created.';

insert into gea_migration (filename, note) values
  ('116_what_kind_of_deal_is_this.sql',
   'Deals are labelled before the pipeline is measured, so a sales '
   'funnel and a renewals book are no longer averaged together.')
on conflict do nothing;
