-- 079 Plainer instructions.
--
-- Three colon-then-reveals in the v0.12 export line content, which the
-- style checker refuses in report prose and which read no better here.
-- Written in one pass and not checked, which is how that construction
-- gets everywhere.
--
-- The checker also objected to all twenty questions as rhetorical
-- questions. They are not: the field exists to be a question, and rule 5
-- is about a report asking one it intends to answer itself. A report style
-- guide applied to interface labels produces noise, which is a note for
-- the next person to point it at something.

-- An active instrument is immutable, so even three words need a version.
-- That rule is right and the cost of honouring it is now one button on the
-- engagement.

do $$
declare v_iv uuid; v_old uuid; v_msg record;
begin
  if exists (select 1 from instrument_version where label = 'v0.13') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.12';
  v_iv := gea_clone_instrument(v_old, 'v0.13');

  update instrument_version
     set notes = 'Three colon-then-reveals removed from the export line '
                 'instructions. No element, anchor or requirement changed.'
   where id = v_iv;

  update export_line set salesforce_guidance =
    'Reports, then a new Opportunity report. Salesforce caps a report at '
    'around a hundred columns and most clients exceed that, so export it in '
    'two passes. Put Opportunity ID and the first half of the fields in one, '
    'Opportunity ID and the rest in the other. Upload both and they will be '
    'joined on the ID. Include every record type.'
   where instrument_version_id = v_iv and ref = 'T1-01';

  update export_line set without_it =
    'Every firmographic cut goes. Who actually buys, win rates by segment, '
    'customer concentration. Seven analyses read it.'
   where instrument_version_id = v_iv and ref = 'T1-02';

  update export_line set salesforce_guidance =
    'Leads. All fields, including Converted, Converted Date and Converted '
    'Contact ID. Include leads that were never converted, which will be most '
    'of them.'
   where instrument_version_id = v_iv and ref = 'T1-10';

  for v_msg in select * from gea_activate_instrument('v0.13') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('079_plainer_export_instructions.sql',
   'Three colon-then-reveals removed from the export line instructions.');
