-- 088 How the client splits its business.
--
-- The pipeline detection worked out which columns to split by from a
-- hardcoded list: opportunity_type, then account_segment, then
-- product_family. Which of a client's dimensions matters is a
-- consultant's judgement and not something to fix in a list, and the
-- list had two further faults.
--
--   The column that matters is often one the instrument has no field
--   for. The first real client separates its motions by the deal owner's
--   division, which is not a Growth Engineering concept and never will
--   be, and is the most important dimension in their business.
--
--   Getting the order you wanted meant mapping a division to a field
--   called opportunity_type and a deal type to one called
--   account_segment. Both mappings then say something untrue, and the
--   next person to read them has no idea what happened.
--
-- So the split belongs to the engagement: whichever columns a consultant
-- names, in the order they name them. And it is not a pipeline setting.
-- Every analysis that reports a rate should be able to cut by it, which
-- is the whole reason for having it.

create table engagement_segmentation (
  id            uuid primary key default gen_random_uuid(),
  engagement_id uuid not null references engagement(id) on delete cascade,
  level         integer not null,
  dataset_id    uuid not null references dataset(id) on delete cascade,
  column_name   text not null,
  label         text,
  chosen_by     uuid references app_user(id),
  chosen_at     timestamptz not null default now(),
  unique (engagement_id, level)
);

comment on table engagement_segmentation is
  'The columns this client''s business is split by, outermost first. Any '
  'column of any file they have sent, because the dimension that matters '
  'is often one the instrument has no field for.';

comment on column engagement_segmentation.level is
  'One is the outermost. A client split by division and then by deal '
  'type has two rows.';

comment on column engagement_segmentation.label is
  'What to call this level in a report. "Division" reads better than '
  '"Opportunity Owner: Division".';

alter table engagement_segmentation enable row level security;
create policy engagement_segmentation_member on engagement_segmentation
  for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));

create or replace function gea_set_segmentation(
  p_engagement uuid, p_levels jsonb)
returns table (level integer, column_name text, label text, distinct_values integer)
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; r jsonb; i integer := 0; n integer;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  delete from engagement_segmentation where engagement_id = p_engagement;

  for r in select * from jsonb_array_elements(coalesce(p_levels, '[]'::jsonb))
  loop
    i := i + 1;
    -- A column nobody can point at is not a split.
    if not exists (
      select 1 from dataset_field_profile p
        join dataset d on d.id = p.dataset_id
        join artefact a on a.id = d.artefact_id and a.purged_at is null
       where a.engagement_id = p_engagement
         and d.id = (r ->> 'dataset_id')::uuid
         and p.field_name = r ->> 'column_name') then
      raise exception
        'there is no column called % in that file',
        coalesce(r ->> 'column_name', '(none)')
        using errcode = 'check_violation';
    end if;

    insert into engagement_segmentation (engagement_id, level, dataset_id,
                                         column_name, label, chosen_by)
         values (p_engagement, i, (r ->> 'dataset_id')::uuid,
                 r ->> 'column_name',
                 nullif(btrim(r ->> 'label'), ''), v_me);
  end loop;

  return query
    select s.level, s.column_name, s.label,
           (select p.distinct_count from dataset_field_profile p
             where p.dataset_id = s.dataset_id
               and p.field_name = s.column_name)
      from engagement_segmentation s
     where s.engagement_id = p_engagement
     order by s.level;
end $fn$;

comment on function gea_set_segmentation is
  'Record how this client''s business splits. Replaces whatever was there, '
  'because the levels are an ordered whole rather than a set.';

-- What a consultant chooses from --------------------------------------------
--
-- A column worth splitting by has a handful of values and is on nearly
-- every row. A column with two thousand distinct values is a name, and a
-- column populated on a tenth of the rows splits the client into one
-- large bucket called "not recorded".

create or replace view segmentation_candidates
with (security_invoker = true) as
select a.engagement_id, d.id as dataset_id, a.original_filename,
       el.ref as export_ref, p.field_name, p.distinct_count,
       p.populated_rate, p.top_value, p.sample_values,
       (p.distinct_count between 2 and 12 and p.populated_rate >= 0.6)
         as worth_splitting_by
  from dataset_field_profile p
  join dataset d on d.id = p.dataset_id
  join artefact a on a.id = d.artefact_id and a.purged_at is null
  left join export_request_line erl on erl.id = a.export_request_line_id
  left join export_line el on el.id = erl.export_line_id
 where p.distinct_count between 2 and 40
   and p.populated_rate >= 0.2
   and coalesce(p.is_free_text, false) is false;

comment on view segmentation_candidates is
  'Columns a client''s business could be split by: few enough values to '
  'read, populated on enough rows to mean something.';

insert into gea_migration (filename, note) values
  ('088_how_the_client_splits_its_business.sql',
   'How a client splits its business belongs to the engagement, as any '
   'columns in any order, not to a list in the analysis code.');

-- What was written down, and what must have happened ------------------------
--
-- Nothing reaches the fourth stage of a pipeline without passing through
-- the first three, so a deal recorded only at four was at one, two and
-- three as well. Counting only what was written down gives a funnel that
-- widens in the middle, which is not what happened.
--
-- What cannot be inferred is when. A stage a deal certainly passed
-- through, on a date nobody recorded, supports a conversion rate and can
-- support no duration at all.
--
-- The share inferred is the measure of how well the pipeline is kept. On
-- the first real client, ninety-four per cent of new business deals that
-- reached the fourth stage had no record of the first.

alter table pipeline_stage add column deals_recorded integer;
alter table pipeline add column stage_records_inferred numeric;

comment on column pipeline_stage.deals_entered is
  'Deals that were in this stage, written down or necessarily implied by '
  'a later one.';
comment on column pipeline_stage.deals_recorded is
  'Deals the client actually recorded here. The difference is what the '
  'pipeline implies and nobody wrote down.';
comment on column pipeline.stage_records_inferred is
  'The share of stage records that had to be inferred. This is pipeline '
  'hygiene measured rather than asserted, and it caps what can be said '
  'about stage duration.';

drop view if exists pipeline_board;
create view pipeline_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.segment_field,
       p.segment_fields, p.segment_values, p.era, p.era_from, p.era_to,
       p.era_label, p.deals, p.deals_with_any_stage_date,
       p.stage_records_inferred,
       p.confirmed_at, u.display_name as confirmed_by_name,
       count(s.id) as stages,
       jsonb_agg(jsonb_build_object(
         'stage', s.stage_name, 'position', s.position,
         'deals_entered', s.deals_entered,
         'deals_recorded', s.deals_recorded,
         'median_entered', s.median_entered,
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
  'in it, with what was recorded at each and what the pipeline implies.';
