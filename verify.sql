-- GEA schema verification
-- Paste into the Supabase SQL editor and run:   select * from gea_verify();
-- Every row should read 'pass'. Any FAIL means a methodology rule is not being
-- enforced by the database, and nothing should be built on top until it is.
--
-- Safe to run against an empty database. It creates fixtures, attempts each
-- violation inside a rolled-back block, then removes the fixtures.

create or replace function gea_verify()
returns table (rule text, description text, result text)
language plpgsql as $fn$
declare ok boolean;
begin
  -- fixtures ---------------------------------------------------------------
    insert into instrument_version (id,label,status) values
            ('11111111-1111-1111-1111-111111111111','0.6-test','draft');
  
          insert into element (id,instrument_version_id,ref,kind,stage_code,name,
                               ne_permitted,tier_dependent)
          values
            ('22222222-2222-2222-2222-222222222221','11111111-1111-1111-1111-111111111111',
             '1.1','element','01','ICP definition', true, false),
            ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111',
             '2.3','element','02','Proof architecture', false, false),
            ('22222222-2222-2222-2222-222222222223','11111111-1111-1111-1111-111111111111',
             '2.5','element','02','Discovery quality', true, true),
            ('22222222-2222-2222-2222-222222222224','11111111-1111-1111-1111-111111111111',
             'H01','handoff',null,'Stage 01 to 02', false, false);
  
          insert into app_user (id,auth_subject,email,display_name,org_role) values
            ('33333333-3333-3333-3333-333333333331','44444444-4444-4444-4444-444444444441',
             'ga@blend.test','GA One','ga'),
            ('33333333-3333-3333-3333-333333333332','44444444-4444-4444-4444-444444444442',
             'gc@blend.test','GC One','gc'),
            ('33333333-3333-3333-3333-333333333333','44444444-4444-4444-4444-444444444443',
             'out@blend.test','Outsider','gc');
  
          insert into client (id,company_name) values
            ('55555555-5555-5555-5555-555555555555','Fixture Co');
  
          insert into engagement (id,client_id,instrument_version_id,name,motion_in_scope,
                                  window_start,window_end,storage_prefix)
          values ('66666666-6666-6666-6666-666666666666',
                  '55555555-5555-5555-5555-555555555555',
                  '11111111-1111-1111-1111-111111111111',
                  'Fixture GEA','New business','2024-01-01','2025-12-31','eng/fixture');
  
          insert into engagement_member (engagement_id,app_user_id,engagement_role) values
            ('66666666-6666-6666-6666-666666666666','33333333-3333-3333-3333-333333333331','lead_architect'),
            ('66666666-6666-6666-6666-666666666666','33333333-3333-3333-3333-333333333332','lead_consultant');
  
          insert into population_count (id,engagement_id,key,value,exclusion_rule) values
            ('77777777-7777-7777-7777-777777777777','66666666-6666-6666-6666-666666666666',
             'closed_won',412,'Closed-won opportunities with a close date inside the window');
  
          insert into analysis_run (id,engagement_id,job_type,status,accepted_at) values
            ('88888888-8888-8888-8888-888888888881','66666666-6666-6666-6666-666666666666',
             'analysis:pricing','succeeded',now()),
            ('88888888-8888-8888-8888-888888888882','66666666-6666-6666-6666-666666666666',
             'analysis:pipeline','succeeded',null),
            ('88888888-8888-8888-8888-888888888883','66666666-6666-6666-6666-666666666666',
             'classify:discovery','succeeded',null);
  
          insert into score (id,engagement_id,element_id,state) values
            ('99999999-9999-9999-9999-999999999991','66666666-6666-6666-6666-666666666666',
             '22222222-2222-2222-2222-222222222221','unscored');

  -- rule checks ------------------------------------------------------------

  -- R1a
  ok := false;
  begin
        update instrument_version set status='active', activated_at=now()
          where id='11111111-1111-1111-1111-111111111111';
        insert into anchor (element_id, level, descriptor)
          values ('22222222-2222-2222-2222-222222222221', 0, 'sneaked in');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R1a'; description := 'Reference data cannot be inserted against an activated instrument version';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R1b
  ok := false;
  begin
        insert into anchor (id, element_id, level, descriptor)
          values ('aaaaaaa1-0000-0000-0000-000000000001',
                  '22222222-2222-2222-2222-222222222221', 3, 'original');
        update instrument_version set status='active', activated_at=now()
          where id='11111111-1111-1111-1111-111111111111';
        update anchor set descriptor='rewritten'
          where id='aaaaaaa1-0000-0000-0000-000000000001';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R1b'; description := 'Anchor text cannot be edited on an activated instrument version';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R2
  ok := false;
  begin
        insert into metric (engagement_id, metric_key, value, unit)
          values ('66666666-6666-6666-6666-666666666666','win_rate',0.42,'rate');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R2'; description := 'A rate metric cannot be stored without a denominator';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R3
  ok := false;
  begin
        insert into score (engagement_id, element_id, value, not_evidenced, ne_reason)
          values ('66666666-6666-6666-6666-666666666666',
                  '22222222-2222-2222-2222-222222222223', 3, true, 'both');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R3'; description := 'A score cannot carry both a value and Not Evidenced';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R4
  ok := false;
  begin
        insert into score (engagement_id, element_id, not_evidenced, ne_reason)
          values ('66666666-6666-6666-6666-666666666666',
                  '22222222-2222-2222-2222-222222222222', true, 'no evidence found');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R4'; description := 'Not Evidenced is refused on an element that forbids it';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R5
  ok := false;
  begin
        update element set ne_permitted = true
          where id = '22222222-2222-2222-2222-222222222224';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R5'; description := 'Not Evidenced is refused on a handoff';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R6
  ok := false;
  begin
        insert into score (engagement_id, element_id, value, cap_applied, cap_reason)
          values ('66666666-6666-6666-6666-666666666666',
                  '22222222-2222-2222-2222-222222222223', 4, 2, 'loss_reason unmapped');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R6'; description := 'A score cannot exceed a cap applied to it';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R7
  ok := false;
  begin
        insert into evidence_tier (engagement_id, tier, verdict, score_ceiling)
          values ('66666666-6666-6666-6666-666666666666','C','fail',4);
        insert into score (engagement_id, element_id, value)
          values ('66666666-6666-6666-6666-666666666666',
                  '22222222-2222-2222-2222-222222222223', 5);
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R7'; description := 'A tier-dependent element cannot exceed the evidence tier ceiling';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R8
  ok := false;
  begin
        update score set value = 3, state = 'final'
          where id = '99999999-9999-9999-9999-999999999991';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R8'; description := 'A score cannot become final without a citation';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R9
  ok := false;
  begin
        insert into score_citation (score_id, analysis_run_id)
          values ('99999999-9999-9999-9999-999999999991',
                  '88888888-8888-8888-8888-888888888882');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R9'; description := 'A score cannot cite a run that has not been accepted';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R10
  ok := false;
  begin
        insert into score_citation (score_id, note)
          values ('99999999-9999-9999-9999-999999999991','I remember seeing it');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R10'; description := 'A citation must point at something retrievable';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R11
  ok := false;
  begin
        insert into score_citation (score_id, analysis_run_id)
          values ('99999999-9999-9999-9999-999999999991',
                  '88888888-8888-8888-8888-888888888881');
        update analysis_run set is_stale = true
          where id = '88888888-8888-8888-8888-888888888881';
        update score set value = 3, state = 'final'
          where id = '99999999-9999-9999-9999-999999999991';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R11'; description := 'A score cannot become final while citing a stale run';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R12
  ok := false;
  begin
        update analysis_run set compute_output = '{"rewritten": true}'::jsonb
          where id = '88888888-8888-8888-8888-888888888881';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R12'; description := 'A completed analysis run''s output cannot be edited';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R13
  ok := false;
  begin
        update analysis_run set accepted_at = now()
          where id = '88888888-8888-8888-8888-888888888883';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R13'; description := 'A classification run cannot be accepted without a trusted validation set';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R14
  ok := false;
  begin
        insert into population_count (engagement_id, key, value, exclusion_rule)
          values ('66666666-6666-6666-6666-666666666666','closed_lost',700,'   ');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R14'; description := 'A population count cannot be stored without an exclusion rule';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R15
  ok := false;
  begin
        insert into analysis_capability (engagement_id, analysis_key, verdict)
          values ('66666666-6666-6666-6666-666666666666','forecast_accuracy','supported');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R15'; description := 'An analysis cannot be marked supported without naming supporting fields';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R16
  ok := false;
  begin
        insert into tco_line (engagement_id, category, annual_cost, is_open_input)
          values ('66666666-6666-6666-6666-666666666666','Duplicate licensing',48000,false);
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R16'; description := 'A cost line with a figure must trace to a source document';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R17
  ok := false;
  begin
        insert into evidence_requirement (instrument_version_id, element_id, ref, source_kind,
                                          description, waiver_consequence)
          values ('11111111-1111-1111-1111-111111111111',
                  '22222222-2222-2222-2222-222222222221','1.1-R1','export',
                  'Closed opportunity export','Element 1.1 scored on interview alone');
        insert into engagement_requirement (engagement_id, evidence_requirement_id, state)
          select '66666666-6666-6666-6666-666666666666', id, 'waived'
            from evidence_requirement where ref = '1.1-R1';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R17'; description := 'A requirement cannot be waived without a reason';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R18
  ok := false;
  begin
        insert into library_record (engagement_id, instrument_version_id, segment_attributes,
                                    snapshot, contains_identifiable_data)
          values ('66666666-6666-6666-6666-666666666666',
                  '11111111-1111-1111-1111-111111111111','{}'::jsonb,'{}'::jsonb, true);
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R18'; description := 'The library record cannot contain identifiable data';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R19
  ok := false;
  begin
        insert into instrument_version (id,label,status)
          values ('1111111a-1111-1111-1111-111111111111','0.7-test','draft');
        insert into element_version_change (from_instrument_version_id, to_instrument_version_id,
                                            element_ref, change_type)
          values ('11111111-1111-1111-1111-111111111111',
                  '1111111a-1111-1111-1111-111111111111','2.5','threshold');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R19'; description := 'A threshold change must name the metric to be recompared';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R20
  ok := false;
  begin
        insert into measurement_definition (engagement_id, metric_key, name, is_computable)
          values ('66666666-6666-6666-6666-666666666666','m04','Signal to first contact', true);
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R20'; description := 'A metric marked computable must name its source fields';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R21
  ok := false;
  begin
        insert into honesty_test (engagement_id, question_one_answer, question_two_answer)
          values ('66666666-6666-6666-6666-666666666666','Yes','No');
        update score set value = 3, state = 'provisional'
          where id = '99999999-9999-9999-9999-999999999991';
        update engagement set score_frozen_at = now()
          where id = '66666666-6666-6666-6666-666666666666';
        update score set value = 4
          where id = '99999999-9999-9999-9999-999999999991';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R21'; description := 'A frozen scorecard cannot be changed';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R22
  ok := false;
  begin
        insert into honesty_test (engagement_id, question_one_answer, question_two_answer)
          values ('66666666-6666-6666-6666-666666666666','Yes','No');
        update score set value = 3, state = 'provisional'
          where id = '99999999-9999-9999-9999-999999999991';
        insert into challenge (engagement_id, element_id, challenge_text)
          values ('66666666-6666-6666-6666-666666666666',
                  '22222222-2222-2222-2222-222222222221','Single source');
        update engagement set score_frozen_at = now()
          where id = '66666666-6666-6666-6666-666666666666';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R22'; description := 'An engagement cannot be frozen while a challenge is open';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R23
  ok := false;
  begin
        update score set value = 3, state = 'provisional'
          where id = '99999999-9999-9999-9999-999999999991';
        update engagement set score_frozen_at = now()
          where id = '66666666-6666-6666-6666-666666666666';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R23'; description := 'An engagement cannot be frozen without the honesty test';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R24
  ok := false;
  begin
        insert into engagement_member (engagement_id, app_user_id, engagement_role)
          values ('66666666-6666-6666-6666-666666666666',
                  '33333333-3333-3333-3333-333333333333','lead_consultant');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R24'; description := 'An engagement cannot hold two active lead consultants';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R25
  ok := false;
  begin
        update engagement_member set to_date = current_date
          where engagement_id = '66666666-6666-6666-6666-666666666666'
            and engagement_role = 'lead_architect';
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R25'; description := 'The last active lead architect cannot be removed';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;

  -- R26
  ok := false;
  begin
        insert into artefact (engagement_id, kind, original_filename, storage_path, sha256)
          values ('66666666-6666-6666-6666-666666666666','raw_export','deals.csv','p/1','abc123');
        insert into artefact (engagement_id, kind, original_filename, storage_path, sha256)
          values ('66666666-6666-6666-6666-666666666666','raw_export','deals-copy.csv','p/2','abc123');
    set constraints all immediate;   -- force deferred triggers to fire now
    ok := false;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R26'; description := 'The same file cannot be registered twice against one engagement';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end;
  return next;


  -- structural check: row-level security -----------------------------------
  select count(*) = 0 into ok
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname in ('engagement','score','artefact','analysis_run','metric',
                       'population_count','interview','task','deliverable')
     and not (c.relrowsecurity and c.relforcerowsecurity);
  rule := 'RLS'; description := 'Row-level security is enabled and forced on protected tables';
  result := case when ok then 'pass' else 'FAIL — a protected table is unguarded' end;
  return next;

  -- clean up ---------------------------------------------------------------
  delete from engagement where id = '66666666-6666-6666-6666-666666666666';
  delete from client where id = '55555555-5555-5555-5555-555555555555';
  delete from app_user where id in (
    '33333333-3333-3333-3333-333333333331',
    '33333333-3333-3333-3333-333333333332',
    '33333333-3333-3333-3333-333333333333');
  delete from instrument_version where id = '11111111-1111-1111-1111-111111111111';
  return;
end $fn$;
