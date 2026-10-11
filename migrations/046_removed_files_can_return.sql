-- 046 A file that was removed can be uploaded again.
--
-- Uploading identical bytes twice is refused, which is right: it is almost
-- always someone making sure rather than making a mistake, and telling them
-- the file is already here is more use than storing a second copy.
--
-- But the rule was written as if a file never leaves. Removing one keeps the
-- artefact row — deliberately, because "the client sent the wrong export
-- twice" is a finding — and that row went on blocking the hash forever. So a
-- file removed by mistake could never be put back, and a corrected export that
-- happened to match an earlier one was refused.
--
-- Uniqueness now applies to the files that are actually here.

alter table artefact drop constraint artefact_engagement_id_sha256_key;

create unique index artefact_engagement_sha256
  on artefact (engagement_id, sha256)
  where purged_at is null;

comment on index artefact_engagement_sha256 is
  'One copy of any given file per engagement. Removed files are excluded, so '
  'a file taken away can be uploaded again.';

insert into gea_migration (filename, note) values
  ('046_removed_files_can_return.sql',
   'Uploading the same bytes is still refused, but only while the file is '
   'still here. A removed file can be uploaded again.');
