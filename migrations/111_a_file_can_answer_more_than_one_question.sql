-- 111 A file can answer more than one question.
--
-- A client's export rarely maps one-to-one onto the questions an
-- assessment asks. One opportunity history report holds the stage
-- transitions T2-01 wants and the forecast category changes T3-08 wants.
-- A general ledger holds marketing spend and the cost of the stack.
--
-- The methodology already knows this: thirteen canonical fields name two
-- export lines they might be found in. The storage did not. A file had
-- one line, so placing it against a second silently took it off the
-- first, and a consultant who placed the history report against T3-08
-- after placing it against T2-01 lost the first placement with no
-- warning and no way to see it had happened.
--
-- So a file can answer several lines. Placing is adding, not moving;
-- taking it off one line leaves the others alone. The column on artefact
-- stays and goes on meaning the first line it answered, because a great
-- deal reads it and because most files really do answer one question.
-- It is now derived from the new table rather than being the truth
-- itself.

create table artefact_answers (
  artefact_id            uuid not null references artefact(id) on delete cascade,
  export_request_line_id uuid not null references export_request_line(id)
                         on delete cascade,
  placed_at              timestamptz not null default now(),
  placed_by              uuid references app_user(id),
  primary key (artefact_id, export_request_line_id)
);

comment on table artefact_answers is
  'Which export lines a file answers. A client''s export is written for '
  'their systems, not for our questions, and one file often answers '
  'several of them.';

create index artefact_answers_by_line on artefact_answers (export_request_line_id);

alter table artefact_answers enable row level security;
create policy artefact_answers_member on artefact_answers for all to authenticated
  using (exists (select 1 from artefact a where a.id = artefact_id
                   and app_is_member(a.engagement_id)))
  with check (exists (select 1 from artefact a where a.id = artefact_id
                        and app_is_member(a.engagement_id)));

-- What is already placed, carried across.
insert into artefact_answers (artefact_id, export_request_line_id, placed_at)
select a.id, a.export_request_line_id, coalesce(a.created_at, now())
  from artefact a
 where a.export_request_line_id is not null and a.purged_at is null
on conflict do nothing;

-- The column on artefact becomes a reflection of the table ------------------
--
-- Kept because views, functions and the service all read it, and
-- because a file answering one line is still the common case. It names
-- the first line the file was placed against, so nothing that reads it
-- sees a file become unplaced when a second line is added.

create or replace function trg_artefact_first_answer() returns trigger
language plpgsql as $fn$
begin
  update artefact a
     set export_request_line_id = (
           select aa.export_request_line_id from artefact_answers aa
            where aa.artefact_id = a.id
            order by aa.placed_at, aa.export_request_line_id limit 1)
   where a.id = coalesce(new.artefact_id, old.artefact_id);
  return null;
end $fn$;

create trigger artefact_first_answer
  after insert or delete on artefact_answers
  for each row execute function trg_artefact_first_answer();

create or replace view files_and_what_they_answer
with (security_invoker = true) as
select a.engagement_id, a.id as artefact_id, a.original_filename,
       coalesce(array_agg(el.ref order by el.ref)
                filter (where el.ref is not null), array[]::text[]) as answers,
       count(el.ref) as lines_answered
  from artefact a
  left join artefact_answers aa on aa.artefact_id = a.id
  left join export_request_line erl on erl.id = aa.export_request_line_id
  left join export_line el on el.id = erl.export_line_id
 where a.purged_at is null
 group by a.engagement_id, a.id, a.original_filename;

comment on view files_and_what_they_answer is
  'Every file and the export lines it answers. A file answering none is '
  'in the pile waiting for somebody to say what it is.';

-- Placing adds; it no longer moves -----------------------------------------

drop function if exists gea_assign_file(uuid, text);

create function gea_assign_file(
  p_artefact uuid, p_export_ref text, p_instead_of text default null)
returns table (added text, removed text, answers text[],
               mappings_reopened integer, mapping_run_queued boolean)
language plpgsql security definer set search_path = public as $fn$
declare
  v_eng uuid; v_me uuid; v_now uuid; v_was uuid; n integer := 0;
  v_parsed boolean; v_queued boolean := false;
begin
  select engagement_id into v_eng from artefact
   where id = p_artefact and purged_at is null;
  if v_eng is null then
    raise exception 'that file is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  select erl.id into v_now
    from export_request_line erl
    join export_line el on el.id = erl.export_line_id
   where erl.engagement_id = v_eng and el.ref = p_export_ref;
  if v_now is null then
    raise exception 'there is no export line called % on this engagement',
      p_export_ref using errcode = 'check_violation';
  end if;

  -- Correcting a mistake is explicit. Adding a second line is the
  -- ordinary case and must not quietly undo the first, which is how a
  -- consultant lost a stage history placement by also recording it
  -- against forecasts.
  if p_instead_of is not null then
    select erl.id into v_was
      from export_request_line erl
      join export_line el on el.id = erl.export_line_id
     where erl.engagement_id = v_eng and el.ref = p_instead_of;
    if v_was is null then
      raise exception 'there is no export line called % to replace',
        p_instead_of using errcode = 'check_violation';
    end if;

    -- A column chosen from this file was chosen believing it answered
    -- that line. Only the mappings made against the line being left.
    update field_mapping m
       set status = 'proposed', confirmed_field_name = null,
           confirmed_at = null, confirmed_by = null
      from dataset d
     where d.id = m.dataset_id and d.artefact_id = p_artefact
       and m.status in ('confirmed', 'corrected', 'auto_accepted');
    get diagnostics n = row_count;

    delete from artefact_answers
     where artefact_id = p_artefact and export_request_line_id = v_was;
    removed := p_instead_of;
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  insert into artefact_answers (artefact_id, export_request_line_id, placed_by)
       values (p_artefact, v_now, v_me)
  on conflict do nothing;

  update artefact_identification
     set decided_at = now(), decided_by = v_me, decided_ref = p_export_ref
   where artefact_id = p_artefact;

  update export_request_line
     set status = 'received', received_at = coalesce(received_at, now())
   where id = v_now;

  -- A line nothing answers any more goes back on the list.
  if v_was is not null and not exists (
       select 1 from artefact_answers aa
         join artefact a2 on a2.id = aa.artefact_id and a2.purged_at is null
        where aa.export_request_line_id = v_was) then
    update export_request_line set status = 'requested', received_at = null
     where id = v_was;
  end if;

  perform gea_recompute_tasks(v_eng);

  select exists (select 1 from dataset d
                  where d.artefact_id = p_artefact and d.parse_status = 'parsed')
    into v_parsed;
  if v_parsed then
    select e.was_created into v_queued
      from gea_enqueue_mapping_proposals(v_eng) e;
  end if;

  added := p_export_ref;
  select coalesce(array_agg(el.ref order by el.ref), array[]::text[])
    into answers
    from artefact_answers aa
    join export_request_line erl on erl.id = aa.export_request_line_id
    join export_line el on el.id = erl.export_line_id
   where aa.artefact_id = p_artefact;
  mappings_reopened := n;
  mapping_run_queued := coalesce(v_queued, false);
  return next;
end $fn$;

comment on function gea_assign_file is
  'Say a file answers an export line. Adding a second line leaves the '
  'first alone, because a client''s export often answers several of our '
  'questions. Pass p_instead_of to correct a placement rather than add '
  'to it, which reopens the columns chosen from the file.';

drop function if exists gea_unplace_file(uuid);

create function gea_unplace_file(
  p_artefact uuid, p_export_ref text default null)
returns table (removed text[], still_answers text[],
               mappings_reopened integer)
language plpgsql security definer set search_path = public as $fn$
declare v_eng uuid; v_me uuid; n integer; v_lines uuid[];
begin
  select engagement_id into v_eng from artefact
   where id = p_artefact and purged_at is null;
  if v_eng is null then
    raise exception 'that file is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  -- One line, or all of them where none is named.
  select coalesce(array_agg(aa.export_request_line_id), array[]::uuid[]),
         coalesce(array_agg(el.ref), array[]::text[])
    into v_lines, removed
    from artefact_answers aa
    join export_request_line erl on erl.id = aa.export_request_line_id
    join export_line el on el.id = erl.export_line_id
   where aa.artefact_id = p_artefact
     and (p_export_ref is null or el.ref = p_export_ref);

  if array_length(v_lines, 1) is null then
    removed := array[]::text[]; mappings_reopened := 0;
    still_answers := array[]::text[]; return next; return;
  end if;

  update field_mapping m
     set status = 'proposed', confirmed_field_name = null,
         confirmed_at = null, confirmed_by = null
    from dataset d
   where d.id = m.dataset_id and d.artefact_id = p_artefact
     and m.status in ('confirmed', 'corrected', 'auto_accepted');
  get diagnostics n = row_count;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  delete from artefact_answers
   where artefact_id = p_artefact
     and export_request_line_id = any (v_lines);

  select coalesce(array_agg(el.ref order by el.ref), array[]::text[])
    into still_answers
    from artefact_answers aa
    join export_request_line erl on erl.id = aa.export_request_line_id
    join export_line el on el.id = erl.export_line_id
   where aa.artefact_id = p_artefact;

  -- What the system thought it was is kept where the file is now in the
  -- pile again: disagreeing with where it went is not disagreeing with
  -- that.
  if array_length(still_answers, 1) is null then
    update artefact_identification
       set decided_at = null, decided_by = null, decided_ref = null
     where artefact_id = p_artefact;
  end if;

  update export_request_line erl
     set status = 'requested', received_at = null
   where erl.id = any (v_lines)
     and not exists (select 1 from artefact_answers aa
                       join artefact a2 on a2.id = aa.artefact_id
                                       and a2.purged_at is null
                      where aa.export_request_line_id = erl.id);

  perform gea_recompute_tasks(v_eng);
  mappings_reopened := n;
  return next;
end $fn$;

comment on function gea_unplace_file is
  'Take a file off one export line, or off all of them where none is '
  'named. The columns chosen from it reopen; the lines it still answers '
  'are returned.';

-- Everything that joins a file to its line now joins through the table ------

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
      join artefact_answers aa on aa.artefact_id = a.id
      join export_request_line erl on erl.id = aa.export_request_line_id
      join export_line el on el.id = erl.export_line_id
     where a.engagement_id = p_engagement
       and a.purged_at is null
       and d.parse_status = 'parsed'
       -- Only the exports this field comes from, and now any file that
       -- answers one of them rather than the single line a file used to
       -- be pinned to. A loss reason lives in the deals file and is
       -- never offered from a contact export, however well a column
       -- there happens to be named — unless the contact export also
       -- answers the deals line, in which case it genuinely might.
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
drop view if exists export_line_coverage cascade;
create view export_line_coverage
with (security_invoker = true) as
 WITH wanted AS (
         SELECT e.id AS engagement_id,
            el.ref,
            el.title,
            el.question,
            el.found_in,
            el.minutes,
            el.importance,
            el.tier,
            cf.id AS field_id,
            cf.key,
            cf.priority,
            cf.is_cap_bearing
           FROM engagement e
             JOIN export_line el ON el.instrument_version_id = e.instrument_version_id
             JOIN canonical_field cf ON cf.instrument_version_id = e.instrument_version_id AND (el.ref = ANY (cf.source_export_refs))
        ), got AS (
         SELECT w_1.engagement_id,
            w_1.ref,
            w_1.field_id,
            w_1.key,
            w_1.is_cap_bearing,
            m.status,
            a.original_filename,
            el2.ref AS came_from
           FROM wanted w_1
             LEFT JOIN field_mapping m ON m.engagement_id = w_1.engagement_id AND m.canonical_field_id = w_1.field_id AND (m.status = ANY (ARRAY['confirmed'::mapping_status, 'corrected'::mapping_status, 'auto_accepted'::mapping_status]))
             LEFT JOIN dataset d ON d.id = m.dataset_id
             LEFT JOIN artefact a ON a.id = d.artefact_id AND a.purged_at IS NULL
             LEFT JOIN artefact_answers aa_erl ON aa_erl.artefact_id = a.id
     JOIN export_request_line erl ON erl.id = aa_erl.export_request_line_id
             LEFT JOIN export_line el2 ON el2.id = erl.export_line_id
        )
 SELECT g.engagement_id,
    w.ref,
    w.question,
    w.title,
    w.found_in,
    w.minutes,
    w.importance,
    w.tier,
    count(*) AS fields_wanted,
    count(*) FILTER (WHERE g.status IS NOT NULL) AS fields_mapped,
    round(100.0 * count(*) FILTER (WHERE g.status IS NOT NULL)::numeric / NULLIF(count(*), 0)::numeric) AS percent_covered,
    count(*) FILTER (WHERE g.status IS NULL AND g.is_cap_bearing) AS cap_bearing_missing,
    COALESCE(array_agg(DISTINCT g.original_filename) FILTER (WHERE g.original_filename IS NOT NULL), ARRAY[]::text[]) AS covered_by_files,
    COALESCE(array_agg(DISTINCT g.came_from) FILTER (WHERE g.came_from IS NOT NULL AND g.came_from <> w.ref), ARRAY[]::text[]) AS covered_by_other_lines,
    COALESCE(array_agg(g.key ORDER BY g.key) FILTER (WHERE g.status IS NULL), ARRAY[]::text[]) AS fields_still_missing
   FROM got g
     JOIN wanted w ON w.engagement_id = g.engagement_id AND w.ref = g.ref AND w.field_id = g.field_id
  GROUP BY g.engagement_id, w.ref, w.question, w.title, w.found_in, w.minutes, w.importance, w.tier;

comment on view export_line_coverage is
  'How much of each export line is actually mapped, and from which files. Replaces "has a file arrived": one file can serve several lines and several files can serve one, and a line half answered should not look like a line answered.';

drop view if exists field_mapping_board cascade;
create view field_mapping_board
with (security_invoker = true) as
 SELECT m.id AS mapping_id,
    m.engagement_id,
    cf.key AS field_key,
    cf.name AS field_name,
    cf.description AS field_description,
    cf.expected_type,
    cf.priority,
    cf.is_cap_bearing,
    cf.source_export_refs,
    m.status::text AS status,
    COALESCE(m.confirmed_field_name, m.proposed_field_name) AS column_name,
    m.confirmed_field_name,
    m.proposed_field_name,
    m.confidence::text AS confidence,
    m.evidence_note,
    m.candidate_alternatives,
    m.confirmed_at,
    u.display_name AS confirmed_by_name,
    a.original_filename AS file_name,
    el.ref AS export_ref,
    el.title AS export_title,
    p.populated_count,
    p.populated_rate,
    p.distinct_count,
    p.inferred_type AS column_type,
    p.top_value,
    p.sample_values,
    d.row_count,
    (EXISTS ( SELECT 1
           FROM export_request_line erl2
             JOIN export_line el2 ON el2.id = erl2.export_line_id
             JOIN artefact a2 ON a2.export_request_line_id = erl2.id AND a2.purged_at IS NULL
          WHERE erl2.engagement_id = m.engagement_id AND (el2.ref = ANY (cf.source_export_refs)))) AS own_export_here,
    (EXISTS ( SELECT 1
           FROM export_request_line erl3
             JOIN export_line el3 ON el3.id = erl3.export_line_id
          WHERE erl3.engagement_id = m.engagement_id AND (el3.ref = ANY (cf.source_export_refs)) AND ((erl3.status = ANY (ARRAY['refused'::export_req_status, 'absent'::export_req_status, 'substituted'::export_req_status])) OR NOT erl3.included))) AS own_export_settled_without_a_file,
    COALESCE(( SELECT array_agg(DISTINCT el4.ref ORDER BY el4.ref) AS array_agg
           FROM export_request_line erl4
             JOIN export_line el4 ON el4.id = erl4.export_line_id
          WHERE erl4.engagement_id = m.engagement_id AND (el4.ref = ANY (cf.source_export_refs)) AND erl4.included AND NOT (EXISTS ( SELECT 1
                   FROM artefact a4
                  WHERE a4.export_request_line_id = erl4.id AND a4.purged_at IS NULL))), ARRAY[]::text[]) AS waiting_on_exports
   FROM field_mapping m
     JOIN canonical_field cf ON cf.id = m.canonical_field_id
     LEFT JOIN app_user u ON u.id = m.confirmed_by
     LEFT JOIN dataset d ON d.id = m.dataset_id
     LEFT JOIN artefact a ON a.id = d.artefact_id AND a.purged_at IS NULL
     LEFT JOIN artefact_answers aa_erl ON aa_erl.artefact_id = a.id
     JOIN export_request_line erl ON erl.id = aa_erl.export_request_line_id
     LEFT JOIN export_line el ON el.id = erl.export_line_id
     LEFT JOIN dataset_field_profile p ON p.dataset_id = m.dataset_id AND p.field_name = COALESCE(m.confirmed_field_name, m.proposed_field_name);

comment on view field_mapping_board is
  'One row per mapping with the column in use and that column''s profile. own_export_here says whether a file this field could come from has arrived: where it has not, the field is waiting for a file rather than for a person, and any cross-file guess is a suggestion rather than a question.';

drop view if exists dropped_files cascade;
create view dropped_files
with (security_invoker = true) as
 SELECT a.engagement_id,
    a.id AS artefact_id,
    a.original_filename,
    a.byte_size,
    a.created_at,
    u.display_name AS uploaded_by_name,
    el.ref AS assigned_to,
    el.question AS assigned_question,
    i.proposed_ref,
    i.confidence,
    i.reason,
    i.also_serves,
    i.is_part_of,
    i.decided_at,
    i.decided_ref,
    pel.question AS proposed_question,
    d.id AS dataset_id,
    d.row_count,
    d.column_count,
    d.parse_status::text AS parse_status,
    r.status::text AS read_status,
    r.error AS read_error
   FROM artefact a
     LEFT JOIN app_user u ON u.id = a.uploaded_by
     LEFT JOIN artefact_answers aa_erl ON aa_erl.artefact_id = a.id
     JOIN export_request_line erl ON erl.id = aa_erl.export_request_line_id
     LEFT JOIN export_line el ON el.id = erl.export_line_id
     LEFT JOIN artefact_identification i ON i.artefact_id = a.id
     LEFT JOIN engagement e ON e.id = a.engagement_id
     LEFT JOIN export_line pel ON pel.ref = i.proposed_ref AND pel.instrument_version_id = e.instrument_version_id
     LEFT JOIN dataset d ON d.artefact_id = a.id
     LEFT JOIN LATERAL ( SELECT ar.status,
            ar.error
           FROM analysis_run ar
          WHERE ar.job_type = 'parse'::text AND (a.id = ANY (ar.input_artefact_ids))
          ORDER BY ar.created_at DESC
         LIMIT 1) r ON true
  WHERE a.purged_at IS NULL AND a.kind = 'raw_export'::artefact_kind;

comment on view dropped_files is
  'Every client file on an engagement: what it was taken for, what the system thinks it is, and how far reading it has got.';

drop view if exists segmentation_candidates cascade;
create view segmentation_candidates
with (security_invoker = true) as
 SELECT a.engagement_id,
    d.id AS dataset_id,
    a.original_filename,
    el.ref AS export_ref,
    p.field_name,
    p.distinct_count,
    p.populated_rate,
    p.top_value,
    p.sample_values,
    p.distinct_count >= 2 AND p.distinct_count <= 12 AND p.populated_rate >= 0.6 AS worth_splitting_by
   FROM dataset_field_profile p
     JOIN dataset d ON d.id = p.dataset_id
     JOIN artefact a ON a.id = d.artefact_id AND a.purged_at IS NULL
     LEFT JOIN artefact_answers aa_erl ON aa_erl.artefact_id = a.id
     JOIN export_request_line erl ON erl.id = aa_erl.export_request_line_id
     LEFT JOIN export_line el ON el.id = erl.export_line_id
  WHERE p.distinct_count >= 2 AND p.distinct_count <= 40 AND p.populated_rate >= 0.2 AND COALESCE(p.is_free_text, false) IS FALSE;

comment on view segmentation_candidates is
  'Columns a client''s business could be split by: few enough values to read, populated on enough rows to mean something.';

insert into gea_migration (filename, note) values
  ('111_a_file_can_answer_more_than_one_question.sql',
   'A client export often answers several of our questions. Placing a '
   'file against a second line no longer takes it off the first.')
on conflict do nothing;
