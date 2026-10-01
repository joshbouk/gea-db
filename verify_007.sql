-- Verification for 007, the Zone A additions.
--
-- Covers the three reference tables the immutability trigger originally
-- missed, and the cap model that replaced cap_element_refs and cap_rule.
--
-- Run:  select * from gea_verify_007();

create or replace function gea_verify_007()
returns table (rule text, description text, result text)
language plpgsql as $fn$
declare ok boolean;
begin
  insert into instrument_version (id, label, status)
    values ('0d7a0000-0000-0000-0000-000000000001', '0.7-verify-007', 'draft');
  insert into element (id, instrument_version_id, ref, kind, stage_code, name, ne_permitted) values
    ('0d7a0000-0000-0000-0000-0000000000e1', '0d7a0000-0000-0000-0000-000000000001',
     '2.2', 'element', '02', 'Persona messaging', true),
    ('0d7a0000-0000-0000-0000-0000000000e2', '0d7a0000-0000-0000-0000-000000000001',
     '5.3', 'element', '05', 'Buyer enablement', true);
  insert into canonical_field (id, instrument_version_id, key, is_cap_bearing) values
    ('0d7a0000-0000-0000-0000-0000000000f1', '0d7a0000-0000-0000-0000-000000000001',
     'verify_contact_role', true),
    ('0d7a0000-0000-0000-0000-0000000000f2', '0d7a0000-0000-0000-0000-000000000001',
     'verify_plain_field', false);
  insert into export_line (id, instrument_version_id, tier, ref, title)
    values ('0d7a0000-0000-0000-0000-0000000000c1',
            '0d7a0000-0000-0000-0000-000000000001', 1, 'TV-01', 'Verify line');
  insert into interview_guide (id, instrument_version_id, ref, function_name)
    values ('0d7a0000-0000-0000-0000-0000000000a1',
            '0d7a0000-0000-0000-0000-000000000001', 9, 'Verify guide');
  insert into interview_question (id, interview_guide_id, sort_order, question_text)
    values ('0d7a0000-0000-0000-0000-0000000000b1',
            '0d7a0000-0000-0000-0000-0000000000a1', 1, 'Verify question');

  -- R27
  ok := false;
  begin
    update instrument_version set status = 'active', activated_at = now()
      where id = '0d7a0000-0000-0000-0000-000000000001';
    insert into export_line_element (export_line_id, element_id)
      values ('0d7a0000-0000-0000-0000-0000000000c1',
              '0d7a0000-0000-0000-0000-0000000000e1');
    set constraints all immediate;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R27';
  description := 'The coverage map cannot be changed on an activated instrument version';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end; return next;

  -- R28
  ok := false;
  begin
    update instrument_version set status = 'active', activated_at = now()
      where id = '0d7a0000-0000-0000-0000-000000000001';
    update interview_question set question_text = 'rewritten'
      where id = '0d7a0000-0000-0000-0000-0000000000b1';
    set constraints all immediate;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R28';
  description := 'Interview question text cannot be edited on an activated instrument version';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end; return next;

  -- R29
  ok := false;
  begin
    update instrument_version set status = 'active', activated_at = now()
      where id = '0d7a0000-0000-0000-0000-000000000001';
    insert into interview_question_element (interview_question_id, element_id)
      values ('0d7a0000-0000-0000-0000-0000000000b1',
              '0d7a0000-0000-0000-0000-0000000000e1');
    set constraints all immediate;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R29';
  description := 'Question-to-element mapping cannot be changed on an activated instrument version';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end; return next;

  -- R30
  ok := false;
  begin
    insert into canonical_field_cap (canonical_field_id, element_id, cap_level, condition)
      values ('0d7a0000-0000-0000-0000-0000000000f2',
              '0d7a0000-0000-0000-0000-0000000000e1', 2, 'x');
    set constraints all immediate;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R30';
  description := 'A cap rule cannot sit on a field that is not cap-bearing';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end; return next;

  -- R31
  ok := false;
  begin
    insert into canonical_field_cap (canonical_field_id, element_id, cap_level, condition)
      values ('0d7a0000-0000-0000-0000-0000000000f1',
              '0d7a0000-0000-0000-0000-0000000000e1', 6, 'x');
    set constraints all immediate;
    raise exception 'GEA_NOT_ENFORCED';
  exception when others then
    if sqlerrm = 'GEA_NOT_ENFORCED' then ok := false; else ok := true; end if;
  end;
  rule := 'R31'; description := 'A cap level outside 0 to 5 is refused';
  result := case when ok then 'pass' else 'FAIL — violation was allowed' end; return next;

  -- R32 positive: the thing the old text[] could not express must now work
  ok := false;
  begin
    insert into canonical_field_cap (canonical_field_id, element_id, cap_level, condition) values
      ('0d7a0000-0000-0000-0000-0000000000f1', '0d7a0000-0000-0000-0000-0000000000e1',
       3, 'contact roles not populated'),
      ('0d7a0000-0000-0000-0000-0000000000f1', '0d7a0000-0000-0000-0000-0000000000e2',
       2, 'absent on the majority of closed-won deals');
    ok := true;
    raise exception 'GEA_ROLLBACK';
  exception when others then
    if sqlerrm = 'GEA_ROLLBACK' then ok := true; else ok := false; end if;
  end;
  rule := 'R32';
  description := 'One field can cap two elements at two different levels';
  result := case when ok then 'pass' else 'FAIL — the cap model cannot express it' end;
  return next;

  delete from instrument_version where id = '0d7a0000-0000-0000-0000-000000000001';
  return;
end $fn$;
