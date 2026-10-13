-- 077 Runs that outlived their files, before anything noticed.
--
-- 075 made removing a file mark its runs stale. It did nothing about the
-- runs already in that state, which is the whole reason it was written:
-- a file removed before 075 existed still has a succeeded run attached to
-- it, that run still blocks the same file being uploaded again, and it is
-- still citable.
--
-- A migration that changes behaviour and does not repair the state it was
-- written to fix is half a migration.

update analysis_run r
   set is_stale = true
 where not r.is_stale
   and r.input_artefact_ids is not null
   and array_length(r.input_artefact_ids, 1) > 0
   -- Every file it read is gone. A run over several files where one
   -- survives still has something to say.
   and not exists (
     select 1 from artefact a
      where a.id = any (r.input_artefact_ids)
        and a.purged_at is null);

-- Citations to a removed file, for the same reason. 076 removes them as
-- the file goes; these were already gone when it was written.
delete from score_citation c
 using artefact a
 where c.artefact_id = a.id and a.purged_at is not null;

-- And a final score left with nothing cited cannot stay final.
update score s
   set state = 'provisional'
 where s.state = 'final'
   and not exists (select 1 from score_citation c where c.score_id = s.id);

insert into gea_migration (filename, note) values
  ('077_runs_that_outlived_their_files.sql',
   'Repairs what 075 and 076 only fixed going forward: runs and citations '
   'belonging to files removed before those rules existed.');
