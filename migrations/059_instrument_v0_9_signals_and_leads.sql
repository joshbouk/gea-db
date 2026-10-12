-- 059 v0.9: measuring interest rather than existence.
--
-- Three things, all from the same realisation: a person being in the CRM
-- says nothing about whether they ever did anything.
--
-- Bought lists, ZoomInfo imports and scraped contacts sit in both HubSpot
-- and Salesforce alongside people who filled in a form. Treating a record's
-- creation as a signal measures the import, not the interest.
--
-- 1. Signals come from records that are inbound by their nature: a form
--    submission, or a meeting the prospect booked. Neither needs a
--    direction flag, which is just as well — direction is a standard field
--    in both systems and populated only when the activity happened inside
--    the tool. Reps logging a call by hand are offered the choice and
--    mostly do not take it, and in Salesforce email tasks carry no
--    direction at all. An analysis requiring it would be unsupported at
--    most clients.
--
--    The response needs no direction either. If a signal arrived at nine
--    and somebody logged anything against that person at eleven, that is
--    the response.
--
-- 2. No signal source means the response cannot be measured at all, and
--    that is where the cap belongs: on the absence of form submissions,
--    not on the absence of a flag.
--
-- 3. Salesforce keeps unconverted leads in their own object, and most
--    leads never convert. Reading only contacts measures the survivors,
--    and the slow responses are disproportionately among those who never
--    converted — so the number would come out flattering and wrong. Leads
--    get their own export line. In HubSpot the line is marked absent,
--    which is an answer rather than a gap.

alter table engagement add column crm text;

comment on column engagement.crm is
  'Which CRM the client runs. It changes what a field means: a contact '
  'created date is when the person arrived in HubSpot and when the lead '
  'converted in Salesforce.';

do $$
declare v_old uuid; v_new uuid; v_msg record; v_line uuid; v_el uuid;
begin
  if exists (select 1 from instrument_version where label = 'v0.9') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.8';
  v_new := gea_clone_instrument(v_old, 'v0.9');

  update instrument_version
     set notes = 'Signals come from forms and booked meetings rather than '
                 'record creation, and unconverted leads are their own '
                 'export.'
   where id = v_new;

  -- The Leads export ----------------------------------------------------
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
          'it.')
  returning id into v_el;

  -- Core where the analysis cannot run without it, supporting where it
  -- sharpens the picture. The six were written without a priority and the
  -- seed check caught it.
  insert into canonical_field (instrument_version_id, key, name, description,
                               expected_type, source_export_refs,
                               is_cap_bearing, priority)
  values
    (v_new, 'lead_id', 'Lead identifier',
     'The lead''s own key.', 'id', array['T1-10'], false, 'core'),
    (v_new, 'lead_created_at', 'When the lead arrived',
     'When the lead record was created. In Salesforce this is when the '
     'person arrived; the contact created date is when they converted, '
     'which is a different and much later thing.',
     'date', array['T1-10'], false, 'core'),
    (v_new, 'lead_status', 'Lead status',
     'Where the lead got to.', 'enum', array['T1-10'], false, 'supporting'),
    (v_new, 'lead_source', 'How the lead arrived',
     'The source recorded on the lead.', 'enum', array['T1-10'], false, 'supporting'),
    (v_new, 'lead_converted_at', 'When the lead converted',
     'Empty on every lead that never converted, which is the point.',
     'date', array['T1-10'], false, 'core'),
    (v_new, 'lead_converted_contact_id', 'The contact it became',
     'Links a converted lead to the contact it became, so the same person '
     'is not counted twice.', 'id', array['T1-10'], false, 'core');

  -- Signals ------------------------------------------------------------
  -- A meeting the prospect booked is as inbound as a form, and some
  -- clients have far more of them.
  insert into analysis_field_requirement
         (instrument_version_id, analysis_key, canonical_field_id, is_required)
  select v_new, 'signal_to_first_contact', cf.id, false
    from canonical_field cf
   where cf.instrument_version_id = v_new
     and cf.key in ('meeting_at', 'lead_id', 'lead_created_at')
  on conflict (instrument_version_id, analysis_key, canonical_field_id)
    do update set is_required = false;

  -- Where the cap really belongs ----------------------------------------
  -- Not on a missing direction flag. On having no way to tell that anyone
  -- ever raised a hand.
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
  ('059_instrument_v0_9_signals_and_leads.sql',
   'v0.9: a signal is a form submission or a booked meeting, not a record '
   'being created. Unconverted leads get their own export. The cap sits on '
   'having no signal source at all.');
