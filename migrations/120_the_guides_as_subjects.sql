-- 120 The guides as subjects.
--
-- 119 made room for topics. This fills them in, on a new instrument
-- version, because guides are instrument data and an active instrument
-- is immutable. A script that wrote them directly was refused, which is
-- the rule working.
--
-- Each guide becomes five subjects to establish, each with the minutes
-- it is worth and some ways into it. The old questions survive as those
-- ways in, which is what they were always good for.
--
-- Every line was read by the style checker in gea-service before it was
-- written here. It caught thirteen three-part lists on the first pass,
-- which is the tell it exists to catch, and they are gone.

-- The clone has to carry topics, or a later version loses every guide's
-- shape and nobody notices until a consultant opens one.
create or replace function gea_clone_instrument(p_from uuid, p_label text)
returns uuid
language plpgsql security definer set search_path = public as $fn$
declare v_new uuid;
begin
  v_new := gea_clone_instrument_body(p_from, p_label);

  insert into analysis_guidance (instrument_version_id, analysis_key,
                                 what_to_check, goes_wrong)
  select v_new, analysis_key, what_to_check, goes_wrong
    from analysis_guidance where instrument_version_id = p_from
  on conflict do nothing;

  insert into report_section (instrument_version_id, ref, title, sort_order,
                              purpose, reads, stage_code, asks, needed)
  select v_new, ref, title, sort_order, purpose, reads, stage_code, asks,
         needed
    from report_section where instrument_version_id = p_from
  on conflict do nothing;

  -- What each conversation has to establish, and the ways into it.
  insert into interview_topic (interview_guide_id, ref, title, establish,
                               minutes, sort_order)
  select ng.id, t.ref, t.title, t.establish, t.minutes, t.sort_order
    from interview_topic t
    join interview_guide og on og.id = t.interview_guide_id
    join interview_guide ng on ng.ref = og.ref
                           and ng.instrument_version_id = v_new
   where og.instrument_version_id = p_from
  on conflict do nothing;

  update interview_question nq
     set interview_topic_id = nt.id, is_a_way_in = oq.is_a_way_in
    from interview_question oq
    join interview_guide og on og.id = oq.interview_guide_id
    join interview_topic ot on ot.id = oq.interview_topic_id
    join interview_guide ng on ng.ref = og.ref
                           and ng.instrument_version_id = v_new
    join interview_topic nt on nt.interview_guide_id = ng.id
                           and nt.ref = ot.ref
   where og.instrument_version_id = p_from
     and nq.interview_guide_id = ng.id
     and nq.question_text = oq.question_text;

  return v_new;
end $fn$;

do $do$
declare
  v_from uuid; v_new uuid; v_guide uuid; v_topic uuid;
  r record; w text; n integer;
begin
  select id into v_from from instrument_version where status = 'active';
  v_new := gea_clone_instrument(v_from, 'v0.18');

  for r in
    select * from (values
      -- guide, ref, title, establish, minutes, ways in
      ('1','T1','Who the company is for',
       'Whether there is a definition of the right customer, where it came '
       'from, and whether anybody outside this room would say the same '
       'thing. A company that cannot say who it is for is telling you how '
       'its budget gets allocated.', 12,
       array['Who are your best customers, and what makes them that?',
             'Who would you rather not sell to?',
             'Where did that definition come from?']),
      ('1','T2','Why you win and lose',
       'What actually decides a deal, in their words, set against what the '
       'records say. Where the two disagree, the disagreement is the '
       'finding.', 10,
       array['Why do customers pick you?',
             'Who do you lose to, and what happens when you do?']),
      ('1','T3','How pricing and packaging got here',
       'Whether the shape of the price list was chosen or inherited, who '
       'can change it, and whether anyone has tested it against what the '
       'market will pay.', 12,
       array['How did the packaging end up the way it is?',
             'Who can approve a discount, and does that hold in practice?']),
      ('1','T4','What this person owns',
       'Where their authority starts and stops, and which decisions need '
       'somebody else. An assessment that does not know who can change a '
       'thing cannot say whether it will be changed.', 8,
       array['What do you own directly?',
             'What would you change if it were yours to change?']),
      ('1','T5','What would have to be true to change direction',
       'What evidence would move them, and what has been put in front of '
       'them before that did not. This tells you whether the roadmap will '
       'be read or filed.', 8,
       array['What would have to be true for you to change direction?',
             'What has been put to you before that you did not act on?']),

      ('2','T1','What the company says it does',
       'Whether there is one account of what the company does, where it is '
       'written down, and whether sales tells the same story. Ask for the '
       'words rather than the document.', 10,
       array['How do you describe what the company does?',
             'Does everyone say it the same way?',
             'Where does that live?']),
      ('2','T2','Who they write for',
       'Whether the people they write for were chosen from evidence or '
       'assembled from assumptions, and whether anyone has checked them '
       'against who actually buys.', 10,
       array['Who are you writing for?',
             'Where did those definitions come from?']),
      ('2','T3','What gets used as proof',
       'What a seller reaches for when a buyer asks for evidence, how long '
       'it takes to get, and what happens when there is nothing suitable.',
       8,
       array['What do you use for proof when a prospect asks?',
             'What happens when sales needs a reference tomorrow?']),
      ('2','T4','How the budget is split',
       'Whether the split across channels was derived from anything, and '
       'whether each channel has a job somebody can state. A marketing '
       'leader who can name each channel''s job has a portfolio. One who '
       'cannot has a collection of line items.', 12,
       array['Take me through why the budget is split the way it is.',
             'What job does each channel have?',
             'If paid stopped tomorrow, what reach would you still own?']),
      ('2','T5','What happens to someone who puts their hand up',
       'What happens between a person showing interest and a seller making '
       'contact, how long it takes, and who decides.', 10,
       array['What happens to a lead once marketing is done with it?',
             'How long before someone makes contact?']),

      ('3','T1','How the pipeline actually works',
       'Whether anything governs movement between stages, and how much of '
       'the outcome is the seller rather than the process. Where deals '
       'stall, and why. A leader who cannot say what makes a deal advance '
       'has told you the stages are descriptive.', 15,
       array['Walk me through the stages.',
             'What has to be true for a deal to move out of each one?',
             'Where do deals most often stall?',
             'How much spread is there between your best and weakest reps?']),
      ('3','T2','What a first conversation has to produce',
       'What a seller must find out early, where it is recorded, and '
       'whether anyone reads it. Then whether the buying process is '
       'understood before a proposal goes out.', 12,
       array['What does a rep have to establish on a first call?',
             'Where does that get recorded?',
             'On the last deal you won, who else had to agree?']),
      ('3','T3','From agreement to signature',
       'How long it takes to get a proposal out and a contract signed, and '
       'what fills that time. Ask them to account for it step by step '
       'rather than for an average.', 12,
       array['How long from the end of discovery until the buyer has a '
             'proposal?',
             'What is in that time?',
             'What slows contracting most often?']),
      ('3','T4','How the forecast is built',
       'Who builds it and from what. How often it holds, and what happens '
       'to a deal that should have closed. Whether anyone compares the '
       'call to the result.', 10,
       array['How is the forecast built, and by whom?',
             'When it is wrong, what is usually the cause?',
             'What do you do about a deal with a close date in the past?']),
      ('3','T5','What arrives from marketing',
       'Their definition of a lead worth working, what comes with one, and '
       'what happens to the rest. Their words, not the company''s.', 11,
       array['What is a qualified lead?',
             'What arrives with one, and is it enough to start a '
             'conversation?',
             'What proportion do you work, and what happens to the rest?']),

      ('4','T1','What the numbers rest on',
       'Which fields would survive a board meeting and which would not, and '
       'whether anyone has checked. Where a reported figure would change if '
       'it were computed another equally reasonable way, that is worth '
       'knowing before it reaches a slide.', 12,
       array['Which fields would you trust for a board number?',
             'Which would you not?',
             'Where does the number in the board pack come from?']),
      ('4','T2','What happens between a form and a phone call',
       'Every step between somebody putting their hand up and a seller '
       'making contact, including the ones nobody designed.', 10,
       array['Walk me through what happens between a form submission and a '
             'rep making contact.',
             'What decides who gets it?']),
      ('4','T3','Where the systems disagree',
       'Which facts have two versions, which system is believed, and how '
       'much work goes into keeping them in step.', 12,
       array['Which facts have two versions depending on who you ask?',
             'How much of your week goes on making two systems agree?']),
      ('4','T4','What the stack costs to run',
       'What is in the stack, and what breaks. The cost that matters here '
       'is attention rather than licence fees.', 12,
       array['What is in the stack?',
             'Which integrations break, and how often?',
             'What was the last thing that broke after a vendor update?']),
      ('4','T5','What is on the list that nobody has let you fix',
       'What they would change and what stops them. Then what it costs to '
       'leave it. Somebody new to a system still has the list and has not '
       'yet stopped minding.', 8,
       array['What is on your list to fix that nobody has let you fix yet?',
             'What surprised you about the data?']),

      ('5','T1','What arrives when a deal closes',
       'What a customer success team is given, and what they end up asking '
       'the seller for afterwards.', 12,
       array['What do you get from sales when a deal closes?',
             'What do you end up asking for?']),
      ('5','T2','How onboarding goes',
       'What a good one looks like, what makes a bad one, and whether '
       'anybody can tell which is happening while it happens.', 12,
       array['How does onboarding usually go?',
             'What makes one go badly?']),
      ('5','T3','When a customer first gets value',
       'Whether there is a moment the company can name, and whether '
       'anybody can see it happen in a system rather than hear about it on '
       'a call.', 10,
       array['When does a customer first get value from this?',
             'How do you know it happened?']),
      ('5','T4','How you find out an account is in trouble',
       'What tells them and how far ahead. Then what it sets off. A score '
       'nobody has tested against a real loss is a habit rather than an '
       'instrument.', 12,
       array['How do you know an account is in trouble, and how far ahead?',
             'What does a red status actually trigger?',
             'Has anyone checked whether it predicts a churn?']),
      ('5','T5','How renewals and expansion happen',
       'Who owns the conversation and when it starts. What separates a '
       'renewal from a deal that should involve sales.', 10,
       array['How do renewals happen?',
             'When does sales get involved in an expansion?']),

      ('6','T1','What the revenue systems cost',
       'The annual cost of everything holding customer data, who owns each '
       'one, and when each renews. Ask for the list rather than the '
       'figures.', 12,
       array['What do the sales and marketing systems cost each year?',
             'Who owns each one?']),
      ('6','T2','What it costs to keep them connected',
       'What the integrations cost to build and to maintain, and whether '
       'anybody counts the hours spent reconciling.', 10,
       array['What does it take to keep the systems connected?',
             'What did the integrations cost to build?']),
      ('6','T3','How retention is reported',
       'Gross and net, whether it is cohorted, and what a churn costs in '
       'their numbers rather than in the abstract.', 12,
       array['How do you report retention?',
             'What does losing a customer cost?']),
      ('6','T4','Whether margin is visible by product',
       'Whether they can see it, and whether it has ever changed a '
       'decision. Margin nobody acts on is a number rather than a control.',
       10,
       array['Do you see margin by package or product?',
             'Has packaging ever changed because of what the margin '
             'showed?']),
      ('6','T5','What you do to the forecast before you believe it',
       'What finance adjusts and why. The size of the adjustment is the '
       'real measure of how much the forecast is trusted.', 10,
       array['How close has the forecast been to what closed?',
             'What do you do to it before it goes into the plan?']),

      ('7','T1','A deal you won',
       'One deal, start to finish, in their words. What they did, what the '
       'company gave them, and what they had to make up. A single worked '
       'example beats a description of the process.', 12,
       array['Take me through a deal you won recently.',
             'What did you have to put together yourself?']),
      ('7','T2','A deal you lost',
       'When they knew, and when the record said so. The gap between those '
       'two is the thing no export shows.', 10,
       array['Tell me about one you lost.',
             'When did you know it was gone?']),
      ('7','T3','What you know before the first conversation',
       'What they can find out about a prospect, where it comes from, and '
       'how long it takes. Whether any of it arrives without them going to '
       'look.', 8,
       array['What do you know about a prospect before you first talk to '
             'them?',
             'Where does that come from?']),
      ('7','T4','What you get from marketing',
       'What arrives and what they use. Ask what they reached for on the '
       'last deal rather than what exists.', 8,
       array['What do you get from marketing?',
             'What do you actually use?']),
      ('7','T5','What happens after you close',
       'What they hand over and to whom. Whether they stay on the account '
       'afterwards, and why.', 7,
       array['What do you hand over when a deal closes?',
             'What comes back to you afterwards?'])
    ) as x(guide, ref, title, establish, minutes, ways)
  loop
    select id into v_guide from interview_guide
     where instrument_version_id = v_new and ref::text = r.guide;
    continue when v_guide is null;

    insert into interview_topic (interview_guide_id, ref, title, establish,
                                 minutes, sort_order)
         values (v_guide, r.ref, r.title, r.establish, r.minutes,
                 substring(r.ref from 2)::integer)
    on conflict (interview_guide_id, ref) do update
       set title = excluded.title, establish = excluded.establish,
           minutes = excluded.minutes, sort_order = excluded.sort_order
    returning id into v_topic;

    n := 900;
    foreach w in array r.ways loop
      n := n + 1;
      update interview_question
         set interview_topic_id = v_topic, is_a_way_in = true
       where interview_guide_id = v_guide and question_text = w;
      if not found then
        insert into interview_question (interview_guide_id,
               interview_topic_id, section_title, sort_order, question_text,
               is_a_way_in)
             values (v_guide, v_topic, r.title, n, w, true);
      end if;
    end loop;
  end loop;

  -- Questions from the old shape keep their place as ways in, under
  -- whichever subject their section was closest to.
  update interview_question q
     set interview_topic_id = t.id, is_a_way_in = true
    from interview_topic t
    join interview_guide g on g.id = t.interview_guide_id
   where g.instrument_version_id = v_new
     and q.interview_guide_id = g.id
     and q.interview_topic_id is null
     and t.sort_order = 1;

  perform gea_activate_instrument('v0.18');
end $do$;

insert into gea_migration (filename, note) values
  ('120_the_guides_as_subjects.sql',
   'v0.18: each guide is five subjects to establish with ways into each, '
   'rather than a list of questions to read out.')
on conflict do nothing;
