-- 075 A run about a deleted file.
--
-- Removing a file reopens the mappings chosen from it, reopens the fields
-- called absent from it, and lifts the caps its absence caused. It does
-- nothing at all to the runs that read it, which is the one thing it
-- obviously should do.
--
-- Two consequences, and the second is worse than the first.
--
--   Uploading the same file again does nothing. A run is matched by the
--   hash of its input, so the second upload finds the first upload's run,
--   sees that it succeeded, and reports that the work is already done. The
--   file it was done to is in the bin. Nothing reads the new one, ever.
--
--   A score can cite it. is_stale exists precisely so the freeze can
--   refuse a citation pointing at a superseded run, and nothing was
--   setting it. A figure resting on a file nobody can produce is the
--   quietest way for an assessment to become indefensible.

-- A column is added to what it returns, so the old one goes first. Every
-- existing caller reads by name and keeps working.
drop function if exists gea_purge_artefact(uuid, text);

create function gea_purge_artefact(
  p_artefact uuid, p_reason text)
returns table (storage_path text, line_reset boolean, mappings_reopened integer,
               absences_reopened integer, caps_lifted integer,
               runs_made_stale integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me         uuid;
  v_stale      integer := 0;
  v_engagement uuid;
  v_line       uuid;
  v_ref        text;
  v_path       text;
  v_file       text;
  v_dataset    uuid;
  v_others     integer;
  v_reopened   integer := 0;
  v_absences   integer := 0;
  v_caps       integer := 0;
  r            record;
begin
  select a.engagement_id, a.export_request_line_id, a.storage_path,
         a.original_filename
    into v_engagement, v_line, v_path, v_file
    from artefact a where a.id = p_artefact and a.purged_at is null;

  if v_engagement is null then
    raise exception 'that file is not on record, or its contents were already removed'
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  if not app_is_engagement_lead(v_engagement) then
    raise exception
      'only a lead consultant or lead architect on this engagement can remove '
      'a client file'
      using errcode = 'insufficient_privilege';
  end if;

  select el.ref into v_ref
    from export_request_line erl
    join export_line el on el.id = erl.export_line_id
   where erl.id = v_line;

  select id into v_dataset from dataset where artefact_id = p_artefact;

  -- Columns chosen from this file.
  if v_dataset is not null then
    update field_mapping
       set status = 'proposed',
           proposed_field_name = coalesce(confirmed_field_name, proposed_field_name),
           confidence = null,
           evidence_note = format(
             'Chosen from %s, which was removed on %s. Confirm it against the '
             'replacement export.', v_file, now()::date),
           confirmed_field_name = null, confirmed_by = null, confirmed_at = null
     where engagement_id = v_engagement
       and dataset_id = v_dataset
       and status in ('confirmed','corrected','auto_accepted');
    get diagnostics v_reopened = row_count;
  end if;

  -- Fields somebody said were not in this file. Each one takes its caps and
  -- its waivers with it.
  if v_ref is not null then
    for r in
      select cf.id, cf.key
        from field_mapping m
        join canonical_field cf on cf.id = m.canonical_field_id
        join engagement e on e.id = v_engagement
       where m.engagement_id = v_engagement
         and m.status = 'unmapped'
         and cf.instrument_version_id = e.instrument_version_id
         and v_ref = any (cf.source_export_refs)
    loop
      update score s
         set cap_applied = null, cap_reason = null
        from canonical_field_cap c
       where c.canonical_field_id = r.id
         and s.element_id = c.element_id
         and s.engagement_id = v_engagement
         and s.cap_reason like '%' || r.key || '%';
      get diagnostics v_others = row_count;
      v_caps := v_caps + v_others;

      update engagement_requirement
         set state = 'outstanding', waiver_reason = null,
             waiver_consequence = null, waived_by = null, waived_at = null
       where engagement_id = v_engagement
         and state = 'waived'
         and waiver_reason = format('The client has no %s field in their export.', r.key);

      update field_mapping
         set status = 'proposed', confidence = null,
             evidence_note = format(
               'Recorded as not in %s, which was removed on %s. Look for it in '
               'the replacement export.', v_file, now()::date),
             confirmed_field_name = null, confirmed_by = null, confirmed_at = null
       where engagement_id = v_engagement and canonical_field_id = r.id;
      v_absences := v_absences + 1;
    end loop;
  end if;

  delete from dataset where artefact_id = p_artefact;

  -- Everything read from the file was a judgement about it, and no
  -- judgement outlives the evidence it was about. A run is one of those.
  --
  -- Two things were wrong without this. A score could cite work done to a
  -- file nobody can produce, because is_stale existed and nothing set it.
  -- And uploading the same file again did nothing at all: a run is matched
  -- by the hash of its input, so the second upload found the first
  -- upload's run, saw that it had succeeded, and reported the work done.
  update analysis_run
     set is_stale = true
   where engagement_id = v_engagement
     and p_artefact = any (input_artefact_ids)
     and not is_stale;
  get diagnostics v_stale = row_count;
  runs_made_stale := v_stale;

  update artefact
     set purged_at = now(), purge_reason = btrim(p_reason), purged_by = v_me
   where id = p_artefact;

  line_reset := false;
  if v_line is not null then
    select count(*) into v_others from artefact
     where export_request_line_id = v_line and purged_at is null;
    if v_others = 0 then
      update export_request_line
         set status = 'requested', received_at = null
       where id = v_line;
      line_reset := true;
    end if;
  end if;

  storage_path := v_path;
  mappings_reopened := v_reopened;
  absences_reopened := v_absences;
  caps_lifted := v_caps;
  return next;
end $fn$;

comment on function gea_purge_artefact is
  'Remove a client file and unmake the decisions that were about it: '
  'columns chosen from it, fields recorded as absent from it, the caps and '
  'waivers those absences caused, and the runs that read it. A run about a '
  'deleted file is stale: it can no longer be cited, and it no longer '
  'blocks the same file being uploaded again.';

-- A stale run is not a reason to refuse new work ------------------------------
--
-- The idempotency index already let a failed or discarded run be retried.
-- A stale one is the same case: the work it describes was done to
-- something that is gone.

drop index if exists analysis_run_idempotency_key;
create unique index analysis_run_idempotency_key
    on analysis_run (idempotency_key)
 where status not in ('failed', 'discarded') and not is_stale;

create or replace function gea_enqueue_run(
  p_engagement uuid, p_job_type text, p_prompt uuid default null,
  p_step_ref text default null, p_artefact_ids uuid[] default null,
  p_hashes text[] default null, p_parameters jsonb default null)
returns table (run_id uuid, was_created boolean)
language plpgsql security definer set search_path = public as $fn$
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
  on conflict (idempotency_key)
    where status not in ('failed', 'discarded') and not is_stale
    do nothing
    returning id into v_id;

  if v_id is not null then
    run_id := v_id; was_created := true; return next; return;
  end if;

  select id into v_id from analysis_run
   where idempotency_key = v_key
     and status not in ('failed', 'discarded')
     and not is_stale;

  run_id := v_id; was_created := false; return next;
  return;
end $fn$;

comment on function gea_enqueue_run is
  'Queue a job, or return the live one already doing it. A failed, '
  'discarded or stale run is not live: the first two can be retried and '
  'the third describes work done to a file that has since been removed.';

insert into gea_migration (filename, note) values
  ('075_a_run_about_a_deleted_file.sql',
   'Removing a file makes its runs stale, so they cannot be cited and do '
   'not block the same file being uploaded again.');
