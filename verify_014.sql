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

-- gea_clone_instrument used to be defined here, and that was the bug.
-- apply.py installs the verification suites after the migrations, so this
-- definition overwrote the real one at the end of every run. The next
-- migration to clone an instrument then used a throwaway built for
-- activation testing, which copies elements and leaves the canonical
-- fields, evidence requirements, interview guides and measurement
-- definitions behind — and says nothing while doing it.
--
-- It lives in migration 057 now. This suite uses it like any other caller.



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

  -- V08 an active prompt cannot lose its contract.
  -- This originally tested the transition into active, which stopped testing
  -- anything once the prompts were activated: the gate only fired when the
  -- status changed. Emptying the contract of a prompt that is already active
  -- is the same failure and is now refused.
  ok := false;
  begin
    update prompt_version set status = 'active' where ref = 'GEA-P01';
    update prompt_version set discard_conditions = '[]'::jsonb where ref = 'GEA-P01';
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    ok := sqlerrm <> 'GEA_NOT_ENFORCED';
  end;
  rule := 'V08';
  description := 'an active prompt cannot have its discard conditions removed';
  result := case when ok then 'pass' else 'FAIL — the change was allowed' end;
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
