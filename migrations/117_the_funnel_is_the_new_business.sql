-- 117 The funnel is the new business.
--
-- 116 told the motions apart by the shape of each deal's journey: how
-- many stages it touched, where its first record sat. That was
-- inferring something the client already records.
--
-- The deals export has a Type column reading Auto Renewal, Renewal, Add
-- On, New Business. A hundred and fifty one-stage deals at Signature
-- are auto-renewals and the file says so; thirty-seven one-stage deals
-- at Discover are new business and the file says that too. Same shape,
-- different things. No arithmetic separates them as well as reading the
-- label, and the arithmetic threw out seventy-two real deals that
-- opened at Nurture because the first two stages are administrative,
-- along with fifty-two leads that were worked and disqualified early —
-- which are leakage at the top of the funnel and belong in it.
--
-- So the funnel is the new business, which is what a sales leader means
-- by the pipeline, and the other motions are counted beside it.

-- The view reads them, so it goes first and is rebuilt below.
drop view if exists pipeline_board;

alter table pipeline
  drop column if exists walked_the_pipeline,
  drop column if exists created_partway_down,
  drop column if exists too_little_recorded,
  drop column if exists created_at_detail;

alter table pipeline
  add column new_business integer,
  add column renewals integer,
  add column expansion integer,
  add column not_labelled integer,
  add column other_motions jsonb not null default '{}'::jsonb;

comment on column pipeline.new_business is
  'Deals the client labels as new business. The funnel is these and '
  'only these: counts, conversion and duration all describe them.';

comment on column pipeline.renewals is
  'Deals the client labels renewal or auto-renewal. A renewals book is '
  'not a pipeline with a leak, and averaging the two describes neither.';

comment on column pipeline.expansion is
  'Add-ons and upsells. A third motion, usually opened near the end of '
  'the process, and worth its own paragraph in a report.';

comment on column pipeline.not_labelled is
  'Deals whose type the client did not record. Where this is most of '
  'them the funnel could not be separated, and that is worth saying '
  'rather than hiding behind a mixed picture.';

comment on column pipeline.other_motions is
  'Where the renewals and the add-ons are created. The shape of the '
  'business that does not come through the funnel.';

drop view if exists pipeline_board;
create view pipeline_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.segment_field,
       p.segment_fields, p.segment_values, p.era, p.era_from, p.era_to,
       p.era_label, p.deals, p.deals_with_any_stage_date,
       p.stage_records_inferred, p.enters_at_the_top, p.is_a_funnel,
       p.new_business, p.renewals, p.expansion, p.not_labelled,
       p.other_motions,
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
  'Each pipeline the client runs. The stages describe the new-business '
  'deals; the renewals and add-ons are counted beside them, with where '
  'they are created.';

insert into gea_migration (filename, note) values
  ('117_the_funnel_is_the_new_business.sql',
   'The motions are told apart by the type the client records, not by '
   'the shape of a journey.')
on conflict do nothing;
