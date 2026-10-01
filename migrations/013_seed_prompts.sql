-- 013 Seed: 25 prompts, 16 measurement definitions
--
-- Prompts are versioned independently of the instrument, so prompt_version carries
-- no instrument_version_id and is not covered by the reference immutability trigger.
-- Output contracts and discard conditions are stored as jsonb because the analysis
-- service validates against them rather than the application reading them field by
-- field.

insert into prompt_version (ref, version, title, purpose, inputs_required,
  template, slots, execution_mode, output_contract, discard_conditions,
  step_ref, owner_role, status) values
  ('GEA-P01', '0.1', 'Intake audit and data quality flag', 'Establish what the exports can and cannot support before any analysis is built on them.', 'All CRM and marketing exports received to date, uploaded as CSV.',
   'You are auditing CRM and marketing exports for a Growth Engineering Assessment. The uploaded files are the client''s raw exports.

For each file report: the row count; the date range of its primary date field; every field present; and for each field, the percentage of rows populated with the record count behind that percentage.

Then flag, per file: any field where one value accounts for more than 50% of populated rows, naming the value and the share; any field holding free text where a controlled list was expected; any field populated on fewer than 30% of rows.

Then produce a table of the following analyses, each marked SUPPORTED, PARTIAL or NOT SUPPORTED, with a one-line reason: cost per qualified opportunity by channel; realised price and discount dispersion; stage-to-stage conversion and time in stage; forecast accuracy against actual; time from high-intent signal to first contact; buying group composition on won deals; renewal timing and non-renewal reason; expansion events distinguishable from new business.

Do not estimate, infer or impute any value to fill a gap. Where something cannot be determined from the files, say so and stop. Output in markdown.',
   null, 'hybrid',
   '{"field_mappings[]": {"type": "array", "required": true, "notes": "canonical_key, dataset, proposed_column, confidence, evidence_note, candidate_alternatives[]"}, "capabilities[]": {"type": "array", "required": true, "notes": "analysis_key, verdict, reason, supporting_fields[] required where verdict is supported"}, "observations[]": {"type": "array", "required": true, "notes": "dataset, field, flag, value, share as Rate, record_count"}}'::jsonb,
   '[{"ref": "GEA-P01-D1", "code": "RATE_NO_DENOMINATOR", "condition": "Reports a percentage without the record count", "machine_checkable": true, "how_checked": "Every Rate in the contract requires value, numerator and denominator."}, {"ref": "GEA-P01-D2", "code": "INFERRED_FIELD_MEANING", "condition": "Infers a field''s meaning that is not evidenced by its values", "machine_checkable": false, "how_checked": "Reviewer confirms each mapping''s evidence note names actual values, not a guess from the column name."}, {"ref": "GEA-P01-D3", "code": "SUPPORTED_NO_FIELDS", "condition": "Marks an analysis SUPPORTED without naming the fields that support it", "machine_checkable": true, "how_checked": "supporting_fields is conditionally required where verdict is supported."}]'::jsonb,
   '1.4', 'GA', 'draft'),
  ('GEA-P02', '0.1', 'Population definition and count reconciliation', 'Fix the denominator for every rate in the assessment, and surface disagreement between systems of record.', 'Closed opportunity export, account or customer list export, and any subscription or contract export.',
   'Establish the assessment population from the uploaded exports. The evaluation window is [START DATE] to [END DATE].

Report as counts, with the exclusion rule you applied stated for each: opportunities with a closed-won status inside the window; opportunities with a closed-lost status inside the window; records with a close date inside the window whose status is neither; records excluded for any other reason, itemised.

Then reconcile customers. Report the number of distinct accounts holding at least one closed-won record in the window, and compare it to the account list export. List every account appearing in one source and not the other, up to fifty, and give the total count of mismatches.

Report counts only. Do not compute rates, and do not exclude any record on a rule you have not stated. Output in markdown.',
   array['START DATE','END DATE']::text[], 'compute',
   '{"populations[]": {"type": "array", "required": true, "notes": "key, value, exclusion_rule. exclusion_rule may not be empty"}, "reconciliation": {"type": "object", "required": true, "notes": "distinct_accounts_from_crm, account_list_count, mismatches[] up to fifty, mismatch_total"}, "parse_reconciliation": {"type": "object", "required": true, "notes": "file_rows, parsed_rows, malformed_rows, malformed_reasons[]"}}'::jsonb,
   '[{"ref": "GEA-P02-D1", "code": "UNSTATED_EXCLUSION", "condition": "Applies an exclusion it does not state", "machine_checkable": true, "how_checked": "exclusion_rule is not-null on every population row."}, {"ref": "GEA-P02-D2", "code": "ROW_RECONCILIATION", "condition": "Silently drops records with malformed dates", "machine_checkable": true, "how_checked": "parsed_rows plus malformed_rows must equal file_rows."}, {"ref": "GEA-P02-D3", "code": "COUNT_INTEGRITY", "condition": "Reconciles by rounding two counts toward each other", "machine_checkable": true, "how_checked": "Reported counts are compared to counts recomputed from the dataset; any difference fails."}]'::jsonb,
   '1.4', 'GA', 'draft'),
  ('GEA-P03', '0.1', 'Note sufficiency test', 'Decide whether written notes qualify as tier B evidence, which sets the ceiling on five elements.', 'Export of activity or note records joined to closed opportunities, with created timestamps and author. Meeting dates where available.',
   'Test the uploaded note records against four sufficiency conditions. The population is [N] closed opportunities in the window.

1. Coverage. What percentage of closed opportunities carry at least one substantive note, with the record count? Report this separately for closed-won and closed-lost, because notes are often present only on deals that went well.

2. Structure. Sample thirty notes across at least three different authors. Do they follow a consistent template, or is the structure author-dependent? Quote three short extracts of under fifteen words each to illustrate, and name the authors only as Author 1, Author 2, Author 3.

3. Content. In the same thirty, what percentage record the buyer''s own position on each of: decision process, timeline, success criteria, agreed next step? Report the four percentages separately.

4. Contemporaneity. What percentage of notes were created within two working days of the meeting date they refer to?

Then state a verdict: PASS only if coverage is at or above 90%, structure is consistent across authors, all four content percentages are at or above 70%, and contemporaneity is at or above 80%. Otherwise FAIL, naming which conditions failed.

Do not soften the verdict. A near miss is a fail. Output in markdown.',
   array['N']::text[], 'hybrid',
   '{"coverage_won": {"type": "Rate", "required": true, "notes": "computed"}, "coverage_lost": {"type": "Rate", "required": true, "notes": "computed"}, "contemporaneity": {"type": "Rate", "required": true, "notes": "computed"}, "structure_consistent": {"type": "boolean", "required": true, "notes": "model, with note"}, "content_rates": {"type": "object", "required": true, "notes": "four Rates: decision_process, timeline, success_criteria, next_step"}, "sample": {"type": "object", "required": true, "notes": "size, seed, pseudonymised authors, stratification"}, "verdict / tier / ceiling": {"type": "enum", "required": true, "notes": "computed from thresholds, never model-generated"}}'::jsonb,
   '[{"ref": "GEA-P03-D1", "code": "VERDICT_WITHOUT_RATES", "condition": "Returns a verdict without all four measured rates", "machine_checkable": true, "how_checked": "All four rates are required fields; the verdict is computed, not returned."}, {"ref": "GEA-P03-D2", "code": "HEDGED_CONDITION", "condition": "It reasons that a condition is ''broadly met'' rather than measuring it", "machine_checkable": true, "how_checked": "Structurally prevented: the verdict is a threshold comparison in code."}]'::jsonb,
   '1.5', 'GA', 'draft'),
  ('GEA-P04', '0.1', 'Win/loss and churn pattern analysis', 'Evidence for elements 1.1, 1.3, 1.4 and 8.4, and the input to the ICP reconciliation.', 'Closed opportunity export with outcome, firmographics, product, deal size, partner involvement and rep. Churn and downgrade export with date and reason.',
   'Analyse the uploaded closed opportunity and churn exports across the full population of [N] records.

Cut win rate by each of: industry or vertical, employee count band, revenue band, geography, product or package, deal size band, partner involvement, and rep. For each cut report the win rate, the record count behind it, and the variance from the overall win rate.

Suppress any cut holding fewer than ten records: report the count and state ''insufficient records'' rather than a rate.

Identify the three cuts with the widest variance from the overall rate that are not suppressed.

Repeat the same structure for churn, using the churn export, cut by the same dimensions plus tenure band at churn.

Then state in plain language, in no more than six sentences: which population actually wins, which population actually churns, and whether those two descriptions are consistent with each other.

Report the recorded loss reason distribution and the recorded churn reason distribution, each with the share held by the single most common value. Do not interpret a defaulted or catch-all reason as a real reason. Do not infer a reason where none is recorded. Output in markdown with tables.',
   array['N']::text[], 'hybrid',
   '{"patterns[]": {"type": "array", "required": true, "notes": "statement, supporting_metric_keys[] at least one, segments[], counter_evidence or absent"}, "loss_reason_quality": {"type": "object", "required": true, "notes": "populated Rate, dominant value and share"}}'::jsonb,
   '[{"ref": "GEA-P04-D1", "code": "MIN_RECORD_FLOOR", "condition": "Reports a rate on fewer than ten records", "machine_checkable": true, "how_checked": "Any Rate whose denominator is below ten is rejected."}, {"ref": "GEA-P04-D2", "code": "CATCHALL_AS_FINDING", "condition": "Treats a catch-all loss reason as a finding", "machine_checkable": false, "how_checked": "Reviewer confirms a dominant catch-all loss reason is reported as a data-quality finding, not a cause."}, {"ref": "GEA-P04-D3", "code": "PATTERN_NO_SUPPORT", "condition": "Describes a pattern without the counts behind it", "machine_checkable": true, "how_checked": "Every pattern requires at least one supporting_metric_key."}]'::jsonb,
   '2.1', 'GA', 'draft'),
  ('GEA-P05', '0.1', 'Pricing and discount dispersion', 'Evidence for element 1.5.', 'Closed-won export with list price, realised price, discount, segment, term and product.',
   'Analyse realised pricing across all [N] closed-won records in the window.

Report the distribution of realised discount overall, and then cut by segment, product or package, deal size band, term length and rep. For each cut give the median, the interquartile range and the record count.

Identify where dispersion is explicable by a stated dimension and where it is not. Be specific: name the cuts where records of comparable scope and segment carry materially different realised prices, and give the spread.

State whether a discount authority threshold is visible in the data as a clustering effect, and if so at what level.

Do not infer a price where the field is empty, and do not treat a null discount as zero. Report the count of records excluded for missing price data. Output in markdown with tables.',
   array['N']::text[], 'compute',
   '{"distribution": {"type": "object", "required": true, "notes": "p10, p25, median, p75, p90"}, "by_segment[]": {"type": "array", "required": true, "notes": null}, "by_owner[]": {"type": "array", "required": false, "notes": null}, "records_with_discount": {"type": "Rate", "required": true, "notes": null}, "list_price_source": {"type": "string", "required": true, "notes": "which field carried list price"}}'::jsonb,
   '[{"ref": "GEA-P05-D1", "code": "NO_IMPUTATION", "condition": "Treats nulls as zeros", "machine_checkable": true, "how_checked": "Compute layer forbids null-to-zero coercion; null counts are returned separately."}, {"ref": "GEA-P05-D2", "code": "RATE_NO_DENOMINATOR", "condition": "Reports a median without the count", "machine_checkable": true, "how_checked": "Distribution figures require their record count."}, {"ref": "GEA-P05-D3", "code": "UNEVIDENCED_CAUSE", "condition": "Explains dispersion with a reason not present in the data", "machine_checkable": false, "how_checked": "Reviewer confirms any explanation names the field it came from."}]'::jsonb,
   '2.1', 'GA', 'draft'),
  ('GEA-P06', '0.1', 'Channel cost per qualified opportunity and payback', 'Evidence for elements 3.1 and 3.4.', 'Spend by channel, campaign and month. Opportunity export with source, campaign, created date, value and outcome.',
   'Compute channel economics from the uploaded spend and opportunity exports for the window [START] to [END].

For each channel report: total spend; qualified opportunities attributed; cost per qualified opportunity; closed-won count and value attributed; and payback period in months, stating the gross margin assumption you used and flagging it as an assumption to be confirmed.

Separate brand from non-brand paid search if the campaign naming allows it. If it does not, say so rather than combining them silently.

Report the percentage of opportunities in the window carrying no usable source value, with the count. If that percentage is above 20%, state that channel economics cannot be reported as complete and compute the figures on the attributed subset only, labelling them as such.

Report channel concentration: the share of qualified opportunities from the single largest channel and from the top two combined.

Do not allocate unattributed opportunities across channels by any method. Output in markdown with tables.',
   array['START','END']::text[], 'compute',
   '{"by_channel[]": {"type": "array", "required": true, "notes": "channel, spend, qualified_opportunities, cpqo, payback_months or absent"}, "unattributed": {"type": "Rate", "required": true, "notes": null}, "spend_source": {"type": "string", "required": true, "notes": "named source document"}}'::jsonb,
   '[{"ref": "GEA-P06-D1", "code": "NO_IMPUTATION", "condition": "Distributes unattributed opportunities proportionally", "machine_checkable": true, "how_checked": "Unattributed opportunities are returned as their own Rate and never allocated."}, {"ref": "GEA-P06-D2", "code": "CHANNEL_GRANULARITY", "condition": "Quietly combines brand and non-brand", "machine_checkable": true, "how_checked": "Channel values in the output must match the declared channel taxonomy one to one."}, {"ref": "GEA-P06-D3", "code": "ASSUMPTION_REQUIRED", "condition": "Reports payback without stating the margin assumption", "machine_checkable": true, "how_checked": "payback_months requires a stated margin assumption in the assumptions array."}]'::jsonb,
   '2.1', 'GA', 'draft'),
  ('GEA-P07', '0.1', 'Pipeline stage history, conversion and time in stage', 'Evidence for elements 5.1 and 5.5, and the handoff conversion rates in the measurement definitions.', 'Stage history export for all opportunities in the window, with opportunity id, stage, entered date and exited date.',
   'Analyse the uploaded stage history across all [N] opportunities in the window.

Report stage-to-stage conversion for each transition, with the record count at each stage entry.

Report time in stage per stage: median, interquartile range, and the ninetieth percentile.

Report stage skipping: the percentage of won deals that never recorded an entry into each stage, per stage, with counts.

Report variance by rep on both conversion and time in stage, naming reps as Rep 1, Rep 2 and so on, and state whether the spread between the best and worst quartile is wide enough to be material.

Identify any stage where the time distribution is bimodal and say so explicitly, since an average conceals it.

Do not reconstruct a stage entry that is not recorded. Where history is missing for a record, exclude it and report the excluded count. Output in markdown with tables.',
   array['N']::text[], 'compute',
   '{"stages[]": {"type": "array", "required": true, "notes": "stage, entered_count, exited_count, conversion as Rate, median_days, p90_days"}, "deals_with_history": {"type": "Rate", "required": true, "notes": null}}'::jsonb,
   '[{"ref": "GEA-P07-D1", "code": "NO_IMPUTATION", "condition": "Fills a missing stage entry by interpolation", "machine_checkable": true, "how_checked": "Missing stage entries are counted, never interpolated."}, {"ref": "GEA-P07-D2", "code": "DISTRIBUTION_SHAPE", "condition": "Reports an average where the distribution is bimodal without saying so", "machine_checkable": true, "how_checked": "Where a computed distribution is bimodal, a mean may not be returned without the distribution alongside it."}, {"ref": "GEA-P07-D3", "code": "EXCLUSION_COUNT_REQUIRED", "condition": "Omits the excluded record count", "machine_checkable": true, "how_checked": "deals_with_history is a required Rate."}]'::jsonb,
   '2.1', 'GA', 'draft'),
  ('GEA-P08', '0.1', 'Forecast accuracy and pipeline hygiene', 'Evidence for element 5.5.', 'Forecast submissions for at least four quarters with submission date and forecast value. Actual closed value per quarter. Current open pipeline export.',
   'Compute forecast accuracy from the uploaded submissions against actuals for the last [N] quarters.

Report per quarter: forecast value, actual value, absolute variance, percentage variance, and the direction. Then report the mean absolute percentage variance across all quarters and whether the direction is consistently one way, which indicates systematic bias rather than noise.

Then audit the current open pipeline and report, each with a count and a percentage of open pipeline value: opportunities with a close date in the past; opportunities with no activity recorded in 30 days; opportunities with no activity in 90 days; opportunities missing any field required by the client''s own stage exit criteria, if those criteria are provided.

Report the coverage ratio of open pipeline to the next quarter''s target, if the target is provided, and state what coverage would be implied by the measured stage conversion rates rather than by a rule of thumb.

Do not adjust a forecast figure for anything. Report what was submitted. Output in markdown with tables.',
   array['N']::text[], 'compute',
   '{"periods[]": {"type": "array", "required": true, "notes": "period, forecast_amount, actual_amount, variance, accuracy"}, "mean_accuracy": {"type": "number", "required": true, "notes": null}, "submissions_retained": {"type": "boolean", "required": true, "notes": null}}'::jsonb,
   '[{"ref": "GEA-P08-D1", "code": "NO_EXCLUSION", "condition": "Excludes a quarter as an outlier", "machine_checkable": true, "how_checked": "Every period in the window must appear; omission fails."}, {"ref": "GEA-P08-D2", "code": "NO_ADJUSTMENT", "condition": "Adjusts a submitted figure", "machine_checkable": true, "how_checked": "Submitted forecast values are compared to source; any difference fails."}, {"ref": "GEA-P08-D3", "code": "RATE_NO_DENOMINATOR", "condition": "Reports coverage without stating the conversion rates behind it", "machine_checkable": true, "how_checked": "Coverage requires the conversion rates behind it as required fields."}]'::jsonb,
   '2.1', 'GA', 'draft'),
  ('GEA-P09', '0.1', 'Signal to first contact response time', 'Evidence for elements 4.3 and 4.5, and for handoff H04.', 'Export of high-intent signals or form submissions with timestamp, and the first outbound activity timestamp against the same record.',
   'Compute response time from the uploaded signal and activity exports for the window.

Report the distribution of elapsed time from signal to first outbound contact: median, interquartile range, ninetieth percentile, and the percentage contacted within one hour, four hours, one working day and three working days, each with counts.

Cut the same distribution by signal type, by source, by rep or owner, and by day of week of the signal.

Report the percentage of signals with no recorded outbound contact at all, with the count.

Report separately for signals the client classifies as high intent, if such a classification exists in the data, and state what the classification is based on.

Do not treat an absent activity record as an instant response or as a non-response: report it as unrecorded and count it separately. Output in markdown with tables.',
   null, 'compute',
   '{"median_hours": {"type": "number", "required": true, "notes": null}, "p90_hours": {"type": "number", "required": true, "notes": null}, "within_one_hour": {"type": "Rate", "required": true, "notes": null}, "within_24_hours": {"type": "Rate", "required": true, "notes": null}, "submissions_counted": {"type": "integer", "required": true, "notes": null}, "unmatched_submissions": {"type": "object", "required": true, "notes": "count with reason"}}'::jsonb,
   '[{"ref": "GEA-P09-D1", "code": "NO_IMPUTATION", "condition": "Treats missing activity as either instant or infinite", "machine_checkable": true, "how_checked": "Unmatched submissions are returned with a reason and excluded from the median."}, {"ref": "GEA-P09-D2", "code": "COMPANION_FIGURE_REQUIRED", "condition": "Reports a median without the never-contacted share alongside it", "machine_checkable": true, "how_checked": "Never-contacted share is a required field alongside the median."}]'::jsonb,
   '2.1', 'GA', 'draft'),
  ('GEA-P10', '0.1', 'Stated ICP against the record', 'Produce the evidenced values for the ICP Reconciliation sheet.', 'The client''s ICP document. Closed-won export, renewed or expanded cohort, churned cohort, all with firmographics.',
   'The first uploaded file is the client''s stated ICP. The others are their closed-won, renewed or expanded, and churned cohorts.

Extract every criterion the stated ICP defines, quoting each in under fifteen words. Include criteria stated as exclusions.

For each criterion, report the evidenced value across three populations separately: closed-won in the window, the renewed or expanded cohort, and the churned cohort. Use medians and distributions rather than averages, and give the record count for each.

For each criterion state whether the evidenced populations fall inside the stated criterion, overlap it partially, or fall outside it. Do not average the three populations together.

Then answer one question directly: does the stated ICP describe the renewed cohort or the churned cohort more closely? Answer with the specific criteria that support your answer.

Where a criterion cannot be tested because the data does not hold it, say so and move on. Do not substitute a proxy without naming it as a proxy. Output in markdown with one table per criterion.',
   null, 'hybrid',
   '{"criteria[]": {"type": "array", "required": true, "notes": "criterion, stated_value, evidenced_distribution, agreement, agreement_rate as Rate"}, "variance_rate": {"type": "Rate", "required": true, "notes": null}, "cap_triggered": {"type": "boolean", "required": true, "notes": "computed, never model-asserted"}}'::jsonb,
   '[{"ref": "GEA-P10-D1", "code": "COHORT_SEPARATION", "condition": "Averages the three cohorts", "machine_checkable": true, "how_checked": "Criteria are returned per cohort; a single averaged figure fails the shape."}, {"ref": "GEA-P10-D2", "code": "PROXY_UNDECLARED", "condition": "Substitutes a proxy field without saying so", "machine_checkable": true, "how_checked": "Any field used that is not the mapped canonical field must be declared in the output."}, {"ref": "GEA-P10-D3", "code": "CRITERIA_REQUIRED", "condition": "Hedges the final answer rather than naming the criteria", "machine_checkable": true, "how_checked": "criteria[] is required and must cover every stated ICP criterion."}]'::jsonb,
   '2.2', 'GA, GC', 'draft'),
  ('GEA-P11', '0.1', 'Substitution test and surface consistency', 'Evidence for elements 1.4, 2.1 and 2.4.', 'Client homepage and primary solution pages, current pitch deck, most recent outbound sequence, and any directory or partner listings. Provide as text or uploaded files.',
   'Audit the uploaded materials for positioning consistency and claim defensibility.

First, extract the core value claim made on each surface separately. Present them side by side so differences in substance, not just in wording, are visible.

Second, run the substitution test on every differentiation claim. Replace the company name with [COMPETITOR 1] and [COMPETITOR 2]. For each claim state whether it remains true after substitution. A claim that survives substitution is not differentiation and should be marked as such.

Third, list every claim that is specific enough to be checked, and state whether supporting evidence appears alongside it on the same surface.

Fourth, identify the target buyer each surface implies, and flag where surfaces imply different buyers.

Quote nothing longer than fifteen words from any single source. Do not improve, rewrite or suggest alternatives to any claim: this is an audit, not an edit. Output in markdown.',
   array['COMPETITOR 1','COMPETITOR 2']::text[], 'model',
   '{"claims[]": {"type": "array", "required": true, "notes": "claim under fifteen words, surface_capture_ref, substitutable, competitor_tested, note"}, "substitutable_rate": {"type": "Rate", "required": true, "notes": "computed"}}'::jsonb,
   '[{"ref": "GEA-P11-D1", "code": "CLAIM_ALTERED", "condition": "Rewrites a claim rather than assessing it", "machine_checkable": true, "how_checked": "Each claim is matched against the captured surface text; a claim not found verbatim fails."}, {"ref": "GEA-P11-D2", "code": "QUOTE_LENGTH", "condition": "Quotes at length", "machine_checkable": true, "how_checked": "Any quoted claim over fifteen words fails."}, {"ref": "GEA-P11-D3", "code": "SUBSTITUTION_BASIS", "condition": "Judges a claim on how it sounds rather than on whether it survives substitution", "machine_checkable": false, "how_checked": "Reviewer confirms the judgement rests on substitution, not on tone."}]'::jsonb,
   '2.3', 'GC', 'draft'),
  ('GEA-P12', '0.1', 'Answer engine presence test', 'Evidence for element 3.3.', 'The standard AEO prompt set from the evidence kit, customised for the client''s segments. The client''s competitor set.',
   'Run the following prompt set as a buyer would and record what comes back. Prompt set: [PASTE 15 TO 25 PROMPTS].

For each prompt report: whether the client company is mentioned; its position in the answer if mentioned; whether the description of it is accurate, with the specific inaccuracy if not; which competitors are named; and which sources the answer appears to draw on.

Then summarise: presence rate across the set with the count; citation share against each named competitor; and the three most consequential inaccuracies.

Record the date and the model version used, because a re-score comparison is invalid without them.

Do not use your own background knowledge of the company to fill in an answer. Report only what the tested response returned. Output in markdown with one row per prompt.',
   array['PASTE 15 TO 25 PROMPTS']::text[], 'upload',
   '{"runs[]": {"type": "array", "required": true, "notes": "prompt_ref, assistant, model_version, run_at, response_text verbatim, client_mentioned, client_cited, competitors_mentioned[], citation_sources[]"}, "mention_rate": {"type": "Rate", "required": true, "notes": "computed"}, "citation_rate": {"type": "Rate", "required": true, "notes": "computed"}, "prompt_set_used": {"type": "object", "required": true, "notes": "refs and slot values, recorded for re-score reproducibility"}}'::jsonb,
   '[{"ref": "GEA-P12-D1", "code": "VERBATIM_ONLY", "condition": "Supplements a response with knowledge not returned by the test", "machine_checkable": true, "how_checked": "response_text is compared to the uploaded source; any difference fails."}, {"ref": "GEA-P12-D2", "code": "PROVENANCE_REQUIRED", "condition": "Omits the model version and date", "machine_checkable": true, "how_checked": "assistant, model_version and run_at are required on every row."}]'::jsonb,
   '2.3', 'GC', 'draft'),
  ('GEA-P13', '0.1', 'Discovery consistency classification', 'Evidence for element 5.2 and, in part, 5.3.', 'Discovery notes or call transcripts across the closed opportunity population. Evidence tier confirmed at step 1.6.',
   'Classify the uploaded discovery records across all [N] closed opportunities in the window.

For each record, answer yes or no to each of: does it record the buyer''s decision process; does it record a timeline; does it record the buyer''s own success criteria; does it record an agreed next step; does it record who else is involved in the decision.

Answer yes only where the record states it. A rep''s assumption, a restatement of your own inference, or an implication is a no.

Report the yes rate for each of the five, overall and cut by rep, with counts. Name reps as Rep 1, Rep 2 and so on.

Then report the percentage of records answering yes to all five, and to none of the five.

Return your per-record classifications for these ten record ids so they can be checked by hand: [PASTE 10 IDS].

Do not infer, and do not give partial credit. Output in markdown.',
   array['N','PASTE 10 IDS']::text[], 'model',
   '{"records[]": {"type": "array", "required": true, "notes": "record_id, classification from the declared label set, evidence_span, model_confidence"}, "distribution": {"type": "object", "required": true, "notes": "computed"}, "census_complete": {"type": "boolean", "required": true, "notes": "must be true to accept"}}'::jsonb,
   '[{"ref": "GEA-P13-D1", "code": "VALIDATION_SET", "condition": "Reading the ten records disagrees with the classification", "machine_checkable": true, "how_checked": "Acceptance requires a validation_set with verdict trust."}, {"ref": "GEA-P13-D2", "code": "LABEL_SET", "condition": "The output gives partial credit on any of the five questions", "machine_checkable": true, "how_checked": "Classifications outside the declared label set fail."}]'::jsonb,
   '2.4', 'GA', 'draft'),
  ('GEA-P14', '0.1', 'Message alignment classification', 'Evidence for element 2.5.', 'The approved marketing narrative. Rep-authored outreach, decks or call transcripts across the population.',
   'The first uploaded file is the client''s approved marketing narrative. The rest are rep-authored sales material and conversations.

Extract the core claim, the primary buyer problem, and the three main proof points from the approved narrative.

For each rep-authored record, classify: does it use the approved core claim, a recognisable variant of it, or a different claim entirely; does it address the same buyer problem; does it use approved proof points, other proof points, or none.

Report the distribution across all three classifications, overall and by rep, with counts. Name reps as Rep 1, Rep 2 and so on.

Then quote three examples of divergence, each under fifteen words, without naming the rep.

Classify what is written. Do not judge whether the divergent version is better. Output in markdown.',
   null, 'model',
   '{"records[]": {"type": "array", "required": true, "notes": "record_id, classification from the declared label set, evidence_span, model_confidence"}, "distribution": {"type": "object", "required": true, "notes": "computed"}, "census_complete": {"type": "boolean", "required": true, "notes": "must be true to accept"}}'::jsonb,
   '[{"ref": "GEA-P14-D1", "code": "LABEL_SET", "condition": "Evaluates the quality of the divergence rather than its existence", "machine_checkable": true, "how_checked": "Classifications outside the declared label set fail."}, {"ref": "GEA-P14-D2", "code": "VARIANT_HANDLING", "condition": "Classifies a recognisable variant as a different claim", "machine_checkable": false, "how_checked": "Reviewer confirms recognisable variants of the same claim were not split."}]'::jsonb,
   '2.4', 'GA', 'draft'),
  ('GEA-P15', '0.1', 'Handover completeness census', 'Evidence for handoffs H04 and H05, and for element 6.1.', 'Opportunity records at the point of handover, with attached context. Onboarding or delivery records for the same deals.',
   'Assess handover completeness across all [N] handovers in the window using the uploaded records.

For H04, marketing to sales: for each record classify whether the following were present at the point of handover: a stated qualification rationale; the research or engagement history; the known contacts and their roles; a stated trigger or reason now. Report the presence rate for each with counts.

For H05, sales to delivery: for each closed-won record classify whether the following were present at handover: the scope as sold; commitments made outside the written contract; success criteria; the named stakeholders. Report the presence rate for each with counts.

Then compare the delivery record against the deal record for each closed-won deal and report the percentage where delivery captured information that was already present in the deal record, which indicates re-keying rather than transfer.

Report the percentage of handovers where all four items were present, for each join separately.

A field that exists but is empty counts as absent. Do not credit an item because it could be inferred from elsewhere. Output in markdown with tables.',
   array['N']::text[], 'hybrid',
   '{"deals[]": {"type": "array", "required": true, "notes": "opportunity_id, structured_fields_present[], artefacts_attached[], complete"}, "completeness": {"type": "Rate", "required": true, "notes": null}}'::jsonb,
   '[{"ref": "GEA-P15-D1", "code": "INFERRED_PRESENCE", "condition": "Credits an item as present because it was inferable", "machine_checkable": true, "how_checked": "Presence is asserted per structured field from the dataset, not from the model."}, {"ref": "GEA-P15-D2", "code": "BREAKDOWN_REQUIRED", "condition": "Reports a completeness rate without the item-level breakdown", "machine_checkable": true, "how_checked": "Item-level structured_fields_present is required alongside the completeness Rate."}]'::jsonb,
   '2.5', 'GC, GA', 'draft'),
  ('GEA-P16', '0.1', 'Interview synthesis to element evidence', 'Convert eight hours of conversation into evidence mapped to numbered elements.', 'All interview recordings or transcripts. The element list from the scoring instrument.',
   'The uploaded files are transcripts of eight stakeholder interviews from a Growth Engineering Assessment.

Map what was said to the forty elements and eight handoffs. For each element where an interview produced relevant evidence, report: the element id; a one-line summary of what was said; which interviews said it; and whether the interviews agree or conflict.

Flag every element where two or more interviewees materially contradict each other, and state both positions. Do not resolve the contradiction. A contradiction between functions is evidence in its own right.

Separately, list every claim made in an interview that could be checked against system data, so it can be tested rather than accepted.

Attribute by role rather than by name. Quote nothing longer than fifteen words.

Do not score anything. Do not conclude that a practice is in place because someone said it is. Output in markdown, ordered by element id.',
   null, 'model',
   '{"element_evidence[]": {"type": "array", "required": true, "notes": "element_ref, observation, question_ref, transcript_span, corroboration, confidence"}, "unmapped_observations[]": {"type": "array", "required": true, "notes": "material observations mapping to no element"}}'::jsonb,
   '[{"ref": "GEA-P16-D1", "code": "CONTRADICTION_PRESERVED", "condition": "Resolves a contradiction", "machine_checkable": true, "how_checked": "corroboration is an enum including contradicts; a resolved contradiction cannot be expressed."}, {"ref": "GEA-P16-D2", "code": "NO_SCORING", "condition": "Assigns a score", "machine_checkable": true, "how_checked": "The contract has no score field; a score cannot be returned."}, {"ref": "GEA-P16-D3", "code": "STATED_VS_OPERATING", "condition": "Treats a stated practice as evidence that the practice operates", "machine_checkable": false, "how_checked": "Reviewer confirms testimony about intent is not recorded as evidence of practice."}]'::jsonb,
   '2.6', 'GC', 'draft'),
  ('GEA-P17', '0.1', 'Adversarial score review', 'Attack the score before a client does.', 'The completed scorecard with evidence citations, confidence flags and evidence tiers. The anchor descriptors. The ICP Reconciliation result.',
   'You are reviewing a completed Growth Engineering Assessment score before it goes to a client. Your job is to argue against every score, not to confirm any of them.

For each element scored 4 or 5: state what the anchor requires at that level, and whether the evidence citation provided actually meets it. Where it does not, state what the score should be.

For each element scored 0 or 1: check the by-product test. Is this an absence of the thing, or only an absence of evidence about the thing? Name any score that has confused the two.

For each element flagged Low confidence: state whether the score can be published at all, or whether it should be reported as a limitation instead.

Then find internal contradictions. Flag any pair of scores that cannot both be true. Examples to check specifically: a high score on H08 alongside a high ICP variance rate; a high score on 6.4 where 6.3 shows no adoption data reaching the team; a high score on 5.5 where 5.1 shows unenforced exit criteria; a high score on 2.5 where 2.1 shows no single authoritative narrative.

List every element whose evidence citation is not specific enough for a colleague to retrieve the same evidence independently.

Do not defend any score. Do not suggest report wording. Output as a table ordered by severity, most serious first.',
   null, 'model',
   '{"challenges[]": {"type": "array", "required": true, "notes": "element_ref, challenge, weakness_type from declared set, suggested_disposition"}}'::jsonb,
   '[{"ref": "GEA-P17-D1", "code": "CHALLENGE_ONLY", "condition": "Confirms scores rather than attacking them", "machine_checkable": true, "how_checked": "Every entry requires a challenge and a weakness_type; a confirmation has no valid shape."}, {"ref": "GEA-P17-D2", "code": "CHALLENGE_ONLY", "condition": "It proposes report wording instead of challenging the evidence", "machine_checkable": false, "how_checked": "Reviewer confirms output challenges evidence rather than proposing wording."}]'::jsonb,
   '3.3', 'GC, GA', 'draft'),
  ('GEA-P18', '0.1', 'Stack cost of ownership model', 'Produce the Stack Cost of Ownership Model from the client''s real numbers.', 'Stack inventory with annual licence costs. Integration build and maintenance invoices. iPaaS or middleware licences. RevOps and data headcount with salary and time allocation. Third-party service costs.',
   'Build a three-year total cost of ownership model for the client''s revenue technology stack using only figures from the uploaded documents.

Structure it in six cost lines: duplicate licensing, where overlapping capability is bought more than once; integration build, amortised over a three-year life; integration maintenance, including middleware licences and post-update rework; reconciliation labour, being the fraction of headcount whose work exists to make systems agree; decision latency; and the AI connection tax, being the number of governed connections implied by systems multiplied by deployed agents.

For each line report the annual figure, the source document it came from, and whether the line buys capability or exists only to compensate for fragmentation. Total each of those two categories separately.

Where a figure is not present in the uploaded documents, leave it blank and list it as an open input. Do not substitute an industry figure, an illustrative figure, or an estimate. Decision latency should be described rather than priced unless the client has supplied a basis for pricing it.

State every assumption in a separate list, not inside the arithmetic. Include the amortisation period, the salary loading, and any allocation percentage you applied.

Model the consolidated alternative only if the client has supplied pricing for it. If they have not, say so and stop rather than estimating it.

Output as a table per year plus a three-year total, and a separate assumptions list.',
   null, 'hybrid',
   '{"lines[]": {"type": "array", "required": true, "notes": "category from the six cost lines, vendor, item, year, annual_cost or absent, source_document_ref, is_open_input, classification"}, "assumptions[]": {"type": "array", "required": true, "notes": "name, value, rationale. Returned separately from the arithmetic"}, "totals": {"type": "object", "required": true, "notes": "by category by year, two categories totalled separately"}}'::jsonb,
   '[{"ref": "GEA-P18-D1", "code": "SOURCE_REQUIRED", "condition": "Any figure appears without a source document", "machine_checkable": true, "how_checked": "A populated annual_cost requires a source_document_ref; otherwise it must be an open input."}, {"ref": "GEA-P18-D2", "code": "NO_BENCHMARK", "condition": "An industry benchmark has been substituted for a client figure", "machine_checkable": true, "how_checked": "Any cost line without a client source document fails as a populated figure."}, {"ref": "GEA-P18-D3", "code": "ASSUMPTION_REQUIRED", "condition": "An assumption is buried inside a calculation", "machine_checkable": true, "how_checked": "assumptions[] is returned separately from the arithmetic and may not be empty where any derived figure exists."}]'::jsonb,
   '3.4', 'GA', 'draft'),
  ('GEA-P19', '0.1', 'Measurement definition tailoring', 'Map the standard measurement spine onto the client''s real systems and fields.', 'The standard Measurement Definition Set from the Blend library. The client''s field schema export. The intake audit from GEA-P01.',
   'The first uploaded file is Blend''s standard Measurement Definition Set. The others are the client''s field schema and the intake audit for this engagement.

For each of the eight stage metrics and eight handoff conversion rates, produce: the metric name; its formula; the source system, object and exact field name for every input; the function that should own it; the reporting cadence; and a verdict of COMPUTABLE, COMPUTABLE WITH REMEDIATION, or NOT COMPUTABLE.

For anything other than COMPUTABLE, name the specific field or object that is missing or unreliable, referring to the intake audit, and state what would have to change.

Use exact field names from the uploaded schema. Do not invent a field name, and do not assume a field exists because a metric requires it.

Then list any metric in the standard set that does not apply to this client''s business model, with the reason. Do not silently drop it.

Output as one table row per metric.',
   null, 'hybrid',
   '{"metrics[]": {"type": "array", "required": true, "notes": "metric_ref, source_system, source_object, source_fields[], owning_function, cadence, verdict, blocker where not computable"}, "inapplicable[]": {"type": "array", "required": true, "notes": "metric_ref, reason"}, "count check": {"type": "rule", "required": true, "notes": "sixteen entries required across both arrays"}}'::jsonb,
   '[{"ref": "GEA-P19-D1", "code": "FIELD_NOT_IN_SCHEMA", "condition": "Invents a plausible field name", "machine_checkable": true, "how_checked": "Every source field is matched against the client''s property list; an unmatched name fails."}, {"ref": "GEA-P19-D2", "code": "SUPPORTED_NO_FIELDS", "condition": "Marks a metric computable without naming its source fields", "machine_checkable": true, "how_checked": "source_fields is conditionally required where the verdict is computable."}, {"ref": "GEA-P19-D3", "code": "COUNT_CHECK", "condition": "Drops an inapplicable metric without saying so", "machine_checkable": true, "how_checked": "Sixteen entries required across metrics[] and inapplicable[]."}]'::jsonb,
   '3.5', 'GA', 'draft'),
  ('GEA-P20', '0.1', 'Priority intervention identification', 'Reduce forty scores to three interventions and one sentence.', 'The completed scorecard. The handoff scores. The analysis outputs from Stage 2.',
   'Using the completed scorecard and the Stage 2 analysis, identify the three priority interventions and the single biggest opportunity in this revenue system.

Rank by consequence rather than by score alone. Weight four things: the score itself; the number of downstream elements that depend on it; whether it is a stage or a join, since a weak join taxes every stage downstream of it and is owned by nobody; and the size of the consequence as actually evidenced in the Stage 2 analysis rather than as asserted.

For each of the three, state: the elements it addresses with their scores; what is currently happening, in evidence; what it is costing, using a figure from the analysis where one exists; and what would be true instead.

Then state the single biggest opportunity in one sentence, and give the evidence for it in no more than three more.

Recommend nothing that is not traceable to a scored element. Do not include an intervention because it is a service Blend sells. If the system is broadly sound and needs one intervention rather than three, say that instead.

Output in markdown.',
   null, 'model',
   '{"interventions[]": {"type": "array", "required": true, "notes": "exactly three: title, description, element_refs[], consequence, downstream_stages_taxed[], value_rating, effort_rating, rank"}}'::jsonb,
   '[{"ref": "GEA-P20-D1", "code": "ELEMENT_REQUIRED", "condition": "Recommends something with no scored element behind it", "machine_checkable": true, "how_checked": "element_refs is required and must resolve to scored elements."}, {"ref": "GEA-P20-D2", "code": "RANK_BY_SCORE", "condition": "Ranks purely by lowest score", "machine_checkable": true, "how_checked": "Rank order is compared to score order; an exact match fails and asks for the dependency logic."}, {"ref": "GEA-P20-D3", "code": "PADDING", "condition": "Pads to three when the evidence supports one", "machine_checkable": false, "how_checked": "Reviewer confirms each of the three has evidence behind it rather than filling a quota."}]'::jsonb,
   '3.6', 'GC', 'draft'),
  ('GEA-P21', '0.1', 'Roadmap sequencing by value and dependency', 'Produce the Growth Engineering Roadmap.', 'The frozen scorecard. The three priority interventions from GEA-P20. Any client migration or platform programme timeline. Any incumbent supplier scope.',
   'Produce a sequenced Growth Engineering Roadmap from the frozen scorecard and the priority interventions.

Four sequencing rules override score order. Where the assessment found the measurement spine missing or implemented in a way that does not support the full lifecycle, that foundation work comes first or runs alongside everything else; it is enabling work and not one of the six transformation projects. Messaging work precedes any scaling of distribution. A governed record precedes any orchestration that reads from it. Nothing that depends on CRM data quality is sequenced ahead of the data work it depends on.

Map each recommendation to one of the six transformation projects: Market Resonance for stages 01 and 02; Demand Generation for 03 and 04; Frictionless Commerce for 04 and 05; Predictive Customer Success for 05 and 06; Advocacy-to-Revenue Loop for 06 and 07; Lifecycle Expansion for 07 and 08. Each project spans two adjacent stages by design, because it has to own the handoff between them.

Propose no more than three projects for the first twelve months. For each give: the elements it addresses with their scores; the dependency that fixes its position in the sequence; an indicative duration; the resourcing shape; and what becomes measurable when it lands.

Then state explicitly where the sequence has been shaped by the client''s existing migration timeline or by an incumbent supplier''s scope.

Do not propose all six projects. Do not sequence by score order alone. Output in markdown.',
   null, 'model',
   '{"projects[]": {"type": "array", "required": true, "notes": "maximum three: project_name from the six, stages[], element_refs[] with scores, dependency, duration_weeks, resourcing_shape, becomes_measurable, owner_side"}, "foundation_work": {"type": "object", "required": true, "notes": "measurement spine work, returned separately from the six"}, "constraints_shaping_sequence[]": {"type": "array", "required": true, "notes": "client migration or incumbent supplier scope"}}'::jsonb,
   '[{"ref": "GEA-P21-D1", "code": "PROJECT_CEILING", "condition": "Proposes more than three projects", "machine_checkable": true, "how_checked": "More than three projects fails."}, {"ref": "GEA-P21-D2", "code": "SEQUENCE_BY_SCORE", "condition": "Sequences by score", "machine_checkable": true, "how_checked": "Sequence order is compared to score order; an exact match fails."}, {"ref": "GEA-P21-D3", "code": "DEPENDENCY_REQUIRED", "condition": "Positions an item without naming the dependency that fixes it there", "machine_checkable": true, "how_checked": "dependency is required on every project."}]'::jsonb,
   '4.1', 'GC, GA', 'draft'),
  ('GEA-P22', '0.1', 'Growth Effectiveness Report draft', 'Draft the report body from the frozen workbook.', 'The frozen scorecard with citations. All Stage 2 analysis outputs. The priority interventions. The ICP Reconciliation result.',
   'Draft the Growth Effectiveness Report from the uploaded frozen scorecard and analysis outputs.

Structure it as: the two headline figures and what they mean; the three priority interventions; the single biggest opportunity; then one section per stage covering its five elements; then the limitations section.

For each element give the score, what the evidence showed, and the citation. Write what was found, not what should be done: recommendations live in the roadmap, not here.

State scores against the instrument''s defined standard. Do not compare the client to a peer group, an industry average, or a benchmark of any kind. There is no benchmark.

The limitations section must name every element scored NE, every element capped by a data condition, and every element carrying low confidence, each with the reason. Do not bury this or soften it.

Where the client''s stated position and their own data disagree, state both and say which the data supports. Do not resolve it in the client''s favour.

Quote nothing longer than fifteen words from any client document. Output in markdown, ready to be built into the Blend branded Word template.',
   null, 'model',
   '{"sections[]": {"type": "array", "required": true, "notes": "per the Deliverable Kit D1 structure"}, "element_findings[]": {"type": "array", "required": true, "notes": "all 48: element_ref, score, what_evidence_showed, citation, cap and cap_reason where capped"}, "limitations[]": {"type": "array", "required": true, "notes": "element_ref, kind, reason. Must reconcile with the scorecard"}}'::jsonb,
   '[{"ref": "GEA-P22-D1", "code": "NO_BENCHMARK", "condition": "Includes a benchmark comparison", "machine_checkable": false, "how_checked": "Reviewer confirms no comparison to a peer group or industry appears. Term matching assists but does not decide."}, {"ref": "GEA-P22-D2", "code": "FINDINGS_ONLY", "condition": "Mixes recommendations into the findings", "machine_checkable": true, "how_checked": "Recommendation language in element_findings fails the prose standard check."}, {"ref": "GEA-P22-D3", "code": "LIMITATIONS_RECONCILE", "condition": "Softens the limitations section", "machine_checkable": true, "how_checked": "limitations[] must reconcile with every NE, cap and low-confidence flag on the scorecard."}]'::jsonb,
   '4.2', 'GC', 'draft'),
  ('GEA-P23', '0.1', 'Handoff Integrity Map annexe', 'Draft the eight-page annexe carried inside the report.', 'The eight handoff scores with citations. The handoff evidence from step 2.5. The GEA-P15 output.',
   'Draft the Handoff Integrity Map from the uploaded handoff scores and evidence. One page per join, eight in total.

For each join give four things and nothing else: what should travel; what currently travels, in evidence; what is being lost, stated as a consequence rather than as a gap; and who should own it, named as a role rather than a person.

Include the score and the citation. Where the evidence came from a retrievability test, say what was actually produced when asked, since that is more telling than any description of the process.

Give H08, the loop from Expansion back into Product-market fit, the same weight as the others. It is the join most often neglected because it does not move a deal forward, and it is the one that decides whether the company gets sharper or drifts.

Do not recommend a fix. This annexe describes the join. Output in markdown, one section per join.',
   null, 'model',
   '{"joins[]": {"type": "array", "required": true, "notes": "exactly eight: handoff_ref, should_travel, currently_travels, being_lost as consequence, owner_role, score, citation, retrievability_observation where one exists"}}'::jsonb,
   '[{"ref": "GEA-P23-D1", "code": "FINDINGS_ONLY", "condition": "Recommends fixes", "machine_checkable": true, "how_checked": "Recommendation language in a join entry fails the prose standard check."}, {"ref": "GEA-P23-D2", "code": "CONSEQUENCE_REQUIRED", "condition": "Describes a gap without its consequence", "machine_checkable": true, "how_checked": "being_lost must be expressed as a consequence; a bare gap statement fails."}, {"ref": "GEA-P23-D3", "code": "JOIN_COUNT", "condition": "Treats H08 as an afterthought", "machine_checkable": true, "how_checked": "Exactly eight joins required, and H08 must meet the same minimum content as the others."}]'::jsonb,
   '4.2', 'GC', 'draft'),
  ('GEA-P24', '0.1', 'Executive readout deck', 'Turn the report into a ninety-minute session that produces decisions.', 'The report draft. The roadmap. The priority interventions. The TCO model.',
   'Draft the executive readout deck for a ninety-minute session with the client''s leadership team.

Structure it around the decisions in front of them rather than around the forty scores. Open with the two headline figures and the single biggest opportunity. Then the three priority interventions with their evidenced consequences. Then the sequenced roadmap and the dependency logic behind the order. Then the cost of ownership position. Then the decisions arising, each stated as a question with a named owner.

Show element detail only where it carries a decision. Forty scores on a slide is a document, not a session.

Where a finding will be uncomfortable, state it plainly and early rather than late and hedged. An honest assessment surfaces things that are nobody''s fault and everybody''s problem, and the sponsor has already been told that is the point.

Include no benchmark comparison. Include no service pitch: the roadmap is the client''s to execute with Blend, with their own team, or with someone else.

For each slide give a headline, the three or four points on it, and one line of speaker note on what it is for. Output in markdown, ready to be built into the Blend branded deck template.',
   null, 'model',
   '{"slides[]": {"type": "array", "required": true, "notes": "number, headline, points[] of three or four, speaker_note, decision_ref where carried"}, "decisions[]": {"type": "array", "required": true, "notes": "question and owner. Owner required"}}'::jsonb,
   '[{"ref": "GEA-P24-D1", "code": "DECISION_DRIVEN", "condition": "Restates the report rather than driving decisions", "machine_checkable": false, "how_checked": "Reviewer confirms the deck drives decisions rather than restating the report."}, {"ref": "GEA-P24-D2", "code": "FINDING_PLACEMENT", "condition": "Buries an uncomfortable finding", "machine_checkable": true, "how_checked": "A finding flagged uncomfortable may not appear after slide fifteen."}, {"ref": "GEA-P24-D3", "code": "NO_SERVICE_PITCH", "condition": "Drifts into selling the transformation projects", "machine_checkable": false, "how_checked": "Reviewer confirms no slide describes a Blend service."}]'::jsonb,
   '4.3', 'GC', 'draft'),
  ('GEA-P25', '0.1', 'Benchmark library record', 'Record the engagement in a fixed structure so a segment benchmark becomes possible once enough exist.', 'The frozen scorecard. The engagement metadata: segment, revenue band, employee count, motion, stack, sponsor type.',
   'Produce the standard library record for this completed assessment.

Include: engagement identifier; segment; revenue band; employee count band; whether sponsor-backed; primary stack; the single revenue motion assessed; evaluation window; the evidence tier established for the five tier-dependent elements; the count of elements marked NE; the count carrying low confidence.

Then all forty element scores and all eight handoff scores as a flat list of id and score, plus the two headline figures.

Then the ICP variance rate, the note sufficiency verdict, and the three priority interventions as element ids rather than as prose.

Include no client name and no identifying detail. This record exists to be aggregated, so it must be anonymous and structurally identical to every other one.

Output as a single flat table of field and value.',
   null, 'compute',
   '{"library_record": {"type": "object", "required": true, "notes": "projection of frozen scores, metrics, tier, variance rate and segment attributes"}, "contains_identifiable_data": {"type": "boolean", "required": true, "notes": "validated false on write"}}'::jsonb,
   '[{"ref": "GEA-P25-D1", "code": "IDENTIFIABLE_DATA", "condition": "Includes a client name or identifying detail", "machine_checkable": true, "how_checked": "contains_identifiable_data must be false, validated on write."}, {"ref": "GEA-P25-D2", "code": "STRUCTURE_FIXED", "condition": "Varies the structure from the standard record.\n\nPage", "machine_checkable": true, "how_checked": "The record must match the standard library schema exactly."}]'::jsonb,
   '4.7', 'GA', 'draft');

insert into measurement_definition_template (instrument_version_id, metric_key,
  name, definition, formula, required_fields, owning_function, cadence, lag,
  why_it_matters, computability_note) values
  ('0f6a0006-0000-4000-8000-000000000006', 'M01', 'ICP fit rate of won revenue', 'The share of closed-won revenue coming from accounts that match the stated ICP on every criterion.',
   'Closed-won revenue from ICP-matching accounts / total closed-won revenue in the period', array['opportunity_status','opportunity_amount','opportunity_account_id','opportunity_close_date','account_industry','account_employee_count','account_country']::text[], 'RevOps',
   'Quarterly', 'one_sales_cycle',
   'The gap between who the company says it sells to and who actually buys. Everything downstream inherits this answer.', 'Requires firmographics populated on accounts. Where industry or employee count is sparse, enrich before computing rather than excluding the blanks.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'M02', 'Self-originated qualified pipeline', 'Qualified pipeline created in the period from accounts that initiated contact, as a share of all qualified pipeline created, reported alongside the absolute value.',
   'Value of new-business qualified opportunities created in period with a self-originated source / total value of new-business qualified opportunities created in period', array['qualified_at','opportunity_amount','opportunity_type','channel_source','contact_original_source','opportunity_account_id']::text[], 'Marketing',
   'Monthly', 'one_quarter',
   'Messaging''s job is to make the right buyers raise their hand and to put sales on the field against real opportunities. Pipeline that comes to you is the cleanest read on whether the story cut through; pipeline that sales had to go and get measures prospecting effort instead. Measured as created pipeline, not leads, clicks, or closed revenue: messaging''s responsibility ends when the opportunity is real and qualified.', 'Requires a source taxonomy on the opportunity that can be split into self-originated and prospected, and the client''s own written qualification definition to fix the point at which pipeline counts as created. Where no qualification definition exists the metric is not computable and the gap is a finding against element 4.5. Renewal and expansion opportunities are excluded. Pipeline is counted in the period it was created and never restated later. Report the absolute value beside the rate, so a collapse in outbound cannot present as a messaging improvement.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'M03', 'Cost per qualified opportunity by channel', 'Fully loaded channel spend divided by qualified opportunities attributed to that channel.',
   'Channel spend in period / qualified opportunities with that channel as source', array['spend_channel','spend_month','spend_amount','qualified_at','channel_source']::text[], 'Marketing',
   'Monthly', 'one_quarter',
   'Whether budget allocation is evidenced or inherited. The denominator must be qualified opportunities, not leads.', 'Requires actual spend by channel and month, and source attribution surviving onto the opportunity. Spend from a finance ledger rather than a platform dashboard.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'M04', 'Signal to first contact, median', 'Median elapsed time from a high-intent form submission to the first human contact attempt.',
   'Median of (first contact timestamp - form submission timestamp) across high-intent submissions', array['form_submission_at','form_name','form_submission_contact_id','first_contact_at']::text[], 'Sales',
   'Monthly', 'immediate',
   'The single most recoverable conversion loss in most businesses, and one of the few metrics where the fix is operational rather than strategic.', 'Requires the form list to distinguish high-intent from low-intent submissions. Measure in hours, not days.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'M05', 'Forecast accuracy', 'Absolute variance between the submitted forecast and the actual closed amount for the period.',
   '1 - (absolute value of (forecast amount - actual amount) / actual amount)', array['forecast_period','forecast_submitted_at','forecast_amount','forecast_actual_amount']::text[], 'Sales leadership',
   'Monthly', 'one_sales_cycle',
   'A proxy for management quality. A team that cannot forecast cannot be coached against a plan.', 'Requires forecast submissions retained as history. CRMs overwrite the current forecast value by default, so where no snapshot exists the metric cannot be computed retrospectively and a snapshot job must be put in place before it can be.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'M06', 'Time to first value, median', 'Median elapsed days from contract start to the customer reaching the defined first value point.',
   'Median of (first value timestamp - contract start date) across customers onboarded in the period', array['contract_start_date','first_value_at','first_value_definition']::text[], 'Customer Success',
   'Monthly', 'one_onboarding_cycle',
   'The most reliable early predictor of retention. Requires a governed definition of first value, not an inferred one.', 'Requires a written, owned definition of first value. Where none exists the metric is not computable and element 6.2 caps at 1.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'M07', 'Referral-sourced opportunity share', 'The share of new opportunities whose source is a customer referral or advocacy action.',
   'New opportunities with a referral source / all new opportunities in the period', array['referral_source','opportunity_created_at','opportunity_type']::text[], 'Marketing',
   'Quarterly', 'one_quarter',
   'Referral-sourced pipeline is the highest-quality revenue most businesses have and the least deliberately generated.', 'Requires referral source captured as a distinct value rather than collapsed into word of mouth or other.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'M08', 'Net revenue retention', 'Revenue retained and expanded from the existing customer base over the period.',
   '(Starting ARR + expansion - downgrade - churn) / starting ARR', array['subscription_account_id','arr_amount','expansion_amount','renewal_outcome','contract_start_date','contract_end_date']::text[], 'Finance with RevOps',
   'Quarterly', 'one_renewal_cycle',
   'The cleanest single read on whether the product delivers and the account team works. Reported alongside gross retention, never instead of it.', 'Requires expansion distinguishable from new business at the record level. Report gross retention beside it so expansion cannot mask churn.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'H01R', 'Evidenced ICP into messaging coverage', 'The share of priority segments that have a current, published persona message set traceable to the evidenced ICP.',
   'Priority segments with a current persona message set / all priority segments', array['account_segment']::text[], 'Marketing',
   'Quarterly', 'immediate',
   'Tests whether the ICP evidence actually reached the people writing the messaging, rather than sitting in a deck.', 'Requires a content inventory with segment tagging and a review date. Rarely in the CRM; usually a marketing operations artefact.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'H02R', 'Proof-supported channel coverage', 'The share of active distribution channels carrying current, approved proof assets.',
   'Active channels with current approved proof assets / all active channels', array['spend_channel']::text[], 'Marketing',
   'Quarterly', 'immediate',
   'Distribution scaled ahead of proof buys more of the wrong conversations.', 'Requires a content inventory with approval status and last-reviewed date, joined to the channel list from spend.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'H03R', 'Reach to identified contact rate', 'The share of sessions that convert into an identified contact with retained context.',
   'New identified contacts in period / sessions in period', array['sessions_count','contact_created_at']::text[], 'Marketing',
   'Monthly', 'immediate',
   'Reach that never becomes identified attention is spend that cannot be followed up.', 'Requires web analytics joinable to contact creation. Where the analytics platform and the CRM cannot be joined, report the two series separately and say so.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'H04R', 'Qualified to accepted opportunity rate', 'The share of qualified records passed to sales that sales accepts as opportunities.',
   'Opportunities created from qualified records / qualified records passed in the period', array['lifecycle_transition_at','lifecycle_transition_to','form_submission_to_opportunity','opportunity_id','qualified_at']::text[], 'RevOps',
   'Monthly', 'one_quarter',
   'The join where the marketing-to-sales agreement either holds or is quietly ignored. A low rate is a definition problem, not an effort problem.', 'Requires lifecycle transition dates retained and a traceable link from the qualified record to the opportunity. Where the link is missing, element 4.1 caps at 2.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'H05R', 'Won to onboarding started within SLA', 'The share of won deals where onboarding started within the agreed time of contract start.',
   'Won deals with onboarding started within SLA / all won deals in the period', array['opportunity_status','opportunity_close_date','contract_start_date','usage_milestone','usage_event_at']::text[], 'Customer Success',
   'Monthly', 'one_quarter',
   'What was sold reaching what gets delivered. Delay here shows up as churn two quarters later.', 'Requires an onboarding start event with a timestamp, and a stated SLA. Delivery milestones substitute where product telemetry does not exist.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'H06R', 'Value delivered to proof captured rate', 'The share of customers reaching first value who then produce a captured proof point.',
   'Customers with a captured proof point / customers reaching first value in the period', array['first_value_at','nps_responded_at','nps_followup_recorded']::text[], 'Customer Success',
   'Quarterly', 'one_onboarding_cycle',
   'Most businesses have more satisfied customers than captured proof. This measures the gap.', 'Requires proof capture recorded against the account, not held in a marketing folder. Survey responses alone are not proof capture unless followed up.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'H07R', 'Advocacy to commercial opening rate', 'The share of advocacy events that produce a specific, owned commercial opening.',
   'Advocacy events producing a referral or expansion opportunity / all advocacy events in the period', array['nps_followup_recorded','referral_source','opportunity_type','opportunity_created_at']::text[], 'Sales with Customer Success',
   'Quarterly', 'one_sales_cycle',
   'Advocacy that produces goodwill but no opening is a cost centre. This is the join that decides otherwise.', 'Requires advocacy events to exist as records with outcomes attached. Where advocacy is handled through relationships rather than recorded events, there is nothing to count and the metric is specified rather than computed.'),
  ('0f6a0006-0000-4000-8000-000000000006', 'H08R', 'Renewal evidence into ICP review rate', 'The share of renewal and churn decisions reviewed in a documented update to the ICP or segment priorities.',
   'Renewal and churn outcomes reviewed in a documented ICP update / all renewal and churn decisions in the period', array['renewal_outcome','non_renewal_reason','renewal_date']::text[], 'RevOps with the executive sponsor',
   'Quarterly', 'one_renewal_cycle',
   'The loop that decides whether the company gets sharper or drifts. Neglected because it does not move a deal forward.', 'Requires a governed ICP review with a cadence and an owner. Where no such review exists the metric is not computable, and that is itself the finding.');
