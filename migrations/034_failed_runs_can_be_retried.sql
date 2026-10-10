-- 034 A failed run must not block the retry.
--
-- The idempotency rule was enforced by a unique index across every run, so a
-- run that failed held its key forever. Nobody could try the same work again:
-- not after a transient storage error, not after a bad credential, not after
-- a bug we had since fixed. The only way through was deleting rows by hand,
-- which is exactly the kind of surgery the audit trail exists to avoid.
--
-- Idempotency is there so that two people clicking the same button produce one
-- job. It was never meant to mean one attempt, ever.
--
-- A failed or discarded run therefore no longer occupies its key. The run
-- stays — it is a record of an attempt and it is still visible — but the work
-- can be queued again. Queued, running and succeeded runs still hold their
-- keys, because those are the cases the rule is for: don't start a second copy
-- of work already in flight, and don't recompute something already done.

drop index if exists analysis_run_idempotency_key;

create unique index analysis_run_idempotency_key
  on analysis_run (idempotency_key)
  where status not in ('failed', 'discarded');

comment on index analysis_run_idempotency_key is
  'One live run per identical request. Failed and discarded runs are excluded '
  'so the same work can be attempted again after it goes wrong.';

create or replace function gea_enqueue_run(
  p_engagement   uuid,
  p_job_type     text,
  p_prompt       uuid    default null,
  p_step_ref     text    default null,
  p_artefact_ids uuid[]  default null,
  p_hashes       text[]  default null,
  p_parameters   jsonb   default '{}'::jsonb)
returns table (run_id uuid, was_created boolean)
language plpgsql as $fn$
declare
  v_key text := gea_run_key(p_engagement, p_job_type, p_prompt,
                            p_hashes, p_parameters);
  v_id  uuid;
begin
  -- The conflict target is the partial index, so a matching failed or
  -- discarded run is not a conflict and this insert succeeds.
  insert into analysis_run (engagement_id, job_type, prompt_version_id,
                            step_ref, input_artefact_ids, input_hashes,
                            parameters, status)
       values (p_engagement, p_job_type, p_prompt, p_step_ref,
               p_artefact_ids, p_hashes, coalesce(p_parameters, '{}'::jsonb),
               'queued')
  on conflict (idempotency_key) where status not in ('failed', 'discarded')
    do nothing
    returning id into v_id;

  if v_id is not null then
    run_id := v_id; was_created := true; return next; return;
  end if;

  -- Found an existing run rather than creating one. Only a live run can have
  -- blocked the insert, so this looks for one and never returns the failure
  -- the caller is trying to get past.
  select id into v_id from analysis_run
   where idempotency_key = v_key
     and status not in ('failed', 'discarded');

  run_id := v_id; was_created := false; return next;
  return;
end $fn$;

comment on function gea_enqueue_run is
  'Queue a job, or return the live run already doing it. Identical requests '
  'produce one run; a failed or discarded attempt does not stop a retry.';

insert into gea_migration (filename, note) values
  ('034_failed_runs_can_be_retried.sql',
   'Failed and discarded runs no longer hold their idempotency key, so work '
   'that went wrong can be attempted again without deleting the record.');
