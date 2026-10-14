-- 084 Two files, one column name.
--
-- The column picker ranks each candidate by where the matcher put it in
-- its own list of near-misses, and looks that up with a scalar subquery
-- on the column's name. A scalar subquery is allowed exactly one row.
--
-- Once a field could take a column from any file, two files could each
-- contribute a column called "Opportunity ID" — the deals export and the
-- stage history report both have one, which is the whole reason they can
-- be joined. The lookup then matched twice, Postgres refused the query,
-- and the picker would not open at all for that field. The screen said
-- only that the columns could not be loaded.
--
-- Introduced by letting candidates come from other files, and invisible
-- until a client arrived with a second file naming a column the same way.
--
-- The lowest rank wins: a column appearing twice in the matcher's list is
-- the same name scored against two files, and the better score is the one
-- worth showing.

CREATE OR REPLACE FUNCTION public.gea_mapping_candidates(p_engagement uuid, p_canonical_field uuid, p_all boolean DEFAULT false)
 RETURNS TABLE(field_name text, dataset_id uuid, export_ref text, inferred_type text, populated_count integer, populated_rate numeric, distinct_count integer, top_value text, sample_values text[], is_proposed boolean, matcher_rank integer, fits_shape boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
             (select min(ord) from jsonb_array_elements(coalesce(v_alts, '[]'::jsonb))
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
end $function$
;

comment on function gea_mapping_candidates is
  'Columns a person could choose for one field, best first. A column name '
  'appearing in more than one file takes its best rank rather than '
  'breaking the query.';

insert into gea_migration (filename, note) values
  ('084_two_files_one_column_name.sql',
   'The column picker survives the same column name appearing in two '
   'files, which is ordinary once a field can take a column from any of '
   'them.');
