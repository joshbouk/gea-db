-- 121 A file nobody wants.
--
-- A file in the pile can be accepted, placed somewhere else, or
-- deleted. There is no way to say the thing a consultant most often
-- wants to say, which is that this one is not needed: superseded by a
-- better export, a duplicate of something already placed, or simply not
-- evidence.
--
-- So the pile only grows, and a file somebody has rejected looks
-- exactly like one nobody has opened. On a real engagement three files
-- sat there all day with confident proposals against them, two of which
-- were wrong. One proposed, with clear confidence, that a hundred and
-- seventy thousand rows of logged email answered the question about what
-- salespeople write down. Accepting it would have scored six elements
-- against email bodies.
--
-- Deleting is the wrong answer. The file was sent by a client, it may be
-- wanted later, and a reason written at the time is worth more than a
-- gap where a file used to be.

alter table artefact
  add column set_aside_at timestamptz,
  add column set_aside_by uuid references app_user(id),
  add column set_aside_why text;

comment on column artefact.set_aside_why is
  'Why this file is not wanted. Kept rather than deleted, because a '
  'client sent it, it may be wanted later, and the reason is evidence '
  'about the client''s data in its own right.';

create or replace function gea_set_aside_file(
  p_artefact uuid, p_why text)
returns table (filename text, was_placed boolean)
language plpgsql security definer set search_path = public as $fn$
declare v_eng uuid; v_me uuid;
begin
  select engagement_id into v_eng from artefact
   where id = p_artefact and purged_at is null;
  if v_eng is null then
    raise exception 'that file is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if p_why is null or length(btrim(p_why)) < 15 then
    raise exception
      'say why this file is not wanted. "Superseded by the October '
      'export" is a reason; "not needed" is not, and somebody will read '
      'this in six weeks'
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  -- A file set aside is off every line it answered. Leaving it placed
  -- and marked as unwanted would be two states at once.
  was_placed := exists (select 1 from artefact_answers
                         where artefact_id = p_artefact);
  if was_placed then
    perform gea_unplace_file(p_artefact);
  end if;

  update artefact
     set set_aside_at = now(), set_aside_by = v_me,
         set_aside_why = btrim(p_why)
   where id = p_artefact
  returning original_filename into filename;

  -- It stops being a question the identification keeps asking.
  update artefact_identification
     set decided_at = now(), decided_by = v_me, decided_ref = null
   where artefact_id = p_artefact;

  perform gea_recompute_tasks(v_eng);
  return next;
end $fn$;

comment on function gea_set_aside_file is
  'Record that a file is not wanted, with why. It stays on record and '
  'stops appearing as something to decide.';

create or replace function gea_want_it_after_all(p_artefact uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_eng uuid;
begin
  select engagement_id into v_eng from artefact
   where id = p_artefact and purged_at is null;
  if v_eng is null then
    raise exception 'that file is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  update artefact
     set set_aside_at = null, set_aside_by = null, set_aside_why = null
   where id = p_artefact;
  update artefact_identification
     set decided_at = null, decided_by = null
   where artefact_id = p_artefact and decided_ref is null;
  perform gea_recompute_tasks(v_eng);
end $fn$;

comment on function gea_want_it_after_all is
  'Put a file back in the pile. Setting one aside is a judgement, and '
  'judgements get revisited.';

-- The pile says which files somebody has already decided against, and
-- shows the unplaced ones at all.
--
-- 111 replaced a column join with a join through the table that records
-- which lines a file answers, and left the join after it inner. A file
-- answering nothing was therefore filtered out of the view whose whole
-- job is to show files answering nothing. It has been showing only
-- placed files ever since.
--
-- Otherwise the shape is the one that was there, because several
-- screens read it and a rewrite from memory would quietly drop a column
-- one of them needs.

drop view if exists dropped_files;
create view dropped_files
with (security_invoker = true) as
 SELECT a.engagement_id,
    a.id AS artefact_id,
    a.original_filename,
    a.byte_size,
    a.created_at,
    u.display_name AS uploaded_by_name,
    el.ref AS assigned_to,
    el.question AS assigned_question,
    i.proposed_ref,
    i.confidence,
    i.reason,
    i.also_serves,
    i.is_part_of,
    i.decided_at,
    i.decided_ref,
    pel.question AS proposed_question,
    d.id AS dataset_id,
    d.row_count,
    d.column_count,
    d.parse_status::text AS parse_status,
    r.status::text AS read_status,
    r.error AS read_error,
    a.set_aside_at,
    a.set_aside_why,
    su.display_name AS set_aside_by_name
   FROM artefact a
     LEFT JOIN app_user u ON u.id = a.uploaded_by
     LEFT JOIN app_user su ON su.id = a.set_aside_by
     LEFT JOIN artefact_answers aa_erl ON aa_erl.artefact_id = a.id
     LEFT JOIN export_request_line erl ON erl.id = aa_erl.export_request_line_id
     LEFT JOIN export_line el ON el.id = erl.export_line_id
     LEFT JOIN artefact_identification i ON i.artefact_id = a.id
     LEFT JOIN engagement e ON e.id = a.engagement_id
     LEFT JOIN export_line pel ON pel.ref = i.proposed_ref AND pel.instrument_version_id = e.instrument_version_id
     LEFT JOIN dataset d ON d.artefact_id = a.id
     LEFT JOIN LATERAL ( SELECT ar.status,
            ar.error
           FROM analysis_run ar
          WHERE ar.job_type = 'parse'::text AND (a.id = ANY (ar.input_artefact_ids))
          ORDER BY ar.created_at DESC
         LIMIT 1) r ON true
  WHERE a.purged_at IS NULL AND a.kind = 'raw_export'::artefact_kind;

comment on view dropped_files is
  'Every file and where it stands: placed, waiting for a decision, or '
  'set aside with a reason. A pile that shows all three is a pile '
  'somebody can work through.';

insert into gea_migration (filename, note) values
  ('121_a_file_nobody_wants.sql',
   'A file can be set aside with a reason, rather than only accepted, '
   'moved or deleted.')
on conflict do nothing;
