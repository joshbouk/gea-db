-- 080 Covered, not arrived.
--
-- An export line was settled when a file arrived against it. That is the
-- wrong question, and it causes three separate problems.
--
--   A deals export carrying associated company columns cannot serve the
--   companies line at all. A file is uploaded against one line and its
--   columns are only ever matched against that line's fields, so those
--   columns are invisible to account_id for ever.
--
--   A line half answered looks the same as a line fully answered. Four of
--   twelve company fields mapped from the deals export reads as received,
--   and the eight that are missing are not named anywhere.
--
--   Dropping several files in at once has no progress to show. "Which
--   lines have a file" is meaningless when one file serves three lines and
--   three files serve one.
--
-- So the question becomes how much of a line is mapped, and from which
-- file. A number that moves as work is done rather than a tick that
-- appears when a file lands.

create or replace view export_line_coverage
with (security_invoker = true) as
with wanted as (
  select e.id as engagement_id, el.ref, el.title, el.question, el.found_in,
         el.minutes, el.importance, el.tier, cf.id as field_id, cf.key,
         cf.priority, cf.is_cap_bearing
    from engagement e
    join export_line el on el.instrument_version_id = e.instrument_version_id
    join canonical_field cf on cf.instrument_version_id = e.instrument_version_id
                           and el.ref = any (cf.source_export_refs)
),
got as (
  select w.engagement_id, w.ref, w.field_id, w.key, w.is_cap_bearing,
         m.status, a.original_filename, el2.ref as came_from
    from wanted w
    left join field_mapping m on m.engagement_id = w.engagement_id
                             and m.canonical_field_id = w.field_id
                             and m.status in ('confirmed', 'corrected',
                                              'auto_accepted')
    left join dataset d on d.id = m.dataset_id
    left join artefact a on a.id = d.artefact_id and a.purged_at is null
    left join export_request_line erl on erl.id = a.export_request_line_id
    left join export_line el2 on el2.id = erl.export_line_id
)
select g.engagement_id, w.ref, w.question, w.title, w.found_in, w.minutes,
       w.importance, w.tier,
       count(*) as fields_wanted,
       count(*) filter (where g.status is not null) as fields_mapped,
       round(100.0 * count(*) filter (where g.status is not null)
             / nullif(count(*), 0)) as percent_covered,
       count(*) filter (where g.status is null and g.is_cap_bearing)
         as cap_bearing_missing,
       -- Which files these fields actually came from. A line can be served
       -- by a file uploaded for something else, and saying so is the point.
       coalesce(array_agg(distinct g.original_filename)
                filter (where g.original_filename is not null),
                array[]::text[]) as covered_by_files,
       coalesce(array_agg(distinct g.came_from)
                filter (where g.came_from is not null and g.came_from <> w.ref),
                array[]::text[]) as covered_by_other_lines,
       -- And what is still missing, by name, because "8 fields short" sends
       -- somebody to look for which eight.
       coalesce(array_agg(g.key order by g.key)
                filter (where g.status is null), array[]::text[])
         as fields_still_missing
  from got g
  join wanted w on w.engagement_id = g.engagement_id and w.ref = g.ref
                and w.field_id = g.field_id
 group by g.engagement_id, w.ref, w.question, w.title, w.found_in, w.minutes,
          w.importance, w.tier;

comment on view export_line_coverage is
  'How much of each export line is actually mapped, and from which files. '
  'Replaces "has a file arrived": one file can serve several lines and '
  'several files can serve one, and a line half answered should not look '
  'like a line answered.';

insert into gea_migration (filename, note) values
  ('080_coverage_not_arrival.sql',
   'An export line is measured by how many of its fields are mapped and '
   'from where, not by whether a file arrived against it.');
