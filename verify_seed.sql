-- Seed verification. Asserts that what landed in the database is what the
-- instrument describes.
--
-- gea_verify() proves the database refuses bad data. This proves the data it
-- accepted is the right data. Different questions, both worth asking.
--
-- Run:  select * from gea_verify_seed();
-- Every row must read 'pass'.

create or replace function gea_verify_seed(p_label text default 'v0.6')
returns table (rule text, description text, result text)
language plpgsql as $fn$
declare
  iv uuid;
  n bigint;
  txt text;
begin
  select id into iv from instrument_version where label = p_label;
  if iv is null then
    rule := 'S00'; description := 'The instrument version exists';
    result := 'FAIL — no instrument version labelled ' || p_label;
    return next; return;
  end if;

  -- structure -------------------------------------------------------------
  select count(*) into n from element where instrument_version_id = iv;
  rule := 'S01'; description := '48 elements';
  result := case when n = 48 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from element
   where instrument_version_id = iv and kind = 'handoff';
  rule := 'S02'; description := '8 of them are handoffs';
  result := case when n = 8 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from (
    select stage_code from element
     where instrument_version_id = iv and kind = 'element'
     group by stage_code having count(*) = 5) x;
  rule := 'S03'; description := 'five elements in each of eight stages';
  result := case when n = 8 then 'pass' else 'FAIL — ' || n || ' stages have five' end;
  return next;

  select count(*) into n from anchor a
    join element e on e.id = a.element_id where e.instrument_version_id = iv;
  rule := 'S04'; description := '288 anchors';
  result := case when n = 288 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from (
    select a.element_id from anchor a
      join element e on e.id = a.element_id
     where e.instrument_version_id = iv
     group by a.element_id
    having count(*) = 6 and min(a.level) = 0 and max(a.level) = 5) x;
  rule := 'S05'; description := 'six anchors on every element, levels 0 to 5';
  result := case when n = 48 then 'pass' else 'FAIL — ' || n || ' of 48' end;
  return next;

  -- element flags ---------------------------------------------------------
  select count(*) into n from element
   where instrument_version_id = iv and not ne_permitted;
  rule := 'S06'; description := 'Not Evidenced forbidden on 16 elements';
  result := case when n = 16 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from element
   where instrument_version_id = iv and kind = 'handoff' and ne_permitted;
  rule := 'S07'; description := 'no handoff permits Not Evidenced';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' do' end; return next;

  select count(*) into n from element
   where instrument_version_id = iv and tier_dependent;
  rule := 'S08'; description := 'tier dependence on exactly five elements';
  result := case when n = 5 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from element
   where instrument_version_id = iv and evidence_decays;
  rule := 'S09'; description := 'evidence decays on 11 elements and 8 handoffs';
  result := case when n = 19 then 'pass' else 'FAIL — ' || n end; return next;

  select string_agg(ref, ',' order by ref) into txt from element
   where instrument_version_id = iv and has_retrievability_test;
  rule := 'S10'; description := 'retrievability tests on H01, H02 and H06 only';
  result := case when txt = 'H01,H02,H06' then 'pass'
                 else 'FAIL — ' || coalesce(txt, 'none') end; return next;

  -- fields and caps -------------------------------------------------------
  select count(*) into n from canonical_field where instrument_version_id = iv;
  rule := 'S11'; description := '123 canonical fields';
  result := case when n = 123 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from canonical_field_cap c
    join canonical_field f on f.id = c.canonical_field_id
   where f.instrument_version_id = iv;
  rule := 'S12'; description := '12 cap rules';
  result := case when n = 12 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from canonical_field f
   where f.instrument_version_id = iv and f.is_cap_bearing
     and not exists (select 1 from canonical_field_cap c
                      where c.canonical_field_id = f.id)
     and f.key <> 'health_score';
  rule := 'S13'; description := 'every cap-bearing field has a rule, health_score excepted';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' without' end;
  return next;

  select count(*) into n from canonical_field
   where instrument_version_id = iv and (name is null or priority is null);
  rule := 'S14'; description := 'every field carries a display name and a priority';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' missing' end;
  return next;

  -- analyses --------------------------------------------------------------
  select count(*) into n from (
    select distinct r.analysis_key from evidence_requirement r
     where r.instrument_version_id = iv and r.source_kind = 'analysis'
       and not exists (
         select 1 from analysis_field_requirement a
          where a.instrument_version_id = iv and a.analysis_key = r.analysis_key)) x;
  rule := 'S15'; description := 'every analysis an element depends on declares its fields';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' undeclared' end;
  return next;

  select count(*) into n from analysis_field_requirement
   where instrument_version_id = iv and analysis_key = 'discovery_consistency_classification';
  rule := 'S16'; description := 'discovery_consistency_classification declares 13 fields';
  result := case when n = 13 then 'pass' else 'FAIL — ' || n end; return next;

  -- exports and coverage --------------------------------------------------
  select count(*) into n from export_line where instrument_version_id = iv;
  rule := 'S17'; description := '24 export lines';
  result := case when n = 24 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from element e
   where e.instrument_version_id = iv
     and e.ref not in ('2.1','2.4','3.3','H01','H02')
     and not exists (select 1 from export_line_element x where x.element_id = e.id);
  rule := 'S18'; description := 'every element has an export line or is a declared exception';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' uncovered' end;
  return next;

  select count(*) into n from export_line_element x
    join export_line l on l.id = x.export_line_id
    join element e on e.id = x.element_id
   where l.instrument_version_id = iv
     and (l.ref, e.ref) in (('T3-09','3.4'), ('T1-06','7.1'));
  rule := 'S19'; description := 'the two withdrawn coverage pairs are absent';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' present' end;
  return next;

  -- requirements ----------------------------------------------------------
  select count(*) into n from evidence_requirement where instrument_version_id = iv;
  rule := 'S20'; description := '171 evidence requirements';
  result := case when n = 171 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from element e
   where e.instrument_version_id = iv
     and not exists (select 1 from evidence_requirement r where r.element_id = e.id);
  rule := 'S21'; description := 'every element carries at least one requirement';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' without' end;
  return next;

  select count(*) into n from evidence_requirement
   where instrument_version_id = iv
     and ((source_kind = 'interview' and interview_guide_id is null)
       or (source_kind = 'analysis'  and analysis_key is null)
       or (source_kind = 'export'    and export_line_refs is null));
  rule := 'S22'; description := 'every requirement resolves its source reference';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' unresolved' end;
  return next;

  -- interviews ------------------------------------------------------------
  select count(*) into n from interview_guide where instrument_version_id = iv;
  rule := 'S23'; description := '7 interview guides';
  result := case when n = 7 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from interview_question q
    join interview_guide g on g.id = q.interview_guide_id
   where g.instrument_version_id = iv;
  rule := 'S24'; description := '116 interview questions';
  result := case when n = 116 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from element e
   where e.ref in ('H01','H02','H06')
     and e.instrument_version_id = iv
     and not exists (select 1 from interview_question_element x
                      where x.element_id = e.id);
  rule := 'S25'; description := 'each retrievability test links to a question';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' unlinked' end;
  return next;

  -- prompts and measurement ----------------------------------------------
  select count(*) into n from prompt_version;
  rule := 'S26'; description := '25 prompts';
  result := case when n = 25 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from prompt_version
   where output_contract = '{}'::jsonb or discard_conditions = '[]'::jsonb;
  rule := 'S27'; description := 'every prompt carries an output contract and a discard condition';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' empty' end;
  return next;

  select count(*) into n from aeo_prompt_template where instrument_version_id = iv;
  rule := 'S28'; description := '21 answer engine templates';
  result := case when n = 21 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from measurement_definition_template
   where instrument_version_id = iv;
  rule := 'S29'; description := '16 measurement definitions';
  result := case when n = 16 then 'pass' else 'FAIL — ' || n end; return next;

  select count(*) into n from measurement_definition_template
   where instrument_version_id = iv
     and (required_fields is null or array_length(required_fields, 1) is null);
  rule := 'S30'; description := 'every measurement names its required fields';
  result := case when n = 0 then 'pass' else 'FAIL — ' || n || ' without' end;
  return next;

  -- the version is still editable ----------------------------------------
  select status::text into txt from instrument_version where id = iv;
  rule := 'S31'; description := 'the version is still draft and can be corrected';
  result := case when txt = 'draft' then 'pass'
                 else 'FAIL — already ' || txt end; return next;

  return;
end $fn$;
