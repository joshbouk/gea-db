-- 049 The task board keeps up with what has happened.
--
-- Blocking is computed. It was also computed once, at engagement setup, and
-- then almost never again: gea_recompute_tasks was called when the tasks were
-- generated and when the revenue paths were committed, and nowhere else.
--
-- So three exports could arrive and "check what the data can carry" would
-- still say it was waiting for the first one. The board looked like a board
-- and behaved like a photograph.
--
-- A precondition can be met by four things, and each now says so:
--
--   another task finishing          task.status
--   a gate passing                  gate_passage
--   an export arriving              export_request_line.status
--   an analysis being accepted      analysis_run.accepted_at
--
-- The recompute only ever sets blocked or ready, never complete or waived, so
-- the trigger on task is restricted to those two and cannot set itself off.

create or replace function trg_recompute_tasks_for_engagement() returns trigger
language plpgsql as $fn$
begin
  perform gea_recompute_tasks(
    coalesce(new.engagement_id, old.engagement_id));
  return null;
end $fn$;

-- A task finishing can unblock the ones that waited for it.
create trigger task_finished_recomputes
  after update of status on task
  for each row
  when (new.status in ('complete','waived')
        and new.status is distinct from old.status)
  execute function trg_recompute_tasks_for_engagement();

-- A gate passing unblocks whatever sat behind it.
create trigger gate_passed_recomputes
  after insert on gate_passage
  for each row execute function trg_recompute_tasks_for_engagement();

-- An export arriving is the commonest unblocking event on a real engagement.
create trigger export_arrived_recomputes
  after insert or update of status, included on export_request_line
  for each row execute function trg_recompute_tasks_for_engagement();

-- Accepting a run is what makes an analysis count as done.
create trigger run_accepted_recomputes
  after update of accepted_at on analysis_run
  for each row
  when (new.accepted_at is not null and old.accepted_at is null)
  execute function trg_recompute_tasks_for_engagement();

-- Catch up every engagement that has been sitting on a stale board.
do $$
declare e record;
begin
  for e in select id from engagement loop
    perform gea_recompute_tasks(e.id);
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('049_the_board_keeps_up.sql',
   'Blocking is recomputed when a task finishes, a gate passes, an export '
   'arrives or a run is accepted. It was only ever computed at setup.');
