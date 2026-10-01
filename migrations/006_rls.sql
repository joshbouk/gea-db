-- 006 Access control. Helper functions and row-level security policies.
-- Created after the tables they read.

create or replace function app_current_user_id() returns uuid
language sql stable as $$
  select id from app_user where auth_subject = auth.uid()
$$;

-- Membership test used by every engagement-scoped RLS policy.
create or replace function app_is_member(p_engagement uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app_is_service() or exists (
    select 1
      from engagement_member m
      join app_user u on u.id = m.app_user_id
     where m.engagement_id = p_engagement
       and u.auth_subject = auth.uid()
       and u.is_active
       and m.to_date is null
  )
$$;

create or replace function app_can_view_raw(p_engagement uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app_is_service() or exists (
    select 1
      from engagement_member m
      join app_user u on u.id = m.app_user_id
     where m.engagement_id = p_engagement
       and u.auth_subject = auth.uid()
       and u.is_active
       and m.to_date is null
       and m.can_view_raw_data
  )
$$;

create or replace function app_is_lead(p_engagement uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app_is_service() or exists (
    select 1
      from engagement_member m
      join app_user u on u.id = m.app_user_id
     where m.engagement_id = p_engagement
       and u.auth_subject = auth.uid()
       and u.is_active
       and m.to_date is null
       and m.engagement_role in ('lead_consultant','lead_architect')
  )
$$;


-- Policies -----------------------------------------------------------------
-- Every engagement-scoped table resolves access through engagement_member.
-- A non-member sees nothing; the API layer returns 404 rather than 403 so
-- engagement existence is not disclosed.

do $$
declare t text;
begin
  foreach t in array array[
    'engagement','engagement_member','task','engagement_requirement',
    'export_request_line','interview','population_count','evidence_tier',
    'delivered_intervention','artefact','field_mapping','analysis_capability',
    'analysis_run','metric','score','challenge','honesty_test','intervention',
    'roadmap_item','tco_line','measurement_definition','deliverable',
    'feedback_item','library_record'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
  end loop;
end $$;

-- engagement itself keys on its own id; the rest key on engagement_id.
create policy engagement_member_access on engagement
  for all using (app_is_member(id)) with check (app_is_member(id));

do $$
declare t text;
begin
  foreach t in array array[
    'engagement_member','task','engagement_requirement','export_request_line',
    'interview','population_count','evidence_tier','delivered_intervention',
    'field_mapping','analysis_capability','analysis_run','metric','score',
    'challenge','honesty_test','intervention','roadmap_item','tco_line',
    'measurement_definition','deliverable','feedback_item','library_record'
  ] loop
    execute format(
      'create policy %I on %I for all using (app_is_member(engagement_id))
         with check (app_is_member(engagement_id))',
      t || '_member_access', t);
  end loop;
end $$;

-- Raw client data is gated separately: a member without can_view_raw_data
-- sees findings, scores and metrics but never the underlying export.
create policy artefact_raw_access on artefact
  for all using (app_can_view_raw(engagement_id))
  with check (app_can_view_raw(engagement_id));

alter table dataset enable row level security;
alter table dataset force row level security;
create policy dataset_raw_access on dataset
  for all using (exists (
    select 1 from artefact a
     where a.id = dataset.artefact_id and app_can_view_raw(a.engagement_id)));

alter table dataset_field_profile enable row level security;
alter table dataset_field_profile force row level security;
create policy profile_raw_access on dataset_field_profile
  for all using (exists (
    select 1 from dataset d join artefact a on a.id = d.artefact_id
     where d.id = dataset_field_profile.dataset_id
       and app_can_view_raw(a.engagement_id)));

-- Citations and revisions inherit their score's engagement.
alter table score_citation enable row level security;
alter table score_citation force row level security;
create policy citation_member_access on score_citation
  for all using (exists (
    select 1 from score s where s.id = score_citation.score_id
      and app_is_member(s.engagement_id)));

alter table score_revision enable row level security;
alter table score_revision force row level security;
create policy revision_member_access on score_revision
  for all using (exists (
    select 1 from score s where s.id = score_revision.score_id
      and app_is_member(s.engagement_id)));

alter table validation_set enable row level security;
alter table validation_set force row level security;
create policy validation_member_access on validation_set
  for all using (exists (
    select 1 from analysis_run r where r.id = validation_set.analysis_run_id
      and app_is_member(r.engagement_id)));
