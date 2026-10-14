-- 082 The client's own pipeline.
--
-- The instrument asks for one field holding when a deal entered a stage.
-- No CRM stores it that way. HubSpot writes a property per stage — Date
-- entered Qualification, Date entered Proposal — and Salesforce reports
-- are usually built the same way. So the answer is not one column we
-- failed to find. It is a column per stage, and how many there are and
-- what they are called depends on a pipeline the methodology cannot know
-- in advance.
--
-- It is also the wrong shape. The analysis wants one row per deal per
-- stage; the export has one row per deal, spread wide.
--
-- The columns announce themselves. The stage names in those headings are
-- the same strings as the values in the stage column, so matching one
-- against the other finds the client's pipeline without a vocabulary and
-- without guessing, custom stages included.
--
-- And it is done per segment. Regulated and Retail may run the same
-- stages and still flow completely differently, and one pipeline averaged
-- across both would hide exactly the difference worth reporting.

create table pipeline (
  id            uuid primary key default gen_random_uuid(),
  engagement_id uuid not null references engagement(id) on delete cascade,
  segment       text not null,
  segment_field text,
  deals         integer not null default 0,
  detected_at   timestamptz not null default now(),
  confirmed_at  timestamptz,
  confirmed_by  uuid references app_user(id),
  source_run_id uuid references analysis_run(id),
  unique (engagement_id, segment)
);

comment on table pipeline is
  'One pipeline per segment of the client''s business, as found in their '
  'own data. Regulated and Retail may run the same stages and flow '
  'differently, and an average across both hides the difference.';

comment on column pipeline.segment is
  'The value that separates this pipeline from the others — Regulated, '
  'Retail — or "all deals" where the client runs one.';

create table pipeline_stage (
  id           uuid primary key default gen_random_uuid(),
  pipeline_id  uuid not null references pipeline(id) on delete cascade,
  stage_name   text not null,
  position     integer not null,
  source_column text,
  deals_entered integer not null default 0,
  median_entered date,
  is_closed_won  boolean not null default false,
  is_closed_lost boolean not null default false,
  unique (pipeline_id, stage_name)
);

comment on column pipeline_stage.position is
  'The order the stages actually run in, from the median date deals '
  'entered each. Which is also the evidence for whether the pipeline is '
  'ordered at all or deals jump about.';

comment on column pipeline_stage.source_column is
  'The column this stage''s entry date was read from, so the pivot can be '
  'checked against the export it came from.';

create table deal_stage_entry (
  engagement_id uuid not null references engagement(id) on delete cascade,
  opportunity_id text not null,
  segment        text not null,
  stage_name     text not null,
  entered_at     date not null,
  primary key (engagement_id, opportunity_id, stage_name)
);

comment on table deal_stage_entry is
  'One row per deal per stage it entered, pivoted from the columns the '
  'client''s export spreads across. The shape the stage analysis wants, '
  'and the shape a stage history export would have arrived in.';

create index deal_stage_entry_by_stage
    on deal_stage_entry (engagement_id, segment, stage_name);

alter table pipeline enable row level security;
alter table pipeline_stage enable row level security;
alter table deal_stage_entry enable row level security;

create policy pipeline_member on pipeline for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));
create policy pipeline_stage_member on pipeline_stage for all to authenticated
  using (exists (select 1 from pipeline p where p.id = pipeline_stage.pipeline_id
                   and app_is_member(p.engagement_id)))
  with check (exists (select 1 from pipeline p where p.id = pipeline_stage.pipeline_id
                        and app_is_member(p.engagement_id)));
-- Deal rows are client data, so the raw-data rule applies as it does to
-- the export rows they were pivoted from.
create policy deal_stage_entry_raw on deal_stage_entry for select to authenticated
  using (app_can_view_raw(engagement_id));
create policy deal_stage_entry_service on deal_stage_entry for all to authenticated
  using (app_is_service()) with check (app_is_service());

create or replace function gea_confirm_pipeline(
  p_pipeline uuid, p_stages jsonb default null)
returns table (segment text, stages integer)
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; v_eng uuid; r jsonb; n integer;
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

  -- A corrected order, where somebody knows the pipeline runs differently
  -- from the order the dates imply.
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

  select p.segment, count(*) into segment, n
    from pipeline p join pipeline_stage s on s.pipeline_id = p.id
   where p.id = p_pipeline group by p.segment;
  stages := n;
  return next;
end $fn$;

comment on function gea_confirm_pipeline is
  'A person has looked at the stages found in the client''s data and says '
  'they are right, optionally correcting the order.';

create or replace view pipeline_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.segment_field,
       p.deals, p.confirmed_at, u.display_name as confirmed_by_name,
       count(s.id) as stages,
       jsonb_agg(jsonb_build_object(
         'stage', s.stage_name, 'position', s.position,
         'deals_entered', s.deals_entered, 'median_entered', s.median_entered,
         'from_column', s.source_column,
         'closed_won', s.is_closed_won, 'closed_lost', s.is_closed_lost)
         order by s.position) as stage_detail,
       (select count(*) from deal_stage_entry d
         where d.engagement_id = p.engagement_id and d.segment = p.segment)
         as entries
  from pipeline p
  left join pipeline_stage s on s.pipeline_id = p.id
  left join app_user u on u.id = p.confirmed_by
 group by p.engagement_id, p.id, p.segment, p.segment_field, p.deals,
          p.confirmed_at, u.display_name;

comment on view pipeline_board is
  'Each segment''s pipeline as found in the client''s data: the stages, the '
  'order the dates imply, and how many deals reached each.';

insert into gea_migration (filename, note) values
  ('082_the_clients_own_pipeline.sql',
   'The client''s pipeline is found in their own export and pivoted into '
   'one row per deal per stage, separately for each segment.');
