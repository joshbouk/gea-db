-- 033 Where the client's exports live.
--
-- Uploaded exports are the most sensitive data in the system: real deal
-- records, contact names, email addresses. Everything else in the application
-- is open to every Blend user by design, and these are the exception — members
-- of that engagement with can_view_raw_data, and nobody else.
--
-- That rule is enforced on the storage objects themselves rather than only in
-- the screen that lists them. A signed URL issued by a screen that forgot to
-- check is still a working link to a client's CRM extract.
--
-- Objects are stored under the engagement's id as the first folder:
--
--     <engagement_id>/<artefact_id>-<original filename>
--
-- The id rather than engagement.storage_prefix, because the prefix is typed by
-- a person and the access rule should not depend on someone not making a typo.
--
-- Supabase provides the storage schema. Where it is absent, which is the local
-- test harness, this does nothing — the same approach 001 takes for auth.

do $$
begin
  if to_regclass('storage.buckets') is null then
    return;  -- not a Supabase database; nothing to configure
  end if;

  insert into storage.buckets (id, name, public, file_size_limit)
       values ('client-exports', 'client-exports', false, 5368709120)
  on conflict (id) do nothing;

  -- A private bucket is not enough on its own. Without policies the service
  -- role can still read everything, which is correct, but so can any signed
  -- URL that leaks. These scope every operation to the engagement in the path.
  execute $p$
    drop policy if exists client_exports_read on storage.objects;
    create policy client_exports_read on storage.objects
      for select to authenticated
      using (
        bucket_id = 'client-exports'
        and app_can_view_raw(((storage.foldername(name))[1])::uuid));
  $p$;

  execute $p$
    drop policy if exists client_exports_write on storage.objects;
    create policy client_exports_write on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'client-exports'
        and app_can_view_raw(((storage.foldername(name))[1])::uuid));
  $p$;

  -- Deleting a client export is a deliberate act at close-out, not something
  -- an upload screen does. Only a lead on that engagement.
  execute $p$
    drop policy if exists client_exports_delete on storage.objects;
    create policy client_exports_delete on storage.objects
      for delete to authenticated
      using (
        bucket_id = 'client-exports'
        and app_is_engagement_lead(((storage.foldername(name))[1])::uuid));
  $p$;
end $$;

-- The path is derived, not typed ---------------------------------------------
-- So no screen has to remember the convention, and a mistyped path cannot
-- quietly place a client's export outside the rule that protects it.

create or replace function gea_export_object_path(
  p_engagement uuid, p_artefact uuid, p_filename text)
returns text language sql immutable as $fn$
  select p_engagement::text || '/' || p_artefact::text || '-' ||
         regexp_replace(btrim(p_filename), '[^A-Za-z0-9._-]+', '_', 'g')
$fn$;

comment on function gea_export_object_path is
  'Where an uploaded client export goes. The engagement id is the first folder '
  'because the storage access rule reads it from there.';

insert into gea_migration (filename, note) values
  ('033_client_export_storage.sql',
   'A private bucket for client exports, with read and write scoped to '
   'members holding can_view_raw_data and deletion to leads. Does nothing on a '
   'database without Supabase storage.');
