-- 113 The same guard, again.
--
-- 109 fixed three functions that refused the analysis service because it
-- connects with no signed-in user. gea_ask_this_person, written three
-- migrations later, has the same guard and the same fault: a consultant
-- loading questions for tomorrow's interviews through a direct database
-- connection is refused, because app_is_member reads a session that is
-- not there.
--
-- Copied from the functions around it without noticing that those had
-- already been corrected. The fix is the same one.

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
  -- Or a connection with nobody signed in, which is an administrator at
  -- the database rather than somebody in a browser.
  if not (app_is_member(v_eng) or app_is_service() or auth.uid() is null) then
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
  'Add a question to one person''s interview, with why them. Callable by '
  'the team, by the service, or from a direct database connection.';

insert into gea_migration (filename, note) values
  ('113_the_same_guard_again.sql',
   'gea_ask_this_person had the guard 109 had already corrected '
   'elsewhere.')
on conflict do nothing;
