-- 018 Enqueueing analysis runs.
--
-- The application hands work to the Python analysis service by inserting a row
-- here and watching it. There is no HTTP between them. Three things were
-- missing before that could be relied on.
--
-- 1. The idempotency key was the application's to compute. Two screens
--    computing it two slightly different ways — input hashes in a different
--    order, parameter keys in a different order — produce different keys for
--    the same request, and the unique index silently stops meaning anything.
--    It is a generated column now, so it cannot be computed wrongly.
--
-- 2. The formula in the contract collides. It names prompt_version_id, the
--    input hashes and the parameters, but not the job type or the engagement.
--    `parse` and `profile` run back to back on the same uploaded file, both
--    with no prompt and no parameters, and would have produced an identical
--    key: the second job refused as a duplicate of the first. Both are in the
--    key now.
--
-- 3. "An identical request returns the existing run" is not what a unique
--    index does. It raises. Every caller would have had to handle the conflict
--    itself, and two people clicking the same button at the same moment is
--    exactly when one of them gets it wrong. gea_enqueue_run() does it once,
--    atomically, and returns the run either way.

-- A stable rendering of the input hashes. Order of upload must not change the
-- key; the same files in a different sequence are the same request.
create or replace function gea_canonical_hashes(p text[])
returns text language sql immutable as $fn$
  select coalesce(
    array_to_string(array(select unnest(coalesce(p, '{}'::text[])) order by 1), ','),
    '')
$fn$;

-- jsonb already stores object keys in a canonical order, so its text form is
-- stable without further work. That is why parameters is jsonb and not json.
create or replace function gea_run_key(
  p_engagement uuid, p_job_type text, p_prompt uuid,
  p_hashes text[], p_parameters jsonb)
returns text language sql immutable as $fn$
  select encode(sha256(convert_to(
    coalesce(p_engagement::text, '') || '|' ||
    coalesce(p_job_type, '')         || '|' ||
    coalesce(p_prompt::text, '')     || '|' ||
    gea_canonical_hashes(p_hashes)   || '|' ||
    coalesce(p_parameters, '{}'::jsonb)::text, 'UTF8')), 'hex')
$fn$;

-- The column exists and is empty, so it can be replaced rather than migrated.
alter table analysis_run drop column idempotency_key;

alter table analysis_run add column idempotency_key text
  generated always as (
    gea_run_key(engagement_id, job_type, prompt_version_id,
                input_hashes, parameters)
  ) stored;

create unique index analysis_run_idempotency_key
  on analysis_run (idempotency_key);

-- Enqueue ------------------------------------------------------------------
-- Returns the run whether it created one or found one. The caller cannot tell
-- the difference and should not need to.

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
  insert into analysis_run (engagement_id, job_type, prompt_version_id,
                            step_ref, input_artefact_ids, input_hashes,
                            parameters, status)
       values (p_engagement, p_job_type, p_prompt, p_step_ref,
               p_artefact_ids, p_hashes, coalesce(p_parameters, '{}'::jsonb),
               'queued')
  on conflict (idempotency_key) do nothing
    returning id into v_id;

  if v_id is not null then
    run_id := v_id; was_created := true; return next; return;
  end if;

  select id into v_id from analysis_run where idempotency_key = v_key;
  run_id := v_id; was_created := false; return next;
  return;
end $fn$;

comment on function gea_enqueue_run is
  'Enqueue an analysis run, or return the identical one already queued. '
  'Two people clicking the same button produce one run.';

-- Watching -----------------------------------------------------------------
-- Realtime delivers nothing until the table is in the publication. A browser
-- subscription connects successfully either way, which is why this is worth
-- stating rather than assuming.

do $$
begin
  -- Supabase creates this publication. Create it empty where it is absent so a
  -- local rebuild runs the same statements, as 001 does for the auth schema.
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;

  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and tablename = 'analysis_run') then
    alter publication supabase_realtime add table analysis_run;
  end if;
end $$;

-- A run that is running but has stopped reporting. The contract says there is
-- no silent stall, so the condition is named here rather than left to each
-- screen to invent its own threshold.
create or replace view analysis_run_state
with (security_invoker = true) as
select r.*,
       (r.status = 'running'
        and r.heartbeat_at is not null
        and r.heartbeat_at < now() - interval '10 minutes') as is_stalled,
       case when r.progress_total > 0
            then round(100.0 * coalesce(r.progress_done, 0) / r.progress_total)
       end as progress_percent
  from analysis_run r;

comment on view analysis_run_state is
  'analysis_run with stall detection and progress percentage. security_invoker '
  'means row-level security applies as the person reading, not the view owner.';

insert into gea_migration (filename, note) values
  ('018_run_enqueue.sql',
   'Idempotency key generated in the database and widened to include job type '
   'and engagement. Atomic enqueue. Realtime enabled on analysis_run.');
