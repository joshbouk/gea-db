-- 126 What growth costs.
--
-- Cost per qualified opportunity measures the top of the funnel. The
-- person commissioning an assessment owns the whole cost of revenue,
-- and their question is what a pound of recurring revenue costs to
-- acquire. A business can buy opportunities cheaply and win nothing.
--
-- The existing analysis also divided everything by opportunities,
-- including four million of salary, and produced a cost per opportunity
-- of eleven thousand that nobody would recognise. Dividing the whole
-- cost base by opportunities is a real figure about the wrong
-- denominator.
--
-- So: the whole cost base, broken into the kinds of cost a reader has
-- to see separately, against the recurring revenue it bought. New
-- business only, because a renewal booked this year was not acquired by
-- this year's spend, and on a client where nine in ten unassigned deals
-- are renewals, counting them would halve the apparent cost.
--
-- The lag is stated rather than hidden. Spend in one year produces
-- revenue in the next, so this is a ratio over the whole period and
-- never by month.

do $do$
declare
  v_iv uuid; v_from uuid; v_field uuid; r record;
begin
  select id into v_from from instrument_version where status = 'active';
  v_iv := gea_clone_instrument(v_from, 'v0.20');

  -- What kind of cost a line is. Four categories, because a chief
  -- revenue officer looking at six million needs to see that four of
  -- it is people before anything else makes sense.
  -- Priority as well as a name: a field without one fails the rule
  -- that every field is presentable. Supporting rather than core,
  -- because the analysis runs without it and says "not recorded" for
  -- the split rather than refusing.
  insert into canonical_field (instrument_version_id, key, name, description,
         expected_type, source_export_refs, is_cap_bearing, priority)
       values (v_iv, 'spend_kind', 'Kind of cost',
               'Whether a line is people, programme, technology or '
               'something else. The split a reader needs before any '
               'ratio means anything.',
               'enum', array['T3-01'], false, 'supporting')
  on conflict do nothing;

  select id into v_field from canonical_field
   where instrument_version_id = v_iv and key = 'spend_kind';

  -- The analysis, and what it may read.
  for r in
    select * from (values
      ('spend_amount', true), ('spend_month', true),
      ('spend_kind', false), ('spend_channel', false),
      ('opportunity_id', true), ('opportunity_status', true),
      ('opportunity_amount', true), ('opportunity_type', false),
      ('opportunity_close_date', true), ('channel_source', false)
    ) as x(key, required)
  loop
    insert into analysis_field_requirement (instrument_version_id,
           analysis_key, canonical_field_id, is_required)
    select v_iv, 'cost_of_growth', cf.id, r.required
      from canonical_field cf
     where cf.instrument_version_id = v_iv and cf.key = r.key
    on conflict do nothing;
  end loop;

  insert into analysis_guidance (instrument_version_id, analysis_key,
         what_to_check, goes_wrong)
       values (v_iv, 'cost_of_growth',
         'Whether the spend covers the same period as the revenue, and '
         'whether the revenue is new business rather than renewal. A '
         'ratio built on renewals flatters the client by roughly the '
         'share of their book that renews.',
         'Spend in one year produces revenue in the next, so a ratio '
         'over a short window says more about timing than about '
         'efficiency. Where a client records no deal value, this cannot '
         'run at all and the count-based figure is all there is.')
  on conflict do nothing;

  -- Elements reach an analysis through the evidence they require
  -- rather than through a table of their own, so nothing is linked
  -- here. A consultant scoring 3.1 or 3.4 will find this run on the
  -- engagement's runs.

  perform gea_activate_instrument('v0.20');
end $do$;

insert into gea_migration (filename, note) values
  ('126_what_growth_costs.sql',
   'An analysis of what a pound of new recurring revenue costs to '
   'acquire, against the whole cost base rather than programme spend '
   'alone.')
on conflict do nothing;
