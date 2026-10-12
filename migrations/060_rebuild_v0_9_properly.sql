-- 060 Rebuild v0.8 and v0.9, which were cloned by the wrong function.
--
-- gea_clone_instrument was defined in two places: migration 057, where the
-- real one lives, and verify_014.sql, which holds a throwaway built for
-- activation testing. apply.py installs the verification suites after the
-- migrations, so every run ended with the throwaway overwriting the real one.
--
-- 057 ran with the real clone and v0.7 is complete. 058 and 059 ran on the
-- next pass, by which time the throwaway was in place, and it copies
-- elements and export lines and nothing else. v0.8 and v0.9 have 48 elements
-- and no canonical fields, no evidence requirements, no interview guides and
-- no measurement definitions.
--
-- Nothing was built on them: an engagement on v0.9 would have had no evidence
-- requirements at all, which the verification suite refused to let pass.
--
-- The duplicate definition is removed from verify_014.sql in the same change.
-- A function that does real work does not live in a test file.

-- The real clone, again, because this migration cannot trust the one in the
-- database. apply.py runs the migrations first and installs the verification
-- suites afterwards, so at this moment the function is whatever the last run
-- left behind — which, until verify_014.sql is fixed later in this same run,
-- is the throwaway. Removing the duplicate stops the next run being poisoned;
-- it does nothing for this one.
--
-- A migration that depends on a function another file might have replaced is
-- a migration that works or not depending on what ran yesterday. This one
-- carries what it needs.
create or replace function gea_clone_instrument(p_src uuid, p_label text)
returns uuid language plpgsql as $fn$
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
end $fn$;

-- Immutability protects a version somebody has used. A version with no
-- engagement pinned to it is not a record of anything: it is a mistake, and
-- there has to be a way to take a mistake back.
--
-- The rule stays strict everywhere it matters. The moment an engagement
-- pins a version, every row of it is frozen for good, whatever its status.

create or replace function trg_reference_draft_only() returns trigger
language plpgsql as $fn$
declare
  v_id uuid;
  v_status instrument_status;
  rec jsonb;
begin
  rec := to_jsonb(coalesce(new, old));

  if tg_table_name = 'instrument_version' then
    v_id := (rec ->> 'id')::uuid;
  elsif tg_table_name = 'anchor' then
    select instrument_version_id into v_id from element
     where id = (rec ->> 'element_id')::uuid;
  elsif tg_table_name = 'export_line_element' then
    select instrument_version_id into v_id from export_line
     where id = (rec ->> 'export_line_id')::uuid;
  elsif tg_table_name = 'interview_question' then
    select instrument_version_id into v_id from interview_guide
     where id = (rec ->> 'interview_guide_id')::uuid;
  elsif tg_table_name = 'interview_question_element' then
    select g.instrument_version_id into v_id
      from interview_question q
      join interview_guide g on g.id = q.interview_guide_id
     where q.id = (rec ->> 'interview_question_id')::uuid;
  elsif tg_table_name = 'canonical_field_cap' then
    select instrument_version_id into v_id from canonical_field
     where id = (rec ->> 'canonical_field_id')::uuid;
  else
    v_id := (rec ->> 'instrument_version_id')::uuid;
  end if;

  if v_id is null then
    return coalesce(new, old);
  end if;

  select status into v_status from instrument_version where id = v_id;

  -- A version nobody has used, and that is not the one in force, can still
  -- be taken back: it is a mistake rather than history.
  --
  -- The active version is never editable, whatever is pinned to it.
  -- Activating is the statement that this is the methodology now, and a
  -- methodology that can be edited underneath a running engagement is not
  -- one. Retire it first, which is a decision somebody makes.
  if v_status <> 'active'
     and not exists (select 1 from engagement e
                      where e.instrument_version_id = v_id) then
    return coalesce(new, old);
  end if;

  -- The version row's own lifecycle transitions are the permitted exception.
  if tg_table_name = 'instrument_version' and tg_op = 'UPDATE' then
    if (to_jsonb(old) ->> 'status') = 'draft' then
      return new;
    end if;
    if (to_jsonb(old) ->> 'status') = 'active'
       and (to_jsonb(new) ->> 'status') = 'retired'
       and (to_jsonb(old) ->> 'label') is not distinct from (to_jsonb(new) ->> 'label') then
      return new;
    end if;
  end if;

  if v_status <> 'draft' then
    raise exception
      'instrument version % is % and is immutable: % on % rejected',
      v_id, v_status, tg_op, tg_table_name
      using errcode = 'check_violation';
  end if;

  return coalesce(new, old);
end $fn$;

comment on function trg_reference_draft_only is
  'Reference data is frozen once a version is active, and for good once an '
  'engagement is pinned to it. A version nobody has used can still be taken '
  'back: it is a mistake, not history.';

do $$
declare v_src uuid; v_new uuid; v_msg record;
begin
  -- Only rebuild if they are actually broken. Running this twice must not
  -- destroy a good v0.9.
  if exists (select 1 from instrument_version iv
              where iv.label = 'v0.9'
                and (select count(*) from canonical_field cf
                      where cf.instrument_version_id = iv.id) > 100) then
    raise notice 'v0.9 is already complete; nothing to rebuild';
    return;
  end if;

  if exists (select 1 from engagement e
               join instrument_version iv on iv.id = e.instrument_version_id
              where iv.label in ('v0.8', 'v0.9')) then
    raise exception
      'an engagement is pinned to v0.8 or v0.9, which were built wrong. '
      'Move or delete it before rebuilding'
      using errcode = 'check_violation';
  end if;

  -- Draft first: an active or retired version is immutable, including
  -- against deletion, which is the rule working rather than getting in
  -- the way.
  -- Retire the broken one before removing it. Active is never editable.
  update instrument_version set status = 'retired', retired_at = now()
   where label = 'v0.9' and status = 'active';
  delete from instrument_version where label in ('v0.8', 'v0.9');

  select id into v_src from instrument_version where label = 'v0.7';
  v_new := gea_clone_instrument(v_src, 'v0.9');

  update instrument_version
     set notes = 'Signals come from forms and booked meetings rather than '
                 'record creation; unconverted leads are their own export; '
                 'and expansion can tell a won deal from a lost one.'
   where id = v_new;

  -- From 058: the contact-level route, and a won deal told from a lost one.
  insert into analysis_field_requirement
         (instrument_version_id, analysis_key, canonical_field_id, is_required)
  select v_new, 'signal_to_first_contact', cf.id, v.required
    from (values ('activity_contact_id', true), ('contact_id', true),
                 ('activity_at', true), ('contact_created_at', false),
                 ('activity_direction', false))
         as v(key, required)
    join canonical_field cf on cf.key = v.key and cf.instrument_version_id = v_new
  on conflict (instrument_version_id, analysis_key, canonical_field_id)
    do update set is_required = excluded.is_required;

  insert into analysis_field_requirement
         (instrument_version_id, analysis_key, canonical_field_id, is_required)
  select v_new, 'expansion_vs_new_business', cf.id, true
    from canonical_field cf
   where cf.instrument_version_id = v_new and cf.key = 'opportunity_status'
  on conflict (instrument_version_id, analysis_key, canonical_field_id)
    do update set is_required = true;

  delete from analysis_field_requirement r using canonical_field cf
   where r.instrument_version_id = v_new
     and r.analysis_key = 'signal_to_first_contact'
     and cf.id = r.canonical_field_id
     and cf.key in ('activity_opportunity_id', 'opportunity_id',
                    'first_contact_at');

  update analysis_field_requirement r set is_required = false
    from canonical_field cf
   where r.instrument_version_id = v_new
     and r.analysis_key = 'signal_to_first_contact'
     and cf.id = r.canonical_field_id
     and cf.key in ('form_name', 'form_submission_at',
                    'form_submission_contact_id');

  -- From 059: leads, signals and the cap.
  insert into export_line (instrument_version_id, tier, ref, title,
                           hubspot_guidance, salesforce_guidance, scope_notes)
  values (v_new, 1, 'T1-10', 'Leads not yet converted, every field',
          'Not applicable. HubSpot has one person object, and an '
          'unconverted lead is a contact. Mark this line absent.',
          'Lead. All fields, including IsConverted, ConvertedDate, '
          'ConvertedContactId and ConvertedOpportunityId. Include leads '
          'that were never converted: they are most of them.',
          'The people who arrived and never became contacts. Measuring '
          'response time without them measures only the ones who survived '
          'it.');

  insert into canonical_field (instrument_version_id, key, name, description,
                               expected_type, source_export_refs,
                               is_cap_bearing, priority)
  values
    (v_new, 'lead_id', 'Lead identifier', 'The lead''s own key.',
     'id', array['T1-10'], false, 'core'),
    (v_new, 'lead_created_at', 'When the lead arrived',
     'When the lead record was created. In Salesforce this is when the '
     'person arrived; the contact created date is when they converted, '
     'which is a different and much later thing.',
     'date', array['T1-10'], false, 'core'),
    (v_new, 'lead_status', 'Lead status', 'Where the lead got to.',
     'enum', array['T1-10'], false, 'supporting'),
    (v_new, 'lead_source', 'How the lead arrived',
     'The source recorded on the lead.', 'enum', array['T1-10'], false,
     'supporting'),
    (v_new, 'lead_converted_at', 'When the lead converted',
     'Empty on every lead that never converted, which is the point.',
     'date', array['T1-10'], false, 'core'),
    (v_new, 'lead_converted_contact_id', 'The contact it became',
     'Links a converted lead to the contact it became, so the same person '
     'is not counted twice.', 'id', array['T1-10'], false, 'core');

  insert into analysis_field_requirement
         (instrument_version_id, analysis_key, canonical_field_id, is_required)
  select v_new, 'signal_to_first_contact', cf.id, false
    from canonical_field cf
   where cf.instrument_version_id = v_new
     and cf.key in ('meeting_at', 'lead_id', 'lead_created_at')
  on conflict (instrument_version_id, analysis_key, canonical_field_id)
    do update set is_required = false;

  update canonical_field set is_cap_bearing = true
   where instrument_version_id = v_new and key = 'form_submission_at';

  insert into canonical_field_cap (canonical_field_id, element_id, cap_level,
                                   condition)
  select cf.id, e.id, 2,
         'No form submissions and no booked meetings, so there is no '
         'record of anyone raising a hand and no response time to measure.'
    from canonical_field cf, element e
   where cf.instrument_version_id = v_new and cf.key = 'form_submission_at'
     and e.instrument_version_id = v_new and e.ref in ('4.3', 'H03')
  on conflict do nothing;

  for v_msg in select * from gea_activate_instrument('v0.9') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('060_rebuild_v0_9_properly.sql',
   'v0.8 and v0.9 were cloned by a throwaway function a test file kept '
   'reinstalling. Rebuilt from v0.7 with both sets of changes.');
