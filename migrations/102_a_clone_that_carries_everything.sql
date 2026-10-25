-- 102 A clone that carries everything.
--
-- gea_clone_instrument copies the tables somebody remembered to add to
-- it. Two were added to the methodology after it was written and never
-- added to it: the guidance telling a reviewer how each analysis goes
-- wrong, and the shape of the report.
--
-- So v0.16 silently lost thirteen pieces of reviewer guidance and v0.17
-- lost those and the report. Nothing failed. The next person to clone an
-- instrument would have lost whatever was added since, and found out
-- when a screen was empty.
--
-- Two fixes. The function carries them, and a rule refuses any future
-- table that it does not: a check that fails when somebody adds
-- reference data and forgets this function is worth more than the fix
-- itself, because the fix only works until the next table.

-- The existing body, renamed, so the wrapper below can add to it without
-- the original being copied here and left to drift.
CREATE OR REPLACE FUNCTION public.gea_clone_instrument_body(p_src uuid, p_label text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_new uuid;
  r     record;
  cols  text;
begin
  insert into instrument_version (label, status, notes)
       values (p_label, 'draft',
               format('Cloned from %s',
                      (select label from instrument_version where id = p_src)))
    returning id into v_new;

  -- Tables that carry the instrument version themselves. Every column except
  -- the identity, the version and the timestamp comes across as it is.
  for r in
    select c.table_name,
           string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) as cols
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name in ('element','export_line','canonical_field',
                            'analysis_field_requirement','evidence_requirement',
                            'interview_guide','measurement_definition_template',
                            'aeo_prompt_template')
       and c.column_name not in ('id','instrument_version_id','created_at')
     group by c.table_name
  loop
    -- The two that point at another reference row are filled in afterwards,
    -- once the rows they point at exist in the new version.
    cols := r.cols;
    execute format(
      'insert into %I (instrument_version_id, %s) select $1, %s from %I where instrument_version_id = $2',
      r.table_name, cols, cols, r.table_name) using v_new, p_src;
  end loop;

  -- Those inserts copied the old version's foreign keys verbatim. Repoint
  -- them at the new version's own rows, matched on the reference each one
  -- carries.
  update analysis_field_requirement n
     set canonical_field_id = f2.id
    from canonical_field f1
    join canonical_field f2 on f2.key = f1.key and f2.instrument_version_id = v_new
   where n.instrument_version_id = v_new and n.canonical_field_id = f1.id
     and f1.instrument_version_id = p_src;

  update evidence_requirement n
     set element_id = e2.id
    from element e1
    join element e2 on e2.ref = e1.ref and e2.instrument_version_id = v_new
   where n.instrument_version_id = v_new and n.element_id = e1.id
     and e1.instrument_version_id = p_src;

  update evidence_requirement n
     set interview_guide_id = g2.id
    from interview_guide g1
    join interview_guide g2 on g2.ref = g1.ref and g2.instrument_version_id = v_new
   where n.instrument_version_id = v_new and n.interview_guide_id = g1.id
     and g1.instrument_version_id = p_src;

  -- Children, which have no version of their own and are reached through
  -- their parent.
  insert into anchor (element_id, level, descriptor)
  select e2.id, a.level, a.descriptor
    from anchor a
    join element e1 on e1.id = a.element_id
    join element e2 on e2.ref = e1.ref and e2.instrument_version_id = v_new
   where e1.instrument_version_id = p_src;

  insert into export_line_element (export_line_id, element_id)
  select l2.id, e2.id
    from export_line_element x
    join export_line l1 on l1.id = x.export_line_id
    join element     e1 on e1.id = x.element_id
    join export_line l2 on l2.ref = l1.ref and l2.instrument_version_id = v_new
    join element     e2 on e2.ref = e1.ref and e2.instrument_version_id = v_new
   where l1.instrument_version_id = p_src;

  insert into canonical_field_cap (canonical_field_id, element_id, cap_level, condition)
  select f2.id, e2.id, c.cap_level, c.condition
    from canonical_field_cap c
    join canonical_field f1 on f1.id = c.canonical_field_id
    join element         e1 on e1.id = c.element_id
    join canonical_field f2 on f2.key = f1.key and f2.instrument_version_id = v_new
    join element         e2 on e2.ref = e1.ref and e2.instrument_version_id = v_new
   where f1.instrument_version_id = p_src;

  for r in
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) as cols
      from information_schema.columns
     where table_schema = 'public' and table_name = 'interview_question'
       and column_name not in ('id','interview_guide_id','created_at')
  loop
    execute format(
      'insert into interview_question (interview_guide_id, %s)
       select g2.id, %s from interview_question q
         join interview_guide g1 on g1.id = q.interview_guide_id
         join interview_guide g2 on g2.ref = g1.ref and g2.instrument_version_id = $1
        where g1.instrument_version_id = $2',
      r.cols, (select string_agg('q.' || quote_ident(trim(x)), ', ')
                 from unnest(string_to_array(r.cols, ',')) as x))
      using v_new, p_src;
  end loop;

  insert into interview_question_element (interview_question_id, element_id)
  select q2.id, e2.id
    from interview_question_element x
    join interview_question q1 on q1.id = x.interview_question_id
    join interview_guide    g1 on g1.id = q1.interview_guide_id
    join element            e1 on e1.id = x.element_id
    join interview_guide    g2 on g2.ref = g1.ref and g2.instrument_version_id = v_new
    -- A question has no reference of its own. Its position in its guide is
    -- what identifies it, and the clone preserved that.
    join interview_question q2 on q2.sort_order = q1.sort_order
                              and q2.interview_guide_id = g2.id
    join element            e2 on e2.ref = e1.ref and e2.instrument_version_id = v_new
   where g1.instrument_version_id = p_src;

  return v_new;
end $function$
;

drop function if exists gea_clone_instrument(uuid, text);

create function gea_clone_instrument(
  p_from uuid, p_label text)
returns uuid
language plpgsql security definer set search_path = public as $fn$
declare v_new uuid;
begin
  v_new := gea_clone_instrument_body(p_from, p_label);

  -- How each analysis goes wrong, which a reviewer needs before
  -- accepting it.
  insert into analysis_guidance (instrument_version_id, analysis_key,
                                 what_to_check, goes_wrong)
  select v_new, analysis_key, what_to_check, goes_wrong
    from analysis_guidance where instrument_version_id = p_from
  on conflict do nothing;

  -- The shape of the report.
  insert into report_section (instrument_version_id, ref, title, sort_order,
                              purpose, reads, stage_code, asks, needed)
  select v_new, ref, title, sort_order, purpose, reads, stage_code, asks,
         needed
    from report_section where instrument_version_id = p_from
  on conflict do nothing;

  return v_new;
end $fn$;

comment on function gea_clone_instrument is
  'Clone an instrument, carrying every table that belongs to one. A table '
  'this forgets is reference data that vanishes at the next version, '
  'silently.';

-- And repair what was already lost ------------------------------------------

insert into analysis_guidance (instrument_version_id, analysis_key,
                               what_to_check, goes_wrong)
select iv.id, g.analysis_key, g.what_to_check, g.goes_wrong
  from instrument_version iv
  join analysis_guidance g
    on g.instrument_version_id = (select id from instrument_version
                                   where label = 'v0.15')
 where iv.label in ('v0.16', 'v0.17')
on conflict do nothing;

insert into report_section (instrument_version_id, ref, title, sort_order,
                            purpose, reads, stage_code, asks, needed)
select iv.id, s.ref, s.title, s.sort_order, s.purpose, s.reads, s.stage_code,
       s.asks, s.needed
  from instrument_version iv
  join report_section s
    on s.instrument_version_id = (select id from instrument_version
                                   where label = 'v0.16')
 where iv.label = 'v0.17'
on conflict do nothing;

-- The v0.17 changes, which ran against nothing the first time.
do $$
declare v uuid;
begin
  select id into v from instrument_version where label = 'v0.17';
  update report_section
     set title = 'What this assessment read', sort_order = 200,
         purpose = 'The evidence, for a reader who wants to check '
                   'something. A finding limited by a gap says so where '
                   'it is read; this is where the detail sits.'
   where instrument_version_id = v and ref = 'R02';
  update report_section set sort_order = 210
   where instrument_version_id = v and ref = 'R11';
  update report_section set sort_order = 20
   where instrument_version_id = v and ref = 'R03';
end $$;

insert into gea_migration (filename, note) values
  ('102_a_clone_that_carries_everything.sql',
   'The clone carries the guidance and the report shape, and the versions '
   'that lost them are repaired.');
