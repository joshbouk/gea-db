-- 023 The methodology step catalogue.
--
-- Every task in an engagement is generated from this table. There is no
-- free-text task creation, so a step missing here is work that never appears
-- on anyone's board.
--
-- It is deliberately NOT tied to an instrument version. The runbook versions
-- independently of the scoring instrument — v0.3 of one against v0.6 of the
-- other — and an activated instrument is immutable. Tying process wording to
-- it would mean a new instrument version every time a sentence changed.
-- Tasks copy what they need at generation time, so an engagement's tasks are
-- fixed at setup whatever happens here afterwards.
--
-- Three changes from Runbook v0.3, agreed in review:
--
--   Setting up the engagement workbook is gone. The application is the
--   workbook, so the step disappears rather than becoming a task nobody can
--   complete.
--
--   Booking interviews and holding them are separate steps. Senior calendars
--   fill weeks ahead, so booking happens in week one with nothing blocking it,
--   while the sessions themselves wait for the analysis. The runbook collapsed
--   both into one step, which made the discipline impossible to follow.
--
--   The growth waterfall is a new step at the end of the evidence stage. It
--   models volume and conversion forward through every route to market, and
--   the priority interventions now depend on it.

create type step_precondition_kind as enum
  ('step', 'gate', 'export_tier', 'export_line', 'analysis');

create table methodology_step (
  id                     uuid primary key default gen_random_uuid(),
  runbook_version        text not null,
  ref                    text not null,
  stage                  smallint not null check (stage between 1 and 4),
  title                  text not null,
  purpose                text not null,
  exit_condition         text not null,
  task_type              task_type not null,
  owner_engagement_role  engagement_role not null,
  status_is_derived      boolean not null,
  derived_from           text,
  element_refs           text[],
  one_task_per           text,
  sort_order             integer not null,
  created_at             timestamptz not null default now(),
  unique (runbook_version, ref),
  -- RULE: a derived step says what decides it. Otherwise nobody knows whether
  -- to wait for the system or tick it themselves.
  constraint step_derived_names_its_source
    check (not status_is_derived
           or (derived_from is not null and length(btrim(derived_from)) > 0))
);

comment on table methodology_step is
  'The methodology steps every engagement task is generated from. Versioned by '
  'runbook label, independently of the scoring instrument.';

create table step_precondition (
  id                  uuid primary key default gen_random_uuid(),
  methodology_step_id uuid not null references methodology_step(id) on delete cascade,
  kind                step_precondition_kind not null,
  value               text,
  blocking_reason     text not null check (length(btrim(blocking_reason)) > 0),
  created_at          timestamptz not null default now(),
  unique (methodology_step_id, kind, value)
);

comment on column step_precondition.blocking_reason is
  'Shown to the consultant while the precondition is unmet. States the '
  'consequence, not the condition: "the deals export has not arrived, so stage '
  'conversion cannot be computed" rather than "missing data".';

do $$
declare t text;
begin
  foreach t in array array['methodology_step','step_precondition'] loop
    execute format('alter table %I enable row level security', t);
    execute format(
      'create policy %I on %I for select to authenticated using (app_is_blend_user())',
      t || '_read', t);
  end loop;
end $$;

-- The catalogue -------------------------------------------------------------

insert into methodology_step (runbook_version, ref, stage, title, purpose,
  exit_condition, task_type, owner_engagement_role, status_is_derived,
  derived_from, element_refs, one_task_per, sort_order) values

('v0.4','1.1',1,'Sponsor kickoff',
 'Ninety minutes with the sponsor to settle what is being assessed. Scope, the evaluation window and the eight people to interview all come out of this conversation, and everything afterwards depends on them. An unclear kickoff costs time in week three rather than week one.',
 'Scope, window, sponsor and the eight interviewees confirmed in writing.',
 'setup','lead_consultant',false,null,null,null,10),

('v0.4','1.2',1,'Issue the export request',
 'Exports take longer to arrive than anyone expects, and the time lost comes out of the analysis weeks rather than off the end of the engagement. Every line needs a named owner at the client and a date, or it sits.',
 'Every line has a client owner and a committed date.',
 'request','lead_consultant',true,'Every export line has an owner and a date',null,null,20),

('v0.4','1.3',1,'Book the interviews',
 'Eight sessions across five functions, in diaries during week one. Senior calendars fill weeks ahead, so booking cannot wait for the data to arrive even though the conversations themselves will. Finance is the one most often dropped, so book it first.',
 'Eight sessions in calendars before the end of week one.',
 'setup','lead_consultant',false,null,null,null,30),

('v0.4','1.4',1,'Check what the data can carry',
 'Work out what the client''s records can actually support before building analysis on them. Finding out in week three that loss reason is blank on most deals means three weeks of work resting on a field that cannot hold it. Fixing the population counts at the same time means every rate computed later reconciles with every other one.',
 'Gaps listed against the elements they affect, and fixed population counts.',
 'intake','lead_architect',true,'The parse and profile runs have been accepted',null,null,40),

('v0.4','1.5',1,'Confirm the quality of written evidence',
 'Five parts of the assessment can only be scored from what people wrote or said. This checks whether call recordings exist, or notes good enough to stand in for them, and records which. That decides the highest score those five can reach, so it is worth knowing in week one rather than week five.',
 'The evidence level recorded, with the coverage rate behind it.',
 'intake','lead_architect',true,'The note sufficiency analysis has been accepted and confirmed',
 '{2.5,5.2,6.1,H04,H05}',null,50),

('v0.4','2.1',2,'Structured analysis pass',
 'Most of the assessment is answerable from the client''s own records rather than from opinion. Running this before the interviews means every conversation starts from what the data already shows, which changes what people tell you.',
 'Every supported analysis complete, and anything unsupported recorded as such rather than attempted.',
 'analysis','lead_architect',true,'Every supported analysis run has been accepted',null,null,60),

('v0.4','2.2',2,'Compare who they sell to against who buys',
 'The client describes the customers they want. Their closed-won records describe the customers they get. Where the stated profile matches the accounts that churn rather than the ones that renew, that gap drives most of what follows.',
 'Variance rate computed. At or above 40 per cent the gap is written up as a named finding.',
 'analysis','lead_architect',true,'The reconciliation run has been accepted','{1.1,1.2}',null,70),

('v0.4','2.3',2,'Public surface audit',
 'What the client''s website, content and answer-engine presence say about them, and whether that matches the positioning the sponsor described. This needs nothing from the client, so it runs while exports are still arriving.',
 'Both audits complete, with the prompts and model versions recorded.',
 'analysis','lead_consultant',true,'The public surface and answer engine runs have been accepted',
 '{1.4,2.1,2.4,3.3}',null,80),

('v0.4','2.4',2,'Classify what people wrote',
 'Some parts of the assessment can only be evidenced by reading discovery notes and call records. Classifying at scale turns that into a census rather than a handful of examples, and hand-scoring a sample afterwards is what makes the resulting rate trustworthy.',
 'One validation pass done and recorded. Rates either trusted or downgraded.',
 'analysis','lead_architect',true,'The classification run has been accepted with a trusted validation set',
 '{2.5,5.2,H01,H02,H06}',null,90),

('v0.4','2.5',2,'Evidence the handoffs',
 'Handoffs between functions are owned by nobody, so nobody describes them accurately. Ask both sides what travels and you get two different answers, which is itself the finding.',
 'All eight joins evidenced from both sides, with the retrievability results recorded word for word.',
 'analysis','lead_consultant',false,null,
 '{H01,H02,H03,H04,H05,H06,H07,H08}',null,100),

('v0.4','2.6',2,'Hold the interviews',
 'Eight conversations that explain what the data already showed, surface the reasons behind it, and test whether a practice that exists on paper is real. They are not the evidence base. Arriving without having read the analysis wastes the hour asking for numbers already in hand.',
 'Eight interviews held and synthesised.',
 'interview','lead_consultant',true,'The interview synthesis has been accepted',null,'interview_guide',110),

('v0.4','2.7',2,'Provisional scoring',
 'Score everything that can be scored now and list by name what is still missing. Doing this at the end of week four leaves time to go back for the thin evidence. Doing it for the first time in week five does not.',
 'A provisional score on most elements, and a named list of what is still needed.',
 'scoring','lead_consultant',true,'Most elements carry a provisional score',null,null,120),

('v0.4','2.8',2,'Build the growth waterfall',
 'Model volume and conversion forward through every route to market, so the roadmap can argue about where to invest rather than only about what is weak. Where channel spend arrived, this carries cost and payback as well; where it did not, the volume model still stands and the gap is stated.',
 'A model covering every route to market in scope, with its assumptions stated separately from its figures.',
 'analysis','lead_architect',true,'The waterfall model has been generated and reviewed',null,null,130),

('v0.4','3.1',3,'Close the evidence gaps',
 'Work the list provisional scoring produced. This is the last point at which anything on it can still be obtained, and after it every remaining gap becomes a recorded limitation.',
 'Every gap closed or recorded as not evidenced, with the reason.',
 'review','lead_architect',true,'Every evidence requirement is satisfied or waived',null,null,140),

('v0.4','3.2',3,'Final scoring pass',
 'Score as a pair, against the written level descriptions rather than from memory of the engagement. A score awarded alone drifts toward what the consultant expected to find.',
 'Every element scored or marked not evidenced, each with a citation specific enough for a colleague to retrieve the same evidence.',
 'scoring','lead_consultant',true,'Every element is scored or marked not evidenced, with a citation',null,null,150),

('v0.4','3.3',3,'Internal challenge',
 'Someone argues against every score before the client sees it. The two worth catching are a four or five awarded on evidence that does not support it, and a zero awarded where nobody looked properly.',
 'Every challenge either defended with a citation or actioned.',
 'review','lead_consultant',true,'Every challenge has been dispositioned',null,null,160),

('v0.4','3.4',3,'Stack cost of ownership model',
 'The only deliverable carrying a number that goes straight into a plan. It is also the easiest to discredit, because a single invented figure makes a finance director distrust everything around it.',
 'A three-year model where every figure names its source document and every assumption is stated separately.',
 'deliverable','lead_architect',true,'Every cost line has a source document or is marked an open input',null,null,170),

('v0.4','3.5',3,'Measurement definition set',
 'Sixteen definitions the client runs on after Blend leaves, and what makes a re-score in twelve months comparable to this one. Most of it is standard; what varies is which of their fields each definition reads.',
 'Sixteen definitions, each with a source field, an owner and a cadence.',
 'deliverable','lead_architect',true,'Every definition names its source fields or its blocker',null,null,180),

('v0.4','3.6',3,'Choose the priority interventions',
 'Forty-eight scores are a diagnosis. Three interventions and one sentence about the biggest opportunity are a decision. Clients act on the second.',
 'Three interventions and one biggest-opportunity statement, each traceable to specific scores.',
 'scoring','lead_consultant',false,null,null,null,190),

('v0.4','3.7',3,'The honesty test',
 'Two questions answered in writing and not delegated: what would make this assessment wrong, and what have we recommended that we would not pay for ourselves. Blend promises to say so when a client needs one project rather than six, and this is where that promise is checked.',
 'Both answers recorded in the engagement file.',
 'review','lead_consultant',true,'Both answers are recorded',null,null,200),

('v0.4','3.8',3,'Freeze the scores',
 'Roadmap work has a way of reshaping the scores that produced it. Freezing first keeps the diagnosis independent of the recommendation.',
 'A dated frozen copy of the scorecard.',
 'review','lead_consultant',true,'The scorecard is frozen',null,null,210),

('v0.4','4.1',4,'Sequence the roadmap',
 'Sequence is where most of the value is decided. Scaling distribution against messaging that does not land buys more of the wrong conversations, and building expansion plays on a CRM nobody trusts builds on sand.',
 'A sequence where every item''s position is explained by a dependency rather than by preference.',
 'deliverable','lead_consultant',true,'Every roadmap item states its dependency',null,null,220),

('v0.4','4.2',4,'Draft the Growth Effectiveness Report',
 'The durable artefact. It gets forwarded to a board, quoted back in twelve months, and used as the baseline when the assessment is run again.',
 'A complete draft with the handoff annexe, every score cited, and no claim that cannot be traced back.',
 'deliverable','lead_consultant',true,'The report has been generated and reviewed',null,null,230),

('v0.4','4.3',4,'Build the executive readout',
 'Ninety minutes with a leadership team is where the engagement lands or does not. The deck exists to drive decisions in the room rather than to summarise the report.',
 'A deck that names the decisions arising.',
 'deliverable','lead_consultant',true,'The deck has been generated and reviewed',null,null,240),

('v0.4','4.4',4,'Sponsor review',
 'The sponsor should not meet a finding for the first time in front of their own leadership team. Reviewing first makes them an owner of the findings rather than a defendant.',
 'Sponsor has seen every finding, and consolidated written feedback has been requested.',
 'review','lead_consultant',false,null,null,null,250),

('v0.4','4.5',4,'Refinement round',
 'One round, actioned on consolidated feedback. Taking feedback piecemeal turns one round into four.',
 'One round actioned, with any change to a frozen score logged against the evidence that justified it.',
 'review','lead_consultant',true,'One refinement round has been actioned',null,null,260),

('v0.4','4.6',4,'Deliver the readout',
 'Deliver in person. The decisions arising are the point of the session, and they go to the sponsor in writing while the conversation is still fresh.',
 'Readout delivered, decisions recorded and sent to the sponsor within two working days.',
 'review','lead_consultant',false,null,null,null,270),

('v0.4','4.7',4,'Close out',
 'Commit this completed assessment to Blend''s repository for inclusion in same-client re-evaluations in future years and anonymised benchmarking.',
 'Engagement archived and the library record filed.',
 'closeout','lead_architect',true,'The library record has been filed',null,null,280);

-- Preconditions -------------------------------------------------------------
-- What each step waits for. The runbook states what a step produces, never
-- what it needs, so these are a judgement rather than a transcription.

insert into step_precondition (methodology_step_id, kind, value, blocking_reason)
select s.id, v.kind::step_precondition_kind, v.value, v.reason
  from (values
  ('1.2','step','1.1','The scope and window are agreed at kickoff, and they decide what the export request asks for.'),
  ('1.3','step','1.1','The eight interviewees are named at kickoff.'),
  ('1.4','export_tier','1','No client export has arrived yet. Work can start on the first one without waiting for the rest.'),
  ('1.5','export_line','T2-04','The notes and call records have not arrived, and they are what the evidence level is judged on.'),
  ('2.1','step','1.4','Field mapping is not confirmed. Analysis built on unmapped fields has to be rebuilt.'),
  ('2.1','gate','G1','Stage 1 has not closed. Analysis before it rests on evidence nobody has checked.'),
  ('2.2','step','1.4','Field mapping is not confirmed, so the customer profile fields cannot be read reliably.'),
  ('2.4','step','1.5','The quality of written evidence is not yet known, and it decides whether classifying is worth running at all.'),
  ('2.5','step','2.1','The structured analysis has not run, and the handoff check reads records it has already parsed.'),
  ('2.6','step','1.3','The session is not in a diary yet.'),
  ('2.6','step','2.1','The analysis has not run. Walking into an interview without it wastes the hour asking for numbers already in hand.'),
  ('2.7','step','2.1','The analysis has not run, so most elements have nothing to score against.'),
  ('2.7','step','2.6','The interviews have not happened, and they carry the evidence for the parts the data cannot reach.'),
  ('2.8','step','2.1','The conversion and volume figures come out of the structured analysis.'),
  ('3.1','step','2.7','Provisional scoring produces the gap list this step works.'),
  ('3.2','step','3.1','Evidence gaps are still open. Final scoring on a moving evidence base produces scores that move under challenge.'),
  ('3.2','gate','G2','Stage 2 has not closed.'),
  ('3.3','step','3.2','There is nothing to argue with until the scores are final.'),
  ('3.4','step','2.6','The cost lines come out of the finance conversation.'),
  ('3.5','step','1.4','A definition names the field it reads, so the mapping has to be confirmed first.'),
  ('3.6','step','3.3','The interventions follow scores that have survived challenge.'),
  ('3.6','step','2.8','The waterfall is what turns a weak score into an argument about where to invest.'),
  ('3.7','step','3.6','The test asks whether the recommendations are worth paying for, so the recommendations have to exist.'),
  ('3.8','step','3.7','The honesty test is not complete.'),
  ('3.8','gate','G3','The freeze gate has not passed.'),
  ('4.1','step','3.8','Freezing first keeps the diagnosis independent of the recommendation.'),
  ('4.2','step','4.1','The report carries the roadmap.'),
  ('4.2','step','3.4','The report carries the cost model.'),
  ('4.2','step','3.5','The report carries the measurement definitions.'),
  ('4.3','step','4.2','The deck follows the report so the two cannot disagree.'),
  ('4.4','step','4.3','There is nothing to walk the sponsor through yet.'),
  ('4.5','step','4.4','Consolidated feedback has not arrived.'),
  ('4.6','step','4.5','The refinement round has not been actioned.'),
  ('4.6','gate','G4','The release gate has not passed.'),
  ('4.7','step','4.6','The readout has not been delivered.'),
  ('4.7','gate','G5','The close-out gate has not passed.')
  ) as v(step_ref, kind, value, reason)
  join methodology_step s on s.ref = v.step_ref and s.runbook_version = 'v0.4';

insert into gea_migration (filename, note) values
  ('023_step_catalogue.sql',
   'The 28 methodology steps every task is generated from, with their '
   'preconditions. Versioned by runbook label rather than instrument version. '
   'Booking and holding interviews are separate; the growth waterfall is new; '
   'setting up the workbook is gone.');
