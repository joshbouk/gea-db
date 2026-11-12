-- 127 v0.21: the report as the exemplar settled it.
--
-- The shape held since v0.17 was eleven sections written before anybody
-- had seen a finished report. The Kestrel exemplar is one, and it differs
-- in ways a generator cannot work around: stage 07 had no section, the
-- headings asked questions ("What we found") that read as machine-made,
-- and there was nowhere for the handoffs, the economics, the limits of
-- the evidence, the decisions the client brought or the commitments
-- that shaped the order.
--
-- So the shape is replaced rather than amended. Two parts and three
-- annexes, numbered as the reader meets them. Stages and the economics
-- have subsections, held as children of a parent section so the
-- generator can number them without the numbering being methodology.
--
-- A section names what it reads. Where nothing yet produces that, the
-- generator prints a marked gap naming what is missing, so the report
-- can be drafted from the first accepted analysis rather than the last.
--
-- Answers given against the retired sections stay in report_answer under
-- their old references. Nothing reads them, and nothing deletes what a
-- consultant wrote.

alter table report_section
  add column if not exists part text,
  add column if not exists parent_ref text;

do $$ begin
  alter table report_section add constraint report_section_part
    check (part is null or part in ('one', 'two', 'annex'));
exception when duplicate_object then null; end $$;

comment on column report_section.part is
  'Which part of the report the section sits in: one, the assessment; '
  'two, the roadmap; or annex.';
comment on column report_section.parent_ref is
  'The section this one sits inside, such as a stage inside Stage by '
  'stage. Null for a numbered section.';

-- The clone has to carry the new columns, or v0.22 loses the shape.
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
                              purpose, reads, stage_code, asks, needed,
                              part, parent_ref)
  select v_new, ref, title, sort_order, purpose, reads, stage_code, asks,
         needed, part, parent_ref
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


create or replace view report_readiness
with (security_invoker = true) as
select e.id as engagement_id,
       s.ref, s.title, s.sort_order, s.purpose, s.reads, s.asks, s.needed,
       a.answer, a.answered_at,
       (s.asks is null or a.answer is not null) as ready,
       s.stage_code, s.part, s.parent_ref
  from engagement e
  join report_section s on s.instrument_version_id = e.instrument_version_id
  left join report_answer a on a.engagement_id = e.id
                           and a.section_ref = s.ref;

do $do$
declare v_old uuid; v_new uuid; v_msg record;
begin
  if exists (select 1 from instrument_version where label = 'v0.21') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.20';
  v_new := gea_clone_instrument(v_old, 'v0.21');
  update instrument_version
     set notes = 'The report in the shape the Kestrel exemplar settled: '
                 'fourteen sections in two parts, and three annexes.'
   where id = v_new;

  delete from report_section where instrument_version_id = v_new;

  insert into report_section (instrument_version_id, ref, title, sort_order,
                              purpose, reads, stage_code, asks, needed,
                              part, parent_ref)
  values
  (v_new, 'R01', 'Scope and method', 10,
   'What was assessed, over what window, from which systems and in what volume, who was interviewed by role, and which tests Blend ran.',
   array['scope']::text[], null, null, true, 'one', null),
  (v_new, 'R02', 'How the scoring works', 20,
   'The eight stages, the six levels, how the two scores are calculated, and why an element that does not apply differs from one that scores zero.',
   array['method']::text[], null, null, true, 'one', null),
  (v_new, 'R03', 'The scores', 30,
   'Each scorecard with its score out of 100 and what that is out of, its handoff score out of 40, its scoring map, and one line per stage on what the score reflects.',
   array['scores','map']::text[], null, null, true, 'one', null),
  (v_new, 'R04', 'Problems that run across stages', 40,
   'The few problems that account for most low scores, each named with the stages it appears in. The part an executive remembers.',
   array['cross_stage']::text[], null, null, true, 'one', null),
  (v_new, 'R05', 'Stage by stage', 50,
   'One section per stage, in a fixed shape: score, what the stage is for, the sentence naming the problem, findings, impact, and the handoff to the next stage.',
   array['stage_intro']::text[], null, null, true, 'one', null),
  (v_new, 'R06', 'Handoffs between stages', 60,
   'All eight handoffs scored out of five for each scorecard, what is lost at each, and the three where the most is lost.',
   array['handoffs']::text[], null, null, true, 'one', null),
  (v_new, 'R07', 'The biggest single opportunity', 70,
   'The one change the figures support most strongly, with the counts behind it and how far they can be trusted.',
   array['opportunity']::text[], null, 'Name the opportunity the figures support most strongly, and say why it matters more than the others.', true, 'one', null),
  (v_new, 'R08', 'Revenue economics', 80,
   'What the client spends to grow revenue and what it gets back.',
   array[]::text[], null, null, true, 'one', null),
  (v_new, 'R08.1', 'Total spend on revenue growth', 81,
   'Every cost of finding, winning, keeping and growing customers, by kind, for one financial year, against what it bought.',
   array['spend_total']::text[], null, null, true, 'one', 'R08'),
  (v_new, 'R08.2', 'Investment by lifecycle stage', 82,
   'People and programme cost assigned to the stages they serve, beside each stage score. Shared costs split evenly. Technology is not split.',
   array['invest_by_stage']::text[], null, null, true, 'one', 'R08'),
  (v_new, 'R08.3', 'Marketing spend by channel', 83,
   'Programme spend by channel and year, and how concentrated it is in a few named items.',
   array['spend_by_channel']::text[], null, null, true, 'one', 'R08'),
  (v_new, 'R08.4', 'Where spend goes, where pipeline comes from, and where wins come from', 84,
   'Each source counted three ways. What it cost, the qualified opportunities and pipeline it created, and the deals and value it won.',
   array['source_mix']::text[], null, null, true, 'one', 'R08'),
  (v_new, 'R08.5', 'What each source costs to produce a won deal', 85,
   'Cost, opportunities, wins, win rate, cost per won deal, average deal and payback for each source, with the counts to judge them by.',
   array['source_cost']::text[], null, null, true, 'one', 'R08'),
  (v_new, 'R08.6', 'Pipeline coverage', 86,
   'Open qualified pipeline due in the coming quarter against its target, and the coverage the client’s own win rate calls for.',
   array['coverage']::text[], null, null, true, 'one', 'R08'),
  (v_new, 'R08.7', 'What next year’s plan needs at today’s source mix', 87,
   'The growth waterfall, working back from a bookings target to the opportunities each source must produce and the activity before them.',
   array['waterfall']::text[], null, null, true, 'one', 'R08'),
  (v_new, 'R08.8', 'Customer cohorts', 88,
   'A group of customers that behaves differently enough to need its own figures, such as those on an older product.',
   array['cohorts']::text[], null, 'Name any group of customers that behaves differently enough to report on its own, and say what sets it apart. If there is none, say so.', false, 'one', 'R08'),
  (v_new, 'R08.9', 'What the technology stack costs', 89,
   'Three-year cost of the revenue technology, split between what buys capability and what keeps the systems in agreement, with the measurements under it.',
   array['stack_cost']::text[], null, null, true, 'one', 'R08'),
  (v_new, 'R09', 'Limits of the evidence', 90,
   'Elements that do not apply and why, scores held down by missing data, scores resting on less evidence, and conditions that affect the figures.',
   array['limits']::text[], null, null, true, 'one', null),
  (v_new, 'R10', 'Recommendations by stage', 100,
   'What to change in each stage, each with the benefit a revenue leader cares about.',
   array['recommendations']::text[], null, null, true, 'two', null),
  (v_new, 'R11', 'Why the work runs in this order', 110,
   'The sequence argued from the scoring maps and from what has to be true before each project can work.',
   array['sequence']::text[], null, null, true, 'two', null),
  (v_new, 'R12', 'The roadmap', 120,
   'Each project by what it changes, why, what changes, its impact and who does it, over twenty-four months.',
   array['roadmap']::text[], null, null, true, 'two', null),
  (v_new, 'R13', 'Decisions for the client', 130,
   'Each decision the client brought to the assessment, answered from the evidence.',
   array['decisions']::text[], null, null, true, 'two', null),
  (v_new, 'R14', 'Outside commitments that shaped the order', 140,
   'Dated commitments outside the assessment that the order of work had to respect.',
   array['commitments']::text[], null, null, false, 'two', null),
  (v_new, 'RA', 'Handoff detail', 200,
   'One page per handoff, recording what was asked for to test it and what was produced.',
   array['handoff_detail']::text[], null, null, true, 'annex', null),
  (v_new, 'RB', 'Element scores and evidence', 210,
   'Every element for every scorecard, with its score and the evidence it rests on.',
   array['element_scores']::text[], null, null, true, 'annex', null),
  (v_new, 'RC', 'Evidence register', 220,
   'Every file, document and interview the assessment read, with the reference used to cite it.',
   array['evidence']::text[], null, null, true, 'annex', null);

  -- One section per stage, named as the stage is named everywhere else.
  insert into report_section (instrument_version_id, ref, title, sort_order,
                              purpose, reads, stage_code, asks, needed,
                              part, parent_ref)
  select v_new, 'R05.' || ls.code, ls.name, 50 + ls.code::int,
         'Score, what the stage is for, the sentence naming the problem, '
         'findings, impact, and the handoff to the next stage.',
         array['scores', 'findings', 'stage_handoff']::text[],
         ls.code, null, true, 'one', 'R05'
    from lifecycle_stage ls;

  for v_msg in select * from gea_activate_instrument('v0.21') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $do$;

insert into gea_migration (filename, note) values
  ('127_the_report_as_the_exemplar_settled_it.sql',
   'v0.21: the report in fourteen sections and three annexes, with stage '
   'and economics subsections, replacing the eleven-section shape.')
on conflict do nothing;
