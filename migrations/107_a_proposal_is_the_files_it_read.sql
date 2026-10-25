-- 107 A proposal is the files it read.
--
-- The third time this mistake has been made, in the third place.
--
-- Proposing mappings was queued with a timestamp in its parameters, so
-- no two calls could match and three files produced three identical
-- runs. That was fixed by removing the parameters, which made every call
-- match the first one ever made — a succeeded run from three days ago
-- answered every request after it, and a consultant placing files today
-- watched nothing happen.
--
-- The roll-up had the same pair of faults and was fixed in 092 by
-- keying it on the evidence it reads. The same answer applies here and
-- should have been applied here at the time: a job's key is what the job
-- is about, and proposing mappings is about the files that have been
-- placed and read.
--
-- Place a file and the set changes, so new work is queued. Place a
-- second while the first is still waiting and it collapses, because the
-- run already queued will see both.

create or replace function gea_enqueue_mapping_proposals(p_engagement uuid)
returns table (run_id uuid, was_created boolean, anything_new boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_files integer; v_newest timestamptz; v_params jsonb; v_existing uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was started'
      using errcode = 'insufficient_privilege';
  end if;

  -- What there is to match against: the files placed against a line and
  -- read, and when the newest of them was placed.
  select count(*), max(a.created_at)
    into v_files, v_newest
    from artefact a
    join dataset d on d.artefact_id = a.id
   where a.engagement_id = p_engagement
     and a.purged_at is null
     and a.export_request_line_id is not null
     and d.parse_status = 'parsed';

  if v_files = 0 then
    raise exception
      'no file has been placed against an export line yet, so there are '
      'no columns to match against. Place them on the Files screen'
      using errcode = 'check_violation';
  end if;

  v_params := jsonb_build_object(
    'placed_files', v_files,
    'newest', coalesce(v_newest::text, ''));

  select id into v_existing from analysis_run
   where engagement_id = p_engagement and job_type = 'propose_mappings'
     and parameters = v_params
     and status not in ('failed', 'discarded') and not is_stale;

  return query
    select e.run_id, e.was_created, v_existing is null
      from gea_enqueue_run(p_engagement, 'propose_mappings', null, null,
                           null, null, v_params) e;
end $fn$;

comment on function gea_enqueue_mapping_proposals is
  'Queue the mapping proposals, keyed on the files they will read. '
  'Placing a file changes the set and queues new work; placing a second '
  'while one is waiting collapses, because that run will see both.';

-- And placing a file uses it ------------------------------------------------

create or replace function gea_assign_file(
  p_artefact uuid, p_export_ref text)
returns table (moved_from text, moved_to text, mappings_reopened integer,
               mapping_run_queued boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_eng uuid; v_me uuid; v_was uuid; v_now uuid; v_was_ref text; n integer;
  v_parsed boolean; v_queued boolean := false;
begin
  select engagement_id, export_request_line_id into v_eng, v_was
    from artefact where id = p_artefact and purged_at is null;
  if v_eng is null then
    raise exception 'that file is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  select erl.id into v_now
    from export_request_line erl
    join export_line el on el.id = erl.export_line_id
   where erl.engagement_id = v_eng and el.ref = p_export_ref;
  if v_now is null then
    raise exception 'there is no export line called % on this engagement',
      p_export_ref using errcode = 'check_violation';
  end if;

  if v_was is not null and v_was = v_now then
    moved_from := p_export_ref; moved_to := p_export_ref;
    mappings_reopened := 0; mapping_run_queued := false; return next; return;
  end if;

  select el.ref into v_was_ref
    from export_request_line erl join export_line el on el.id = erl.export_line_id
   where erl.id = v_was;

  n := 0;
  if v_was is not null then
    update field_mapping m
       set status = 'proposed', confirmed_field_name = null,
           confirmed_at = null, confirmed_by = null
      from dataset d
     where d.id = m.dataset_id and d.artefact_id = p_artefact
       and m.status in ('confirmed', 'corrected', 'auto_accepted');
    get diagnostics n = row_count;
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  update artefact set export_request_line_id = v_now where id = p_artefact;
  update artefact_identification
     set decided_at = now(), decided_by = v_me, decided_ref = p_export_ref
   where artefact_id = p_artefact;

  update export_request_line
     set status = 'received', received_at = coalesce(received_at, now())
   where id = v_now;

  if v_was is not null and not exists (
       select 1 from artefact a where a.export_request_line_id = v_was
         and a.purged_at is null) then
    update export_request_line set status = 'requested', received_at = null
     where id = v_was;
  end if;

  perform gea_recompute_tasks(v_eng);

  select exists (select 1 from dataset d
                  where d.artefact_id = p_artefact and d.parse_status = 'parsed')
    into v_parsed;
  if v_parsed then
    -- Reports whether work was actually queued, not whether it was
    -- asked for. The previous version said yes whenever the file was
    -- parsed, which was true of a request that found an old run and
    -- did nothing.
    select e.was_created into v_queued
      from gea_enqueue_mapping_proposals(v_eng) e;
  end if;

  moved_from := v_was_ref; moved_to := p_export_ref;
  mappings_reopened := n;
  mapping_run_queued := coalesce(v_queued, false);
  return next;
end $fn$;

comment on function gea_assign_file is
  'Say what a file is, or correct what it was taken for. Columns chosen '
  'from it reopen, the mapping proposals are queued, and '
  'mapping_run_queued says whether work actually started rather than '
  'whether it was asked for.';

insert into gea_migration (filename, note) values
  ('107_a_proposal_is_the_files_it_read.sql',
   'Proposing mappings is keyed on the placed files it reads, so it runs '
   'again when they change and collapses when they do not.')
on conflict do nothing;

-- Taking a file back out of the pile ----------------------------------------
--
-- A file can be placed against a line and moved to another, and there is
-- no way to say "I should not have placed this at all". The only
-- recovery is deleting the file and uploading it again, which unmakes
-- every decision taken from it and is a destructive act for a change of
-- mind.
--
-- The same unmaking applies as a move: columns chosen from the file were
-- chosen believing it answered that line.

create or replace function gea_unplace_file(p_artefact uuid)
returns table (was text, mappings_reopened integer)
language plpgsql security definer set search_path = public as $fn$
declare v_eng uuid; v_was uuid; v_me uuid; n integer;
begin
  select engagement_id, export_request_line_id into v_eng, v_was
    from artefact where id = p_artefact and purged_at is null;
  if v_eng is null then
    raise exception 'that file is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if v_was is null then
    was := null; mappings_reopened := 0; return next; return;
  end if;

  select el.ref into was
    from export_request_line erl join export_line el on el.id = erl.export_line_id
   where erl.id = v_was;

  update field_mapping m
     set status = 'proposed', confirmed_field_name = null,
         confirmed_at = null, confirmed_by = null
    from dataset d
   where d.id = m.dataset_id and d.artefact_id = p_artefact
     and m.status in ('confirmed', 'corrected', 'auto_accepted');
  get diagnostics n = row_count;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  update artefact set export_request_line_id = null where id = p_artefact;
  -- The proposal stands; only the decision is undone. Somebody who
  -- disagreed with where a file went has not disagreed with what the
  -- system thought it was.
  update artefact_identification
     set decided_at = null, decided_by = null, decided_ref = null
   where artefact_id = p_artefact;

  if not exists (select 1 from artefact a
                  where a.export_request_line_id = v_was
                    and a.purged_at is null) then
    update export_request_line set status = 'requested', received_at = null
     where id = v_was;
  end if;

  perform gea_recompute_tasks(v_eng);
  mappings_reopened := n;
  return next;
end $fn$;

comment on function gea_unplace_file is
  'Take a file back out of the pile without deleting it. The columns '
  'chosen from it reopen; what the system thought it was is kept, '
  'because disagreeing with where a file went is not disagreeing with '
  'that.';
