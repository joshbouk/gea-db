-- 032 Committing the paths completes its own task, and only a lead may do it.
--
-- Two gaps, both found when the first screen used 030.
--
-- 1. Nothing completed step 2.8 when the paths were committed. The application
--    was doing it in a second write straight afterwards, which can fail on its
--    own: the paths end up committed and the task still open, and the person is
--    asked to refresh. Status is supposed to derive from a real artefact. The
--    artefact here is paths_committed_at, so the database derives it.
--
-- 2. Committing and reopening were restricted to leads in the browser only.
--    The engagement write policy is app_is_member, so any member could do it by
--    other means. Same mistake as the precondition override, and the same fix:
--    the rule belongs where it cannot be routed around.

-- Who may commit ------------------------------------------------------------

create or replace function trg_path_commitment_is_a_lead() returns trigger
language plpgsql as $fn$
begin
  if new.paths_committed_at is distinct from old.paths_committed_at then
    if not app_is_engagement_lead(new.id) then
      raise exception
        'only a lead consultant or lead architect on this engagement can commit '
        'or reopen the revenue paths'
        using errcode = 'insufficient_privilege';
    end if;
  end if;
  return new;
end $fn$;

create trigger path_commitment_is_a_lead before update on engagement
  for each row execute function trg_path_commitment_is_a_lead();

-- The task follows the artefact ---------------------------------------------
-- Completing on commitment and reopening on reopening, in the same transaction
-- as the change that caused it. The recompute function deliberately never
-- un-completes a task, so this sets the row directly: the artefact is the
-- authority, not the previous status.

create or replace function trg_paths_task_follows_commitment() returns trigger
language plpgsql as $fn$
begin
  if new.paths_committed_at is distinct from old.paths_committed_at then
    if new.paths_committed_at is not null then
      update task
         set status = 'complete',
             completed_at = new.paths_committed_at,
             completed_by = new.paths_committed_by,
             blocking_reasons = '[]'::jsonb
       where engagement_id = new.id and step_ref = '2.8';
    else
      update task
         set status = 'ready', completed_at = null, completed_by = null
       where engagement_id = new.id and step_ref = '2.8';
    end if;

    -- Anything waiting on 2.8, which is the waterfall, moves with it.
    perform gea_recompute_tasks(new.id);
  end if;
  return null;
end $fn$;

create trigger paths_task_follows_commitment after update on engagement
  for each row execute function trg_paths_task_follows_commitment();

insert into gea_migration (filename, note) values
  ('032_commitment_is_derived.sql',
   'Committing the revenue paths completes its task in the same transaction, '
   'and only a lead may commit or reopen.');
