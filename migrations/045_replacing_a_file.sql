-- 045 Replacing a client file that has already been mapped.
--
-- The client sends a deals export, somebody maps twenty fields from it, and
-- then the client sends a better one — in this case the first was exported
-- without its associated-object columns, so it had no link from a deal to an
-- account.
--
-- Two problems.
--
-- 1. Purging the old file was refused. field_mapping points at the dataset,
--    the foreign key blocks the delete, and the purge fails with a constraint
--    error the consultant cannot act on. Same cause as the re-parse failure
--    in 040.
--
-- 2. The harder one. Those mappings were decided by a person looking at the
--    old file's columns and sample values. The replacement may have the same
--    columns, or may not. Carrying them across silently would mean a mapping
--    nobody checked against the data it now claims to describe, and the
--    matcher deliberately skips anything already settled, so nobody would
--    ever be asked.
--
--    So purging a file reopens the mappings made against it. They are not
--    lost: the column that was chosen becomes the proposal, with a note
--    saying where it came from, so re-confirming is one click each. What is
--    lost is the pretence that somebody checked.

alter table field_mapping
  drop constraint field_mapping_dataset_id_fkey,
  add constraint field_mapping_dataset_id_fkey
    foreign key (dataset_id) references dataset(id) on delete set null;

-- The function gains a third output column, so it is replaced rather than
-- amended: PostgreSQL will not change the shape of what a function returns.
drop function if exists gea_purge_artefact(uuid, text);

create function gea_purge_artefact(
  p_artefact uuid, p_reason text)
returns table (storage_path text, line_reset boolean, mappings_reopened integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me         uuid;
  v_engagement uuid;
  v_line       uuid;
  v_path       text;
  v_file       text;
  v_dataset    uuid;
  v_others     integer;
  v_reopened   integer := 0;
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

  select id into v_dataset from dataset where artefact_id = p_artefact;

  -- Reopen what was decided by looking at this file. The chosen column
  -- becomes the proposal so the work is not thrown away, but somebody has to
  -- look at the replacement and say yes again.
  if v_dataset is not null then
    update field_mapping
       set status = 'proposed',
           proposed_field_name = coalesce(confirmed_field_name, proposed_field_name),
           confidence = null,
           evidence_note = format(
             'Chosen from %s, which was removed on %s. Confirm it against the '
             'replacement export.', v_file, now()::date),
           confirmed_field_name = null,
           confirmed_by = null,
           confirmed_at = null
     where engagement_id = v_engagement
       and dataset_id = v_dataset
       and status in ('confirmed','corrected','auto_accepted');
    get diagnostics v_reopened = row_count;
  end if;

  delete from dataset where artefact_id = p_artefact;

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
  return next;
end $fn$;

comment on function gea_purge_artefact is
  'Remove a client file and everything derived from it. Mappings decided by '
  'looking at that file are reopened with their chosen column as the '
  'proposal, because nobody has checked them against the replacement.';

insert into gea_migration (filename, note) values
  ('045_replacing_a_file.sql',
   'A file that has been mapped can be replaced. Its mappings reopen rather '
   'than silently carrying across to a different export.');
