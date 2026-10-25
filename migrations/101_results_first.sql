-- 101 v0.17: results first.
--
-- The first version opened with what was looked at and what could not
-- be. The argument was that a reader who finds a gap on page nine
-- distrusts pages one to eight.
--
-- That is a real problem solved the wrong way. Nobody opens an
-- assessment to read about its method, and a page of what we could not
-- see before a single finding teaches the reader that this document is
-- about the work rather than about them.
--
-- The caveat travels with the finding instead. A finding whose evidence
-- was limited says so where it is read, in a clause, and the detail sits
-- in an appendix for whoever disagrees. A reader who meets the limit
-- beside the claim it limits never feels misled, and the other ninety
-- per cent of readers never have to care.

do $$
declare v_old uuid; v_new uuid; v_msg record;
begin
  if exists (select 1 from instrument_version where label = 'v0.17') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.16';
  v_new := gea_clone_instrument(v_old, 'v0.17');
  update instrument_version
     set notes = 'The report opens with the findings. What was looked at '
                 'moves to an appendix, and a finding carries its own '
                 'caveat.'
   where id = v_new;

  -- What we looked at leaves the front and becomes an appendix.
  update report_section
     set title = 'What this assessment read',
         sort_order = 200,
         purpose = 'The evidence, for a reader who wants to check '
                   'something. A finding limited by a gap says so where '
                   'it is read; this is where the detail sits.'
   where instrument_version_id = v_new and ref = 'R02';

  update report_section set sort_order = 210
   where instrument_version_id = v_new and ref = 'R11';

  -- And the findings come first.
  update report_section set sort_order = 20
   where instrument_version_id = v_new and ref = 'R03';

  for v_msg in select * from gea_activate_instrument('v0.17') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

-- Which findings a gap in the evidence touched -------------------------------
--
-- A finding bears on elements; an element needs evidence; evidence comes
-- from export lines. Where a line will never arrive, every finding about
-- an element that needed it is a finding made on less than the full
-- picture, and should say so in a clause rather than leaving the reader
-- to work it out from an appendix.

create or replace view finding_limits
with (security_invoker = true) as
select f.id as finding_id, f.engagement_id,
       coalesce(array_agg(distinct el.ref order by el.ref), array[]::text[])
         as missing_exports,
       coalesce(array_agg(distinct erl.unavailable_reason)
                filter (where erl.unavailable_reason is not null),
                array[]::text[]) as why
  from rollup_finding f
  join engagement e on e.id = f.engagement_id
  join element elem on elem.ref = any (f.element_refs)
                   and elem.instrument_version_id = e.instrument_version_id
  join evidence_requirement er on er.element_id = elem.id
                              and er.is_mandatory
  join export_line el on el.ref = any (er.export_line_refs)
                     and el.instrument_version_id = e.instrument_version_id
  join export_request_line erl on erl.export_line_id = el.id
                              and erl.engagement_id = f.engagement_id
 where erl.status in ('absent', 'refused')
 group by f.id, f.engagement_id;

comment on view finding_limits is
  'Findings made without evidence the methodology asks for, and which '
  'evidence. A caveat read beside the claim it limits never feels like a '
  'discovery; the same caveat found later does.';

insert into gea_migration (filename, note) values
  ('101_results_first.sql',
   'v0.17: the report opens with the findings, the evidence moves to an '
   'appendix, and a finding carries its own caveat.');
