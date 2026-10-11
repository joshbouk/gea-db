-- 042 What can be analysed, and when work becomes evidence.
--
-- Two things, and the second is the one holding everything up.
--
-- 1. Capability. Thirteen analyses each declare the canonical fields they
--    need. Once the mappings are confirmed, whether an analysis can run is a
--    fact rather than a judgement: either the client has those fields or they
--    do not. Computing it is better than discovering it halfway through, and
--    an analysis marked not supported must never be launched — the run would
--    either fail or, worse, quietly produce a figure from a field that is
--    empty.
--
--    A verdict of supported names the fields that support it. The schema
--    already refuses a supported verdict with no fields, which is the rule
--    that stops "supported" meaning "nobody checked".
--
-- 2. Acceptance. Until now a run could succeed and nothing happened. Nothing
--    marked it as reviewed, no evidence requirement moved off outstanding, and
--    readiness sat at zero on an engagement where the work had been done.
--
--    A run becomes evidence when a person accepts it. That is the whole point
--    of the review: the service produces a figure, somebody reads the records
--    behind it, and only then does it count.

-- Accepting a run is a statement that somebody read the records behind it.
-- What they saw is worth keeping: it is the difference between "accepted" and
-- "accepted because the ten records I read agreed with the classification".
alter table analysis_run add column review_note text;

comment on column analysis_run.review_note is
  'What the person who accepted the run saw when they checked it.';

-- Capability -----------------------------------------------------------------

create or replace function gea_compute_capability(p_engagement uuid)
returns table (analysis_key text, verdict capability_verdict, reason text)
language plpgsql security definer set search_path = public as $fn$
-- The output column analysis_key has the same name as the table column, and
-- PL/pgSQL would otherwise refuse "on conflict (analysis_key)" as ambiguous.
#variable_conflict use_column
declare v_instrument uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so capability was not recomputed'
      using errcode = 'insufficient_privilege';
  end if;

  select instrument_version_id into v_instrument
    from engagement where id = p_engagement;

  -- A field counts as present when somebody confirmed it against a column.
  -- A proposal nobody has accepted is not a field the client has.
  insert into analysis_capability (engagement_id, analysis_key, verdict, reason,
                                   supporting_fields)
  select p_engagement, a.analysis_key,
         case
           when a.missing_required > 0 then 'not_supported'::capability_verdict
           when a.missing_optional > 0 then 'partial'::capability_verdict
           else 'supported'::capability_verdict
         end,
         case
           when a.missing_required > 0 then
             format('%s cannot run: the client has no %s.',
                    a.analysis_key, a.missing_required_names)
           when a.missing_optional > 0 then
             format('%s can run on less than its full input: the client has no %s.',
                    a.analysis_key, a.missing_optional_names)
           else null
         end,
         case when a.missing_required > 0 then null else a.present_names end
    from (
      select r.analysis_key,
             count(*) filter (where r.is_required and m.id is null) as missing_required,
             count(*) filter (where not r.is_required and m.id is null) as missing_optional,
             string_agg(cf.key, ', ' order by cf.key)
               filter (where r.is_required and m.id is null) as missing_required_names,
             string_agg(cf.key, ', ' order by cf.key)
               filter (where not r.is_required and m.id is null) as missing_optional_names,
             array_agg(cf.key order by cf.key)
               filter (where m.id is not null) as present_names
        from analysis_field_requirement r
        join canonical_field cf on cf.id = r.canonical_field_id
        left join field_mapping m
               on m.canonical_field_id = r.canonical_field_id
              and m.engagement_id = p_engagement
              and m.status in ('confirmed','corrected','auto_accepted')
       where r.instrument_version_id = v_instrument
       group by r.analysis_key
    ) a
  on conflict (engagement_id, analysis_key) do update
    set verdict = excluded.verdict,
        reason = excluded.reason,
        supporting_fields = excluded.supporting_fields,
        -- Recomputing after a mapping changes clears the sign-off. Somebody
        -- signed off a different picture.
        signed_off_by = null;

  return query
  select c.analysis_key, c.verdict, c.reason
    from analysis_capability c
   where c.engagement_id = p_engagement
   order by c.verdict, c.analysis_key;
end $fn$;

comment on function gea_compute_capability is
  'Work out which analyses the client''s confirmed fields can support. Only a '
  'confirmed mapping counts; a proposal nobody accepted is not a field the '
  'client has.';

-- Acceptance -----------------------------------------------------------------

create or replace function gea_accept_run(p_run uuid, p_note text default null)
returns table (requirements_satisfied integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me        uuid;
  v_run       record;
  v_key       text;
  n           integer := 0;
begin
  select * into v_run from analysis_run where id = p_run;
  if v_run.id is null then
    raise exception 'that run is not on record' using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;
  if v_me is null and not app_is_service() then
    raise exception 'only an active Blend user can accept a run'
      using errcode = 'insufficient_privilege';
  end if;

  if not app_is_member(v_run.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so the run was not accepted'
      using errcode = 'insufficient_privilege';
  end if;

  if v_run.status <> 'succeeded' then
    raise exception
      'only a run that succeeded can be accepted. This one is %', v_run.status
      using errcode = 'check_violation';
  end if;

  if v_run.accepted_at is not null then
    raise exception 'that run was already accepted'
      using errcode = 'check_violation';
  end if;

  update analysis_run
     set accepted_by = v_me, accepted_at = now(),
         review_note = coalesce(p_note, review_note)
   where id = p_run;

  -- An accepted analysis satisfies the evidence requirements that named it.
  -- Everything else a run might serve is satisfied by its own artefact, so
  -- only analysis-sourced requirements move here.
  if v_run.job_type like 'analysis:%' or v_run.job_type like 'classify:%' then
    v_key := split_part(v_run.job_type, ':', 2);

    update engagement_requirement er
       set state = 'satisfied', satisfied_by_run_id = p_run
      from evidence_requirement evr, engagement e
     where er.evidence_requirement_id = evr.id
       and e.id = er.engagement_id
       and er.engagement_id = v_run.engagement_id
       and er.state = 'outstanding'
       and evr.instrument_version_id = e.instrument_version_id
       and evr.source_kind = 'analysis'
       and evr.analysis_key = v_key;
    get diagnostics n = row_count;
  end if;

  requirements_satisfied := n;
  return next;
end $fn$;

comment on function gea_accept_run is
  'A person has read the records behind a run and accepts it. Only then does '
  'it satisfy the evidence requirements that named its analysis.';

create or replace function gea_discard_run(p_run uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_run record;
begin
  select * into v_run from analysis_run where id = p_run;
  if v_run.id is null then
    raise exception 'that run is not on record' using errcode = 'check_violation';
  end if;

  if not app_is_member(v_run.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so the run was not discarded'
      using errcode = 'insufficient_privilege';
  end if;

  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception
      'say why the result is being discarded. It is kept against the run, and '
      'it is what stops the same mistake being made again'
      using errcode = 'check_violation';
  end if;

  if v_run.accepted_at is not null then
    raise exception
      'that run was accepted on %. Discarding it now would leave the evidence '
      'it satisfied pointing at nothing', v_run.accepted_at::date
      using errcode = 'check_violation';
  end if;

  update analysis_run
     set status = 'discarded', discarded_reason = btrim(p_reason)
   where id = p_run;
end $fn$;

comment on function gea_discard_run is
  'Reject a run''s result with a reason. Refused once the run has been '
  'accepted, because evidence already rests on it.';

insert into gea_migration (filename, note) values
  ('042_capability_and_acceptance.sql',
   'Capability computed from confirmed mappings, and a run becoming evidence '
   'when a person accepts it.');
