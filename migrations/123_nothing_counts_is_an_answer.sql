-- 123 Nothing counts is an answer.
--
-- 122 let a consultant clear the qualifying stage, and cleared the
-- person and the time along with it. So a pipeline where somebody
-- decided nothing counts as qualified looks exactly like one nobody has
-- opened, and the screen cannot tell a reader which it is.
--
-- The two are different answers about a business. A renewals book where
-- nothing qualifies is a finding; a pipeline nobody has looked at is
-- work outstanding. Keeping who and when is what separates them.

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

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  -- Deciding nothing counts is a decision, so it is recorded like one.
  -- Only the stage goes; the person and the moment stay, and a pipeline
  -- with no stage but a time on it reads differently from one nobody
  -- has touched.
  if p_stage is null then
    update pipeline
       set qualified_at_stage = null, qualified_at_set_by = v_me,
           qualified_at_set_at = now()
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
  'recorded as a decision rather than as an absence.';

-- Nobody has looked yet, somebody decided nothing counts, or there is a
-- stage. The view says which.
--
-- Dropped rather than replaced, because a column is being added in the
-- middle and Postgres will not rename its way there.
drop view if exists qualification_board;
create view qualification_board
with (security_invoker = true) as
select p.engagement_id, p.id as pipeline_id, p.segment, p.era, p.era_label,
       p.qualified_at_stage, p.qualified_at_set_at,
       u.display_name as set_by_name,
       case when p.qualified_at_stage is not null then 'a stage'
            when p.qualified_at_set_at is not null then 'nothing counts'
            else 'nobody has answered' end as answer,
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
  'Each pipeline and the stage it treats as qualified. The answer column '
  'separates a pipeline where somebody decided nothing counts from one '
  'nobody has opened.';

insert into gea_migration (filename, note) values
  ('123_nothing_counts_is_an_answer.sql',
   'Clearing the qualifying stage records who decided it, so a '
   'deliberate nothing is not mistaken for an absence.')
on conflict do nothing;
