-- 099 What the report says.
--
-- The report is the deliverable the client reads, and until now nothing
-- describes its shape. Writing it in code would make the methodology a
-- property of the service, and the shape of a Blend assessment is
-- methodology: it changes when the thinking changes, not when somebody
-- refactors a generator.
--
-- Two decisions sit underneath this.
--
-- The system drafts and the consultant finishes. Not the other way
-- round. A consultant handed a blank document writes around the
-- evidence; one handed a draft argues with it, and arguing with a draft
-- produces a better report in less time. Everything the data can say,
-- the generator says.
--
-- And a consultant answers questions rather than composing prose. A
-- section that needs human judgement asks for it in a sentence — "what
-- did the interviews say about why qualification happens so late?" —
-- and the answer goes in. Asking somebody to write three paragraphs in
-- a brand voice at eleven at night is how a report ends up sounding
-- like four different people.

create table report_section (
  id            uuid primary key default gen_random_uuid(),
  instrument_version_id uuid not null references instrument_version(id)
                        on delete cascade,
  ref           text not null,
  title         text not null,
  sort_order    integer not null,
  purpose       text not null,
  reads         text[] not null default array[]::text[],
  stage_code    text,
  asks          text,
  needed        boolean not null default true,
  unique (instrument_version_id, ref)
);

comment on table report_section is
  'The shape of the report, as methodology rather than code. Each section '
  'says what it is for, what evidence it draws on, and what it has to ask '
  'a person.';

comment on column report_section.reads is
  'Where the section gets its content: findings, scores, evidence, '
  'pipeline, questions, roadmap. A section reading nothing is written '
  'entirely from what the consultant answers.';

comment on column report_section.asks is
  'What the generator cannot know and has to ask. One question, in words '
  'a consultant can answer in two sentences at the end of a long week.';

comment on column report_section.needed is
  'Whether the report can be produced without this section. The evidence '
  'note cannot be left out: a reader has to know what was looked at.';

alter table report_section enable row level security;
create policy report_section_read on report_section
  for select to authenticated using (true);

create table report_answer (
  id            uuid primary key default gen_random_uuid(),
  engagement_id uuid not null references engagement(id) on delete cascade,
  section_ref   text not null,
  answer        text not null,
  answered_by   uuid references app_user(id),
  answered_at   timestamptz not null default now(),
  unique (engagement_id, section_ref)
);

comment on table report_answer is
  'What a consultant said when the generator asked. Kept apart from the '
  'generated document so regenerating never loses it.';

alter table report_answer enable row level security;
create policy report_answer_member on report_answer for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));

create or replace function gea_answer_section(
  p_engagement uuid, p_ref text, p_answer text)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if p_answer is null or length(btrim(p_answer)) < 20 then
    raise exception
      'the report will print this, so write something a client can read'
      using errcode = 'check_violation';
  end if;
  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;
  insert into report_answer (engagement_id, section_ref, answer, answered_by)
       values (p_engagement, p_ref, btrim(p_answer), v_me)
  on conflict (engagement_id, section_ref) do update
     set answer = excluded.answer, answered_by = excluded.answered_by,
         answered_at = now();
end $fn$;

comment on function gea_answer_section is
  'Record what the generator could not work out. The report prints it, so '
  'it is written once and well rather than typed into a box.';

create or replace view report_readiness
with (security_invoker = true) as
select e.id as engagement_id,
       s.ref, s.title, s.sort_order, s.purpose, s.reads, s.asks, s.needed,
       a.answer, a.answered_at,
       (s.asks is null or a.answer is not null) as ready
  from engagement e
  join report_section s on s.instrument_version_id = e.instrument_version_id
  left join report_answer a on a.engagement_id = e.id
                           and a.section_ref = s.ref;

comment on view report_readiness is
  'Each section of the report and whether it has what it needs. A section '
  'that asks nothing is always ready; one that asks is ready once '
  'somebody has answered.';

insert into gea_migration (filename, note) values
  ('099_what_the_report_says.sql',
   'The shape of the report is methodology, and the questions it asks a '
   'consultant are part of that shape.');
