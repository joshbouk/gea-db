-- 073 v0.12: an export line becomes a question somebody can answer.
--
-- The lines were named after where data sits in an imagined CRM rather than
-- after what we need to know. "Every custom object holding customer data"
-- is a sentence about Salesforce metadata, and a consultant who has used
-- CRMs for twenty years could not tell what it was asking for. What it
-- wants is: what does each customer pay, when does the term end, and did
-- they renew. That might be a Contract, an Order, a custom object, or
-- Zuora, Chargebee or NetSuite — and once the question is asked plainly,
-- anybody knows where to look.
--
-- Three changes.
--
--   Every line is a question, and carries the steps for each place the
--   answer might be. Three sources, not two: spend sits in ad platforms
--   and finance, sessions sit in analytics, subscriptions sit in billing.
--   Writing everything as a CRM export is why half of this felt
--   impossible.
--
--   Every line says what usually goes wrong and what is lost without it.
--   Fourteen of them only cap a score when missing, and a consultant
--   deciding how hard to chase something needs to know which.
--
--   Five lines go. T1-09 asked for a list of the fields in each object,
--   which the parser reports for every file it reads — we were asking for
--   a description of the thing we were about to receive. T3-03, T3-04,
--   T3-07 and T3-10 are content inventories, nurture programmes, case
--   study lists and account plans: documents that nothing automated reads
--   and that arrive through an interview, not an export.

alter table export_line
  add column question text,
  add column found_in text,
  add column minutes integer,
  add column importance text,
  add column elsewhere_guidance text,
  add column usually_goes_wrong text,
  add column without_it text;

comment on column export_line.question is
  'What we need to know, in words a person can act on. Replaces a title '
  'naming an object in a system the client may not have.';
comment on column export_line.found_in is
  'Where the answer lives: crm, analytics, finance, product, or mixed. '
  'The request screen groups by this, because a consultant works through '
  'one system at a time rather than one tier at a time.';
comment on column export_line.without_it is
  'What is lost, and the cap where there is one. Fourteen lines only cap a '
  'score when missing, which is a different conversation from the ones '
  'that remove an analysis outright.';

do $$
declare v_old uuid; v_new uuid; v_msg record; n integer;
begin
  if exists (select 1 from instrument_version where label = 'v0.12') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.11';
  v_new := gea_clone_instrument(v_old, 'v0.12');

  update instrument_version
     set notes = 'Export lines are questions with per-system instructions. '
                 'Five lines removed: one redundant, four that are '
                 'documents rather than exports.'
   where id = v_new;

  -- The field list the parser already produces for every file it reads.
  delete from export_line where instrument_version_id = v_new and ref = 'T1-09';

  -- Documents, not exports. The requirements that named them become
  -- client documents, which is how they actually arrive.
  update evidence_requirement
     set source_kind = 'client_document',
         export_line_refs = (select coalesce(array_agg(x), array[]::text[])
                               from unnest(export_line_refs) x
                              where x not in ('T3-03','T3-04','T3-07','T3-10'))
   where instrument_version_id = v_new
     and export_line_refs && array['T3-03','T3-04','T3-07','T3-10'];

  delete from export_line
   where instrument_version_id = v_new
     and ref in ('T3-03','T3-04','T3-07','T3-10');

  -- Those four lines were the only export covering five elements, so
  -- without this they become unevidenceable and the activation gate
  -- refuses the version. It is right to: an element with no route to
  -- evidence cannot be scored. They are scored from client documents and
  -- interviews now, which is what the flag means.
  update element set scored_without_export = true
   where instrument_version_id = v_new
     and ref in ('2.3', '4.4', '7.2', '7.4', '8.5');

  insert into element_version_change (from_instrument_version_id,
                                      to_instrument_version_id, element_ref,
                                      change_type, note)
  select v_old, v_new, r, 'wording',
         'Evidence now arrives as a client document rather than an export. '
         'Nothing about what is measured or where the anchors sit has '
         'changed, so a score given under v0.11 still stands.'
    from unnest(array['2.3','4.4','7.2','7.4','8.5']) r;

  with content (ref, question, found_in, minutes, importance,
                hubspot, salesforce, elsewhere, goes_wrong, without_it) as (values
    ('T1-01', 'What were the deals, and what happened to them?', 'crm', 15, 'high',
     'Deals. Export all properties, all pipelines. Tick the box to include all deal properties rather than the visible columns.',
     'Reports, then a new Opportunity report. Salesforce caps a report at around a hundred columns, which most clients exceed, so export it in two passes: Opportunity ID plus the first half of the fields, then Opportunity ID plus the rest. Upload both and they will be joined on the ID. Include every record type.',
     null,
     'A report filtered to one record type, or to closed deals only, which hides the live pipeline. Also the column cap, which silently truncates a Salesforce report rather than warning you.',
     'There is no assessment. Eleven of the thirteen analyses read this file.'),
    ('T1-02', 'Who are the customers and prospects, and what are they like?', 'crm', 10, 'high',
     'Companies. All properties.',
     'Accounts. All fields, including Parent Account for group structures. Same column cap applies; split on Account ID if needed.',
     null,
     'Exporting only accounts that have a deal. The accounts with nothing on them are the white space picture and are part of the finding.',
     'Every firmographic cut goes: who actually buys, win rates by segment, concentration. Seven analyses.'),
    ('T1-03', 'Who are the people, and when did each of them arrive?', 'crm', 10, 'high',
     'Contacts. All properties. Filter to contacts associated with a deal in the window, plus anyone handed to sales in the window.',
     'Contacts. All fields. Filter the same way.',
     null,
     'Dumping the whole marketing database. Fifty thousand newsletter subscribers tell us nothing and make everything slower.',
     'The population base goes, so the share of the database that never engaged cannot be measured.'),
    ('T1-04', 'What products and prices were on each deal?', 'crm', 10, 'medium',
     'Line items. Export line items associated with deals, including the deal ID.',
     'Opportunity Products. A report on Opportunity Line Items, including Opportunity ID, Product, Quantity, Sales Price and List Price.',
     null,
     'Forgetting to include the opportunity ID, which leaves the line items unattachable to anything.',
     'Pricing and discount dispersion cannot be measured. One analysis.'),
    ('T1-05', 'What was quoted, and how often did it change?', 'crm', 10, 'low',
     'Quotes, if the Quotes tool is in use. Many clients do not use it; say so rather than hunting.',
     'Quotes. Include Opportunity ID, Status, and the quote line items if quoting is used seriously.',
     'Often in a separate CPQ tool, or in nothing at all. If quotes live in Word documents, that is the finding.',
     'Searching for a quoting process that does not exist. Absence here is an answer.',
     'One element loses its evidence. No analysis depends on it.'),
    ('T1-06', 'What do customers raise after they buy?', 'crm', 10, 'low',
     'Tickets. All properties.',
     'Cases. All fields, including Account ID and the created and closed dates.',
     'Often Zendesk, Intercom, Jira Service Management or Freshdesk rather than the CRM.',
     'Assuming support lives in the CRM. For most clients it does not.',
     'One element loses its evidence. No analysis depends on it.'),
    ('T1-07', 'What does each customer pay, when does the term end, and did they renew?', 'mixed', 30, 'high',
     'Usually a custom object. Check the object list under Data Management for anything named Subscription, Contract or Renewal. If there is none, the answer is in the billing system.',
     'Usually Contract or Order, or a custom object named Subscription. Look in Object Manager for anything holding a recurring amount and a term end date.',
     'Often not in the CRM at all. Zuora, Chargebee, Recurly, NetSuite, Stripe or a finance spreadsheet are all common. Ask finance where renewals are tracked and who owns the number.',
     'Looking only in the CRM and concluding it does not exist. Ask finance before deciding it is unavailable.',
     'Renewal timing, expansion and time to first value cannot be measured. Caps 6.2 at 2 and 7.3 at 1.'),
    ('T1-08', 'Who was involved in each deal, and in what capacity?', 'crm', 10, 'high',
     'Not a separate export. Deals, with associated contacts and their association labels included.',
     'Opportunity Contact Roles. A report on the Opportunity Contact Role object, with Opportunity ID, Contact ID, Role and Primary.',
     null,
     'In HubSpot, looking for an object that does not exist. In Salesforce, finding the object empty because nobody fills it in, which is itself the finding.',
     'The buying group cannot be reconstructed. Caps 2.2 at 3 and 5.3 at 2.'),
    ('T1-10', 'Who arrived and never became a contact?', 'crm', 10, 'medium',
     'Not applicable. HubSpot has one person object, so an unconverted lead is a contact. Mark this line absent.',
     'Leads. All fields, including Converted, Converted Date and Converted Contact ID. Include leads that were never converted: they are most of them.',
     null,
     'Filtering to converted leads, which is the opposite of the point.',
     'Response time is measured only on the people who converted, which flatters it.'),
    ('T2-01', 'How did deals move through the pipeline, and how long did each stage take?', 'crm', 15, 'high',
     'No history export needed. The pipeline creates a Date entered <stage> property for every stage, and those are ordinary deal properties. Include them in the deals export.',
     'Opportunity Field History, or the Opportunity History object. A report on Opportunity History with Opportunity ID, Stage, and the change date. It exists by default and retains eighteen months unless the retention setting was changed.',
     null,
     'Assuming stage history has to be reconstructed by hand. In both systems it is already there.',
     'Conversion and velocity by stage cannot be measured. Caps 5.1 at 3.'),
    ('T2-02', 'When did each person move between lifecycle stages?', 'crm', 15, 'medium',
     'Contacts, including the Became a <stage> date properties. They are standard and exportable alongside everything else.',
     'Lead Status history, and Converted Date on Lead. Where status history is not tracked, say so rather than estimating.',
     null,
     'Exporting the current stage and not the dates. The dates are the whole point.',
     'The route from first touch to opportunity cannot be traced. Caps 4.1 and 4.3 at 2.'),
    ('T2-03', 'What contact actually happened, and when?', 'crm', 20, 'high',
     'Engagements. Calls, emails, meetings and tasks, with the associated contact and deal. Export each type and upload them together.',
     'Tasks and Events. A report on Activities with Subject, Type, Created Date, Who ID and What ID. Call logs from the dialler if calls are not logged in Salesforce.',
     'Call recordings and transcripts are usually in Gong, Chorus or the dialler rather than the CRM.',
     'Date-ranging too narrowly. Activity volume is large and the temptation is to cut it to a month, which breaks response-time measurement.',
     'Response time to a buyer raising their hand cannot be measured at all. Caps 4.3 and H03 at 2.'),
    ('T2-04', 'What did the salesperson write down about the conversation?', 'mixed', 20, 'high',
     'Notes. They are an engagement type, so they come out with the other engagements. Include the note body, not just the metadata.',
     'Notes are a separate object from Activities. Export ContentNote, or Task where the description field is used for call notes. Check which the team actually uses before exporting.',
     'Discovery notes often live in Gong, Notion or a shared drive rather than the CRM.',
     'Exporting note metadata without the body. A note with no text in it cannot be read.',
     'Two analyses go, and with them the evidence tier that caps five other elements.'),
    ('T2-05', 'How has each customer''s health changed over time?', 'mixed', 15, 'low',
     'A custom property on Company, if health is scored at all. The current value is usually all that exists.',
     'A custom field on Account, and its field history if tracking is switched on.',
     'Usually Gainsight, Catalyst, Vitally, ChurnZero or a spreadsheet. Ask customer success what they look at on a Monday.',
     'Finding only the current score. The history is what shows whether anyone acts on it.',
     'Whether health scores predict anything cannot be tested. Caps 6.4 at 3.'),
    ('T3-01', 'What was spent on marketing, by channel and by month?', 'finance', 30, 'high',
     'Campaigns hold a budget field, but almost nobody populates it. Do not rely on it.',
     'Campaigns, with Actual Cost, if campaigns are maintained. Usually they are not.',
     'The ad platforms themselves plus whatever finance has. Google Ads, LinkedIn, Meta, trade press and events. Finance can usually produce a spend-by-supplier extract that covers most of it. Twelve months minimum, by month.',
     'Accepting a total. Cost per qualified opportunity needs the split by channel, and a single annual figure answers nothing.',
     'Cost per qualified opportunity cannot be computed for any channel. Caps 3.1 at 2.'),
    ('T3-02', 'Who came to the website, and what did they do?', 'analytics', 20, 'medium',
     'Marketing Hub holds sessions by source and form submissions with the contact. Both export from the analytics tools.',
     'Not in Salesforce. Pardot or Account Engagement if they run it.',
     'GA4 for sessions, and whatever captures forms. HockeyStack, Dreamdata or similar if they run attribution. Form submissions with the contact who submitted are the part that matters most.',
     'Exporting aggregate session counts with no link to a person. Sessions nobody can tie to a contact answer nothing.',
     'Response time has no signal to measure from. Caps 4.1, 4.3 and H03 at 2.'),
    ('T3-05', 'When did each customer first get value, and how do we know?', 'product', 30, 'medium',
     'Rarely in HubSpot. A custom property on Company if someone has defined first value.',
     'Rarely in Salesforce. A custom field if someone has defined first value.',
     'Product telemetry, an onboarding tracker, or the professional services system. Often nothing records it, which is itself the finding at 6.2.',
     'Spending a week looking for something nobody has defined. Ask whether first value has a definition before hunting for the data.',
     'Time to first value cannot be measured. Caps 6.2 at 2.'),
    ('T3-06', 'What do customers say when asked, and what happens next?', 'mixed', 15, 'low',
     'Survey responses if Feedback Surveys are in use.',
     'A custom object or a field on Account, if NPS is recorded at all.',
     'Usually Delighted, SurveyMonkey, Typeform or Qualtrics. The follow-up actions matter more than the scores.',
     'Collecting scores without the follow-up. A detractor nobody contacted is the finding.',
     'Four requirements lose their evidence. No analysis depends on it.'),
    ('T3-08', 'What was forecast, and what actually happened?', 'mixed', 20, 'medium',
     'Forecast submissions are not retained by HubSpot. Whatever the team saved each month, usually a spreadsheet.',
     'Collaborative Forecasting holds submissions if it is switched on. Otherwise the saved snapshots the sales operations team keeps.',
     'Almost always a spreadsheet kept by sales operations or finance. Ask for the last eight quarters of submitted forecasts against actuals.',
     'Reconstructing a forecast from the current pipeline. That is not a forecast, it is today''s number with a date on it.',
     'Forecast accuracy and bias cannot be measured. Caps 5.5 at 1.'),
    ('T3-09', 'What does the revenue stack cost to own, all in?', 'finance', 45, 'high',
     'Not a CRM export.',
     'Not a CRM export.',
     'A finance conversation plus a contract list. Every system touching marketing, sales or customer success, with its annual cost, renewal date and licence count. Include the integration tooling and any contractor spend keeping it running, because that is where the real number hides.',
     'Collecting licence costs only. The stack costs what it costs to run, which includes the people whose job is making four systems agree.',
     'The stack cost of ownership model cannot be built. It is a contracted deliverable.')
  )
  update export_line el
     set question = c.question,
         title = c.question,
         found_in = c.found_in,
         minutes = c.minutes,
         importance = c.importance,
         hubspot_guidance = c.hubspot,
         salesforce_guidance = c.salesforce,
         elsewhere_guidance = c.elsewhere,
         usually_goes_wrong = c.goes_wrong,
         without_it = c.without_it
    from content c
   where el.instrument_version_id = v_new and el.ref = c.ref;
  get diagnostics n = row_count;
  raise notice 'v0.12: % export lines rewritten', n;

  for v_msg in select * from gea_activate_instrument('v0.12') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('073_instrument_v0_12_export_lines.sql',
   'v0.12: every export line is a question with instructions for each place '
   'the answer might be. Five lines removed.');
