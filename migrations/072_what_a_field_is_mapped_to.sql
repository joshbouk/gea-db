-- 072 What a field is mapped to.
--
-- A mapping has two column names. proposed_field_name is what the matcher
-- suggested; confirmed_field_name is what a person agreed to, or what was
-- auto-accepted on an exact match. A settled mapping has the second and
-- usually not the first.
--
-- The screen was reading the proposal, so nine auto-accepted mappings
-- showed an empty column: the engagement knew perfectly well that
-- opportunity_id came from Record ID and had no way to say so.
--
-- There was no view, so the application was assembling this join itself
-- and assembling it wrong. Every other surface in this system reads from a
-- view for exactly this reason.

create or replace view field_mapping_board
with (security_invoker = true) as
select m.id as mapping_id,
       m.engagement_id,
       cf.key as field_key,
       cf.name as field_name,
       cf.description as field_description,
       cf.expected_type::text,
       cf.priority,
       cf.is_cap_bearing,
       cf.source_export_refs,
       m.status::text,
       -- What the column actually is. A settled mapping carries the
       -- confirmed name; one still waiting carries the proposal.
       coalesce(m.confirmed_field_name, m.proposed_field_name) as column_name,
       m.confirmed_field_name,
       m.proposed_field_name,
       m.confidence::text,
       m.evidence_note,
       m.candidate_alternatives,
       m.confirmed_at,
       u.display_name as confirmed_by_name,
       a.original_filename as file_name,
       el.ref as export_ref,
       el.title as export_title,
       -- The profile of the column in use, so the screen can show how much
       -- of it is populated without working out which column that is.
       p.populated_count,
       p.populated_rate,
       p.distinct_count,
       p.inferred_type as column_type,
       p.top_value,
       p.sample_values,
       d.row_count
  from field_mapping m
  join canonical_field cf on cf.id = m.canonical_field_id
  left join app_user u on u.id = m.confirmed_by
  left join dataset d on d.id = m.dataset_id
  left join artefact a on a.id = d.artefact_id and a.purged_at is null
  left join export_request_line erl on erl.id = a.export_request_line_id
  left join export_line el on el.id = erl.export_line_id
  left join dataset_field_profile p
         on p.dataset_id = m.dataset_id
        and p.field_name = coalesce(m.confirmed_field_name,
                                    m.proposed_field_name);

comment on view field_mapping_board is
  'One row per mapping with the column actually in use and that column''s '
  'profile. A settled mapping carries a confirmed name and no proposal, '
  'which is why reading the proposal showed nothing.';

insert into gea_migration (filename, note) values
  ('072_what_a_field_is_mapped_to.sql',
   'A view giving the column a field is mapped to, settled or proposed, '
   'with that column''s profile.');
