-- 048 Evidence requirements that can actually be satisfied.
--
-- Until now only the 21 analysis-sourced requirements of 171 had any path to
-- satisfied. Three exports could arrive, forty-five fields be mapped, and the
-- readiness figure stay at zero — which makes it a number nobody trusts and
-- therefore nobody reads.
--
-- Two paths, because the requirements fall into two shapes.
--
--   Forty-three name the export lines they need. Whether those have arrived is
--   a fact, so the database keeps them up to date and nobody ticks anything.
--   A refused or absent line waives the requirement and carries the
--   instrument's own consequence text, because a refusal is a finding rather
--   than a gap.
--
--   Forty-seven name nothing a system can check: a client's ICP document, a
--   captured competitor page, an answer-engine result run by hand. Those need
--   a person to say this is the evidence, and to attach it.
--
-- The remaining sixty are interviews. They name their guide and are satisfied
-- when its synthesis is accepted, which is not built yet.

alter table engagement_requirement
  add column satisfied_by uuid references app_user(id),
  add column satisfied_at timestamptz,
  add column satisfaction_note text;

comment on column engagement_requirement.satisfaction_note is
  'What a person pointed at as the evidence, where no system could decide it. '
  'Null for requirements the database satisfies on its own.';

-- Exports ---------------------------------------------------------------------

create or replace function gea_recompute_export_evidence(p_engagement uuid)
returns integer language plpgsql as $fn$
declare n integer;
begin
  with wanted as (
    select er.id,
           evr.export_line_refs,
           evr.waiver_consequence,
           -- every line this requirement names, with where it has got to
           array_agg(erl.status) filter (where erl.id is not null) as states,
           count(*) filter (where erl.id is null) as lines_not_on_the_engagement
      from engagement_requirement er
      join evidence_requirement evr on evr.id = er.evidence_requirement_id
      join engagement e on e.id = er.engagement_id
      cross join lateral unnest(evr.export_line_refs) as ref(ref)
      left join export_line el
             on el.ref = ref.ref and el.instrument_version_id = e.instrument_version_id
      left join export_request_line erl
             on erl.export_line_id = el.id and erl.engagement_id = er.engagement_id
                and erl.included
     where er.engagement_id = p_engagement
       and evr.source_kind = 'export'
       and evr.export_line_refs is not null
     group by er.id, evr.export_line_refs, evr.waiver_consequence
  ), verdict as (
    select w.id, w.waiver_consequence,
           case
             -- A line the client refused, or that does not exist at all, is a
             -- finding. The requirement is waived and carries its consequence.
             when w.states && array['refused','absent']::export_req_status[]
               then 'waived'
             -- Excluded lines leave the requirement unmet with nothing to
             -- chase, which is the same outcome.
             when w.lines_not_on_the_engagement > 0 then 'waived'
             when not (w.states && array['not_requested','requested']::export_req_status[])
               then 'satisfied'
             else 'outstanding'
           end as state,
           case
             when w.states && array['refused','absent']::export_req_status[]
               then 'The client did not supply every export this needs.'
             when w.lines_not_on_the_engagement > 0
               then 'Blend is not asking for every export this needs.'
             else null
           end as reason
      from wanted w
  )
  update engagement_requirement er
     set state = v.state::requirement_state,
         waiver_reason = case when v.state = 'waived' then v.reason end,
         waiver_consequence = case when v.state = 'waived' then v.waiver_consequence end,
         waived_at = case when v.state = 'waived' then coalesce(er.waived_at, now()) end,
         satisfied_at = case when v.state = 'satisfied' then coalesce(er.satisfied_at, now()) end
    from verdict v
   where er.id = v.id
     and er.state is distinct from v.state::requirement_state;
  get diagnostics n = row_count;
  return n;
end $fn$;

comment on function gea_recompute_export_evidence is
  'Bring the export-sourced evidence requirements up to date with which lines '
  'have arrived. Nobody ticks these; the files arriving is the answer.';

create or replace function trg_export_line_moves_evidence() returns trigger
language plpgsql as $fn$
begin
  perform gea_recompute_export_evidence(new.engagement_id);
  return null;
end $fn$;

create trigger export_line_moves_evidence
  after insert or update of status, included on export_request_line
  for each row execute function trg_export_line_moves_evidence();

-- Everything a system cannot decide ------------------------------------------

create or replace function gea_satisfy_requirement(
  p_requirement uuid, p_artefact uuid default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; v_engagement uuid; v_kind req_source_kind;
begin
  select er.engagement_id, evr.source_kind into v_engagement, v_kind
    from engagement_requirement er
    join evidence_requirement evr on evr.id = er.evidence_requirement_id
   where er.id = p_requirement;

  if v_engagement is null then
    raise exception 'that evidence requirement is not on record'
      using errcode = 'check_violation';
  end if;

  if not app_is_member(v_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  -- The export-sourced ones are kept up to date from the export lines. Marking
  -- one satisfied by hand would be overwritten the next time a line moved, and
  -- would quietly disagree with the export request in the meantime.
  if v_kind = 'export' then
    raise exception
      'this is satisfied by the export arriving, not by hand. Set the export '
      'line''s status instead'
      using errcode = 'check_violation';
  end if;

  if p_artefact is null and (p_note is null or length(btrim(p_note)) = 0) then
    raise exception
      'point at the evidence: attach the file, or say in a line where it is'
      using errcode = 'check_violation';
  end if;

  if p_artefact is not null and not exists (
       select 1 from artefact a
        where a.id = p_artefact and a.engagement_id = v_engagement
          and a.purged_at is null) then
    raise exception 'that file is not on this engagement, or it was removed'
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  update engagement_requirement
     set state = 'satisfied',
         satisfied_by_artefact_id = p_artefact,
         satisfied_by = v_me,
         satisfied_at = now(),
         satisfaction_note = btrim(p_note),
         waiver_reason = null, waiver_consequence = null,
         waived_by = null, waived_at = null
   where id = p_requirement;
end $fn$;

create or replace function gea_waive_requirement(
  p_requirement uuid, p_reason text)
returns table (consequence text)
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; v_engagement uuid; v_kind req_source_kind; v_consequence text;
begin
  select er.engagement_id, evr.source_kind, evr.waiver_consequence
    into v_engagement, v_kind, v_consequence
    from engagement_requirement er
    join evidence_requirement evr on evr.id = er.evidence_requirement_id
   where er.id = p_requirement;

  if v_engagement is null then
    raise exception 'that evidence requirement is not on record'
      using errcode = 'check_violation';
  end if;

  if not app_is_member(v_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  if v_kind = 'export' then
    raise exception
      'this follows the export line. Mark the line refused or absent instead, '
      'and this waives itself'
      using errcode = 'check_violation';
  end if;

  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception
      'say why this evidence will not be obtained. It reaches the report as a '
      'limitation'
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  update engagement_requirement
     set state = 'waived',
         waiver_reason = btrim(p_reason),
         waiver_consequence = v_consequence,
         waived_by = v_me, waived_at = now(),
         satisfied_by_artefact_id = null, satisfied_by = null,
         satisfied_at = null, satisfaction_note = null
   where id = p_requirement;

  consequence := v_consequence;
  return next;
end $fn$;

comment on function gea_waive_requirement is
  'Record that a piece of evidence will not be obtained, and return the '
  'consequence the instrument states for it so the person is told.';

-- Bring existing engagements up to date.
do $$
declare e record;
begin
  for e in select id from engagement loop
    perform gea_recompute_export_evidence(e.id);
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('048_evidence_arrives.sql',
   'Export-sourced evidence requirements follow their export lines. Everything '
   'a system cannot decide can be satisfied or waived by a person, pointing at '
   'the evidence or saying why there is none.');
