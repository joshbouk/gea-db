-- 014 Activation gate.
--
-- Activating an instrument version makes it immutable and binds every
-- engagement that pins it. Until now nothing stood in the way: the R1 trigger
-- permits any update to a draft row, so `update instrument_version set
-- status = 'active'` succeeded and all the immutability protection switched on
-- behind whatever state the data happened to be in.
--
-- The gate is a trigger rather than a function the application calls, because
-- a gate that can be routed around by writing the UPDATE yourself is not a
-- gate. gea_activate_instrument() exists for the application's benefit and
-- gives a readable result, but it is a convenience over the trigger, not the
-- thing doing the work.
--
-- Hand-written. Reviewed before running.

-- 1. Record the elements scored without a client export ---------------------
-- 2.1, 2.4, 3.3, H01 and H02 are evidenced from public surfaces and interview.
-- That was previously a list hardcoded inside a verification function, which
-- meant the gate would have been checking the list rather than the data.

alter table element
  add column scored_without_export boolean not null default false;

update element set scored_without_export = true
 where ref in ('2.1', '2.4', '3.3', 'H01', 'H02');

-- RULE: an element is evidenced by exports or without them, never recorded as
-- both. Catching this at insert is cheaper than discovering it at activation.
create or replace function trg_no_export_link_when_exempt() returns trigger
language plpgsql as $fn$
declare v_ref text; v_exempt boolean;
begin
  select ref, scored_without_export into v_ref, v_exempt
    from element where id = new.element_id;
  if v_exempt then
    raise exception
      'element % is marked as scored without a client export and cannot take an export line',
      v_ref using errcode = 'check_violation';
  end if;
  return new;
end $fn$;

create trigger no_export_link_when_exempt
  before insert or update on export_line_element
  for each row execute function trg_no_export_link_when_exempt();

-- 2. What makes a prompt fit to activate ------------------------------------
-- Prompts version independently of the instrument, so this is its own gate.

create or replace function trg_prompt_activation_gate() returns trigger
language plpgsql as $fn$
begin
  if new.status = 'active' and old.status <> 'active' then
    if new.template is null or length(btrim(new.template)) = 0 then
      raise exception 'prompt % cannot activate without a template', new.ref
        using errcode = 'check_violation';
    end if;
    if new.output_contract = '{}'::jsonb then
      raise exception 'prompt % cannot activate without an output contract', new.ref
        using errcode = 'check_violation';
    end if;
    if jsonb_array_length(new.discard_conditions) = 0 then
      raise exception 'prompt % cannot activate without a discard condition', new.ref
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $fn$;

create trigger prompt_activation_gate before update on prompt_version
  for each row execute function trg_prompt_activation_gate();

-- 3. What an element is, for the purpose of noticing it changed -------------
-- Anchor text is included because a score is awarded against a descriptor. A
-- reworded anchor changes what a 3 means, even when nothing else moved.

create or replace function gea_element_fingerprint(p_element uuid)
returns text language sql stable as $fn$
  select md5(
    coalesce(e.name,'') || '|' || coalesce(e.why_assessed,'') || '|' ||
    coalesce(e.evidence_required,'') || '|' || coalesce(e.method,'') || '|' ||
    coalesce(e.fallback_rule,'') || '|' || e.ne_permitted::text || '|' ||
    e.tier_dependent::text || '|' || e.evidence_decays::text || '|' ||
    e.has_retrievability_test::text || '|' ||
    coalesce((select string_agg(a.level::text || ':' || a.descriptor, '~'
                                order by a.level)
                from anchor a where a.element_id = e.id), '')
  )
  from element e where e.id = p_element
$fn$;

-- 4. The gate ---------------------------------------------------------------

create or replace function gea_activation_failures(p_version uuid)
returns table (check_ref text, detail text)
language plpgsql stable as $fn$
declare
  v_prior uuid;
begin
  -- A1: the element set is complete
  if (select count(*) from element where instrument_version_id = p_version) <> 48 then
    check_ref := 'A1';
    detail := 'the instrument must hold 48 elements, found ' ||
      (select count(*) from element where instrument_version_id = p_version);
    return next;
  end if;

  if (select count(*) from element
       where instrument_version_id = p_version and kind = 'handoff') <> 8 then
    check_ref := 'A1';
    detail := 'the instrument must hold 8 handoffs, found ' ||
      (select count(*) from element
        where instrument_version_id = p_version and kind = 'handoff');
    return next;
  end if;

  -- A2: five elements in each of eight stages
  for check_ref, detail in
    select 'A2', 'stage ' || coalesce(stage_code, 'null') || ' holds ' ||
           count(*) || ' elements, expected 5'
      from element
     where instrument_version_id = p_version and kind = 'element'
     group by stage_code having count(*) <> 5
  loop return next; end loop;

  if (select count(distinct stage_code) from element
       where instrument_version_id = p_version and kind = 'element') <> 8 then
    check_ref := 'A2';
    detail := 'the instrument must span 8 stages, found ' ||
      (select count(distinct stage_code) from element
        where instrument_version_id = p_version and kind = 'element');
    return next;
  end if;

  -- A3: six anchors on every element, levels 0 to 5, no gaps
  for check_ref, detail in
    select 'A3', 'element ' || e.ref || ' carries ' ||
           coalesce(count(a.id), 0) || ' anchors at level(s) ' ||
           coalesce(string_agg(a.level::text, ',' order by a.level), 'none') ||
           ', expected 0 to 5'
      from element e
      left join anchor a on a.element_id = e.id
     where e.instrument_version_id = p_version
     group by e.id, e.ref
    having count(a.id) <> 6
        or min(a.level) <> 0
        or max(a.level) <> 5
        or count(distinct a.level) <> 6
  loop return next; end loop;

  -- A4: every element is evidenced by an export line or declared exempt
  for check_ref, detail in
    select 'A4', 'element ' || e.ref ||
           ' has no export line and is not marked as scored without one'
      from element e
     where e.instrument_version_id = p_version
       and not e.scored_without_export
       and not exists (select 1 from export_line_element x
                        where x.element_id = e.id)
  loop return next; end loop;

  -- A5: every prompt referenced by a step is present and active
  for check_ref, detail in
    select 'A5', 'prompt ' || p.ref || ' is referenced by step ' || p.step_ref ||
           ' and has no active version'
      from (select distinct ref, step_ref from prompt_version
             where step_ref is not null) p
     where not exists (select 1 from prompt_version q
                        where q.ref = p.ref and q.status = 'active')
  loop return next; end loop;

  -- A6: tier dependence on exactly five elements
  if (select count(*) from element
       where instrument_version_id = p_version and tier_dependent) <> 5 then
    check_ref := 'A6';
    detail := 'tier dependence must sit on exactly 5 elements, found ' ||
      (select count(*) from element
        where instrument_version_id = p_version and tier_dependent);
    return next;
  end if;

  -- A7: where a version is being superseded, every changed element declares
  -- how it changed, so re-scoring knows what is comparable
  select id into v_prior from instrument_version
   where status = 'active' and id <> p_version
   order by activated_at desc limit 1;

  if v_prior is not null then
    for check_ref, detail in
      select 'A7', 'element ' || coalesce(n.ref, o.ref) ||
             ' differs from ' || (select label from instrument_version
                                   where id = v_prior) ||
             ' with no declared change type'
        from (select ref, id from element where instrument_version_id = p_version) n
        full join (select ref, id from element
                    where instrument_version_id = v_prior) o on o.ref = n.ref
       where (n.ref is null or o.ref is null
              or gea_element_fingerprint(n.id) is distinct from
                 gea_element_fingerprint(o.id))
         and not exists (
           select 1 from element_version_change c
            where c.from_instrument_version_id = v_prior
              and c.to_instrument_version_id = p_version
              and c.element_ref = coalesce(n.ref, o.ref))
    loop return next; end loop;
  end if;

  return;
end $fn$;

create or replace function trg_instrument_activation_gate() returns trigger
language plpgsql as $fn$
declare n integer; first_detail text;
begin
  if new.status = 'active' and old.status = 'draft' then
    select count(*), min(check_ref || ': ' || detail)
      into n, first_detail
      from gea_activation_failures(new.id);
    if n > 0 then
      raise exception
        'instrument version % cannot activate: % check(s) failed. First: %',
        new.label, n, first_detail
        using errcode = 'check_violation',
              hint = 'select * from gea_activation_failures(''' || new.id ||
                     ''') for the full list';
    end if;
    new.activated_at := coalesce(new.activated_at, now());
  end if;
  return new;
end $fn$;

create trigger instrument_activation_gate before update on instrument_version
  for each row execute function trg_instrument_activation_gate();

-- 5. The readable wrapper the application calls -----------------------------

create or replace function gea_activate_instrument(p_label text)
returns table (result text, detail text)
language plpgsql as $fn$
declare v_id uuid; v_status instrument_status; n integer;
begin
  select id, status into v_id, v_status
    from instrument_version where label = p_label;

  if v_id is null then
    result := 'refused'; detail := 'no instrument version labelled ' || p_label;
    return next; return;
  end if;

  if v_status <> 'draft' then
    result := 'refused';
    detail := p_label || ' is already ' || v_status::text;
    return next; return;
  end if;

  select count(*) into n from gea_activation_failures(v_id);
  if n > 0 then
    for result, detail in
      select 'blocked', check_ref || ': ' || detail
        from gea_activation_failures(v_id)
    loop return next; end loop;
    return;
  end if;

  update instrument_version
     set status = 'active', activated_at = now()
   where id = v_id;

  result := 'activated';
  detail := p_label || ' is active and immutable as of ' || now()::text;
  return next;
  return;
end $fn$;
