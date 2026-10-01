-- Verification for the activation gate.
--
-- Each check is tested twice over: the violation must be refused, and the
-- clean case must be allowed. A rule that refuses everything passes the first
-- half and is useless.
--
-- The suite clones the seeded instrument into a throwaway draft, breaks the
-- clone one way at a time, and attempts activation. Every mutation is rolled
-- back, so the real v0.6 is never touched and nothing is left behind.
--
-- Run:  select * from gea_verify_014();

create or replace function gea_clone_instrument(p_src uuid, p_label text)
returns uuid language plpgsql as $fn$
declare v_new uuid;
begin
  insert into instrument_version (label, status, notes)
    values (p_label, 'draft', 'throwaway clone for activation testing')
    returning id into v_new;

  insert into element (instrument_version_id, ref, kind, stage_code, from_stage,
    to_stage, name, why_assessed, evidence_required, method, owner_role,
    support_role, fallback_rule, ne_permitted, tier_dependent, evidence_decays,
    has_retrievability_test, sort_order, scored_without_export)
  select v_new, ref, kind, stage_code, from_stage, to_stage, name, why_assessed,
    evidence_required, method, owner_role, support_role, fallback_rule,
    ne_permitted, tier_dependent, evidence_decays, has_retrievability_test,
    sort_order, scored_without_export
    from element where instrument_version_id = p_src;

  insert into anchor (element_id, level, descriptor)
  select e2.id, a.level, a.descriptor
    from anchor a
    join element e1 on e1.id = a.element_id
    join element e2 on e2.ref = e1.ref and e2.instrument_version_id = v_new
   where e1.instrument_version_id = p_src;

  insert into export_line (instrument_version_id, tier, ref, title)
  select v_new, tier, ref, title
    from export_line where instrument_version_id = p_src;

  insert into export_line_element (export_line_id, element_id)
  select l2.id, e2.id
    from export_line_element x
    join export_line l1 on l1.id = x.export_line_id
    join element     e1 on e1.id = x.element_id
    join export_line l2 on l2.ref = l1.ref and l2.instrument_version_id = v_new
    join element     e2 on e2.ref = e1.ref and e2.instrument_version_id = v_new
   where l1.instrument_version_id = p_src;

  return v_new;
end $fn$;


create or replace function gea_verify_014(p_label text default 'v0.6')
returns table (rule text, description text, result text)
language plpgsql as $fn$
declare
  src uuid;
  cl  uuid;
  ok  boolean;
  msg text;
  n   integer;
begin
  select id into src from instrument_version where label = p_label;
  if src is null then
    rule := 'V00'; description := 'the seeded instrument exists';
    result := 'FAIL — no version labelled ' || p_label; return next; return;
  end if;

  cl := gea_clone_instrument(src, '__activation_test__');

  -- V01 the named requirement: a missing anchor blocks, and says which element
  ok := false; msg := '';
  begin
    delete from anchor a using element e
     where a.element_id = e.id and e.instrument_version_id = cl
       and e.ref = '5.2' and a.level = 4;
    update prompt_version set status = 'active';
    update instrument_version set status = 'active' where id = cl;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    msg := sqlerrm;
    ok := msg <> 'GEA_NOT_ENFORCED' and position('5.2' in msg) > 0;
  end;
  rule := 'V01';
  description := 'a draft missing one anchor cannot activate, and names the element';
  result := case when ok then 'pass'
                 when msg = 'GEA_NOT_ENFORCED' then 'FAIL — activation was allowed'
                 else 'FAIL — refused but did not name 5.2' end;
  return next;

  -- V02 element count
  ok := false;
  begin
    delete from element where instrument_version_id = cl and ref = '8.5';
    update prompt_version set status = 'active';
    update instrument_version set status = 'active' where id = cl;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    ok := sqlerrm <> 'GEA_NOT_ENFORCED';
  end;
  rule := 'V02'; description := 'a draft with 47 elements cannot activate';
  result := case when ok then 'pass' else 'FAIL — activation was allowed' end;
  return next;

  -- V03 stage shape
  ok := false;
  begin
    update element set stage_code = '07'
     where instrument_version_id = cl and ref = '8.1';
    update prompt_version set status = 'active';
    update instrument_version set status = 'active' where id = cl;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    ok := sqlerrm <> 'GEA_NOT_ENFORCED';
  end;
  rule := 'V03'; description := 'a stage holding four or six elements cannot activate';
  result := case when ok then 'pass' else 'FAIL — activation was allowed' end;
  return next;

  -- V04 coverage
  ok := false; msg := '';
  begin
    delete from export_line_element x using element e
     where x.element_id = e.id and e.instrument_version_id = cl and e.ref = '1.1';
    update prompt_version set status = 'active';
    update instrument_version set status = 'active' where id = cl;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    msg := sqlerrm;
    ok := msg <> 'GEA_NOT_ENFORCED' and position('1.1' in msg) > 0;
  end;
  rule := 'V04';
  description := 'an uncovered element that is not marked exempt cannot activate';
  result := case when ok then 'pass'
                 when msg = 'GEA_NOT_ENFORCED' then 'FAIL — activation was allowed'
                 else 'FAIL — refused but did not name 1.1' end;
  return next;

  -- V04b the exemption is what makes it acceptable, not the absence itself
  ok := false;
  begin
    delete from export_line_element x using element e
     where x.element_id = e.id and e.instrument_version_id = cl and e.ref = '1.1';
    update element set scored_without_export = true
     where instrument_version_id = cl and ref = '1.1';
    update prompt_version set status = 'active';
    select count(*) into n from gea_activation_failures(cl);
    ok := n = 0;
    raise exception 'GEA_ROLLBACK';
  exception when others then
    if sqlerrm <> 'GEA_ROLLBACK' then ok := false; end if;
  end;
  rule := 'V04b';
  description := 'the same element marked as scored without an export is accepted';
  result := case when ok then 'pass' else 'FAIL — exemption not honoured' end;
  return next;

  -- V05 prompts
  ok := false; msg := '';
  begin
    update prompt_version set status = 'active';
    update prompt_version set status = 'draft' where ref = 'GEA-P01';
    update instrument_version set status = 'active' where id = cl;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    msg := sqlerrm;
    ok := msg <> 'GEA_NOT_ENFORCED' and position('GEA-P01' in msg) > 0;
  end;
  rule := 'V05';
  description := 'a step whose prompt has no active version blocks activation, and names it';
  result := case when ok then 'pass'
                 when msg = 'GEA_NOT_ENFORCED' then 'FAIL — activation was allowed'
                 else 'FAIL — refused but did not name GEA-P01' end;
  return next;

  -- V06 tier dependence
  ok := false;
  begin
    update element set tier_dependent = true
     where instrument_version_id = cl and ref = '1.1';
    update prompt_version set status = 'active';
    update instrument_version set status = 'active' where id = cl;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    ok := sqlerrm <> 'GEA_NOT_ENFORCED';
  end;
  rule := 'V06'; description := 'tier dependence on other than five elements cannot activate';
  result := case when ok then 'pass' else 'FAIL — activation was allowed' end;
  return next;

  -- V07 an exempt element cannot also carry an export line
  ok := false;
  begin
    insert into export_line_element (export_line_id, element_id)
    select l.id, e.id from export_line l, element e
     where l.instrument_version_id = cl and l.ref = 'T1-01'
       and e.instrument_version_id = cl and e.ref = 'H01';
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    ok := sqlerrm <> 'GEA_NOT_ENFORCED';
  end;
  rule := 'V07';
  description := 'an element marked as scored without an export cannot take one';
  result := case when ok then 'pass' else 'FAIL — the link was allowed' end;
  return next;

  -- V08 a prompt cannot activate without its contract
  ok := false;
  begin
    update prompt_version set discard_conditions = '[]'::jsonb where ref = 'GEA-P01';
    update prompt_version set status = 'active' where ref = 'GEA-P01';
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    ok := sqlerrm <> 'GEA_NOT_ENFORCED';
  end;
  rule := 'V08';
  description := 'a prompt with no discard condition cannot be activated';
  result := case when ok then 'pass' else 'FAIL — activation was allowed' end;
  return next;

  -- V09 the positive case: a clean draft activates and becomes immutable
  ok := false; msg := '';
  begin
    update prompt_version set status = 'active';
    update instrument_version set status = 'active' where id = cl;
    select status::text into msg from instrument_version where id = cl;
    ok := msg = 'active';
    if ok then
      begin
        update element set name = 'tampered'
         where instrument_version_id = cl and ref = '1.1';
        ok := false;  -- the immutability trigger should have refused this
      exception when others then
        ok := true;
      end;
    end if;
    raise exception 'GEA_ROLLBACK';
  exception when others then
    if sqlerrm <> 'GEA_ROLLBACK' then ok := false; end if;
  end;
  rule := 'V09';
  description := 'a complete draft activates, and is immutable immediately afterwards';
  result := case when ok then 'pass' else 'FAIL — clean draft refused, or still editable' end;
  return next;

  -- V10 supersession: a changed element must declare how it changed
  ok := false; msg := '';
  begin
    update prompt_version set status = 'active';
    update instrument_version set status = 'active' where id = cl;
    declare cl2 uuid;
    begin
      cl2 := gea_clone_instrument(cl, '__activation_test_2__');
      update anchor a set descriptor = descriptor || ' (reworded)'
        from element e
       where a.element_id = e.id and e.instrument_version_id = cl2
         and e.ref = '4.2' and a.level = 3;
      update instrument_version set status = 'active' where id = cl2;
      raise exception 'GEA_NOT_ENFORCED';
    end;
  exception when others then
    msg := sqlerrm;
    ok := msg <> 'GEA_NOT_ENFORCED' and position('4.2' in msg) > 0;
  end;
  rule := 'V10';
  description := 'a reworded anchor in a superseding version needs a declared change type';
  result := case when ok then 'pass'
                 when msg = 'GEA_NOT_ENFORCED' then 'FAIL — activation was allowed'
                 else 'FAIL — refused but did not name 4.2' end;
  return next;

  -- V11 the real instrument is untouched by all of the above
  select count(*) into n from gea_activation_failures(src);
  rule := 'V11';
  description := 'the seeded instrument is unchanged and its only blocker is prompt status';
  result := case when n = (select count(distinct ref) from prompt_version
                            where step_ref is not null and status <> 'active')
                 then 'pass' else 'FAIL — ' || n || ' unexpected failures' end;
  return next;

  delete from instrument_version where label in ('__activation_test__',
                                                 '__activation_test_2__');
  return;
end $fn$;
