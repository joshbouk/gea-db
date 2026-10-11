-- 040 The service queues its own follow-on work.
--
-- 037 put the chain in a trigger: a dataset row appearing queued the mapping
-- proposals. That broke when re-reading a file started updating the row rather
-- than replacing it, and the obvious repair — fire on update too — needs the
-- trigger to tell "this file was read again" from "this row was touched for
-- some other reason". Row counts cannot tell them apart, because re-reading
-- the same file gives the same counts.
--
-- A trigger guessing at intent is a trigger that will be wrong eventually. The
-- only thing that can make a dataset parsed is the analysis service, and the
-- service knows perfectly well that it has just finished reading a file. So it
-- queues the follow-on itself and the trigger goes.
--
-- The run still carries the dataset and the moment it was read, so each
-- reading gets its own proposal run instead of being mistaken for the last.

drop trigger if exists parsed_dataset_proposes_mappings on dataset;
drop function if exists trg_parsed_dataset_proposes_mappings();

insert into gea_migration (filename, note) values
  ('040_reread_proposes_again.sql',
   'The chain from reading a file to proposing its mappings moves out of a '
   'trigger and into the service, which knows when a read has finished.');
