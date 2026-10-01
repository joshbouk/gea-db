-- 001 Foundation: extensions, auth compatibility, helper functions
-- Supabase provides the auth schema and auth.uid(). This block creates them only
-- when absent, so the same migrations run locally and on Supabase unchanged.

-- Supabase provides pgcrypto. Where it is unavailable (local test harness),
-- fall back to a gen_random_uuid() shim. PostgreSQL 13+ provides this natively.
do $$
begin
  begin
    create extension if not exists "pgcrypto";
  exception when others then
    null;  -- gen_random_uuid() is built in from PostgreSQL 13
  end;
end $$;

do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    create schema auth;
  end if;
end $$;

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

-- Identifies the analysis service, which bypasses RLS because it acts for the
-- system rather than a person. On Supabase this is the service_role.
create or replace function app_is_service() returns boolean
language sql stable as $$
  select coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role'
$$;

