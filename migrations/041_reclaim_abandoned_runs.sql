-- 041 Runs abandoned by a worker that died.
--
-- A worker claims a run by setting it to running. If the process is then
-- killed, or the machine loses power, the row stays claimed and no other
-- worker will touch it, because claiming only takes queued runs. The work
-- never happens and nothing says so. The only way out was editing rows by
-- hand, which is what happened the first time this occurred.
--
-- The stall is already visible: analysis_run_state computes is_stalled from a
-- heartbeat older than ten minutes. What was missing is anything acting on it.
--
-- A worker calls this when it starts. Ten minutes is deliberately longer than
-- any heartbeat interval, so a run that is genuinely in flight on another
-- worker is never taken from it — the service heartbeats every thousand rows,
-- which on the slowest job is seconds apart.
--
-- The run is failed rather than re-queued. Re-queueing would hide the fact
-- that something went wrong, and the work that was abandoned may be the reason
-- the worker died. Someone decides whether to redo it, with gea_redo_run.

create or replace function gea_fail_abandoned_runs(
  p_older_than interval default interval '10 minutes')
returns table (run_id uuid, job_type text, abandoned_for interval)
language plpgsql as $fn$
begin
  return query
  update analysis_run r
     set status = 'failed',
         finished_at = now(),
         error = format(
           'The service stopped while this run was in flight. It last reported '
           'progress %s ago.',
           date_trunc('second', now() - coalesce(r.heartbeat_at, r.started_at)))
   where r.status = 'running'
     and coalesce(r.heartbeat_at, r.started_at) < now() - p_older_than
  returning r.id, r.job_type,
            date_trunc('second', now() - coalesce(r.heartbeat_at, r.started_at));
end $fn$;

comment on function gea_fail_abandoned_runs is
  'Fail runs left claimed by a worker that died. Called by a worker at '
  'startup. Failed rather than re-queued, because the abandoned work may be '
  'why the worker died; redoing it is a decision.';

insert into gea_migration (filename, note) values
  ('041_reclaim_abandoned_runs.sql',
   'A run left claimed by a dead worker is failed with the reason, rather than '
   'staying claimed forever.');
