-- 058 v0.8: two analyses asked for the wrong things.
--
-- Both found by building them.
--
--   signal_to_first_contact was specified against opportunities, and no
--   route exists from a form submission to an opportunity. It is a
--   contact-level measure: something arrives on a contact, and somebody
--   either reaches out or does not. So it needs the activity's contact, not
--   the activity's opportunity, and it can fall back to when the contact was
--   created where no form export arrives — a client with no form data still
--   has leads appearing and a response time worth measuring.
--
--   expansion_vs_new_business could not tell a won deal from a lost one. It
--   never required opportunity_status, so it counted every deal in the
--   export as closed-won. The figure would have been wrong by the width of
--   the loss rate and looked entirely plausible.
--
-- v0.7 is retired rather than corrected, for the same reason v0.6 was: what
-- an analysis requires is what "supported" means.

do $$
declare v_old uuid; v_new uuid; v_msg record;
begin
  if exists (select 1 from instrument_version where label = 'v0.8') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.7';
  v_new := gea_clone_instrument(v_old, 'v0.8');

  update instrument_version
     set notes = 'Measures the response to a signal on the contact rather '
                 'than the opportunity, and lets expansion tell a won deal '
                 'from a lost one.'
   where id = v_new;

  -- The contact-level route, and the fallback signal.
  insert into analysis_field_requirement
         (instrument_version_id, analysis_key, canonical_field_id, is_required)
  select v_new, 'signal_to_first_contact', cf.id, v.required
    from (values ('activity_contact_id', true),
                 ('contact_id', true),
                 ('activity_at', true),
                 ('contact_created_at', false),
                 ('activity_direction', false))
         as v(key, required)
    join canonical_field cf on cf.key = v.key
                           and cf.instrument_version_id = v_new
  on conflict (instrument_version_id, analysis_key, canonical_field_id)
    do update set is_required = excluded.is_required;

  -- Without this it counted every deal as won.
  insert into analysis_field_requirement
         (instrument_version_id, analysis_key, canonical_field_id, is_required)
  select v_new, 'expansion_vs_new_business', cf.id, true
    from canonical_field cf
   where cf.instrument_version_id = v_new and cf.key = 'opportunity_status'
  on conflict (instrument_version_id, analysis_key, canonical_field_id)
    do update set is_required = true;

  -- The opportunity route it cannot use, and never could.
  delete from analysis_field_requirement r
   using canonical_field cf
   where r.instrument_version_id = v_new
     and r.analysis_key = 'signal_to_first_contact'
     and cf.id = r.canonical_field_id
     and cf.key in ('activity_opportunity_id', 'opportunity_id',
                    'first_contact_at');

  -- The signal can be either a form submission or the contact appearing at
  -- all. Requiring the form export would make a client with no form data
  -- unmeasurable, when their leads still arrive and somebody still does or
  -- does not call them back. Neither is required on its own; the analysis
  -- refuses when it has neither, and says which one it used.
  update analysis_field_requirement r
     set is_required = false
    from canonical_field cf
   where r.instrument_version_id = v_new
     and r.analysis_key = 'signal_to_first_contact'
     and cf.id = r.canonical_field_id
     and cf.key in ('form_name', 'form_submission_at',
                    'form_submission_contact_id');

  for v_msg in select * from gea_activate_instrument('v0.8') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('058_instrument_v0_8_two_corrections.sql',
   'v0.8: signal to first contact is measured on the contact, and expansion '
   'can tell a won deal from a lost one.');
