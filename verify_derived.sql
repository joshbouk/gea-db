-- Derived state must not outlive the evidence it came from.
--
-- Three migrations exist because a judgement survived the thing it was about.
-- A mapping outlived its file. An absence outlived its file. A score cap
-- outlived the absence that caused it. Each was invisible until somebody did
-- the obvious thing in the application and got a wrong answer that looked
-- right.
--
-- The pattern: whenever one record is a judgement about another, removing or
-- superseding the second has to reopen the first. Nothing enforces that in
-- general, and nothing can — it is a property of each pair. So each pair gets
-- a rule here, and the rule fails if a future change breaks it.
--
-- These run like the other suites: build a fixture, do the thing, check the
-- consequence. Add a rule here whenever a new piece of derived state appears.

create or replace function gea_verify_derived()
returns table (rule text, description text, result text)
language plpgsql as $$
declare
  cl uuid; eng uuid; usr uuid; art uuid; ds uuid; lin uuid;
  capf uuid; capkey text; othf uuid; otherexport uuid;
  n integer; ok boolean; txt text;
begin
  -- Fixture ------------------------------------------------------------------
  insert into client (company_name) values ('Derived fixture') returning id into cl;
  insert into app_user (auth_subject, email, display_name, org_role)
       values (gen_random_uuid(), 'derived@blendb2b.com', 'Derived', 'admin')
    returning id into usr;

  insert into engagement (client_id, instrument_version_id, name, window_start,
                          window_end, storage_prefix)
  select cl, iv.id, 'Derived fixture', '2024-01-01', '2025-12-31', 'derived/'
    from instrument_version iv where iv.status = 'active' limit 1
  returning id into eng;

  insert into engagement_member (engagement_id, app_user_id, engagement_role)
       values (eng, usr, 'lead_consultant');
  insert into score (engagement_id, element_id, state)
  select eng, e.id, 'unscored' from element e
    join engagement en on en.id = eng and en.instrument_version_id = e.instrument_version_id;
  insert into engagement_requirement (engagement_id, evidence_requirement_id, state)
  select eng, r.id, 'outstanding' from evidence_requirement r
    join engagement en on en.id = eng and en.instrument_version_id = r.instrument_version_id;
  insert into export_request_line (engagement_id, export_line_id, included, status)
  select eng, l.id, true, 'received' from export_line l
    join engagement en on en.id = eng and en.instrument_version_id = l.instrument_version_id;

  select erl.id into lin from export_request_line erl
    join export_line el on el.id = erl.export_line_id
   where erl.engagement_id = eng and el.ref = 'T1-01';

  insert into artefact (engagement_id, kind, export_request_line_id,
                        original_filename, storage_path, sha256, is_row_data)
       values (eng, 'raw_export', lin, 'fixture.csv', 'd/fixture.csv',
               'derivedfixture', true)
    returning id into art;
  insert into dataset (artefact_id, row_count, column_count, parse_status)
       values (art, 100, 4, 'parsed') returning id into ds;

  select cf.id, cf.key into capf, capkey
    from canonical_field cf
    join canonical_field_cap cc on cc.canonical_field_id = cf.id
    join engagement en on en.id = eng and en.instrument_version_id = cf.instrument_version_id
   where 'T1-01' = any (cf.source_export_refs) and cf.is_cap_bearing limit 1;

  select cf.id into othf from canonical_field cf
    join engagement en on en.id = eng and en.instrument_version_id = cf.instrument_version_id
   where 'T1-01' = any (cf.source_export_refs) and cf.id <> capf limit 1;

  select cf.id into otherexport from canonical_field cf
    join engagement en on en.id = eng and en.instrument_version_id = cf.instrument_version_id
   where 'T1-03' = any (cf.source_export_refs)
     and not ('T1-01' = any (cf.source_export_refs)) limit 1;

  perform set_config('request.jwt.claim.sub',
                     (select auth_subject::text from app_user where id = usr), true);

  -- Decisions about that file -------------------------------------------------
  perform gea_confirm_mapping(eng, othf, 'confirmed', 'Some Column', ds);
  perform gea_confirm_mapping(eng, capf, 'unmapped');
  if otherexport is not null then
    perform gea_confirm_mapping(eng, otherexport, 'unmapped');
  end if;

  select count(*) into n from score s
    join canonical_field_cap cc on cc.element_id = s.element_id
                               and cc.canonical_field_id = capf
   where s.engagement_id = eng and s.cap_applied is not null;
  rule := 'D0'; description := 'calling a cap-bearing field absent caps its elements';
  result := case when n > 0 then 'pass'
                 else 'FAIL — no cap was applied, so the rest proves nothing' end;
  return next;

  -- Remove the file -----------------------------------------------------------
  perform gea_purge_artefact(art, 'Fixture: replaced by a better export.');

  select status::text into txt from field_mapping
   where engagement_id = eng and canonical_field_id = othf;
  rule := 'D1'; description := 'removing a file reopens the columns chosen from it';
  result := case when txt = 'proposed' then 'pass'
                 else 'FAIL — the mapping is still ' || coalesce(txt,'missing') end;
  return next;

  select status::text into txt from field_mapping
   where engagement_id = eng and canonical_field_id = capf;
  rule := 'D2'; description := 'removing a file reopens the fields called absent from it';
  result := case when txt = 'proposed' then 'pass'
                 else 'FAIL — the field is still ' || coalesce(txt,'missing') end;
  return next;

  select count(*) into n from score s
    join canonical_field_cap cc on cc.element_id = s.element_id
                               and cc.canonical_field_id = capf
   where s.engagement_id = eng and s.cap_applied is not null;
  rule := 'D3'; description := 'the score caps that absence caused are lifted';
  result := case when n = 0 then 'pass'
                 else 'FAIL — ' || n || ' score(s) still capped by a withdrawn decision' end;
  return next;

  select count(*) into n from engagement_requirement
   where engagement_id = eng and state = 'waived'
     and waiver_reason like '%' || capkey || '%';
  rule := 'D4'; description := 'the evidence waivers that absence caused are lifted';
  result := case when n = 0 then 'pass'
                 else 'FAIL — ' || n || ' requirement(s) still waived by a withdrawn decision' end;
  return next;

  if otherexport is not null then
    select status::text into txt from field_mapping
     where engagement_id = eng and canonical_field_id = otherexport;
    rule := 'D5'; description := 'a field absent from a different export is left alone';
    result := case when txt = 'unmapped' then 'pass'
                   else 'FAIL — it became ' || coalesce(txt,'missing') end;
    return next;
  end if;

  -- Evidence that something still rests on cannot be withdrawn ---------------
  declare run uuid;
  begin
    insert into analysis_run (engagement_id, job_type, status, finished_at,
                              compute_output)
         values (eng, 'analysis:icp_reconciliation', 'succeeded', now(), '{}'::jsonb)
      returning id into run;
    perform gea_accept_run(run, 'Fixture: checked.');
    ok := false;
    begin
      perform gea_discard_run(run, 'Fixture: changed my mind.');
    exception when others then ok := true;
    end;
    rule := 'D6';
    description := 'a run that evidence rests on cannot be discarded';
    result := case when ok then 'pass' else 'FAIL — it was discarded anyway' end;
    return next;
  end;

  -- A placeholder is not a result ---------------------------------------------
  declare stub uuid;
  begin
    insert into analysis_run (engagement_id, job_type, status, finished_at,
                              model_name, compute_output)
         values (eng, 'analysis:note_sufficiency', 'succeeded', now(), 'stub',
                 '{"rate":0.72}'::jsonb)
      returning id into stub;
    ok := false;
    begin
      perform gea_accept_run(stub, 'Fixture: looks fine.');
    exception when others then ok := true;
    end;
    rule := 'D8';
    description := 'a run from an analysis that is still a stub cannot be accepted';
    result := case when ok then 'pass'
                   else 'FAIL — an invented figure became evidence' end;
    return next;
  end;

  -- Mapping a field back lifts the cap its absence caused ---------------------
  perform gea_confirm_mapping(eng, capf, 'unmapped');
  perform gea_confirm_mapping(eng, capf, 'confirmed', 'Found It After All');
  select count(*) into n from score s
    join canonical_field_cap cc on cc.element_id = s.element_id
                               and cc.canonical_field_id = capf
   where s.engagement_id = eng and s.cap_applied is not null;
  rule := 'D7';
  description := 'finding a field after all lifts the cap its absence caused';
  result := case when n = 0 then 'pass'
                 else 'FAIL — ' || n || ' score(s) still capped' end;
  return next;

  -- Tidy up. The engagement goes first: client does not cascade, deliberately,
  -- because losing a client should never quietly take its engagements with it.
  delete from engagement where id = eng;
  delete from client where id = cl;
  delete from app_user where id = usr;
end $$;

comment on function gea_verify_derived is
  'Proves that a judgement recorded about a piece of evidence is reopened when '
  'that evidence goes. Add a rule whenever a new piece of derived state '
  'appears.';
