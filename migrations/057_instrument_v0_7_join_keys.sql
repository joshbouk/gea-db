-- 057 v0.7: the analyses can reach their own data.
--
-- Every one of the thirteen analyses reads more than one export, and not one
-- required the identifiers needed to join them. icp_reconciliation asks for a
-- deal's account pointer and the company's industry, and never asked for the
-- company's own key, so there was no way to put the two together. The
-- capability table reported "supported" for analyses that could not have run.
--
-- The requirements were written as "what this analysis reads". A join key is
-- not read; it is what makes reading possible.
--
-- Two repairs first.
--
--   gea_clone_instrument lived in verify_014.sql, a test file apply.py loads
--   after the migrations, and its own note called it "a throwaway clone for
--   activation testing". It copied four of the twelve reference tables.
--
--   It is rewritten here to read the columns from the catalogue rather than
--   listing them. A clone that names its columns is a clone that silently
--   stops copying one the day somebody adds it, and the damage would not
--   appear until a methodology change months later.
--
--   gea_activate_instrument left the previous version active. Two active
--   instruments is a state nothing else expects.

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

comment on function gea_clone_instrument is
  'Copy every piece of reference data into a new draft, reading the columns '
  'from the catalogue so a new column is never silently left behind. How a '
  'methodology change is made, because an active version is immutable.';

-- Activation retires what it replaces -----------------------------------------

create or replace function gea_activate_instrument(p_label text)
returns table (result text, detail text)
language plpgsql as $fn$
declare v_id uuid; v_status instrument_status; n integer;
begin
  select id, status into v_id, v_status
    from instrument_version where label = p_label;

  if v_id is null then
    result := 'refused'; detail := 'no instrument version labelled ' || p_label;
    return next; return;
  end if;

  if v_status <> 'draft' then
    result := 'refused';
    detail := p_label || ' is already ' || v_status::text;
    return next; return;
  end if;

  select count(*) into n from gea_activation_failures(v_id);
  if n > 0 then
    for result, detail in
      select 'blocked', check_ref || ': ' || detail
        from gea_activation_failures(v_id)
    loop return next; end loop;
    return;
  end if;

  -- One active instrument at a time. Leaving the previous one active left
  -- the system with two, and a new engagement would have picked whichever
  -- the query returned first.
  update instrument_version
     set status = 'retired', retired_at = now()
   where status = 'active' and id <> v_id;

  update instrument_version
     set status = 'active', activated_at = now()
   where id = v_id;

  result := 'activated';
  detail := p_label || ' is active and immutable as of ' || now()::text;
  return next;
  return;
end $fn$;

comment on function gea_activate_instrument is
  'Activate a draft instrument version and retire the one it replaces. One '
  'active version at a time.';

-- v0.7 -------------------------------------------------------------------------

do $$
declare v_old uuid; v_new uuid; n integer; v_msg record;
begin
  if exists (select 1 from instrument_version where label = 'v0.7') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.6';
  v_new := gea_clone_instrument(v_old, 'v0.7');

  update instrument_version
     set notes = 'Adds the identifiers every analysis needs to join the '
                 'exports it reads. v0.6 reported analyses supported that '
                 'could not have run.'
   where id = v_new;

  -- A join key is as required as the export it unlocks. Where an export only
  -- supplies optional fields, its key is optional too: the analysis runs on
  -- less rather than not at all.
  with wanted (analysis_key, field_key) as (values
    ('buying_group_composition', 'contact_id'),
    ('cost_per_qualified_opportunity', 'account_id'),
    ('cost_per_qualified_opportunity', 'opportunity_account_id'),
    ('cost_per_qualified_opportunity', 'stage_history_opportunity_id'),
    ('discovery_consistency_classification', 'opportunity_id'),
    ('expansion_vs_new_business', 'account_id'),
    ('expansion_vs_new_business', 'line_item_opportunity_id'),
    ('expansion_vs_new_business', 'opportunity_account_id'),
    ('expansion_vs_new_business', 'opportunity_id'),
    ('expansion_vs_new_business', 'subscription_id'),
    ('forecast_accuracy', 'opportunity_id'),
    ('handover_completeness_census', 'account_id'),
    ('handover_completeness_census', 'activity_id'),
    ('handover_completeness_census', 'contact_role_opportunity_id'),
    ('handover_completeness_census', 'note_id'),
    ('handover_completeness_census', 'note_opportunity_id'),
    ('handover_completeness_census', 'opportunity_account_id'),
    ('handover_completeness_census', 'subscription_account_id'),
    ('handover_completeness_census', 'subscription_id'),
    ('icp_reconciliation', 'account_id'),
    ('icp_reconciliation', 'line_item_opportunity_id'),
    ('icp_reconciliation', 'opportunity_id'),
    ('note_sufficiency', 'activity_id'),
    ('note_sufficiency', 'activity_opportunity_id'),
    ('note_sufficiency', 'opportunity_id'),
    ('price_discount_dispersion', 'account_id'),
    ('price_discount_dispersion', 'line_item_opportunity_id'),
    ('price_discount_dispersion', 'opportunity_account_id'),
    ('renewal_timing_and_reason', 'health_score_account_id'),
    ('signal_to_first_contact', 'activity_id'),
    ('signal_to_first_contact', 'activity_opportunity_id'),
    ('signal_to_first_contact', 'opportunity_id'),
    ('stage_conversion_and_duration', 'account_id'),
    ('stage_conversion_and_duration', 'opportunity_account_id'),
    ('win_loss_and_churn_patterns', 'account_id'),
    ('win_loss_and_churn_patterns', 'opportunity_account_id'),
    ('win_loss_and_churn_patterns', 'subscription_account_id'),
    ('win_loss_and_churn_patterns', 'subscription_id')
  ), resolved as (
    select w.analysis_key, cf.id as field_id,
           coalesce(bool_or(r.is_required), true) as is_required
      from wanted w
      join canonical_field cf on cf.key = w.field_key
                             and cf.instrument_version_id = v_new
      left join canonical_field other
             on other.instrument_version_id = v_new
            and other.source_export_refs && cf.source_export_refs
            and other.id <> cf.id
      left join analysis_field_requirement r
             on r.canonical_field_id = other.id
            and r.analysis_key = w.analysis_key
            and r.instrument_version_id = v_new
     group by w.analysis_key, cf.id
  )
  insert into analysis_field_requirement
         (instrument_version_id, analysis_key, canonical_field_id, is_required)
  select v_new, analysis_key, field_id, is_required from resolved
  on conflict (instrument_version_id, analysis_key, canonical_field_id) do nothing;
  get diagnostics n = row_count;
  raise notice 'v0.7: % join requirements added', n;

  for v_msg in select * from gea_activate_instrument('v0.7') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('057_instrument_v0_7_join_keys.sql',
   'A clone that copies every reference table, activation that retires what '
   'it replaces, and v0.7: every analysis requires the identifiers it needs '
   'to join the exports it reads.');
