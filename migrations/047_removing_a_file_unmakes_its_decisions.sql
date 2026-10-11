-- 047 Removing a file unmakes the decisions that were about it.
--
-- 045 reopened the mappings that chose a column from the file being removed.
-- It missed the other half: the fields somebody looked at that file and said
-- were not in it.
--
-- "The client has no account id on their deals" was a statement about one
-- export. The first deals file was taken without its associated-object
-- columns, so it had no account id and that statement was true of it. The
-- replacement has one. But the decision survived the file, the matcher skips
-- anything settled, and nobody was ever asked again — the field simply stayed
-- absent and icp_reconciliation stayed unrunnable.
--
-- Marking a cap-bearing field absent also caps scores and waives evidence
-- requirements. Those followed from the decision, so they go with it. A
-- scorecard carrying a cap nobody now believes in is worse than one carrying
-- no cap at all, because the cap looks like a finding.
--
-- Only fields that come from the removed file are touched. A field whose
-- export has not arrived at all was never about this file and is left alone.

-- Two more output columns, so the function is replaced rather than amended.
drop function if exists gea_purge_artefact(uuid, text);

create function gea_purge_artefact(
  p_artefact uuid, p_reason text)
returns table (storage_path text, line_reset boolean, mappings_reopened integer,
               absences_reopened integer, caps_lifted integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me         uuid;
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
  'Remove a client file and unmake the decisions that were about it: columns '
  'chosen from it, and fields recorded as absent from it, with the score caps '
  'and waivers those absences caused.';

insert into gea_migration (filename, note) values
  ('047_removing_a_file_unmakes_its_decisions.sql',
   'Removing a file also reopens the fields recorded as not being in it, and '
   'lifts the caps and waivers that followed.');
