-- 016 Read for every Blend user, write for assigned members.
--
-- The access model changes here. Until now membership decided both who could
-- see an engagement and who could change it, and a user on no engagement saw
-- nothing. That was wrong for this product: Blend is a small team and a
-- consultant learning from a finished assessment is the point of having a
-- library of them.
--
-- From here:
--   read   any active Blend user, on every engagement
--   write  the consultants assigned to that engagement
--   raw    members with can_view_raw_data, unchanged
--
-- Mechanically this is additive. Postgres ORs permissive policies together, so
-- adding a `for select` policy alongside the existing `for all using
-- (app_is_member(...))` opens reads while leaving insert, update and delete
-- resolving through membership: a `for select` policy does not apply to them.
-- Not one policy from 006 is altered, which matters because those are the ones
-- already proven by the access tests.
--
-- Raw client exports stay members-only. artefact, dataset and
-- dataset_field_profile hold the client's own CRM extract: deal records,
-- contact names, email addresses. Blend processes that under the contract with
-- that client for that assessment, which is not a basis for showing it to every
-- consultant on the platform. Nothing is lost for learning — scores, findings,
-- interventions, the roadmap, the TCO model and the measurement set are all
-- open.

-- Who counts as a Blend user ------------------------------------------------
-- Read access is not "anyone holding a token". It is an active row in
-- app_user, so deactivating someone who has left revokes their reads even
-- while their SSO identity still resolves.

create or replace function app_is_blend_user() returns boolean
language sql stable security definer set search_path = public as $$
  select app_is_service() or exists (
    select 1 from app_user u
     where u.auth_subject = auth.uid()
       and u.is_active
  )
$$;

comment on function app_is_blend_user is
  'An active Blend employee. Grants read across every engagement. Writing '
  'still resolves through app_is_member().';

-- Reference data and the directory -------------------------------------------
-- Sixteen of these policies already existed on the live database, added
-- outside the migration set in response to a security linter. They are correct
-- and are adopted here as written, so the repository reproduces the live
-- access layer. Two Zone A tables added by 007 had no policy at all.

do $$
declare t text;
begin
  foreach t in array array[
    'instrument_version','element','anchor','canonical_field',
    'canonical_field_cap','analysis_field_requirement','export_line',
    'export_line_element','interview_guide','interview_question',
    'interview_question_element','evidence_requirement','prompt_version',
    'aeo_prompt_template','measurement_definition_template',
    'element_version_change','app_user','client'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t || '_read_authenticated', t);
    execute format('drop policy if exists %I on %I', t || '_read', t);
    execute format(
      'create policy %I on %I for select to authenticated
         using (app_is_blend_user())', t || '_read', t);
  end loop;
end $$;

-- The assessment layer -------------------------------------------------------
-- Read opens to every Blend user. The member_access policies from 006 continue
-- to govern insert, update and delete untouched.

do $$
declare t text;
begin
  foreach t in array array[
    'engagement','engagement_member','task','engagement_requirement',
    'export_request_line','interview','population_count','evidence_tier',
    'delivered_intervention','field_mapping','analysis_capability',
    'analysis_run','metric','score','challenge','honesty_test','intervention',
    'roadmap_item','tco_line','measurement_definition','deliverable',
    'feedback_item','library_record','score_citation','score_revision',
    'validation_set'
  ] loop
    execute format('drop policy if exists %I on %I', t || '_read_all', t);
    execute format(
      'create policy %I on %I for select to authenticated
         using (app_is_blend_user())', t || '_read_all', t);
  end loop;
end $$;

-- artefact, dataset and dataset_field_profile are deliberately absent from the
-- list above. They keep the app_can_view_raw policies from 006 and nothing
-- else. A migration that adds a read-all policy to one of those three is
-- undoing a decision, not extending one.

insert into gea_migration (filename, note) values
  ('016_read_all_write_members.sql',
   'Read opened to every active Blend user. Write still resolves through '
   'engagement_member. Raw client exports unchanged.');
