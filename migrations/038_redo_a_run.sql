-- 038 Doing a piece of work again.
--
-- A finished run holds its idempotency key, which is right: identical work
-- should not be queued twice. But a run finished under an older version of the
-- service is a stale answer, and there was no way to replace it except
-- deleting rows by hand and hoping nothing referenced them.
--
-- Putting the service version into the key would be the tidy answer. It is not
-- available: the key is a generated column, generated columns require
-- immutable expressions, and looking up a version in a table is not immutable.
-- Worse, it would silently invalidate every run on every engagement the moment
-- a version changed, starting a great deal of work nobody asked for.
--
-- So redoing a run is a decision somebody makes, with a reason, one run at a
-- time. The old run is discarded rather than deleted — it stays as the record
-- of what was computed and why it was replaced — and 034 already allows a
-- discarded run's key to be taken again.
--
-- That needs one change to the append-only rule. Today a finished run cannot
-- change status at all, which is what stops a succeeded run being quietly
-- rewritten. Discarding is different: it supersedes rather than rewrites, it
-- is how the methodology already retires a run a reviewer rejects, and it
-- leaves every input and output exactly where it was.

create or replace function trg_run_append_only() returns trigger
language plpgsql as $$
begin
  if old.status in ('succeeded','failed','discarded') then
    -- Inputs and outputs never change once a run has finished. A figure
    -- someone cited must still read the same a year later.
    if (new.compute_output      is distinct from old.compute_output)
    or (new.model_output_text   is distinct from old.model_output_text)
    or (new.model_output_parsed is distinct from old.model_output_parsed)
    or (new.parameters          is distinct from old.parameters)
    or (new.input_hashes        is distinct from old.input_hashes)
    or (new.input_artefact_ids  is distinct from old.input_artefact_ids)
    then
      raise exception 'analysis_run % is % and its inputs and outputs are append-only',
        old.id, old.status using errcode = 'check_violation';
    end if;

    -- The one permitted status change: retiring it. Everything else about a
    -- finished run is fixed, and a retired one is fixed entirely — it is the
    -- record of what was computed and why it was replaced.
    if new.status is distinct from old.status
       and (old.status = 'discarded' or new.status <> 'discarded') then
      raise exception
        'analysis_run % is % and can only be discarded, not changed to %',
        old.id, old.status, new.status using errcode = 'check_violation';
    end if;

    if new.status = 'discarded'
       and (new.discarded_reason is null or length(btrim(new.discarded_reason)) = 0) then
      raise exception
        'discarding a finished run needs a reason. It explains why the result '
        'was replaced'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create or replace function gea_redo_run(p_run uuid, p_reason text)
returns table (run_id uuid, was_created boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me  uuid;
  r     record;
begin
  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  select * into r from analysis_run where id = p_run;
  if r.id is null then
    raise exception 'that run is not on record' using errcode = 'check_violation';
  end if;

  if v_me is null and not app_is_service() then
    raise exception 'only an active Blend user can redo a run'
      using errcode = 'insufficient_privilege';
  end if;

  if not app_is_member(r.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so nothing was redone'
      using errcode = 'insufficient_privilege';
  end if;

  if r.status in ('queued','running') then
    raise exception
      'that run has not finished yet. Wait for it rather than starting a '
      'second copy'
      using errcode = 'check_violation';
  end if;

  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception
      'say why the work is being done again. It is kept against the run it '
      'replaces'
      using errcode = 'check_violation';
  end if;

  update analysis_run
     set status = 'discarded', discarded_reason = btrim(p_reason)
   where id = p_run;

  -- The same request, now that the old run no longer holds the key.
  select * into run_id, was_created
    from gea_enqueue_run(r.engagement_id, r.job_type, r.prompt_version_id,
                         r.step_ref, r.input_artefact_ids, r.input_hashes,
                         r.parameters);

  -- Point the retired run at its replacement, so anything citing the old one
  -- leads to the new answer rather than a dead end.
  update analysis_run set superseded_by_run_id = run_id where id = p_run;
  return next;
end $fn$;

comment on function gea_redo_run is
  'Retire a finished run with a reason and queue the same work again. The old '
  'run stays as the record of what was computed and why it was replaced.';

insert into gea_migration (filename, note) values
  ('038_redo_a_run.sql',
   'A finished run can be discarded with a reason and the work queued again. '
   'Discarding is the only status change a finished run allows.');
