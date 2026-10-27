-- 118 What an interview said.
--
-- An hour with somebody who knows a business is the densest evidence an
-- assessment gets, and there was nowhere to put it. The synthesis
-- produced three yes-or-no labels per guide question and a quotation
-- under fifteen words, which is a coverage check rather than a reading.
--
-- Run against a real interview it missed everything that mattered. The
-- client's revenue operations lead explained that a set of fields
-- nobody understood were retired, that their quoting tool had been
-- uninstalled after a failed implementation, that the sales process had
-- thirteen stages rather than the eight the data suggested, and that
-- the person who looked like an administrator owning three hundred
-- renewals actually ran the digital client success team. None of those
-- answered a question in the guide. People volunteer things when they
-- are talking rather than being surveyed, and the form had no box.
--
-- So: four kinds of thing an interview produces, each stored with the
-- speaker's own words and the moment they said them, and each marked
-- with whether those words were found in the transcript where the
-- reading claimed. A quotation that reads better than the transcript is
-- a quotation nobody said, and the difference between evidence and
-- plausible text is worth a column.

create type interview_finding_kind as enum (
  'learned',      -- what this says about an element being assessed
  'corrects',     -- where it contradicts what the data suggested
  'new',          -- a person, system, process or document nobody knew of
  'ask_next'      -- a question it raises for somebody else
);

create type quote_check as enum (
  'verified',     -- those words, in one person's mouth, at that moment
  'misplaced',    -- said, but not where the reading said
  'not_found',    -- not in the transcript
  'stitched',     -- assembled across a speaker change; nobody said it
  'no_quote'      -- nothing offered to check
);

create table interview_finding (
  id                 uuid primary key default gen_random_uuid(),
  engagement_id      uuid not null references engagement(id) on delete cascade,
  interview_id       uuid not null references interview(id) on delete cascade,
  run_id             uuid references analysis_run(id) on delete set null,
  kind               interview_finding_kind not null,
  headline           text not null,
  detail             text,
  element_refs       text[] not null default '{}',
  -- For 'corrects': the belief it bears on and what the reading made of
  -- it. For 'new': what kind of thing and whether to chase it. For
  -- 'ask_next': who to ask.
  about              text,
  verdict            text,
  said_by            text,
  quote              text,
  said_at            text,
  quote_is           quote_check not null default 'no_quote',
  how_sure           text,
  accepted_at        timestamptz,
  accepted_by        uuid references app_user(id),
  dismissed_at       timestamptz,
  dismissed_by       uuid references app_user(id),
  dismissed_why      text,
  created_at         timestamptz not null default now()
);

comment on table interview_finding is
  'What a conversation produced: what it establishes about the elements '
  'being assessed, where it corrects the data, what it reveals that no '
  'export contains, and what it raises for the other interviews.';

comment on column interview_finding.quote_is is
  'Whether the quoted words were found in the transcript, in one '
  'person''s mouth, at the moment claimed. A reading that quotes well '
  'and quotes wrongly is worse than one that quotes nothing.';

comment on column interview_finding.about is
  'What this bears on: the belief being corrected, the name of the thing '
  'discovered, or the person to ask next.';

create index interview_finding_by_interview
  on interview_finding (interview_id, kind);
create index interview_finding_by_engagement
  on interview_finding (engagement_id, kind)
  where dismissed_at is null;

alter table interview_finding enable row level security;
create policy interview_finding_member on interview_finding for all to authenticated
  using (app_is_member(engagement_id))
  with check (app_is_member(engagement_id));

-- What each guide question got, kept apart from the findings because it
-- is a different question: not what was learned, but whether the
-- conversation went where it was meant to.
create table interview_coverage (
  id                 uuid primary key default gen_random_uuid(),
  interview_id       uuid not null references interview(id) on delete cascade,
  question_ref       text not null,
  question_text      text not null,
  element_refs       text[] not null default '{}',
  asked              boolean not null default false,
  answered           text,
  quote              text,
  said_at            text,
  quote_is           quote_check not null default 'no_quote',
  unique (interview_id, question_ref)
);

comment on table interview_coverage is
  'Which of the guide''s questions were put and which were answered. '
  'Consultants run out of time and skip the last ten minutes; a question '
  'nobody asked is a gap in the evidence rather than a silence about the '
  'client.';

alter table interview_coverage enable row level security;
create policy interview_coverage_member on interview_coverage for all to authenticated
  using (exists (select 1 from interview i where i.id = interview_id
                   and app_is_member(i.engagement_id)))
  with check (exists (select 1 from interview i where i.id = interview_id
                        and app_is_member(i.engagement_id)));

create or replace view what_the_interview_found
with (security_invoker = true) as
select f.engagement_id, f.interview_id, i.interviewee_name,
       i.interviewee_role, g.function_name, g.ref as guide_ref,
       f.id as finding_id, f.kind, f.headline, f.detail, f.element_refs,
       f.about, f.verdict, f.quote, f.said_at, f.quote_is, f.how_sure,
       f.accepted_at, f.dismissed_at, f.dismissed_why,
       u.display_name as accepted_by_name
  from interview_finding f
  join interview i on i.id = f.interview_id
  left join interview_guide g on g.id = i.interview_guide_id
  left join app_user u on u.id = f.accepted_by;

comment on view what_the_interview_found is
  'Everything a conversation produced, with who said it and whether the '
  'words check out.';

create or replace function gea_accept_interview_finding(
  p_finding uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_eng uuid; v_me uuid; v_check quote_check;
begin
  select engagement_id, quote_is into v_eng, v_check
    from interview_finding where id = p_finding;
  if v_eng is null then
    raise exception 'that finding is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if v_check in ('not_found', 'stitched') then
    raise exception
      'those words are not in the transcript, so this cannot be accepted '
      'as evidence. Dismiss it, or read the transcript and record what '
      'was actually said'
      using errcode = 'check_violation';
  end if;
  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;
  update interview_finding
     set accepted_at = now(), accepted_by = v_me,
         dismissed_at = null, dismissed_by = null, dismissed_why = null
   where id = p_finding;
end $fn$;

comment on function gea_accept_interview_finding is
  'Accept what a reading found. A finding whose quotation is not in the '
  'transcript cannot be accepted at all: the point of checking was to '
  'stop it becoming evidence.';

create or replace function gea_dismiss_interview_finding(
  p_finding uuid, p_why text)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_eng uuid; v_me uuid;
begin
  select engagement_id into v_eng from interview_finding where id = p_finding;
  if v_eng is null then
    raise exception 'that finding is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if p_why is null or length(btrim(p_why)) < 10 then
    raise exception
      'say why this is being set aside. A dismissed finding with no '
      'reason looks the same as one nobody read'
      using errcode = 'check_violation';
  end if;
  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;
  update interview_finding
     set dismissed_at = now(), dismissed_by = v_me,
         dismissed_why = btrim(p_why), accepted_at = null, accepted_by = null
   where id = p_finding;
end $fn$;

insert into gea_migration (filename, note) values
  ('118_what_an_interview_said.sql',
   'An interview produces what it establishes, what it corrects, what it '
   'reveals and what it raises — each with the words that were said and '
   'whether they check out.')
on conflict do nothing;
