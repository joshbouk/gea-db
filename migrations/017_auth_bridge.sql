-- 017 Auth bridge: a Supabase identity becomes a Blend user.
--
-- app_user.auth_subject is not null, so a person cannot be provisioned before
-- they first sign in. Nothing can create their row in advance. And
-- app_is_blend_user() requires an active app_user row, so without this trigger
-- a new starter signs in successfully and sees an empty application.
--
-- Authentication is Entra ID. Only accounts in Blend's tenant can reach the
-- sign-in at all, so the domain check below is a second line rather than the
-- first. It is here because a misconfigured provider is a quiet failure and
-- this makes it a loud one.

-- A minimal stand-in for Supabase's auth.users, created only where it is
-- absent, so the migration and its tests run against a local rebuild. On
-- Supabase the real table already exists and this does nothing. The three
-- columns named here are the three the trigger reads.
do $$
begin
  if to_regclass('auth.users') is null then
    create table auth.users (
      id                 uuid primary key,
      email              text,
      raw_user_meta_data jsonb
    );
  end if;
end $$;

create or replace function trg_provision_blend_user() returns trigger
language plpgsql security definer set search_path = public, auth as $fn$
declare
  v_email   text := lower(btrim(coalesce(new.email, '')));
  v_name    text;
  v_role    org_role;
  v_existing uuid;
begin
  if v_email = '' or v_email not like '%@blendb2b.com' then
    raise exception
      'cannot provision %: this application is for Blend accounts only',
      coalesce(nullif(v_email, ''), '(no email)')
      using errcode = 'check_violation';
  end if;

  -- Entra supplies one of these depending on how the provider is configured.
  -- Falling back to the local part of the address keeps display_name not null
  -- rather than failing a sign-in over a missing claim.
  v_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    initcap(replace(split_part(v_email, '@', 1), '.', ' ')));

  -- An identity can be rebuilt in Entra while the person stays the same. Match
  -- on email and re-point the existing row rather than failing on the unique
  -- constraint, which would lock them out of their own history.
  select id into v_existing from app_user where email = v_email;

  if v_existing is not null then
    update app_user
       set auth_subject = new.id,
           display_name = v_name
     where id = v_existing;
    return new;
  end if;

  -- The first person through the door is an admin, because otherwise nobody
  -- can promote anybody and the application has no way in. Every subsequent
  -- person is a Growth Consultant until an admin says otherwise. This is a
  -- deliberate bootstrap, not an oversight: the Entra tenant is Blend's, so
  -- the first account to sign in is a Blend account.
  if exists (select 1 from app_user where org_role = 'admin' and is_active) then
    v_role := 'gc';
  else
    v_role := 'admin';
  end if;

  insert into app_user (auth_subject, email, display_name, org_role)
    values (new.id, v_email, v_name, v_role);

  return new;
end $fn$;

drop trigger if exists provision_blend_user on auth.users;
create trigger provision_blend_user after insert on auth.users
  for each row execute function trg_provision_blend_user();

-- An admin can maintain the directory: promote a consultant, deactivate a
-- leaver. 016 enabled row-level security on app_user with a read policy only,
-- which left nobody able to write it except the service role.
create or replace function app_is_admin() returns boolean
language sql stable security definer set search_path = public as $fn$
  select app_is_service() or exists (
    select 1 from app_user u
     where u.auth_subject = auth.uid()
       and u.is_active
       and u.org_role = 'admin'
  )
$fn$;

drop policy if exists app_user_admin_write on app_user;
create policy app_user_admin_write on app_user
  for update to authenticated
  using (app_is_admin()) with check (app_is_admin());

-- RULE: deactivating yourself would remove the last admin by accident and
-- leave the directory unmaintainable.
create or replace function trg_app_user_keep_an_admin() returns trigger
language plpgsql as $fn$
begin
  if (old.org_role = 'admin' and old.is_active)
     and (new.org_role <> 'admin' or not new.is_active) then
    if not exists (select 1 from app_user
                    where org_role = 'admin' and is_active and id <> old.id) then
      raise exception 'cannot remove the last active admin'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $fn$;

create trigger app_user_keep_an_admin before update on app_user
  for each row execute function trg_app_user_keep_an_admin();

insert into gea_migration (filename, note) values
  ('017_auth_bridge.sql',
   'Entra identities provision an app_user row on first sign-in. Admins maintain '
   'the directory. The last active admin cannot be removed.');
