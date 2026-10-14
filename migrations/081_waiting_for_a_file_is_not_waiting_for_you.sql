-- 081 Waiting for a file is not waiting for you.
--
-- Matching a field against every uploaded file was right for the case it
-- was built for: a deals export carrying associated company columns does
-- genuinely serve the companies line.
--
-- It is wrong for every field whose own export has not arrived yet. With
-- only the deals and accounts files loaded, activity_id is matched against
-- a column called Last Activity, because something in a few hundred
-- columns always looks vaguely right. The suggestion is confident, wrong,
-- and lands in the queue of fields needing a person — who rejects it, and
-- then does the same for the next one.
--
-- The work is real and the queue is not. When the activities export
-- arrives the obvious column is usually there and settles itself.
--
-- So a field whose own export has not arrived is waiting for a file, not
-- for a person. The guess is kept, because sometimes it is right and a
-- consultant may want it; it just stops being asked about.

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
       p.populated_count,
       p.populated_rate,
       p.distinct_count,
       p.inferred_type as column_type,
       p.top_value,
       p.sample_values,
       d.row_count,
       -- Has any file arrived for an export this field comes from?
       exists (
         select 1
           from export_request_line erl2
           join export_line el2 on el2.id = erl2.export_line_id
           join artefact a2 on a2.export_request_line_id = erl2.id
                           and a2.purged_at is null
          where erl2.engagement_id = m.engagement_id
            and el2.ref = any (cf.source_export_refs)
       ) as own_export_here,
       -- Has the line been settled some other way, so no file is coming?
       exists (
         select 1
           from export_request_line erl3
           join export_line el3 on el3.id = erl3.export_line_id
          where erl3.engagement_id = m.engagement_id
            and el3.ref = any (cf.source_export_refs)
            and (erl3.status in ('refused', 'absent', 'substituted')
                 or not erl3.included)
       ) as own_export_settled_without_a_file,
       -- Which of this field's exports are still outstanding, so the
       -- screen can say what it is waiting for rather than that it is
       -- waiting.
       coalesce((
         select array_agg(distinct el4.ref order by el4.ref)
           from export_request_line erl4
           join export_line el4 on el4.id = erl4.export_line_id
          where erl4.engagement_id = m.engagement_id
            and el4.ref = any (cf.source_export_refs)
            and erl4.included
            and not exists (select 1 from artefact a4
                             where a4.export_request_line_id = erl4.id
                               and a4.purged_at is null)
       ), array[]::text[]) as waiting_on_exports
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
  'One row per mapping with the column in use and that column''s profile. '
  'own_export_here says whether a file this field could come from has '
  'arrived: where it has not, the field is waiting for a file rather than '
  'for a person, and any cross-file guess is a suggestion rather than a '
  'question.';

insert into gea_migration (filename, note) values
  ('081_waiting_for_a_file_is_not_waiting_for_you.sql',
   'A field whose own export has not arrived is waiting for a file. Its '
   'cross-file guess is kept and stops being asked about.');
