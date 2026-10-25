-- 104 Proceeding without it, for now.
--
-- Step 1.4 cannot complete until every export line has arrived or been
-- declared never coming, and everything after it waits on 1.4. So a
-- single line still in flight stalls the whole assessment, and the only
-- way to clear it is to say it will never arrive — which is a lie about
-- a file somebody is pulling on Thursday.
--
-- On a real engagement a consultant had eight of twenty lines, twelve
-- still being chased, and could not score anything. Nothing was wrong
-- with the evidence. The gate had two states where the work has three.
--
-- The third is the one a lead actually makes: we are not waiting for
-- this. The assessment proceeds, the elements it would have supported
-- are capped exactly as an absence would cap them, and if the file turns
-- up later the scores that rest on it reopen — which already happens,
-- because evidence arriving is already treated as a change.
--
-- Not a weaker standard. A decision that was previously only
-- expressible as a falsehood.

-- if not exists, because this migration shipped without recording
-- itself. It ran, changed the database, and apply.py found no record of
-- it and tried again — a migration that does its work and does not say
-- so is a migration that can only be run once and will be run twice.
alter table export_request_line
  add column if not exists proceeding_without_at timestamptz,
  add column if not exists proceeding_without_by uuid references app_user(id),
  add column if not exists proceeding_without_why text;

comment on column export_request_line.proceeding_without_why is
  'Why the assessment is not waiting for this. Different from never '
  'arriving: the file may still come, and the work does not stop in the '
  'meantime.';

create or replace function gea_proceed_without(
  p_engagement uuid, p_refs text[], p_why text)
returns table (ref text, caps text[])
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; v_ref text;
begin
  if not app_is_engagement_lead(p_engagement) then
    raise exception
      'only a lead can decide the assessment proceeds without a client '
      'file. It caps what can be said and the report says so'
      using errcode = 'insufficient_privilege';
  end if;
  if p_why is null or length(btrim(p_why)) < 15 then
    raise exception
      'say why the assessment is not waiting. "Chased twice, nobody at '
      'the client owns it" is a reason; "pending" is not'
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  foreach v_ref in array coalesce(p_refs, array[]::text[]) loop
    update export_request_line erl
       set proceeding_without_at = now(), proceeding_without_by = v_me,
           proceeding_without_why = btrim(p_why),
           -- Still requested. Somebody may still send it, and the day
           -- they do the work that rests on it reopens.
           status = case when status = 'not_requested' then 'requested'
                         else status end
      from export_line el
     where el.id = erl.export_line_id
       and erl.engagement_id = p_engagement and el.ref = v_ref
       and erl.status in ('not_requested', 'requested');
  end loop;

  perform gea_recompute_export_evidence(p_engagement);
  perform gea_compute_capability(p_engagement);
  perform gea_recompute_tasks(p_engagement);

  return query
    select el.ref,
           coalesce((select array_agg(distinct e.ref order by e.ref)
                       from evidence_requirement er
                       join element e on e.id = er.element_id
                      where el.ref = any (er.export_line_refs)
                        and er.is_mandatory
                        and er.instrument_version_id = el.instrument_version_id),
                    array[]::text[])
      from export_request_line erl
      join export_line el on el.id = erl.export_line_id
     where erl.engagement_id = p_engagement
       and el.ref = any (p_refs)
       and erl.proceeding_without_at is not null;
end $fn$;

comment on function gea_proceed_without is
  'A lead decides the assessment does not wait for these files. Returns '
  'what each one caps, so the cost is visible at the moment the decision '
  'is made. Reversible by chasing the line again, and the file arriving '
  'reopens whatever rested on its absence.';

create or replace function gea_waiting_again(
  p_engagement uuid, p_ref text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  update export_request_line erl
     set proceeding_without_at = null, proceeding_without_by = null,
         proceeding_without_why = null,
         chase_note = coalesce(nullif(btrim(p_note), ''), chase_note)
    from export_line el
   where el.id = erl.export_line_id
     and erl.engagement_id = p_engagement and el.ref = p_ref;
  perform gea_recompute_tasks(p_engagement);
end $fn$;

comment on function gea_waiting_again is
  'Put a line back on the list of things the assessment is waiting for. '
  'A decision not to wait is not a decision never to look.';

insert into gea_migration (filename, note) values
  ('104_proceeding_without_it.sql',
   'A lead can decide the assessment does not wait for a file, without '
   'claiming it will never arrive.')
on conflict do nothing;
