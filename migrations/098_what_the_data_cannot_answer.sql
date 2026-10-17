-- 098 What the data cannot answer.
--
-- An analysis finds things a person must explain. On the first real
-- client: only twelve per cent of deals carry a stage date and every one
-- recorded is dated 2026; the deal value is in one of six revenue columns
-- and none is called Amount; three hundred and ninety deals have no
-- division; four in five recorded wins say "Existing Relationship".
--
-- None of those is in any export and all of them came out of looking.
-- Each is a question with one right person to ask, and asking it in an
-- interview takes ninety seconds. Not asking it means the report either
-- guesses or goes quiet on the most interesting thing in the data.
--
-- This is also the argument for analysing before interviewing rather than
-- alongside. A generic guide asks how qualification works. A guide armed
-- with the data asks why one division disqualifies half its pipeline and
-- another a third. One gets a process description and the other gets the
-- truth.

create table data_question (
  id            uuid primary key default gen_random_uuid(),
  engagement_id uuid not null references engagement(id) on delete cascade,
  analysis_key  text not null,
  question      text not null,
  because       text not null,
  element_refs  text[] not null default array[]::text[],
  ask_role      text,
  answered_at   timestamptz,
  answered_by   uuid references app_user(id),
  answer        text,
  source_run_id uuid references analysis_run(id),
  created_at    timestamptz not null default now(),
  unique (engagement_id, question)
);

comment on table data_question is
  'Something the data raised and only a person can settle. Raised by an '
  'analysis, carried into the interview guide of whoever can answer it, '
  'and answered there.';

comment on column data_question.because is
  'What in the data prompted it. An interviewer who can say "twelve per '
  'cent of your deals carry a stage date" gets a different answer from '
  'one who asks how stage tracking works.';

comment on column data_question.ask_role is
  'Who can answer. A question about what populates a field is for whoever '
  'runs the CRM, not the VP of sales, and putting it in the wrong guide '
  'wastes both conversations.';

create index data_question_open
    on data_question (engagement_id, ask_role) where answered_at is null;

alter table data_question enable row level security;
create policy data_question_member on data_question for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));

create or replace function gea_answer_question(
  p_question uuid, p_answer text)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; v_eng uuid;
begin
  select engagement_id into v_eng from data_question where id = p_question;
  if v_eng is null then
    raise exception 'that question is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if p_answer is null or length(btrim(p_answer)) < 10 then
    raise exception
      'write down what they said. An answer nobody recorded is a question '
      'that gets asked again in the next interview'
      using errcode = 'check_violation';
  end if;
  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;
  update data_question
     set answered_at = now(), answered_by = v_me, answer = btrim(p_answer)
   where id = p_question;
end $fn$;

comment on function gea_answer_question is
  'Record what they said. An answer nobody wrote down is a question that '
  'gets asked again.';

create or replace view questions_for_the_interview
with (security_invoker = true) as
select q.engagement_id, q.id as question_id, q.question, q.because,
       q.element_refs, q.ask_role, q.analysis_key,
       q.answered_at, q.answer, u.display_name as answered_by_name,
       -- The interview this belongs in: one scheduled with somebody in
       -- that role, or failing that whose guide covers that function.
       -- Matched loosely on purpose — "RevOps" and "Revenue Operations"
       -- are the same person, and a question in no guide is worse than a
       -- question in a nearly-right one.
       (select min(i.id::text) from interview i
          left join interview_guide g on g.id = i.interview_guide_id
         where i.engagement_id = q.engagement_id
           and q.ask_role is not null
           and i.status <> 'declined'
           and (lower(coalesce(i.interviewee_role, '')) like
                  '%' || lower(q.ask_role) || '%'
             or lower(coalesce(g.function_name, '')) like
                  '%' || lower(q.ask_role) || '%')) as interview_id
  from data_question q
  left join app_user u on u.id = q.answered_by;

comment on view questions_for_the_interview is
  'The questions this client''s own data raised, and which interview each '
  'belongs in. An interviewer sees them beside the standard guide.';

insert into gea_migration (filename, note) values
  ('098_what_the_data_cannot_answer.sql',
   'An analysis raises questions only a person can settle, and they are '
   'carried into the interview guide of whoever can answer them.');
