-- 019 Claiming a run.
--
-- The analysis service polls for queued work. Two workers must never pick up
-- the same run, and a worker that dies mid-job must not leave a row that looks
-- claimed forever.
--
-- `for update skip locked` is what makes the first part true: the row is locked
-- for the claiming transaction and any other worker looking at the same moment
-- skips past it rather than waiting. Without it, two workers both read the same
-- queued row and both run the job.
--
-- The second part is already handled: heartbeat_at plus the analysis_run_state
-- view surfaces a running job that has stopped reporting.
--
-- Polling is the service's business. The browser subscribes via realtime and
-- never polls.

create or replace function gea_claim_run(p_job_types text[] default null)
returns setof analysis_run
language plpgsql as $fn$
begin
  return query
  update analysis_run
     set status       = 'running',
         started_at   = now(),
         heartbeat_at = now()
   where id = (
     select r.id
       from analysis_run r
      where r.status = 'queued'
        and (p_job_types is null or r.job_type = any (p_job_types))
      order by r.created_at
      for update skip locked
      limit 1)
  returning *;
end $fn$;

comment on function gea_claim_run is
  'Claim the oldest queued run, or return nothing. Safe to call from several '
  'workers at once: for update skip locked means no two claim the same row.';

-- Progress without rewriting the row. A census of 4,000 records calls this
-- every few hundred, so it stays as small as possible.
create or replace function gea_heartbeat_run(
  p_run uuid, p_done integer default null, p_total integer default null)
returns void language sql as $fn$
  update analysis_run
     set heartbeat_at  = now(),
         progress_done = coalesce(p_done, progress_done),
         progress_total = coalesce(p_total, progress_total)
   where id = p_run and status = 'running';
$fn$;

insert into gea_migration (filename, note) values
  ('019_run_claim.sql',
   'Workers claim queued runs with for update skip locked, and report progress '
   'without rewriting the row.');
