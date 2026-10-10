-- 025 Generating the work.
--
-- Every task comes from the step catalogue. There is no free-text task
-- creation, now or later: a step missing from the catalogue is work that never
-- appears on anyone's board, and a task invented on a screen is work nobody
-- can repeat on the next engagement.
--
-- Three things are built here.
--
--   Gate passage, because preconditions refer to gates and nothing recorded
--   whether one had been passed.
--
--   Task generation and status. Status is derived wherever a real artefact
--   decides it. Blocking is computed, and each unmet precondition carries the
--   sentence shown to the consultant.
--
--   The override. A lead can start a blocked task when the precondition
--   cannot be met — the data does not exist, the client will not supply it —
--   provided they record why. The alternative is an engagement that stops
--   dead because one export never arrived.

create table gate_passage (
  id              uuid primary key default gen_random_uuid(),
  engagement_id   uuid not null references engagement(id) on delete cascade,
  gate_ref        text not null check (gate_ref in ('G0','G1','G2','G3','G4','G5')),
  passed_at       timestamptz not null default now(),
  passed_by       uuid references app_user(id),
  waived_conditions jsonb not null default '[]'::jsonb,
  note            text,
  unique (engagement_id, gate_ref)
);

comment on table gate_passage is
  'When each gate was passed, by whom, and which of its conditions were waived '
  'rather than met. A waiver is normal; an unrecorded one is not.';

create table task_precondition_override (
  id                  uuid primary key default gen_random_uuid(),
  task_id             uuid not null references task(id) on delete cascade,
  step_precondition_id uuid not null references step_precondition(id),
  reason              text not null check (length(btrim(reason)) > 0),
  overridden_by       uuid not null references app_user(id),
  created_at          timestamptz not null default now(),
  unique (task_id, step_precondition_id)
);

comment on table task_precondition_override is
  'A lead starting a task whose precondition cannot be met, with the basis '
  'recorded. Visible on the task and in the engagement record.';

do $$
declare t text;
begin
  foreach t in array array['gate_passage','task_precondition_override'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy %I on %I for select to authenticated using (app_is_blend_user())', t || '_read', t);
  end loop;
end $$;

create policy gate_passage_write on gate_passage
  for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));

create policy task_override_write on task_precondition_override
  for all to authenticated
  using (exists (select 1 from task t where t.id = task_id and app_is_member(t.engagement_id)))
  with check (exists (select 1 from task t where t.id = task_id and app_is_member(t.engagement_id)));

-- Is one precondition met? -------------------------------------------------

create or replace function gea_precondition_met(
  p_engagement uuid, p_kind step_precondition_kind, p_value text)
returns boolean language plpgsql stable as $fn$
begin
  case p_kind

    -- Every task for that step is finished. A step generating several tasks,
    -- such as the interviews, is met only when all of them are.
    when 'step' then
      return not exists (
        select 1 from task t
         where t.engagement_id = p_engagement and t.step_ref = p_value
           and t.status not in ('complete','waived'))
        and exists (
        select 1 from task t
         where t.engagement_id = p_engagement and t.step_ref = p_value);

    when 'gate' then
      return exists (select 1 from gate_passage g
                      where g.engagement_id = p_engagement and g.gate_ref = p_value);

    -- At least one export of that tier has arrived. Exports come in waves and
    -- the engagement should not wait for the last one.
    when 'export_tier' then
      return exists (
        select 1 from export_request_line r
          join export_line l on l.id = r.export_line_id
         where r.engagement_id = p_engagement
           and l.tier = p_value::smallint
           and r.status in ('received','partial','substituted'));

    when 'export_line' then
      return exists (
        select 1 from export_request_line r
          join export_line l on l.id = r.export_line_id
         where r.engagement_id = p_engagement and l.ref = p_value
           and r.status in ('received','partial','substituted','refused','absent'));

    when 'analysis' then
      return exists (
        select 1 from analysis_run a
         where a.engagement_id = p_engagement
           and a.job_type = 'analysis:' || p_value
           and a.accepted_at is not null);
  end case;
  return false;
end $fn$;

-- Recompute status and blocking ---------------------------------------------
-- Called after anything that could change an answer. Cheap: a few dozen rows.

create or replace function gea_recompute_tasks(p_engagement uuid)
returns integer language plpgsql as $fn$
declare
  r record;
  v_reasons jsonb;
  v_blocked boolean;
  n integer := 0;
begin
  for r in select t.id, t.step_ref, t.status, t.status_is_derived
             from task t where t.engagement_id = p_engagement
  loop
    -- A finished task stays finished. Recomputing must never undo work.
    if r.status in ('complete','waived') then continue; end if;

    v_reasons := '[]'::jsonb;
    v_blocked := false;

    for v_reasons, v_blocked in
      select coalesce(jsonb_agg(jsonb_build_object(
               'precondition_id', p.id,
               'kind', p.kind,
               'value', p.value,
               'reason', p.blocking_reason)), '[]'::jsonb),
             count(*) > 0
        from step_precondition p
        join methodology_step s on s.id = p.methodology_step_id
       where s.ref = r.step_ref
         and not gea_precondition_met(p_engagement, p.kind, p.value)
         and not exists (select 1 from task_precondition_override o
                          where o.task_id = r.id and o.step_precondition_id = p.id)
    loop end loop;

    update task
       set blocking_reasons = v_reasons,
           status = case
                      when v_blocked then 'blocked'
                      when status = 'blocked' then 'ready'
                      else status
                    end
     where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $fn$;

comment on function gea_recompute_tasks is
  'Recompute what is blocked and why. Never changes a task that is already '
  'complete or waived.';

-- Generate the tasks ---------------------------------------------------------

create or replace function gea_generate_tasks(
  p_engagement uuid, p_runbook_version text default 'v0.4')
returns integer language plpgsql as $fn$
declare n integer;
begin
  -- One task per step, except steps that say otherwise.
  insert into task (engagement_id, step_ref, title, purpose, task_type,
                    owner_engagement_role, status, status_is_derived, element_refs)
  select p_engagement, s.ref, s.title, s.purpose, s.task_type,
         s.owner_engagement_role, 'blocked', s.status_is_derived, s.element_refs
    from methodology_step s
   where s.runbook_version = p_runbook_version
     and s.one_task_per is null
   order by s.sort_order;

  -- The interviews are one task per session, not one for all eight. Each
  -- names its guide so a consultant knows who they are speaking to.
  insert into task (engagement_id, step_ref, title, purpose, task_type,
                    owner_engagement_role, status, status_is_derived)
  select p_engagement, s.ref, s.title || ': ' || i.function_name, s.purpose,
         s.task_type, s.owner_engagement_role, 'blocked', s.status_is_derived
    from methodology_step s
    join interview iv on iv.engagement_id = p_engagement
    join interview_guide i on i.id = iv.interview_guide_id
   where s.runbook_version = p_runbook_version
     and s.one_task_per = 'interview_guide';

  select count(*) into n from task where engagement_id = p_engagement;
  perform gea_recompute_tasks(p_engagement);
  return n;
end $fn$;

insert into gea_migration (filename, note) values
  ('025_tasks.sql',
   'Tasks are generated from the step catalogue, blocking is computed with a '
   'reason per unmet precondition, and a lead can override one with a recorded '
   'basis. Gate passage is recorded.');
