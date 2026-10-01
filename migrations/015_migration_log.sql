-- 015 Migration log.
--
-- Nothing in the database recorded what had been applied to it. Supabase's own
-- supabase_migrations.schema_migrations holds only 001 to 006, because
-- everything after that was applied through the SQL editor, which writes no
-- file and registers nothing. Anyone inspecting migration history got a picture
-- that stopped being true on 23 September.
--
-- This log is ours rather than Supabase's, because the migrations are ours:
-- they live in the gea-db repository, shared by the Lovable application and the
-- Python analysis service, and are applied by hand after review. Writing rows
-- into Supabase's table instead would claim files exist in a folder where they
-- deliberately do not.
--
-- CONVENTION: every migration from here on ends with its own insert into this
-- table. A migration that does not log itself is incomplete.
--
-- The verification suites are not logged. verify.sql, verify_007.sql,
-- verify_seed.sql and verify_014.sql use create or replace, are idempotent, and
-- are re-run freely. A migration is a thing you run once; those are not.

create table gea_migration (
  filename    text primary key,
  applied_at  timestamptz not null default now(),
  note        text
);

comment on table gea_migration is
  'What has been applied to this database, from the gea-db repository. '
  'Every migration logs itself as its final statement.';

-- Read access is granted explicitly here rather than left for a security
-- linter to prompt someone into adding later. Sixteen policies arrived on this
-- database that way and are still being untangled.
alter table gea_migration enable row level security;

-- Supabase provides the authenticated role. Create it only when absent, so the
-- same migration runs against a local rebuild unchanged. Same approach 001
-- takes for the auth schema.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
end $$;

create policy gea_migration_read on gea_migration
  for select to authenticated using (true);

-- Backfill. Dates are established from supabase_migrations.schema_migrations
-- for 001 to 006 and from the created_at of the rows each migration wrote for
-- 007 to 014. They are accurate to the day, not the minute.
insert into gea_migration (filename, applied_at, note) values
  ('001_foundation.sql',        '2026-09-16', 'Backfilled. Applied through the Lovable agent.'),
  ('002_zone_a_reference.sql',  '2026-09-16', 'Backfilled. Applied through the Lovable agent.'),
  ('003_zone_b_c.sql',          '2026-09-16', 'Backfilled. Applied through the Lovable agent.'),
  ('004_zone_d_e.sql',          '2026-09-16', 'Backfilled. Applied through the Lovable agent.'),
  ('005_triggers.sql',          '2026-09-16', 'Backfilled. Applied through the Lovable agent.'),
  ('006_rls.sql',               '2026-09-16', 'Backfilled. Applied through the Lovable agent.'),
  ('007_zone_a_additions.sql',  '2026-09-23', 'Backfilled. Applied through the SQL editor.'),
  ('008_seed_instrument.sql',   '2026-09-23', 'Backfilled. Applied through the SQL editor.'),
  ('009_seed_fields.sql',       '2026-09-23', 'Backfilled. Applied through the SQL editor.'),
  ('010_seed_exports.sql',      '2026-09-23', 'Backfilled. Applied through the SQL editor.'),
  ('011_seed_interviews.sql',   '2026-09-23', 'Backfilled. Applied through the SQL editor.'),
  ('012_seed_requirements.sql', '2026-09-23', 'Backfilled. Applied through the SQL editor.'),
  ('013_seed_prompts.sql',      '2026-09-23', 'Backfilled. Applied through the SQL editor.'),
  ('014_activation_gate.sql',   '2026-09-23', 'Backfilled. Applied through the SQL editor.');

insert into gea_migration (filename, note) values
  ('015_migration_log.sql', 'Created the log and backfilled 001 to 014.');
