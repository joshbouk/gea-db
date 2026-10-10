-- 029 A path with an open dimension is still the same path.
--
-- The unique constraint in 027 used PostgreSQL's default, where two nulls are
-- treated as different values. An open dimension is stored as null, so
-- "Renewal, any product, any segment, base growth" could be added twice and
-- the constraint would not notice. It silently failed to apply to exactly the
-- case the model was built around.
--
-- NULLS NOT DISTINCT makes two open dimensions equal, which is what a person
-- means when they choose Any twice.
--
-- The application was checking for this in the browser against the list it had
-- already loaded. That catches the common case and loses a race between two
-- people adding the same path at the same moment. A constraint does not race.

alter table revenue_path
  drop constraint revenue_path_engagement_id_motion_product_id_segment_id_cha_key;

alter table revenue_path
  add constraint revenue_path_is_unique
  unique nulls not distinct (engagement_id, motion, product_id, segment_id, channel_id);

insert into gea_migration (filename, note) values
  ('029_path_uniqueness.sql',
   'Two open dimensions count as equal, so a duplicate path with Any in it is '
   'refused by the database rather than only by the browser.');
