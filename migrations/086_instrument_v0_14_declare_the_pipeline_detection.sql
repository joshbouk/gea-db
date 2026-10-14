-- 086 v0.14: the instrument learns about the pipeline detection.
--
-- detect_pipeline was built, wired to a screen and tested against a real
-- client export, and the instrument was never told it exists. Capability
-- is computed from analysis_field_requirement, so an analysis with no
-- requirements gets no capability row; the screen checks for one before
-- offering to run anything, finds none, and shows no button at all.
--
-- The analysis was unreachable from the interface the whole time, and
-- nothing said so. It is the sort of gap that only appears when somebody
-- goes looking for a button that should be there.
--
-- What it needs is small: the deal's own reference and the stage it is in.
-- Everything else it discovers from the client's own columns, which is the
-- point of it. The segment fields are optional and the analysis takes the
-- first it finds.

do $$
declare v_old uuid; v_new uuid; v_msg record; n integer;
begin
  if exists (select 1 from instrument_version where label = 'v0.14') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.13';
  v_new := gea_clone_instrument(v_old, 'v0.14');

  update instrument_version
     set notes = 'The pipeline detection is declared, so capability can be '
                 'computed for it and the screen can offer to run it.'
   where id = v_new;

  insert into analysis_field_requirement (instrument_version_id, analysis_key,
                                          canonical_field_id, is_required)
  select v_new, 'detect_pipeline', cf.id,
         cf.key in ('opportunity_id', 'opportunity_status')
    from canonical_field cf
   where cf.instrument_version_id = v_new
     -- Only fields on the deals export itself.
     --
     -- The segment can in principle come from the product family or the
     -- account's own segment, and this analysis cannot use either: it
     -- requires the segment column to be in the same file as the deals,
     -- because it is pivoting that file row by row. Declaring them made
     -- the instrument say it reads the companies and line item exports,
     -- which it does not, and the seed check caught it — an analysis that
     -- reads an export must be able to identify that export's rows, and
     -- this one has no way to identify a company.
     and cf.key in ('opportunity_id', 'opportunity_status',
                    'opportunity_type');
  get diagnostics n = row_count;
  raise notice 'v0.14: detect_pipeline declared with % fields', n;

  for v_msg in select * from gea_activate_instrument('v0.14') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('086_instrument_v0_14_declare_the_pipeline_detection.sql',
   'v0.14: detect_pipeline is declared, so it gets a capability row and the '
   'screen can offer it.');
