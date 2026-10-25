-- 106 Placing a file asks what its columns are.
--
-- Proposing mappings is queued after a file is read, and never after a
-- file is placed. That worked while the only way to upload was to choose
-- the export line first: the line was known, the file was read, and the
-- proposal followed.
--
-- The drop zone reverses the order. A file is read before anybody says
-- what it is, so at the moment of reading there is no line and nothing
-- to match against, and the proposal is correctly skipped. Then a person
-- places it and nothing happens, because placing is not reading.
--
-- A consultant on the first real drop placed three files and waited for
-- a mapping screen that was never going to fill.
--
-- So the act that completes the knowledge is the act that triggers the
-- work. Saying what a file is tells the system which fields its columns
-- could answer, and that is exactly when to go looking.

-- A column is added to what it returns, so the old one goes first.
drop function if exists gea_assign_file(uuid, text);

create function gea_assign_file(
  p_artefact uuid, p_export_ref text)
returns table (moved_from text, moved_to text, mappings_reopened integer,
               mapping_run_queued boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_eng uuid; v_me uuid; v_was uuid; v_now uuid; v_was_ref text; n integer;
  v_parsed boolean;
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

  -- Moving a file unmakes the columns chosen from it, because they were
  -- chosen believing it was something else. Saying what an unassigned
  -- file is corrects nothing.
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

  -- And go looking for what its columns answer.
  --
  -- Only once it has been read: a file placed before the reader has
  -- finished has no columns to offer, and the read will queue this
  -- itself when it lands.
  select exists (select 1 from dataset d
                  where d.artefact_id = p_artefact and d.parse_status = 'parsed')
    into v_parsed;
  if v_parsed then
    perform gea_enqueue_run(v_eng, 'propose_mappings');
  end if;

  moved_from := v_was_ref; moved_to := p_export_ref;
  mappings_reopened := n;
  mapping_run_queued := v_parsed;
  return next;
end $fn$;

comment on function gea_assign_file is
  'Say what a file is, or correct what it was taken for. Columns chosen '
  'from it reopen, because they were chosen believing it was something '
  'else, and the system goes looking for what its columns answer — '
  'placing a file is the moment that becomes possible.';

insert into gea_migration (filename, note) values
  ('106_placing_a_file_asks_what_its_columns_are.sql',
   'Placing a file queues the mapping proposals. The drop zone reads '
   'before it places, so the read could not.');
