-- 095 v0.15: how each analysis goes wrong.
--
-- The guidance a reviewer needs is methodology, so it belongs to an
-- instrument version. Each line is the one thing worth checking before
-- accepting that analysis, and the way it characteristically fails.
--
-- These are written from failures that actually happened on the first
-- real client rather than from imagination. A win rate of eighty-eight
-- per cent passed review until somebody noticed that two hundred and
-- thirteen disqualified deals were being counted as still open.

do $$
declare v_old uuid; v_new uuid; v_msg record;
begin
  if exists (select 1 from instrument_version where label = 'v0.15') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.14';
  v_new := gea_clone_instrument(v_old, 'v0.15');
  update instrument_version
     set notes = 'What to check before accepting each analysis, and how '
                 'each one characteristically goes wrong.'
   where id = v_new;

  insert into analysis_guidance (instrument_version_id, analysis_key,
                                 what_to_check, goes_wrong)
  values
  (v_new, 'win_loss_and_churn_patterns',
   'Check that won, lost, unqualified and still-open add up to roughly '
   'the number of deals you would expect to have closed in the window. '
   'If most of the pipeline reads as still open, the outcome values are '
   'not being recognised.',
   'A client whose stage names the methodology has not seen before. '
   'Qualified Out, Closed Cancelled and Stale all mean a deal ended, and '
   'a client who uses a word nobody has met will have those deals '
   'counted as live, which flatters the win rate.'),

  (v_new, 'stage_conversion_and_duration',
   'Check that the number of deals falls from one stage to the next. '
   'Where it rises, the stage records are incomplete rather than deals '
   'having appeared from nowhere, and the durations will be short.',
   'A history export that records every edit rather than every stage '
   'change. On the first real client two fifths of the rows changed no '
   'stage at all, and counting them made every stage look nine times '
   'faster than it was.'),

  (v_new, 'price_discount_dispersion',
   'Check the number of deals carrying both a list price and a sold '
   'price. A discount is the difference between two figures and a client '
   'who records one of them has no discount to report.',
   'A list price left blank on most deals, which makes the few that have '
   'one look like the whole book.'),

  (v_new, 'icp_reconciliation',
   'Check that the firmographics are populated on a real share of the '
   'accounts. An industry recorded on a fifth of customers describes '
   'that fifth, not the client.',
   'A company export filtered to accounts that have a deal. The accounts '
   'with nothing on them are the white space, and leaving them out turns '
   'a question about who to sell to into a description of who already '
   'bought.'),

  (v_new, 'cost_per_qualified_opportunity',
   'Check that the spend months and the qualified months overlap. A '
   'year of spend against a quarter of opportunities produces a cost per '
   'opportunity four times too high.',
   'Spend exported for a different period from the deals, or spend '
   'recorded against channels the CRM names differently.'),

  (v_new, 'handover_completeness_census',
   'Check how many won deals the census could look at. A handover census '
   'over a tenth of the wins is a sample, and a small one.',
   'A partial activity or note export. What is missing reads as a '
   'handover that did not happen rather than as a record that was not '
   'exported.'),

  (v_new, 'forecast_accuracy',
   'Check that each period has both a forecast and an actual. A period '
   'with one of them contributes nothing and quietly shrinks the base.',
   'Forecasts kept in a spreadsheet that was rebuilt partway through the '
   'year, so the earlier periods are missing or restated.'),

  (v_new, 'renewal_timing_and_reason',
   'Check that the renewal outcomes include renewals as well as losses. '
   'A list of churned customers is not a renewal rate.',
   'An export filtered to non-renewals, which is the commoner request '
   'and makes the renewal rate unreadable.'),

  (v_new, 'buying_group_composition',
   'Check the number of contacts per deal against what the team says in '
   'interviews. A single-threaded figure that disagrees with what the '
   'sellers describe usually means roles are not being recorded rather '
   'than that deals are single-threaded.',
   'Contact roles left unset, which reads as a deal with one person on '
   'it.'),

  (v_new, 'expansion_vs_new_business',
   'Check that the deal types distinguish new business from expansion. '
   'Where every deal is one type, the split is not being recorded.',
   'A client who books expansion as new business, or who uses the type '
   'field for something else entirely.'),

  (v_new, 'signal_to_first_contact',
   'Check that the first-contact times are not all zero or all '
   'identical. Either means a bulk update rather than real response '
   'times.',
   'An activity export that carries the date a record was loaded rather '
   'than the date the contact happened.'),

  (v_new, 'note_sufficiency',
   'Read three or four of the notes the analysis called thin. If they '
   'look adequate to you, the threshold is wrong for this client rather '
   'than their note-taking being poor.',
   'A client whose notes live somewhere the export does not reach, so '
   'the field is short because it is the wrong field.'),

  (v_new, 'discovery_consistency_classification',
   'Read the records the analysis set aside for checking. The '
   'classification is a model''s reading of free text and the sample is '
   'there to be disagreed with.',
   'Discovery notes written to a template, which makes every call look '
   'consistent whether or not the questions were asked.');

  for v_msg in select * from gea_activate_instrument('v0.15') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('095_how_each_analysis_goes_wrong.sql',
   'v0.15: what to check before accepting each analysis, written from '
   'failures that actually happened.');
