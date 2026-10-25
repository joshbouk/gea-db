-- 100 v0.16: the report itself.
--
-- Eleven sections. The order is an argument: what we looked at, what we
-- found, what it scores, what it costs, what to do. A reader who stops
-- after three pages should still have the finding.
--
-- The evidence note comes first and not last. A report that opens with
-- its conclusions and buries what it could not see invites the reader to
-- discover the gap themselves, halfway through, and distrust everything
-- before it. Saying it first costs a page and buys the rest.

do $$
declare v_old uuid; v_new uuid; v_msg record;
begin
  if exists (select 1 from instrument_version where label = 'v0.16') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.15';
  v_new := gea_clone_instrument(v_old, 'v0.16');
  update instrument_version
     set notes = 'The shape of the report, and the questions it asks the '
                 'consultant.'
   where id = v_new;

  insert into report_section (instrument_version_id, ref, title, sort_order,
                              purpose, reads, stage_code, asks, needed)
  values
  (v_new, 'R01', 'What this is', 10,
   'Who asked, what was assessed, over what period, and what the reader '
   'is holding.',
   array[]::text[], null,
   'In two sentences, what did this client want to know? Not the brief — '
   'the question behind it.', true),

  (v_new, 'R02', 'What we looked at', 20,
   'The evidence, and what was not available. A reader who finds a gap '
   'themselves on page nine distrusts pages one to eight.',
   array['evidence'], null, null, true),

  (v_new, 'R03', 'What we found', 30,
   'The findings, in order of how much they matter. The part a reader '
   'who stops after three pages should still have.',
   array['findings'], null, null, true),

  (v_new, 'R04', 'How the engine scores', 40,
   'The scorecard: the shape across eight stages, and where the handoffs '
   'leak.',
   array['scores', 'map'], null, null, true),

  (v_new, 'R05', 'Who they sell to', 50,
   'Product-market fit and ICP clarity. Whether the client can say who '
   'their best customers are and show it in the data.',
   array['scores', 'findings'], '01',
   'What did the interviews say about how a target account gets chosen? '
   'Where that differs from what the data shows, say so.', true),

  (v_new, 'R06', 'How demand is created', 60,
   'Distribution. What the client spends, what it returns, and whether '
   'anybody can tell.',
   array['scores', 'findings'], '03', null, true),

  (v_new, 'R07', 'How a deal is won', 70,
   'Sales execution. The pipeline as it actually runs, the conversions '
   'between stages, and where deals leak out.',
   array['scores', 'findings', 'pipeline'], '05',
   'What did the sellers say about why deals stall? Put it beside what '
   'the pipeline shows.', true),

  (v_new, 'R08', 'How a customer is kept', 80,
   'Customer delivery. Handover, what was sold against what gets '
   'delivered, and the handoffs between them.',
   array['scores', 'findings'], '06', null, true),

  (v_new, 'R08b', 'Whether they come back', 85,
   'Customer excitement and expansion. Renewal, advocacy, and whether '
   'growth comes from the customers they already have.',
   array['scores', 'findings'], '08', null, true),

  (v_new, 'R05b', 'What they say', 55,
   'Messaging resonance. Whether what the client says lands with the '
   'people they want to reach.',
   array['scores', 'findings'], '02', null, true),

  (v_new, 'R06b', 'How a prospect engages', 65,
   'Engagement. What a prospect meets when they arrive, and what happens '
   'between interest and a conversation.',
   array['scores', 'findings'], '04', null, true),

  (v_new, 'R09', 'What it is costing', 90,
   'The stack, what it costs, and what is not being used.',
   array['tco'], null, null, false),

  (v_new, 'R10', 'What to do about it', 100,
   'The roadmap: what to fix, in what order, and why that order.',
   array['roadmap'], null,
   'Of everything in the roadmap, which one thing would you do first if '
   'they could only do one? Say why.', true),

  (v_new, 'R11', 'How we got here', 110,
   'The method, the instrument version, who was interviewed, and what '
   'the scores rest on. The part nobody reads until they disagree with '
   'something.',
   array['method', 'evidence'], null, null, true);

  for v_msg in select * from gea_activate_instrument('v0.16') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('100_the_report_itself.sql',
   'v0.16: eleven sections, in an order that is an argument.');
