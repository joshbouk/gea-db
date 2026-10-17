-- 096 A file before we know what it is.
--
-- Uploading means choosing an export line first, so a consultant has to
-- know which of twenty questions a file answers before the system has
-- read a single column of it. That is backwards: the file knows what it
-- is and the system can work it out, and on a Salesforce export set the
-- only person who can reliably say is whoever ran the export.
--
-- So a file can arrive unassigned, be read, be identified, and be
-- assigned afterwards. Assignment becomes its own act rather than a
-- precondition, which also makes it reversible: a file put against the
-- wrong line is moved rather than deleted and uploaded again, and
-- everything decided from it moves with it.

create table artefact_identification (
  artefact_id    uuid primary key references artefact(id) on delete cascade,
  proposed_ref   text,
  confidence     text not null,
  reason         text not null,
  also_serves    text[] not null default array[]::text[],
  is_part_of     uuid references artefact(id),
  evidence       jsonb not null default '{}'::jsonb,
  decided_at     timestamptz,
  decided_by     uuid references app_user(id),
  decided_ref    text,
  created_at     timestamptz not null default now()
);

comment on table artefact_identification is
  'What the system thinks a dropped file is, and what a person decided. '
  'Kept apart because a proposal somebody overruled is worth having: a '
  'matcher that keeps guessing the same thing wrong is a matcher to fix.';

comment on column artefact_identification.reason is
  'Why, in words a consultant can check. "The Ref column holds Salesforce '
  'ids beginning 006" can be verified by looking; a confidence score '
  'cannot.';

comment on column artefact_identification.is_part_of is
  'The file this one continues, where a client split an export in two to '
  'get under a column cap.';

alter table artefact_identification enable row level security;
create policy artefact_identification_member on artefact_identification
  for all to authenticated
  using (exists (select 1 from artefact a where a.id = artefact_id
                   and app_is_member(a.engagement_id)))
  with check (exists (select 1 from artefact a where a.id = artefact_id
                        and app_is_member(a.engagement_id)));

-- Arriving ------------------------------------------------------------------

create or replace function gea_receive_file(
  p_engagement uuid, p_filename text, p_storage_path text, p_sha256 text,
  p_byte_size bigint default null, p_content_type text default null,
  p_export_ref text default null)
returns table (artefact_id uuid, already_had_it boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me uuid; v_line uuid; v_existing uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  -- The same file twice is the same file. A client who sends it again
  -- after a reminder should not produce two of everything.
  select id into v_existing from artefact
   where engagement_id = p_engagement and sha256 = p_sha256
     and purged_at is null;
  if v_existing is not null then
    artefact_id := v_existing; already_had_it := true; return next; return;
  end if;

  if p_export_ref is not null then
    select erl.id into v_line
      from export_request_line erl
      join export_line el on el.id = erl.export_line_id
     where erl.engagement_id = p_engagement and el.ref = p_export_ref;
    if v_line is null then
      raise exception 'there is no export line called % on this engagement',
        p_export_ref using errcode = 'check_violation';
    end if;
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  insert into artefact (engagement_id, kind, export_request_line_id,
                        original_filename, storage_path, sha256,
                        byte_size, content_type, uploaded_by, is_row_data)
       values (p_engagement, 'raw_export', v_line, p_filename, p_storage_path,
               p_sha256, p_byte_size, p_content_type, v_me, true)
    returning id into artefact_id;

  if v_line is not null then
    update export_request_line
       set status = 'received', received_at = coalesce(received_at, now())
     where id = v_line;
  end if;

  already_had_it := false;
  return next;
end $fn$;

comment on function gea_receive_file is
  'Take a file, with or without knowing what it is. The same file twice '
  'is the same file.';

-- Deciding what it is -------------------------------------------------------

create or replace function gea_assign_file(
  p_artefact uuid, p_export_ref text)
returns table (moved_from text, moved_to text, mappings_reopened integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_eng uuid; v_me uuid; v_was uuid; v_now uuid; v_was_ref text; n integer;
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
    mappings_reopened := 0; return next; return;
  end if;

  select el.ref into v_was_ref
    from export_request_line erl join export_line el on el.id = erl.export_line_id
   where erl.id = v_was;

  -- Moving a file unmakes the columns chosen from it, because they were
  -- chosen believing it was something else. A mapping is a judgement
  -- about a file and what the file is has just changed.
  --
  -- Only on a move. Saying what an unassigned file is for the first time
  -- corrects nothing: whoever chose a column from it while it sat
  -- unassigned was looking at the same columns either way.
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

  -- The line it left may have nothing against it any more.
  if v_was is not null and not exists (
       select 1 from artefact a where a.export_request_line_id = v_was
         and a.purged_at is null) then
    update export_request_line set status = 'requested', received_at = null
     where id = v_was;
  end if;

  perform gea_recompute_tasks(v_eng);

  moved_from := v_was_ref; moved_to := p_export_ref;
  mappings_reopened := n;
  return next;
end $fn$;

comment on function gea_assign_file is
  'Say what a file is, or correct what it was taken for. Columns chosen '
  'from it reopen, because they were chosen believing it was something '
  'else.';

create or replace view dropped_files
with (security_invoker = true) as
select a.engagement_id, a.id as artefact_id, a.original_filename,
       a.byte_size, a.created_at, u.display_name as uploaded_by_name,
       el.ref as assigned_to, el.question as assigned_question,
       i.proposed_ref, i.confidence, i.reason, i.also_serves,
       i.is_part_of, i.decided_at, i.decided_ref,
       pel.question as proposed_question,
       d.id as dataset_id, d.row_count, d.column_count,
       d.parse_status::text,
       r.status::text as read_status, r.error as read_error
  from artefact a
  left join app_user u on u.id = a.uploaded_by
  left join export_request_line erl on erl.id = a.export_request_line_id
  left join export_line el on el.id = erl.export_line_id
  left join artefact_identification i on i.artefact_id = a.id
  left join engagement e on e.id = a.engagement_id
  left join export_line pel on pel.ref = i.proposed_ref
                           and pel.instrument_version_id = e.instrument_version_id
  left join dataset d on d.artefact_id = a.id
  left join lateral (
    select status, error from analysis_run ar
     where ar.job_type = 'parse' and a.id = any (ar.input_artefact_ids)
     order by ar.created_at desc limit 1) r on true
 where a.purged_at is null and a.kind = 'raw_export';

comment on view dropped_files is
  'Every client file on an engagement: what it was taken for, what the '
  'system thinks it is, and how far reading it has got.';

insert into gea_migration (filename, note) values
  ('096_a_file_before_we_know_what_it_is.sql',
   'A file can arrive before anybody says what it is, and be assigned or '
   'reassigned afterwards.');
