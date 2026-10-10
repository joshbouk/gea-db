-- 035 Removing a client file that should not have been sent.
--
-- A client sends the deal export instead of the contact export, or a file with
-- the wrong date window, or one that turns out to hold another customer's
-- records. Blend should not keep it, and the consultant needs a way to say so
-- that does not involve deleting rows by hand.
--
-- Purging is not deleting. The bytes go; the record that a file arrived stays.
--
--   The storage object is removed by the application, because only it can
--   reach storage. This marks the artefact so nothing shows or reads it again.
--
--   The artefact row stays, with purged_at and a reason. "The client sent the
--   wrong export twice before sending the right one" is a finding about how
--   they operate, and it belongs in the evidence log.
--
--   The dataset and its field profiles go, because they describe bytes that
--   are no longer there. They are derived, not evidence.
--
--   The export request line goes back to being outstanding, unless another
--   file is still attached to it.
--
--   Runs are untouched. A run that read a purged file is still a true record
--   of an attempt.
--
-- Leads only, matching the storage deletion policy in 033. Removing a client's
-- data is not something done in passing.

alter table artefact
  add column purge_reason text,
  add column purged_by uuid references app_user(id);

comment on column artefact.purged_at is
  'When the bytes were removed from storage. The row stays as the record that '
  'a file arrived and was rejected.';

-- RULE: a purge states why, and a purged file cannot quietly come back.
create or replace function trg_artefact_purge() returns trigger
language plpgsql as $fn$
begin
  if new.purged_at is not null and old.purged_at is null then
    if new.purge_reason is null or length(btrim(new.purge_reason)) = 0 then
      raise exception
        'removing a client file needs a reason. It is kept as the record of '
        'why the file was rejected'
        using errcode = 'check_violation';
    end if;
  end if;

  if new.purged_at is null and old.purged_at is not null then
    raise exception
      'a file whose contents were removed cannot be restored. Upload the '
      'corrected file instead'
      using errcode = 'check_violation';
  end if;
  return new;
end $fn$;

create trigger artefact_purge before update on artefact
  for each row execute function trg_artefact_purge();

create or replace function gea_purge_artefact(
  p_artefact uuid, p_reason text)
returns table (storage_path text, line_reset boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me         uuid;
  v_engagement uuid;
  v_line       uuid;
  v_path       text;
  v_others     integer;
begin
  select a.engagement_id, a.export_request_line_id, a.storage_path
    into v_engagement, v_line, v_path
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

  -- Derived from bytes that are going, so it goes too. The cascade takes the
  -- field profiles with it.
  delete from dataset where artefact_id = p_artefact;

  update artefact
     set purged_at = now(), purge_reason = btrim(p_reason), purged_by = v_me
   where id = p_artefact;

  -- Back to outstanding, unless something else is still attached.
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
  return next;
end $fn$;

comment on function gea_purge_artefact is
  'Mark a client file as removed and clear what was derived from it, returning '
  'the storage path so the caller can delete the object. Leads only.';

insert into gea_migration (filename, note) values
  ('035_purge_artefact.sql',
   'A lead can remove a client file with a recorded reason. The record that it '
   'arrived stays; the bytes and everything derived from them go.');
