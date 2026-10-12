-- 061 v0.10: note sufficiency could not tell a won deal from a lost one.
--
-- The first of its four conditions is coverage, reported separately for
-- closed-won and closed-lost because notes cluster on deals that went well —
-- and a client whose notes exist only on wins has a particular problem that
-- a single coverage figure hides.
--
-- It never required opportunity_status, so both figures came out of an empty
-- set and were reported as not measurable. The third time an analysis has
-- needed a field it did not declare: the requirements were written from the
-- prompt text, which says what to analyse rather than what to read.
--
-- The service now checks its own reads against the instrument at startup, so
-- the next one is caught before anybody looks at its output.

do $$
declare v_old uuid; v_new uuid; v_msg record;
begin
  if exists (select 1 from instrument_version where label = 'v0.10') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.9';
  v_new := gea_clone_instrument(v_old, 'v0.10');

  update instrument_version
     set notes = 'Note sufficiency can report coverage separately for won '
                 'and lost, which is the point of reporting it at all.'
   where id = v_new;

  insert into analysis_field_requirement
         (instrument_version_id, analysis_key, canonical_field_id, is_required)
  select v_new, 'note_sufficiency', cf.id, true
    from canonical_field cf
   where cf.instrument_version_id = v_new
     and cf.key in ('opportunity_id', 'opportunity_status')
  on conflict (instrument_version_id, analysis_key, canonical_field_id)
    do update set is_required = true;

  for v_msg in select * from gea_activate_instrument('v0.10') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('061_instrument_v0_10_note_coverage.sql',
   'v0.10: note sufficiency requires the deal outcome, so coverage can be '
   'reported for won and lost separately.');
