-- 125 How much, not only how many.
--
-- Every analysis that groups deals counted them and stopped. A client
-- whose conferences produce two opportunities from fifty-six has a
-- problem; whether those two were worth four hundred thousand or four
-- thousand decides how big a problem, and which channel should have had
-- the money instead. A consultant reading a count will ask for the
-- value, and had nowhere to get it.
--
-- So the deal value joins the fields each of those analyses may read.
-- Optional everywhere, because a client that records no value should
-- still get every analysis: a figure nobody keeps is a finding about
-- them rather than a reason to produce nothing.

-- On a new version, because an active instrument is immutable and the
-- fields an analysis may read are instrument data.
do $do$
declare
  v_iv uuid; v_from uuid; v_field uuid; r record;
begin
  select id into v_from from instrument_version where status = 'active';
  v_iv := gea_clone_instrument(v_from, 'v0.19');
  select id into v_field from canonical_field
   where instrument_version_id = v_iv and key = 'opportunity_amount';
  if v_field is null then
    raise exception 'opportunity_amount is not a field on the active instrument';
  end if;

  for r in
    select unnest(array[
      'win_loss_and_churn_patterns',
      'icp_reconciliation',
      'buying_group_composition',
      'handover_completeness_census',
      'note_sufficiency',
      'discovery_consistency_classification',
      'detect_pipeline',
      'cost_per_qualified_opportunity',
      'expansion_vs_new_business',
      'stage_conversion_and_duration'
    ]) as analysis_key
  loop
    insert into analysis_field_requirement (instrument_version_id,
           analysis_key, canonical_field_id, is_required)
         values (v_iv, r.analysis_key, v_field, false)
    on conflict do nothing;
  end loop;

  perform gea_activate_instrument('v0.19');
end $do$;

insert into gea_migration (filename, note) values
  ('125_how_much_not_only_how_many.sql',
   'Deal value is readable by every analysis that groups deals, as an '
   'optional field.')
on conflict do nothing;
