-- 087 Nested segments, and the pipeline a client used to have.
--
-- Three things the first version of this got wrong, all found by running
-- it on a real client.
--
--   A pipeline had one segment. The client splits by division — Regulated
--   East, Regulated West, Retail — and also by deal type — New Business,
--   Add On, Renewal. Both are real questions and choosing between them
--   throws away the other. A segment is a path now, so Regulated (West)
--   holds its own four pipelines and the division's own picture is the
--   roll-up of them.
--
--   The detection read the deals export, which only knows the present. A
--   deal's stage column holds the stage it is in today, so every pipeline
--   it found was the current one. The history export holds every
--   transition, including the ones into stages nobody uses any more.
--
--   And a client can change their pipeline. This one replaced twelve
--   stages with six in the middle of the assessment window and is still
--   moving deals across by hand. A single definition per segment cannot
--   say that, and any conversion rate spanning the change is meaningless.
--   So a pipeline has an era: the period a stage set was in use, with the
--   date it gave way.

alter table pipeline
  add column segment_fields text[] not null default array[]::text[],
  add column segment_values text[] not null default array[]::text[],
  add column era integer not null default 1,
  add column era_from date,
  add column era_to date,
  add column era_label text;

comment on column pipeline.segment_fields is
  'The columns the split was made on, outermost first: the division, then '
  'the deal type within it.';
comment on column pipeline.segment_values is
  'This pipeline''s value at each level, in the same order. The segment '
  'column holds them joined for display.';
comment on column pipeline.era is
  'Which stage set this is. A client that replaces its pipeline has more '
  'than one, and a conversion rate spanning the change means nothing.';
comment on column pipeline.era_to is
  'When this stage set gave way to the next, where it did. Null while it '
  'is the one in use.';

alter table pipeline drop constraint if exists pipeline_engagement_id_segment_key;
create unique index pipeline_one_per_segment_and_era
    on pipeline (engagement_id, segment, era);

alter table deal_stage_entry
  add column era integer not null default 1;

comment on column deal_stage_entry.era is
  'The stage set this entry belongs to, so rows from two pipelines are '
  'never averaged together.';

-- Which pipeline a row belongs to is now a segment and an era.
alter table deal_stage_entry drop constraint deal_stage_entry_pkey;
alter table deal_stage_entry
  add primary key (engagement_id, opportunity_id, stage_name, era);

-- The column list changes, so the view goes first.
drop view if exists pipeline_board;
create view pipeline_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.segment_field,
       p.segment_fields, p.segment_values, p.era, p.era_from, p.era_to,
       p.era_label, p.deals, p.deals_with_any_stage_date,
       p.confirmed_at, u.display_name as confirmed_by_name,
       count(s.id) as stages,
       jsonb_agg(jsonb_build_object(
         'stage', s.stage_name, 'position', s.position,
         'deals_entered', s.deals_entered, 'median_entered', s.median_entered,
         'from_column', s.source_column,
         'date_is', s.date_kind,
         'closed_won', s.is_closed_won, 'closed_lost', s.is_closed_lost)
         order by s.position) filter (where s.id is not null) as stage_detail,
       (select count(*) from deal_stage_entry d
         where d.engagement_id = p.engagement_id and d.segment = p.segment
           and d.era = p.era) as entries
  from pipeline p
  left join pipeline_stage s on s.pipeline_id = p.id
  left join app_user u on u.id = p.confirmed_by
 group by p.id, u.display_name;

comment on view pipeline_board is
  'Each pipeline the client runs: a segment path, an era, and the stages '
  'in it. A client with three divisions, four deal types and a pipeline '
  'change has more than one.';

insert into gea_migration (filename, note) values
  ('087_nested_segments_and_pipeline_eras.sql',
   'A pipeline belongs to a nested segment and an era, because a client '
   'splits more than one way and changes their stages.');
