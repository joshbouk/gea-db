-- 051 When a step is done.
--
-- Twenty-three of the twenty-nine steps say they complete on their own.
-- Exactly one did: 2.8, wired by hand because we needed it that day. For the
-- other twenty-two, derived_from was prose written for a consultant to read —
-- "every supported analysis run has been accepted" — and nothing checked it.
--
-- So a consultant could accept every run and the task stayed ready for ever.
-- Worse, the screen correctly says a derived task completes on its own, so
-- there was no manual tick either. Most of the board could not be finished.
--
-- Two things here.
--
--   A completion rule, shaped like a precondition: a kind, a value, and a
--   threshold where one applies. Seven steps get one now. The rest depend on
--   work that does not exist yet.
--
--   A floor: no task may be impossible to complete. A step declared derived
--   with no wired rule falls back to a person ticking it, with its
--   derived_from sentence shown as what they are confirming. That is the
--   actual defect — not the missing rules, but a board that silently cannot
--   be finished.

create type completion_kind as enum (
  'export_lines_owned',      -- every included line has an owner and a date
  'exports_all_resolved',    -- every line has arrived or is a recorded limitation
  'fields_all_settled',      -- every field from an arrived export is decided
  'analysis_accepted',       -- a named analysis has an accepted run
  'supported_analyses_done', -- every analysis marked supported has one
  'ready_elements_scored',   -- every element whose evidence is in carries a score
  'requirements_resolved'    -- every evidence requirement is satisfied or waived
);

create table step_completion (
  id               uuid primary key default gen_random_uuid(),
  runbook_version  text not null,
  step_ref         text not null,
  kind             completion_kind not null,
  value            text,
  -- What the person is confirming, shown where a rule cannot be checked.
  note             text,
  created_at       timestamptz not null default now(),
  unique (runbook_version, step_ref, kind, value)
);

comment on table step_completion is
  'Machine-checkable completion rules. A derived step with no row here falls '
  'back to being ticked by a person: no task may be impossible to finish.';

alter table step_completion enable row level security;
create policy step_completion_read on step_completion
  for select to authenticated using (app_is_blend_user());

insert into step_completion (runbook_version, step_ref, kind, value) values
  ('v0.4', '1.2', 'export_lines_owned',      null),
  ('v0.4', '1.4', 'exports_all_resolved',    null),
  ('v0.4', '1.4', 'fields_all_settled',      null),
  ('v0.4', '2.1', 'supported_analyses_done', null),
  ('v0.4', '2.2', 'analysis_accepted',       'icp_reconciliation'),
  ('v0.4', '2.3', 'analysis_accepted',       'public_surface_audit'),
  ('v0.4', '2.7', 'ready_elements_scored',   'provisional'),
  ('v0.4', '3.1', 'requirements_resolved',   null);

-- Is a step's work finished? ---------------------------------------------------

create or replace function gea_step_is_done(p_engagement uuid, p_step_ref text)
returns table (done boolean, unmet text[])
language plpgsql stable as $fn$
declare
  v_version text;
  v_iv      uuid;
  r         record;
  n         integer;
  m         integer;
  reasons   text[] := array[]::text[];
  any_rule  boolean := false;
begin
  select e.instrument_version_id into v_iv from engagement e where e.id = p_engagement;
  select s.runbook_version into v_version
    from methodology_step s where s.ref = p_step_ref limit 1;

  for r in select * from step_completion
            where runbook_version = v_version and step_ref = p_step_ref loop
    any_rule := true;
    case r.kind

      when 'export_lines_owned' then
        select count(*) into n from export_request_line
         where engagement_id = p_engagement and included
           and (client_owner_name is null or due_date is null)
           and status = 'not_requested';
        if n > 0 then
          reasons := reasons || format(
            '%s export line%s still has no owner or no date.',
            n, case when n = 1 then '' else 's' end);
        end if;

      when 'exports_all_resolved' then
        select count(*) into n from export_request_line
         where engagement_id = p_engagement and included
           and status in ('not_requested','requested');
        if n > 0 then
          reasons := reasons || format(
            '%s export%s not arrived, and not recorded as refused or absent.',
            n, case when n = 1 then ' has' else 's have' end);
        end if;

      when 'fields_all_settled' then
        -- only fields whose export has actually arrived; the rest are not
        -- this step's problem yet.
        select count(*) into n
          from canonical_field cf
          left join field_mapping fm on fm.canonical_field_id = cf.id
                                    and fm.engagement_id = p_engagement
         where cf.instrument_version_id = v_iv
           and coalesce(fm.status::text,'proposed')
               not in ('confirmed','corrected','auto_accepted','unmapped')
           and exists (
             select 1 from unnest(cf.source_export_refs) as want(ref)
               join export_line el on el.ref = want.ref and el.instrument_version_id = v_iv
               join export_request_line erl on erl.export_line_id = el.id
                                           and erl.engagement_id = p_engagement
              where erl.status in ('received','partial','substituted'));
        if n > 0 then
          reasons := reasons || format(
            '%s field%s from an export that has arrived still needs a decision.',
            n, case when n = 1 then '' else 's' end);
        end if;

      when 'analysis_accepted' then
        if not exists (select 1 from analysis_run
                        where engagement_id = p_engagement
                          and job_type = 'analysis:' || r.value
                          and accepted_at is not null) then
          reasons := reasons || format(
            'The %s run has not been accepted.', replace(r.value, '_', ' '));
        end if;

      when 'supported_analyses_done' then
        select count(*) into n from analysis_capability c
         where c.engagement_id = p_engagement
           and c.verdict in ('supported','partial')
           and not exists (select 1 from analysis_run ar
                            where ar.engagement_id = p_engagement
                              and ar.job_type = 'analysis:' || c.analysis_key
                              and ar.accepted_at is not null);
        select count(*) into m from analysis_capability
         where engagement_id = p_engagement;
        if m = 0 then
          reasons := reasons || 'The capability table has not been computed.'::text;
        elsif n > 0 then
          reasons := reasons || format(
            '%s analys%s the data supports %s no accepted run.',
            n, case when n = 1 then 'is' else 'es' end,
            case when n = 1 then 'has' else 'have' end);
        end if;

      when 'ready_elements_scored' then
        -- An element is ready to score when its evidence is all in. Elements
        -- still waiting are not this step's failure, and the task reopens
        -- when their evidence lands, because there is then more to score.
        select count(*) into n
          from element e
          join score s on s.element_id = e.id and s.engagement_id = p_engagement
         where e.instrument_version_id = v_iv
           and s.state = 'unscored'
           and not exists (
             select 1 from engagement_requirement er
               join evidence_requirement evr on evr.id = er.evidence_requirement_id
              where er.engagement_id = p_engagement
                and evr.element_id = e.id
                and er.state = 'outstanding');
        if n > 0 then
          reasons := reasons || format(
            '%s element%s whose evidence is in %s no score yet.',
            n, case when n = 1 then '' else 's' end,
            case when n = 1 then 'has' else 'have' end);
        end if;

      when 'requirements_resolved' then
        select count(*) into n from engagement_requirement
         where engagement_id = p_engagement and state = 'outstanding';
        if n > 0 then
          reasons := reasons || format(
            '%s evidence requirement%s still outstanding.',
            n, case when n = 1 then ' is' else 's are' end);
        end if;
    end case;
  end loop;

  done := any_rule and array_length(reasons, 1) is null;
  unmet := case when array_length(reasons, 1) is null then null else reasons end;
  return next;
end $fn$;

comment on function gea_step_is_done is
  'Whether a step''s work is finished, and what is outstanding if not. Returns '
  'done = false with no reasons where the step has no machine-checkable rule: '
  'that is the signal to let a person tick it.';

-- Does this step have a rule at all? ------------------------------------------

create or replace view step_completion_rule
with (security_invoker = true) as
select s.runbook_version, s.ref as step_ref, s.status_is_derived,
       exists (select 1 from step_completion c
                where c.runbook_version = s.runbook_version
                  and c.step_ref = s.ref) as has_rule,
       s.derived_from
  from methodology_step s;

comment on view step_completion_rule is
  'Which steps complete on their own and which fall back to a person. A '
  'derived step without a rule is ticked by hand, showing derived_from as '
  'what is being confirmed.';

insert into gea_migration (filename, note) values
  ('051_when_a_step_is_done.sql',
   'Completion rules for seven steps, and a floor: a derived step with no '
   'rule can be ticked by a person rather than being impossible to finish.');

-- Setting them -----------------------------------------------------------------
-- The recompute already runs whenever something could unblock a task. The same
-- events are the ones that finish a step, so it also closes what is done.

create or replace function gea_close_finished_steps(p_engagement uuid)
returns integer language plpgsql as $fn$
declare r record; v record; n integer := 0;
begin
  for r in select t.id, t.step_ref from task t
            where t.engagement_id = p_engagement
              and t.step_ref is not null
              -- Never a blocked task. Its artefacts may exist, but the step
              -- has not legitimately happened: completing the export request
              -- before the sponsor kickoff would be a false record.
              and t.status in ('ready','in_progress')
              and exists (select 1 from methodology_step s
                           where s.ref = t.step_ref and s.status_is_derived) loop
    select * into v from gea_step_is_done(p_engagement, r.step_ref);
    if v.done then
      update task set status = 'complete', completed_at = now() where id = r.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $fn$;

comment on function gea_close_finished_steps is
  'Complete the derived tasks whose work is finished. Only closes; a step that '
  'reopens because more evidence arrived is handled by the recompute.';

-- The original recompute keeps its logic under a name that says what it does.
create or replace function gea_recompute_task_blocking(p_engagement uuid)
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

comment on function gea_recompute_task_blocking is
  'Work out which tasks are blocked and why. Half of keeping the board '
  'current; the other half is closing what is finished.';

-- The public name now does both halves, so every existing caller gets both.
create or replace function gea_recompute_tasks(p_engagement uuid)
returns integer language plpgsql as $fn$
declare n integer;
begin
  n := gea_recompute_task_blocking(p_engagement);
  perform gea_close_finished_steps(p_engagement);
  return n;
end $fn$;

do $$
declare e record;
begin
  for e in select id from engagement loop
    perform gea_recompute_tasks(e.id);
  end loop;
end $$;
