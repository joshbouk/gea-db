-- 030 Committing the revenue paths.
--
-- Paths are declared at setup from what the client says their business looks
-- like. That account is often wrong in a way nobody discovers until week three,
-- when a RevOps lead mentions that the reseller channel is really two channels
-- with different economics. Locking the paths at setup would mean either
-- living with a wrong model or starting again.
--
-- So paths follow the same shape as scores: editable while the evidence is
-- still moving, committed by a deliberate act, and changeable afterwards only
-- through an explicit reopening that records why.
--
-- The commitment sits after the interviews and before the waterfall, because
-- the waterfall is modelled per path. Build it, then change the paths, and the
-- model describes a business that does not exist.
--
-- Two steps change in the catalogue:
--   2.8 becomes "Confirm the revenue paths", after the interviews
--   2.9 becomes "Build the growth waterfall", after 2.8
-- Neither is in the published runbook, so renumbering costs nothing.

alter table engagement
  add column paths_committed_at timestamptz,
  add column paths_committed_by uuid references app_user(id),
  add column paths_reopened_reason text;

comment on column engagement.paths_committed_at is
  'When the revenue paths were agreed as final. Before this they are setup and '
  'freely editable. After it they are locked, because the waterfall and the '
  'per-path analyses are built from them.';

-- RULE: a committed path set cannot be changed without reopening it first.
create or replace function trg_paths_locked_when_committed() returns trigger
language plpgsql as $fn$
declare v_engagement uuid; v_committed timestamptz;
begin
  v_engagement := coalesce(new.engagement_id, old.engagement_id);
  select paths_committed_at into v_committed
    from engagement where id = v_engagement;

  if v_committed is not null then
    raise exception
      'the revenue paths were committed on %. Reopen them before changing one, '
      'and expect anything computed from them to need running again',
      v_committed::date
      using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end $fn$;

create trigger paths_locked_when_committed
  before insert or update or delete on revenue_path
  for each row execute function trg_paths_locked_when_committed();

-- RULE: committing requires at least one path, and reopening states why.
create or replace function trg_engagement_path_commitment() returns trigger
language plpgsql as $fn$
declare n integer;
begin
  if new.paths_committed_at is not null and old.paths_committed_at is null then
    select count(*) into n from revenue_path where engagement_id = new.id;
    if n = 0 then
      raise exception
        'there are no revenue paths to commit. Add how this business makes '
        'money before confirming it'
        using errcode = 'check_violation';
    end if;
  end if;

  if new.paths_committed_at is null and old.paths_committed_at is not null then
    if new.paths_reopened_reason is null
       or length(btrim(new.paths_reopened_reason)) = 0 then
      raise exception
        'reopening the revenue paths needs a reason. It is recorded against '
        'the engagement and explains why the model changed'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $fn$;

create trigger engagement_path_commitment before update on engagement
  for each row execute function trg_engagement_path_commitment();

-- The catalogue -------------------------------------------------------------

update methodology_step
   set ref = '2.9', sort_order = 135
 where runbook_version = 'v0.4' and ref = '2.8';

insert into methodology_step (runbook_version, ref, stage, title, purpose,
  exit_condition, task_type, owner_engagement_role, status_is_derived,
  derived_from, element_refs, one_task_per, sort_order) values
('v0.4','2.8',2,'Confirm the revenue paths',
 'The paths were written down at setup from what the client told us. By now the exports and the interviews have shown what the business actually does, and that is often different: a route to market that turns out to be two with different economics, or a product that only ever sells into one segment. Agree the real set before anything is modelled on it, because the waterfall is built per path and a model of a business that does not exist is worse than no model.',
 'The revenue paths agreed and committed, with any change from the original set explained.',
 'review','lead_consultant',true,'The revenue paths have been committed',null,null,132);

insert into step_precondition (methodology_step_id, kind, value, blocking_reason)
select s.id, v.kind::step_precondition_kind, v.value, v.reason
  from (values
  ('2.8','step','2.6','The interviews have not happened, and they are where a wrong route to market usually surfaces.'),
  ('2.9','step','2.8','The revenue paths are not committed. Modelling before they are settled means modelling a business that may not exist.')
  ) as v(step_ref, kind, value, reason)
  join methodology_step s on s.ref = v.step_ref and s.runbook_version = 'v0.4';

-- 3.6 waited on the waterfall at its old number.
update step_precondition p
   set value = '2.9'
  from methodology_step s
 where s.id = p.methodology_step_id
   and s.ref = '3.6' and p.kind = 'step' and p.value = '2.8';

insert into gea_migration (filename, note) values
  ('030_commit_revenue_paths.sql',
   'Revenue paths are editable until committed, then locked, and reopening '
   'states why. Confirming them is a step after the interviews; the waterfall '
   'moves to 2.9 and depends on it.');
