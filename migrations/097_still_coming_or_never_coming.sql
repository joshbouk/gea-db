-- 097 Still coming, or never coming.
--
-- An export line that has not arrived is in one of two situations and the
-- difference decides what everything downstream should do.
--
--   Still coming. Somebody is pulling it, or finance has been asked. The
--   assessment is incomplete and knows it: a score taken now would be
--   taken on evidence that is about to change, and anything resting on
--   this line should wait.
--
--   Never coming. The client does not hold it, will not share it, or
--   keeps it somewhere nobody can export from. That is final, and the
--   assessment proceeds without it — with the consequence recorded,
--   because a figure the client could not supply caps what can be said
--   and the report has to say so.
--
-- Today both read as "requested" and nothing distinguishes them, so
-- nothing can tell whether an engagement is nearly done or nearly
-- blocked.
--
-- Declaring a line never coming needs a written reason. Not as
-- ceremony: the reason appears in the report, because "the client does
-- not record marketing spend by channel" is a finding about how they run
-- marketing and belongs in front of the reader who asks why there is no
-- cost per opportunity.

alter table export_request_line
  add column unavailable_reason text,
  add column unavailable_at timestamptz,
  add column unavailable_by uuid references app_user(id),
  add column chase_note text;

comment on column export_request_line.unavailable_reason is
  'Why this will never arrive, in words that can be read in the report. '
  'A figure the client could not supply caps what the assessment can say, '
  'and the reason is the finding.';

comment on column export_request_line.chase_note is
  'Where a line that is still coming has got to. Who is pulling it and '
  'when they said it would land, so the next person does not ask again.';

create or replace function gea_still_coming(
  p_engagement uuid, p_ref text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_line uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  select erl.id into v_line from export_request_line erl
    join export_line el on el.id = erl.export_line_id
   where erl.engagement_id = p_engagement and el.ref = p_ref;
  if v_line is null then
    raise exception 'there is no export line called % on this engagement', p_ref
      using errcode = 'check_violation';
  end if;

  -- Reversible by design. A line somebody gave up on last week can be
  -- chased again this week, and nothing is lost by saying so.
  update export_request_line
     set status = case when status in ('received', 'partial') then status
                       else 'requested' end,
         unavailable_reason = null, unavailable_at = null,
         unavailable_by = null,
         chase_note = nullif(btrim(p_note), '')
   where id = v_line;
end $fn$;

comment on function gea_still_coming is
  'Mark a line as expected: somebody is getting it. The assessment is '
  'incomplete until it lands or is declared never coming.';

create or replace function gea_will_not_arrive(
  p_engagement uuid, p_ref text, p_why text,
  p_because text default 'they do not hold it')
returns table (ref text, caps text[])
language plpgsql security definer set search_path = public as $fn$
declare v_line uuid; v_me uuid; v_status export_req_status;
begin
  if not app_is_engagement_lead(p_engagement) then
    raise exception
      'only a lead can say a client file will never arrive. The assessment '
      'proceeds without it and the report says why'
      using errcode = 'insufficient_privilege';
  end if;
  if p_why is null or length(btrim(p_why)) < 20 then
    raise exception
      'say why it will never arrive, in a sentence that can be read in the '
      'report. "The client does not record marketing spend by channel" is '
      'a finding about how they run marketing; "unavailable" is not'
      using errcode = 'check_violation';
  end if;

  select erl.id into v_line from export_request_line erl
    join export_line el on el.id = erl.export_line_id
   where erl.engagement_id = p_engagement and el.ref = p_ref;
  if v_line is null then
    raise exception 'there is no export line called % on this engagement', p_ref
      using errcode = 'check_violation';
  end if;

  v_status := case lower(btrim(p_because))
                when 'they will not share it' then 'refused'::export_req_status
                else 'absent'::export_req_status end;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  update export_request_line
     set status = v_status, unavailable_reason = btrim(p_why),
         unavailable_at = now(), unavailable_by = v_me, chase_note = null
   where id = v_line;

  perform gea_recompute_export_evidence(p_engagement);
  perform gea_compute_capability(p_engagement);
  perform gea_recompute_tasks(p_engagement);

  ref := p_ref;
  -- What this costs, so the decision is made with its price visible.
  -- A requirement names the export lines it reads, so the elements this
  -- costs are the ones with a mandatory requirement on this line.
  select coalesce(array_agg(distinct e.ref order by e.ref), array[]::text[])
    into caps
    from evidence_requirement er
    join engagement en on en.id = p_engagement
                      and en.instrument_version_id = er.instrument_version_id
    join element e on e.id = er.element_id
   where p_ref = any (er.export_line_refs)
     and er.is_mandatory;
  return next;
end $fn$;

comment on function gea_will_not_arrive is
  'Say a client file will never arrive, with the reason that goes in the '
  'report. Returns the elements this caps, so the cost is visible at the '
  'moment the decision is made rather than discovered at scoring.';

-- Is the evidence settled? ---------------------------------------------------
--
-- Not "has everything arrived", which never happens. Settled: every line
-- has either arrived or been declared never coming, so nothing anybody is
-- waiting for is going to change the answer.
--
-- That is the only honest gate on scoring. A score taken while a file is
-- still being pulled is a score about to be wrong, and the person taking
-- it usually does not know which file.

create or replace view evidence_readiness
with (security_invoker = true) as
with lines as (
  select erl.engagement_id, el.ref, el.question, el.found_in, el.importance,
         erl.status, erl.included, erl.chase_note, erl.unavailable_reason,
         (select count(*) from canonical_field cf
           where cf.instrument_version_id = e.instrument_version_id
             and el.ref = any (cf.source_export_refs)) as fields,
         (select count(*) from canonical_field cf
           where cf.instrument_version_id = e.instrument_version_id
             and el.ref = any (cf.source_export_refs)
             and cf.is_cap_bearing) as cap_bearing
    from export_request_line erl
    join export_line el on el.id = erl.export_line_id
    join engagement e on e.id = erl.engagement_id
   where erl.included
)
select engagement_id,
       count(*) as lines_asked_for,
       count(*) filter (where status in ('received', 'partial')) as arrived,
       count(*) filter (where status in ('absent', 'refused', 'substituted'))
         as never_coming,
       count(*) filter (where status in ('not_requested', 'requested'))
         as still_expected,
       sum(fields) as fields_asked_for,
       sum(fields) filter (where status in ('received', 'partial'))
         as fields_arrived,
       sum(cap_bearing) filter (where status in ('not_requested', 'requested'))
         as cap_bearing_still_expected,
       -- Settled means nothing anybody is waiting for will change the
       -- answer. It is not the same as complete and is the only state
       -- worth gating a score on.
       count(*) filter (where status in ('not_requested', 'requested')) = 0
         as settled,
       coalesce(array_agg(ref order by importance desc nulls last, ref)
                filter (where status in ('not_requested', 'requested')),
                array[]::text[]) as waiting_on,
       coalesce(array_agg(ref order by ref)
                filter (where status in ('absent', 'refused')
                          and unavailable_reason is null),
                array[]::text[]) as declared_gone_without_a_reason
  from lines
 group by engagement_id;

comment on view evidence_readiness is
  'Whether the evidence is settled: every line either arrived or declared '
  'never coming. Not the same as complete, and the only state worth '
  'gating a score on.';

insert into gea_migration (filename, note) values
  ('097_still_coming_or_never_coming.sql',
   'A line that has not arrived is either still coming or never coming, '
   'and the second needs a reason that goes in the report.');
