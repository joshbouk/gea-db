-- 052 Waiting for the right thing.
--
-- Step 3.4 builds the stack cost of ownership model. It waited on step 2.6,
-- which is all eight interviews, and on no export at all.
--
-- Both are wrong. The cost model comes out of the finance conversation, and
-- waiting for both sales rep interviews before it can start blocks a week of
-- work for no reason. And it needs the technology stack inventory with annual
-- costs — T3-09 — which nothing said.
--
-- So a consultant looking at 3.4 was told "the cost lines come out of the
-- finance conversation" and shown eight interview links, with no mention of
-- the export the model is actually built from.
--
-- A precondition can now name a single interview, which is what several steps
-- really wait for. 2.7 and 2.8 keep waiting on all eight: provisional scoring
-- and confirming the revenue paths genuinely need every conversation.

alter type step_precondition_kind add value 'interview_guide';

insert into gea_migration (filename, note) values
  ('052_waiting_for_the_right_thing.sql',
   'A precondition can name a single interview.');
