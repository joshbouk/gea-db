-- 039 Looking at the data before deciding what a column is.
--
-- Mapping a client's column to a canonical field from its name alone is
-- guesswork. "Record source" and "Original Source" are different things in
-- HubSpot and you cannot tell which is which without seeing what is in them.
-- Every importer worth using shows the data: HubSpot's own shows the first
-- row's value beside each mapping.
--
-- Two things here.
--
-- 1. A handful of real values per column, collected while the file is read.
--
--    These are the client's own records — names, addresses, email addresses.
--    They sit under the same rule as everything else raw: members of that
--    engagement holding can_view_raw_data, and nobody else. dataset_field_
--    profile already keeps top_value on those terms, so this widens what is
--    stored rather than changing who can see it.
--
--    Distinct values, so a column that is "Closed Won" on nine rows out of ten
--    shows what else it can be rather than the same word ten times.
--
-- 2. Candidate columns for a field, ranked, filtered to the shape the field
--    needs. An identifier field offers only columns where every populated row
--    is distinct. A date field offers only columns that parsed as dates. So
--    contact_id offers four columns out of five hundred rather than all of
--    them.

alter table dataset_field_profile
  add column sample_values text[];

comment on column dataset_field_profile.sample_values is
  'Up to ten distinct values from this column, for deciding what it holds. '
  'Client data: covered by the same access rule as the rest of this table.';

-- Candidate columns ---------------------------------------------------------

create or replace function gea_mapping_candidates(
  p_engagement uuid, p_canonical_field uuid, p_all boolean default false)
returns table (
  field_name       text,
  dataset_id       uuid,
  export_ref       text,
  inferred_type    text,
  populated_count  integer,
  populated_rate   numeric,
  distinct_count   integer,
  top_value        text,
  sample_values    text[],
  is_proposed      boolean,
  matcher_rank     integer,
  fits_shape       boolean)
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_expected  text;
  v_alts      jsonb;
  v_proposed  text;
  v_refs      text[];
begin
  if not app_can_view_raw(p_engagement) then
    raise exception
      'you need access to this engagement''s raw client data to choose a column'
      using errcode = 'insufficient_privilege';
  end if;

  select cf.expected_type, cf.source_export_refs
    into v_expected, v_refs
    from canonical_field cf where cf.id = p_canonical_field;

  select fm.candidate_alternatives, fm.proposed_field_name
    into v_alts, v_proposed
    from field_mapping fm
   where fm.engagement_id = p_engagement
     and fm.canonical_field_id = p_canonical_field;

  return query
  with cols as (
    select p.field_name, d.id as dataset_id, el.ref as export_ref,
           p.inferred_type, p.populated_count, p.populated_rate,
           p.distinct_count, p.top_value, p.sample_values
      from dataset_field_profile p
      join dataset d on d.id = p.dataset_id
      join artefact a on a.id = d.artefact_id
      join export_request_line erl on erl.id = a.export_request_line_id
      join export_line el on el.id = erl.export_line_id
     where a.engagement_id = p_engagement
       and a.purged_at is null
       and d.parse_status = 'parsed'
       -- Only the export this field comes from. A loss reason lives in the
       -- deals file and is never offered from a contact export, however well
       -- a column there happens to be named.
       and el.ref = any(coalesce(v_refs, array[]::text[]))
  ), shaped as (
    select c.*,
           case lower(coalesce(v_expected, ''))
             -- An identifier is only an identifier if it actually identifies:
             -- every populated row distinct.
             when 'id' then c.distinct_count is not null
                         and c.populated_count > 0
                         and c.distinct_count = c.populated_count
             when 'date' then c.inferred_type = 'date'
             when 'timestamp' then c.inferred_type = 'date'
             when 'number' then c.inferred_type = 'number'
             when 'currency' then c.inferred_type = 'number'
             when 'integer' then c.inferred_type = 'number'
             when 'boolean' then c.inferred_type = 'boolean'
             -- A picklist has few distinct values relative to its rows.
             -- Something with twelve thousand distinct values is free text.
             when 'enum' then c.populated_count = 0
                            or (c.distinct_count is not null
                                and c.distinct_count <= greatest(60, c.populated_count / 50))
             else true
           end as fits
      from cols c
  ), ranked as (
    select s.*,
           s.field_name = v_proposed as proposed,
           -- The matcher's own ordering, where it had one. Its near-misses
           -- were not good enough to offer as an answer; they are still the
           -- best research available when someone goes looking.
           coalesce(
             (select ord from jsonb_array_elements(coalesce(v_alts, '[]'::jsonb))
                with ordinality as t(val, ord)
               where t.val->>'field_name' = s.field_name),
             999) as rank
      from shaped s
  )
  select r.field_name, r.dataset_id, r.export_ref, r.inferred_type,
         r.populated_count, r.populated_rate, r.distinct_count, r.top_value,
         r.sample_values, r.proposed, r.rank::integer, r.fits
    from ranked r
   where p_all or r.fits
   order by r.proposed desc, r.rank, r.populated_rate desc, r.field_name;
end $fn$;

comment on function gea_mapping_candidates is
  'Columns that could be this field, from the export it comes from, ranked by '
  'the matcher''s own findings and filtered to the shape the field needs. '
  'p_all true drops the shape filter, for the occasional client who has put '
  'something somewhere strange.';

insert into gea_migration (filename, note) values
  ('039_sample_values_and_candidates.sql',
   'Sample values per column, and a ranked candidate list filtered to the '
   'shape a canonical field needs.');
