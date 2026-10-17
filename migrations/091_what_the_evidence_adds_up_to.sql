-- 091 What the evidence adds up to.
--
-- An engagement now produces forty-five pipelines and a dozen analyses
-- cut several ways. That is evidence, and a consultant cannot read it
-- out. The report needs four or five sentences, each traceable to a
-- specific cut, and the work of getting from one to the other has been
-- done by hand so far.
--
-- Three rules decide what is worth saying.
--
--   A segment earns a sentence by being different, not by existing. Three
--   divisions behaving alike is one sentence, not three.
--
--   A difference is only worth reporting if the smaller side is large
--   enough to mean something. On the first real client one segment held a
--   single deal, and a hundred per cent of one deal is not a finding.
--
--   And nothing is compared across a pipeline change. A client that
--   replaced its stages has two populations, and a figure spanning them
--   describes neither.

create table rollup_finding (
  id            uuid primary key default gen_random_uuid(),
  engagement_id uuid not null references engagement(id) on delete cascade,
  analysis_key  text not null,
  kind          text not null,
  headline      text not null,
  detail        jsonb not null default '{}'::jsonb,
  element_refs  text[] not null default array[]::text[],
  source_run_id uuid references analysis_run(id),
  dismissed_at  timestamptz,
  dismissed_by  uuid references app_user(id),
  dismissed_why text,
  created_at    timestamptz not null default now()
);

comment on table rollup_finding is
  'What the cuts add up to: the differences large enough and clear enough '
  'to be worth a sentence. Proposed from the evidence, dismissed by a '
  'person where the difference is explained by something the data cannot '
  'see.';

comment on column rollup_finding.kind is
  'What sort of thing this is: a difference between segments, a change '
  'between pipeline eras, or a figure that stands on its own.';

comment on column rollup_finding.headline is
  'The sentence, with its numbers in it. A finding without its figures is '
  'an opinion.';

comment on column rollup_finding.dismissed_why is
  'Why a consultant set it aside. "The East division only sells to '
  'regulated utilities" explains a difference the data cannot see, and is '
  'worth keeping: the next assessment of this client will raise it again.';

create index rollup_finding_live
    on rollup_finding (engagement_id, analysis_key)
 where dismissed_at is null;

alter table rollup_finding enable row level security;
create policy rollup_finding_member on rollup_finding for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));

create or replace function gea_dismiss_finding(
  p_finding uuid, p_why text)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; v_eng uuid;
begin
  select engagement_id into v_eng from rollup_finding where id = p_finding;
  if v_eng is null then
    raise exception 'that finding is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if p_why is null or length(btrim(p_why)) < 15 then
    raise exception
      'say why this is not worth reporting. A difference the data shows '
      'and a person sets aside needs its reason on the record, because '
      'the next assessment will raise it again'
      using errcode = 'check_violation';
  end if;
  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;
  update rollup_finding
     set dismissed_at = now(), dismissed_by = v_me,
         dismissed_why = btrim(p_why)
   where id = p_finding;
end $fn$;

comment on function gea_dismiss_finding is
  'Set a proposed finding aside, with the reason. Nothing is deleted: a '
  'difference the data shows is still there next time.';

create or replace view findings_board
with (security_invoker = true) as
select f.engagement_id, f.id as finding_id, f.analysis_key, f.kind,
       f.headline, f.detail, f.element_refs, f.created_at,
       f.dismissed_at, f.dismissed_why, u.display_name as dismissed_by_name,
       r.accepted_at as evidence_accepted_at,
       r.is_stale as evidence_is_stale
  from rollup_finding f
  left join app_user u on u.id = f.dismissed_by
  left join analysis_run r on r.id = f.source_run_id;

comment on view findings_board is
  'The findings proposed from this engagement''s evidence, with whether '
  'the run behind each has been accepted and whether it has since gone '
  'stale.';

insert into gea_migration (filename, note) values
  ('091_what_the_evidence_adds_up_to.sql',
   'What the cuts add up to, as sentences with their figures in them, '
   'proposed from the evidence and set aside with a reason.');
