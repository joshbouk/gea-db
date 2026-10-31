-- 122 Which stage means qualified.
--
-- Some of what an assessment needs is not in a column. When a deal
-- became qualified is a date no CRM holds, because qualification is not
-- an event anybody records: it is a stage the business treats as the
-- point where a deal counts. A client's revenue operations lead can say
-- which stage that is in one sentence, and no export will ever say it.
--
-- Asked for a column, a consultant has nothing to give. The field sits
-- unmapped, cost per qualified opportunity cannot run, and the whole
-- question of what demand costs goes unanswered on an assessment that
-- exists to answer it.
--
-- So it is nominated rather than mapped, on the pipeline where the
-- stages are already in front of somebody, and once per pipeline because
-- the stages differ. A client that replaced a thirteen-stage process
-- with a seven-stage one has two answers, and a segment that sells
-- differently may have another.
--
-- A deal that skipped the nominated stage is qualified at the first
-- stage beyond it that it did reach and that has a date. Sellers skip
-- stages when a deal moves quickly, and a deal that reached Negotiate
-- without passing Propose was qualified on the way.

alter table pipeline
  add column qualified_at_stage text,
  add column qualified_at_set_by uuid references app_user(id),
  add column qualified_at_set_at timestamptz;

comment on column pipeline.qualified_at_stage is
  'The stage this pipeline treats as the point a deal becomes '
  'qualified. A judgement a consultant makes from what the client says, '
  'not a column in any export.';

create or replace function gea_qualification_is(
  p_pipeline uuid, p_stage text)
returns table (segment text, era integer, stage text, deals_qualified integer)
language plpgsql security definer set search_path = public as $fn$
declare v_eng uuid; v_me uuid; v_pos integer;
begin
  select p.engagement_id into v_eng from pipeline p where p.id = p_pipeline;
  if v_eng is null then
    raise exception 'that pipeline is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  -- Clearing it is a decision too: a pipeline where nothing counts as
  -- qualified is a real answer about a business.
  if p_stage is null then
    update pipeline set qualified_at_stage = null, qualified_at_set_by = null,
           qualified_at_set_at = null
     where id = p_pipeline;
    return query select p.segment, p.era, null::text, 0
                   from pipeline p where p.id = p_pipeline;
    return;
  end if;

  select s.position into v_pos from pipeline_stage s
   where s.pipeline_id = p_pipeline and s.stage_name = p_stage
     and not s.is_outcome;
  if v_pos is null then
    raise exception
      'there is no working stage called % in this pipeline. The stage has '
      'to be one of its own, because the stages differ between pipelines',
      p_stage using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  update pipeline
     set qualified_at_stage = p_stage, qualified_at_set_by = v_me,
         qualified_at_set_at = now()
   where id = p_pipeline;

  return query
    select p.segment, p.era, p_stage,
           (select coalesce(sum(s.deals_entered), 0)::integer
              from pipeline_stage s
             where s.pipeline_id = p_pipeline and s.position = v_pos
               and not s.is_outcome)
      from pipeline p where p.id = p_pipeline;
end $fn$;

comment on function gea_qualification_is is
  'Nominate the stage at which a deal counts as qualified, for one '
  'pipeline. Pass null where nothing in that pipeline does, which is '
  'itself an answer.';

create or replace view qualification_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.era, p.era_label,
       p.qualified_at_stage, p.qualified_at_set_at,
       u.display_name as set_by_name,
       coalesce((select array_agg(s.stage_name order by s.position)
                   from pipeline_stage s
                  where s.pipeline_id = p.id and not s.is_outcome),
                array[]::text[]) as stages_to_choose_from,
       (select s.position from pipeline_stage s
         where s.pipeline_id = p.id and s.stage_name = p.qualified_at_stage
           and not s.is_outcome) as position
  from pipeline p
  left join app_user u on u.id = p.qualified_at_set_by;

comment on view qualification_board is
  'Each pipeline and the stage it treats as qualified, with the stages '
  'available to choose from. A pipeline with none is a question nobody '
  'has answered yet.';

insert into gea_migration (filename, note) values
  ('122_which_stage_means_qualified.sql',
   'Qualification is nominated per pipeline rather than mapped to a '
   'column no export contains.')
on conflict do nothing;
