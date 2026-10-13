-- 074 The rows themselves.
--
-- Until now a client's data lived in object storage and the database held
-- a description of it: how many rows, which columns, ten sample values
-- each. Every analysis downloaded its file and streamed it in Python.
--
-- That shaped the whole system, mostly badly.
--
--   Joining across two exports meant one analysis opening two files and
--   matching keys by hand, which is why thirty-eight join requirements had
--   to be added to the instrument in v0.7 and why a Salesforce report
--   split across two passes could not be read at all.
--
--   Identifying what a file is had to be done from column names, because
--   the names were all that reached the database. A column called Stage
--   holding Closed Won and Closed Lost is obviously a deal stage, and the
--   matcher could not see the values.
--
--   A figure in a report could not be drilled into. "Forty-one per cent of
--   pipeline is partner-sourced" is a number a client will ask about, and
--   the three hundred deals behind it were in a file in a bucket.
--
-- So the rows come in. Volume is not the problem it sounds: a whole
-- engagement is on the order of a million rows, which Postgres does not
-- notice.

create table dataset_row (
  dataset_id  uuid not null references dataset(id) on delete cascade,
  row_number  integer not null,
  data        jsonb not null,
  primary key (dataset_id, row_number)
);

comment on table dataset_row is
  'Every row of every client export, as it was read. The column names are '
  'the client''s own, so this is the file rather than an interpretation of '
  'it; the canonical view over the top is where mapping is applied.';

comment on column dataset_row.data is
  'The row as an object keyed by the client''s own column names. Values are '
  'text as they appeared: parsing them is the analysis''s job, and a date '
  'coerced on the way in is a date nobody can check against the export.';

alter table dataset_row enable row level security;

-- The same rule the profile follows: raw client data is visible to the
-- members of that engagement who are allowed to see raw data.
create policy dataset_row_raw_access on dataset_row
  for select to authenticated
  using (exists (
    select 1 from dataset d
      join artefact a on a.id = d.artefact_id
     where d.id = dataset_row.dataset_id
       and app_can_view_raw(a.engagement_id)));

create policy dataset_row_service on dataset_row
  for all to authenticated
  using (app_is_service()) with check (app_is_service());

-- Finding a row by what is in it, which is what drill-down needs.
create index dataset_row_data on dataset_row using gin (data jsonb_path_ops);

-- Removing a file takes its rows, which the cascade does. Worth saying
-- out loud because the rule everywhere else in this system is that no
-- judgement outlives the evidence it was about, and this is the evidence.

insert into gea_migration (filename, note) values
  ('074_the_rows_themselves.sql',
   'Client export rows are held in the database, so files can be joined, '
   'identified from their values, and drilled into from a figure.');

-- What a column actually contains ---------------------------------------------
--
-- Identifying a file from its column names alone got seven of nine test
-- cases right, and the two it missed were the ones whose names say
-- nothing: a column called Role, a column called Stage. The values settle
-- both instantly.
--
-- This gives the matcher what it was missing, without it having to read a
-- file to find out.

create or replace function gea_column_values(
  p_dataset uuid, p_column text, p_limit integer default 25)
returns table (value text, rows integer)
language sql stable security definer set search_path = public as $fn$
  select r.data ->> p_column, count(*)::integer
    from dataset_row r
   where r.dataset_id = p_dataset
     and nullif(btrim(r.data ->> p_column), '') is not null
   group by 1
   order by 2 desc
   limit p_limit;
$fn$;

comment on function gea_column_values is
  'The commonest values in one column. A Stage column holding Closed Won '
  'and Closed Lost identifies itself; its name does not.';

-- Salesforce says what an object is in the first three characters of its
-- id. A file keyed on something starting 006 is the opportunity export,
-- whatever its columns are called and whoever renamed them.
create or replace function gea_id_prefix_object(p_sample text)
returns text language sql immutable as $fn$
  select case left(coalesce(p_sample, ''), 3)
    when '001' then 'account'
    when '003' then 'contact'
    when '005' then 'user'
    when '006' then 'opportunity'
    when '00Q' then 'lead'
    when '00T' then 'task'
    when '00U' then 'event'
    when '500' then 'case'
    when '800' then 'contract'
    when '801' then 'order'
    when '0WO' then 'opportunity_contact_role'
    else null end
  where length(coalesce(p_sample, '')) in (15, 18);
$fn$;

comment on function gea_id_prefix_object is
  'What a Salesforce id says it belongs to. The first three characters '
  'encode the object, so a key column settles what a file is without any '
  'guessing from column names.';
