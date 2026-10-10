-- 020 Creating a client and an engagement.
--
-- Two problems, both found when the first screen tried to use the schema.
--
-- 1. Nobody could create a client. 016 gave client a read policy and no write
--    policy, so every insert was refused for every signed-in user.
--
-- 2. Nobody could create an engagement, ever. The write policy from 006 is
--    app_is_member(id), and a brand new engagement has no members — so the
--    check is false for the row being inserted. engagement_member had the same
--    deadlock: you had to already be a member to add the first member.
--
--    The access tests missed this because all 25 of them run against an
--    engagement that already exists. A policy can be correct for every
--    operation on a row and still make the row impossible to create.
--
-- Creation also has to be atomic. An engagement is not just a row: it is a row
-- plus 48 scores plus 171 evidence requirements plus its first members. The
-- application talks to the database one request at a time and cannot roll back
-- the earlier ones when a later one fails, so a half-created engagement would
-- survive. A function is the only way to make it all-or-nothing.

-- Clients -------------------------------------------------------------------
-- Any active Blend user may add a client. There is no approval step: the team
-- is small, and a client row is a name and a domain.

drop policy if exists client_write on client;
create policy client_write on client
  for insert to authenticated with check (app_is_blend_user());

drop policy if exists client_update on client;
create policy client_update on client
  for update to authenticated
  using (app_is_blend_user()) with check (app_is_blend_user());

-- Engagements ---------------------------------------------------------------

create or replace function gea_create_engagement(
  p_client            uuid,
  p_instrument_label  text,
  p_name              text,
  p_motion            text,
  p_window_start      date,
  p_window_end        date,
  p_storage_prefix    text,
  p_sponsor_name      text default null,
  p_sponsor_role      text default null,
  p_locale            text default 'en-GB',
  p_creator_role      engagement_role default 'lead_consultant')
returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_me          uuid;
  v_instrument  uuid;
  v_status      instrument_status;
  v_engagement  uuid;
  n_scores      integer;
  n_requirements integer;
begin
  -- The caller acts as themselves even though this function runs with the
  -- owner's rights. A definer function that does not check who is calling is
  -- a hole, not a convenience.
  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  if v_me is null and not app_is_service() then
    raise exception 'only an active Blend user can create an engagement'
      using errcode = 'insufficient_privilege';
  end if;

  select id, status into v_instrument, v_status
    from instrument_version where label = p_instrument_label;

  if v_instrument is null then
    raise exception 'there is no instrument version labelled %', p_instrument_label
      using errcode = 'check_violation';
  end if;

  if v_status <> 'active' then
    raise exception
      'instrument version % is % — an engagement can only pin an active version',
      p_instrument_label, v_status
      using errcode = 'check_violation';
  end if;

  insert into engagement (client_id, instrument_version_id, name, motion_in_scope,
                          window_start, window_end, sponsor_name, sponsor_role,
                          storage_prefix, locale)
       values (p_client, v_instrument, p_name, p_motion,
               p_window_start, p_window_end, p_sponsor_name, p_sponsor_role,
               p_storage_prefix, p_locale)
    returning id into v_engagement;

  -- The creator is the first member, which is what lets them do anything else
  -- to it. Without this the engagement would be created and immediately
  -- unreachable.
  if v_me is not null then
    insert into engagement_member (engagement_id, app_user_id, engagement_role,
                                   can_view_raw_data, added_by)
         values (v_engagement, v_me, p_creator_role, true, v_me);
  end if;

  -- One score per element, unscored. The scorecard exists from the first day
  -- so that scoring progress has a denominator before anything is scored.
  insert into score (engagement_id, element_id, state)
  select v_engagement, e.id, 'unscored'
    from element e where e.instrument_version_id = v_instrument;

  -- One requirement per evidence requirement, outstanding. Readiness has a
  -- denominator from the first day for the same reason.
  insert into engagement_requirement (engagement_id, evidence_requirement_id, state)
  select v_engagement, r.id, 'outstanding'
    from evidence_requirement r where r.instrument_version_id = v_instrument;

  select count(*) into n_scores from score where engagement_id = v_engagement;
  select count(*) into n_requirements
    from engagement_requirement where engagement_id = v_engagement;

  -- A miscount means the instrument is not what it should be. Better to refuse
  -- the whole engagement than to start one on a partial scorecard.
  if n_scores <> 48 then
    raise exception 'expected 48 scores, created % — instrument % is incomplete',
      n_scores, p_instrument_label using errcode = 'check_violation';
  end if;
  if n_requirements = 0 then
    raise exception 'instrument % carries no evidence requirements',
      p_instrument_label using errcode = 'check_violation';
  end if;

  return v_engagement;
end $fn$;

comment on function gea_create_engagement is
  'Create an engagement with its scorecard, its evidence requirements and its '
  'first member, or create none of it. Runs as the owner to escape the '
  'bootstrap deadlock, and checks the caller is an active Blend user itself.';

insert into gea_migration (filename, note) values
  ('020_engagement_creation.sql',
   'Clients are writable by Blend users. Engagement creation runs through a '
   'function, because the member policy made a new engagement impossible to '
   'insert and because the scorecard must be created in the same transaction.');
