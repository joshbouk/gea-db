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

  -- A classification nobody read is not evidence ------------------------------
  declare cls uuid;
  begin
    insert into analysis_run (engagement_id, job_type, status, finished_at,
                              model_name, compute_output)
         values (eng, 'analysis:discovery_consistency_classification',
                 'succeeded', now(), 'claude-sonnet-4-6',
                 jsonb_build_object(
                   'census_complete', true,
                   'to_check_by_hand', jsonb_build_array(
                     jsonb_build_object('record_id', 'N1', 'labels',
                                        jsonb_build_object('next_step', 'yes')))))
      returning id into cls;
    ok := false;
    begin
      perform gea_accept_run(cls, 'Fixture: looks right.');
    exception when others then ok := true;
    end;
    rule := 'D9';
    description := 'a classification nobody read cannot become evidence';
    result := case when ok then 'pass'
                   else 'FAIL — an unchecked classification was accepted' end;
    return next;
  end;

  -- Every enqueue says what it is about --------------------------------------
  --
  -- A job's key decides whether two requests are the same work. Get it
  -- wrong in one direction — a timestamp in the key — and nothing ever
  -- matches, so three files produce three identical runs. Get it wrong
  -- in the other — no key at all — and everything matches the first run
  -- ever made, so the job runs once and never again. Both were shipped,
  -- twice each, and neither failed loudly.
  --
  -- A function may queue work without a key only if it first refuses
  -- when one is already in flight. Anything else is a job that will
  -- either duplicate itself or never run twice.
  declare unkeyed text[];
  begin
    select coalesce(array_agg(p.proname order by p.proname), array[]::text[])
      into unkeyed
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname <> 'gea_enqueue_run'
       and p.prosrc like '%gea_enqueue_run%'
       -- No key passed: no parameters, no hashes, no artefacts.
       and pg_get_functiondef(p.oid) ~
           'gea_enqueue_run\s*\([^;]*?\)\s*(e\s*)?;'
       and pg_get_functiondef(p.oid) !~ 'jsonb_build_object|p_parameters|v_params|input_hashes|p_hashes|r\.parameters'
       -- And no guard against one already running.
       and pg_get_functiondef(p.oid) !~ 'status in \(''queued'', ?''running''\)';
    rule := 'D12';
    description := 'every enqueue says what it is about';
    result := case when array_length(unkeyed, 1) is null then 'pass'
                   else 'FAIL — ' || array_to_string(unkeyed, ', ')
                        || ' queue work with no key and no guard, so each '
                        || 'will run once and never again' end;
    return next;
  end;

  -- A clone carries everything an instrument owns ---------------------------
  --
  -- gea_clone_instrument copies the tables somebody remembered. Two were
  -- added to the methodology after it was written and never added to it,
  -- so one version silently lost thirteen pieces of reviewer guidance and
  -- the next lost the shape of the report. Nothing failed and nothing
  -- said anything.
  --
  -- A table carrying instrument_version_id belongs to an instrument and
  -- has to be cloned with it. The two exceptions name themselves: an
  -- engagement points at the version it is pinned to, and a library
  -- record is written once and outlives every version.
  declare forgotten text[];
  begin
    select coalesce(array_agg(c.table_name order by c.table_name),
                    array[]::text[])
      into forgotten
      from information_schema.columns c
      join pg_proc p on p.proname = 'gea_clone_instrument'
     where c.column_name = 'instrument_version_id'
       and c.table_schema = 'public'
       and c.table_name not in ('engagement', 'library_record')
       and position(c.table_name in
             pg_get_functiondef(p.oid)
             || coalesce((select pg_get_functiondef(b.oid) from pg_proc b
                           where b.proname = 'gea_clone_instrument_body'), '')
           ) = 0;
    rule := 'D11';
    description := 'a clone carries everything an instrument owns';
    result := case when array_length(forgotten, 1) is null then 'pass'
                   else 'FAIL — ' || array_to_string(forgotten, ', ')
                        || ' would be lost at the next version' end;
    return next;
  end;

  -- Nothing survives the file it was about -----------------------------------
  --
  -- The standing version of a bug found five separate times: a mapping,
  -- an absence, a cap, a run and a citation each outlived the file they
  -- were about, and each was fixed on its own after somebody hit it. This
  -- asks the whole question at once, so the sixth is caught here instead.
  declare gone uuid; leftovers text[] := array[]::text[];
  begin
    select a.id into gone from artefact a
     where a.engagement_id = eng and a.purged_at is null
       and a.is_row_data limit 1;
    if gone is not null then
      perform gea_purge_artefact(gone, 'Fixture: checking nothing survives.');

      if exists (select 1 from field_mapping m
                   join dataset d on d.id = m.dataset_id
                  where d.artefact_id = gone
                    and m.status in ('confirmed','corrected','auto_accepted')) then
        leftovers := leftovers || 'a confirmed mapping'::text;
      end if;
      if exists (select 1 from score_citation c where c.artefact_id = gone) then
        leftovers := leftovers || 'a score citation'::text;
      end if;
      if exists (select 1 from analysis_run r
                  where gone = any (r.input_artefact_ids) and not r.is_stale) then
        leftovers := leftovers || 'a run that is not stale'::text;
      end if;
      if exists (select 1 from dataset_row r
                   join dataset d on d.id = r.dataset_id
                  where d.artefact_id = gone) then
        leftovers := leftovers || 'its rows'::text;
      end if;
      if exists (select 1 from score s
                   join score_citation c on c.score_id = s.id
                  where s.engagement_id = eng and s.state = 'final'
                    and c.artefact_id = gone) then
        leftovers := leftovers || 'a final score citing it'::text;
      end if;
    end if;
    rule := 'D10';
    description := 'nothing survives the file it was about';
    result := case when array_length(leftovers, 1) is null then 'pass'
                   else 'FAIL — ' || array_to_string(leftovers, ', ')
                        || ' outlived the removed file' end;
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
