-- 036 Confirming what a client's column is, and what it costs when it is absent.
--
-- A mapping decision is not one write. Confirming that the client has no loss
-- reason field means, at the same moment: the mapping is settled, every
-- element that depended on that field is capped with the field named as the
-- reason, and the evidence requirements that needed it are waived with their
-- consequence recorded.
--
-- All of it or none of it. A mapping marked unmapped without the caps applied
-- is worse than no decision at all: the scorecard then says a level 5 is
-- reachable on evidence nobody has.
--
-- The application cannot do this. It talks to the database one request at a
-- time and cannot undo the earlier ones when a later one fails.
--
-- Caps come from canonical_field_cap, which carries the element and the level
-- for each cap-bearing field. Nothing here invents a cap: a field with no rule
-- recorded caps nothing, and says so in what it returns.

create or replace function gea_confirm_mapping(
  p_engagement       uuid,
  p_canonical_field  uuid,
  p_status           mapping_status,
  p_field_name       text default null,
  p_dataset          uuid default null)
returns table (caps_applied integer, requirements_waived integer, cap_summary text)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me        uuid;
  v_key       text;
  v_cap_bear  boolean;
  v_caps      integer := 0;
  v_waived    integer := 0;
  v_summary   text;
  r           record;
begin
  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  if v_me is null and not app_is_service() then
    raise exception 'only an active Blend user can confirm a field mapping'
      using errcode = 'insufficient_privilege';
  end if;

  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so the mapping was not changed'
      using errcode = 'insufficient_privilege';
  end if;

  if p_status not in ('confirmed', 'corrected', 'unmapped') then
    raise exception
      'a mapping is confirmed, corrected or unmapped. "%" is not a decision '
      'a person makes', p_status
      using errcode = 'check_violation';
  end if;

  -- A mapping to a column has to name the column.
  if p_status in ('confirmed', 'corrected')
     and (p_field_name is null or length(btrim(p_field_name)) = 0) then
    raise exception
      'say which column in the client''s export this field is'
      using errcode = 'check_violation';
  end if;

  select cf.key, cf.is_cap_bearing into v_key, v_cap_bear
    from canonical_field cf where cf.id = p_canonical_field;

  if v_key is null then
    raise exception 'that canonical field is not in the instrument'
      using errcode = 'check_violation';
  end if;

  insert into field_mapping (engagement_id, canonical_field_id, dataset_id,
                             confirmed_field_name, status, confirmed_by,
                             confirmed_at)
       values (p_engagement, p_canonical_field, p_dataset,
               case when p_status = 'unmapped' then null
                    else btrim(p_field_name) end,
               p_status, v_me, now())
  on conflict (engagement_id, canonical_field_id) do update
    set confirmed_field_name = excluded.confirmed_field_name,
        status               = excluded.status,
        dataset_id           = coalesce(excluded.dataset_id, field_mapping.dataset_id),
        confirmed_by         = excluded.confirmed_by,
        confirmed_at         = excluded.confirmed_at;

  if p_status <> 'unmapped' then
    -- The field is present after all. Lift any cap this field had caused,
    -- leaving caps that came from somewhere else alone.
    update score s
       set cap_applied = null, cap_reason = null
      from canonical_field_cap c
     where c.canonical_field_id = p_canonical_field
       and s.element_id = c.element_id
       and s.engagement_id = p_engagement
       and s.cap_reason like '%' || v_key || '%';
    caps_applied := 0; requirements_waived := 0;
    cap_summary := null;
    return next;
    return;
  end if;

  -- Unmapped. Apply every cap this field carries.
  for r in
    select c.element_id, c.cap_level, c.condition, e.ref, e.name
      from canonical_field_cap c
      join element e on e.id = c.element_id
     where c.canonical_field_id = p_canonical_field
  loop
    update score
       set cap_applied = least(coalesce(cap_applied, 5), r.cap_level),
           cap_reason  = format(
             'The client has no %s field, so %s', v_key, r.condition)
     where engagement_id = p_engagement and element_id = r.element_id;

    if found then
      v_caps := v_caps + 1;
      v_summary := concat_ws('; ', v_summary,
        format('%s %s capped at %s', r.ref, r.name, r.cap_level));
    end if;
  end loop;

  -- Waive the evidence requirements that needed an export this field comes
  -- from, recording the consequence the instrument already states for each.
  update engagement_requirement er
     set state = 'waived',
         waiver_reason = format(
           'The client has no %s field in their export.', v_key),
         waiver_consequence = evr.waiver_consequence,
         waived_by = v_me,
         waived_at = now()
    from evidence_requirement evr, canonical_field cf
   where er.evidence_requirement_id = evr.id
     and cf.id = p_canonical_field
     and er.engagement_id = p_engagement
     and er.state = 'outstanding'
     and evr.source_kind in ('export','analysis')
     and evr.export_line_refs && cf.source_export_refs
     and exists (select 1 from canonical_field_cap c
                  where c.canonical_field_id = cf.id
                    and c.element_id = evr.element_id);
  get diagnostics v_waived = row_count;

  caps_applied := v_caps;
  requirements_waived := v_waived;
  cap_summary := coalesce(
    v_summary,
    case when v_cap_bear
         then format('No cap rule is recorded for %s, so nothing was capped. '
                     'Check the instrument.', v_key)
         else format('%s carries no cap, so nothing was capped.', v_key) end);
  return next;
end $fn$;

comment on function gea_confirm_mapping is
  'Settle one canonical field against the client''s export. Confirming it as '
  'unmapped applies every cap the field carries and waives the requirements '
  'that needed it, in the same transaction, and returns what it did so the '
  'person can be told.';

insert into gea_migration (filename, note) values
  ('036_confirm_mapping.sql',
   'Confirming a mapping, including the cap and waiver cascade that follows '
   'from confirming a cap-bearing field as absent.');
