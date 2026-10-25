-- 112 A question for one person.
--
-- The guides are written per function: sales leadership, finance,
-- customer success. That is right, and it is never quite right, because
-- somebody always turns out to be different from their job title.
--
-- On the first real engagement an SVP of Sales Strategy turned out to
-- run the retail side of the business rather than sales operations, so
-- the sales guide would have wasted the hour; and a VP of Sales turned
-- out to have personally built the territory model the whole assessment
-- had been puzzling over, which nothing in his guide asks about.
--
-- Both are questions for one person in one room, not changes to the
-- methodology. A guide is what you ask somebody in that seat; this is
-- what you ask this person because of who they are.
--
-- The table that already holds questions the data raised holds these
-- too. There they are routed by role and matched to whichever interview
-- fits; here they are pinned to one. Same thing arriving two ways, and
-- an interviewer should meet them in one list.

alter table data_question
  add column interview_id uuid references interview(id) on delete cascade,
  add column asked_because text;

comment on column data_question.interview_id is
  'The one interview this belongs to, where somebody wrote it for a '
  'person rather than it arising from the data. Null means it is routed '
  'by role to whoever fits.';

comment on column data_question.asked_because is
  'Why this person in particular. "He built the territory model" is the '
  'difference between a question and a question worth asking him.';

create or replace function gea_ask_this_person(
  p_interview uuid, p_question text, p_because text,
  p_element_refs text[] default array[]::text[])
returns uuid
language plpgsql security definer set search_path = public as $fn$
declare v_eng uuid; v_id uuid;
begin
  select engagement_id into v_eng from interview where id = p_interview;
  if v_eng is null then
    raise exception 'that interview is not on record' using errcode = 'check_violation';
  end if;
  if not app_is_member(v_eng) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if p_question is null or length(btrim(p_question)) < 10 then
    raise exception 'write the question out' using errcode = 'check_violation';
  end if;
  if p_because is null or length(btrim(p_because)) < 10 then
    raise exception
      'say why this person. An interviewer with a question and no reason '
      'for it asks it flatly and gets a flat answer'
      using errcode = 'check_violation';
  end if;

  insert into data_question (engagement_id, analysis_key, question, because,
         asked_because, element_refs, interview_id)
       values (v_eng, 'asked_by_the_consultant', btrim(p_question),
               btrim(p_because), btrim(p_because), p_element_refs,
               p_interview)
  on conflict (engagement_id, question) do update
     set interview_id = excluded.interview_id,
         because = excluded.because,
         asked_because = excluded.asked_because,
         element_refs = excluded.element_refs
   where data_question.answered_at is null
  returning id into v_id;
  return v_id;
end $fn$;

comment on function gea_ask_this_person is
  'Add a question to one person''s interview, with why them. For where '
  'somebody turns out to be different from their job title, which is '
  'most of the time.';

drop view if exists questions_for_the_interview;
create view questions_for_the_interview
with (security_invoker = true) as
select q.engagement_id, q.id as question_id, q.question, q.because,
       q.asked_because, q.element_refs, q.ask_role, q.analysis_key,
       q.analysis_key = 'asked_by_the_consultant' as written_for_this_person,
       q.answered_at, q.answer, u.display_name as answered_by_name,
       -- Pinned to one interview, or routed by role to whoever fits.
       coalesce(q.interview_id::text,
         (select min(i.id::text) from interview i
            left join interview_guide g on g.id = i.interview_guide_id
           where i.engagement_id = q.engagement_id
             and q.ask_role is not null
             and i.status <> 'declined'
             and (lower(coalesce(i.interviewee_role, '')) like
                    '%' || lower(q.ask_role) || '%'
               or lower(coalesce(g.function_name, '')) like
                    '%' || lower(q.ask_role) || '%'))) as interview_id
  from data_question q
  left join app_user u on u.id = q.answered_by;

comment on view questions_for_the_interview is
  'Every question for an interviewer: the ones this client''s data '
  'raised, and the ones somebody wrote for this person. They are read '
  'in one list because they are asked in one room.';

insert into gea_migration (filename, note) values
  ('112_a_question_for_one_person.sql',
   'A question can be written for one interview, because somebody always '
   'turns out to be different from their job title.')
on conflict do nothing;
