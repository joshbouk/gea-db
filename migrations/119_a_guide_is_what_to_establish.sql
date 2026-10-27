-- 119 A guide is what to establish, not what to say.
--
-- Seventeen questions in five sections, each tagged to an element, and a
-- consultant expected to read them out. On three real interviews he
-- asked four of them and got better evidence than the list would have
-- produced, because he could see where the conversation was and the list
-- could not.
--
-- Asked about deals closed as unqualified, a sales leader explained that
-- there is no lead object at all: everything is piped straight to an
-- opportunity and disqualified later. That one answer bears on
-- qualification, routing, lead definition and pipeline hygiene. No
-- question in the guide would have found it, and the coverage check
-- marked the hour two out of sixteen.
--
-- So the unit stops being a question. It becomes a thing to establish,
-- with what the data already shows beside it, some ways into the subject
-- for when it does not come up on its own, and a line saying how you
-- know you have it. The questions survive as prompts, which is what they
-- were always good for.

create table interview_topic (
  id                  uuid primary key default gen_random_uuid(),
  interview_guide_id  uuid not null references interview_guide(id)
                      on delete cascade,
  ref                 text not null,
  title               text not null,
  -- What has to be true at the end of this part of the conversation.
  establish           text not null,
  -- What the client's own data shows, filled in per engagement rather
  -- than written into the instrument, because it is about them.
  minutes             integer,
  sort_order          integer not null,
  created_at          timestamptz not null default now(),
  unique (interview_guide_id, ref)
);

comment on table interview_topic is
  'What a conversation has to establish, which is a different thing from '
  'what to say. A consultant who can see where the conversation is gets '
  'there faster than a list can.';

comment on column interview_topic.establish is
  'What has to be true by the end of this subject. Written so that not '
  'knowing is also an answer: a sales leader who cannot say what makes a '
  'deal advance has told you something.';

alter table interview_question
  add column interview_topic_id uuid references interview_topic(id)
      on delete set null,
  add column is_a_way_in boolean not null default false;

comment on column interview_question.is_a_way_in is
  'A prompt to reach for where a subject does not come up on its own, '
  'rather than a question to read out. The difference decides whether a '
  'consultant feels behind for having had a better conversation.';

create or replace view what_the_guide_covers
with (security_invoker = true) as
select g.id as interview_guide_id, g.ref as guide_ref, g.function_name,
       g.duration_minutes,
       t.id as topic_id, t.ref as topic_ref, t.title, t.establish,
       t.minutes, t.sort_order,
       coalesce((select array_agg(distinct e.ref order by e.ref)
                   from interview_question q
                   join interview_question_element qe
                     on qe.interview_question_id = q.id
                   join element e on e.id = qe.element_id
                  where q.interview_topic_id = t.id), array[]::text[])
         as elements,
       coalesce((select array_agg(q.question_text order by q.sort_order)
                   from interview_question q
                  where q.interview_topic_id = t.id and q.is_a_way_in),
                array[]::text[]) as ways_in
  from interview_guide g
  left join interview_topic t on t.interview_guide_id = g.id
 order by g.ref, t.sort_order;

comment on view what_the_guide_covers is
  'Each conversation as subjects to establish, with the elements they '
  'serve and some ways into each one.';

insert into gea_migration (filename, note) values
  ('119_a_guide_is_what_to_establish.sql',
   'A guide is subjects to establish with ways into each, not a list of '
   'questions to read out.')
on conflict do nothing;
