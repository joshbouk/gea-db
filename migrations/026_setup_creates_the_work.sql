-- 026 Engagement setup creates the interviews, the export request and the tasks.
--
-- G0 requires export request lines generated and interview records created
-- before an engagement can open. Doing that at creation rather than as a later
-- step means the board is populated from the first minute, with everything
-- blocked for a named reason — which is the point of showing blocked work from
-- day one rather than revealing it as the engagement unfolds.

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
  p_creator_role      engagement_role default 'lead_consultant',
  p_products          text[] default null,
  p_segments          text[] default null,
  p_channels          text[] default null)
returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_me           uuid;
  v_instrument   uuid;
  v_status       instrument_status;
  v_engagement   uuid;
  n_scores       integer;
  n_requirements integer;
  n_tasks        integer;
begin
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
      p_instrument_label, v_status using errcode = 'check_violation';
  end if;

  if coalesce(array_length(p_channels, 1), 0) = 0 then
    raise exception 'an engagement must name at least one route to market'
      using errcode = 'check_violation';
  end if;

  insert into engagement (client_id, instrument_version_id, name, motion_in_scope,
                          window_start, window_end, sponsor_name, sponsor_role,
                          storage_prefix, locale)
       values (p_client, v_instrument, p_name, p_motion, p_window_start,
               p_window_end, p_sponsor_name, p_sponsor_role, p_storage_prefix,
               p_locale)
    returning id into v_engagement;

  if v_me is not null then
    insert into engagement_member (engagement_id, app_user_id, engagement_role,
                                   can_view_raw_data, added_by)
         values (v_engagement, v_me, p_creator_role, true, v_me);
  end if;

  insert into engagement_scope (engagement_id, dimension, name)
  select v_engagement, d.dimension, btrim(n)
    from (values ('product'::scope_dimension, p_products),
                 ('segment'::scope_dimension, p_segments),
                 ('channel'::scope_dimension, p_channels)) as d(dimension, names)
    cross join lateral unnest(coalesce(d.names, '{}'::text[])) as n
   where btrim(n) <> ''
  on conflict do nothing;

  insert into engagement_deliverable (engagement_id, kind, promised_to_client)
  values (v_engagement, 'effectiveness_report', true),
         (v_engagement, 'roadmap',              true),
         (v_engagement, 'readout_deck',         true),
         (v_engagement, 'growth_waterfall',     true),
         (v_engagement, 'tco_model',            false),
         (v_engagement, 'measurement_set',      false);

  insert into score (engagement_id, element_id, state)
  select v_engagement, e.id, 'unscored'
    from element e where e.instrument_version_id = v_instrument;

  insert into engagement_requirement (engagement_id, evidence_requirement_id, state)
  select v_engagement, r.id, 'outstanding'
    from evidence_requirement r where r.instrument_version_id = v_instrument;

  -- The export request. Every line is included by default; excluding one is a
  -- decision someone makes with a reason, not an omission.
  insert into export_request_line (engagement_id, export_line_id, included, status)
  select v_engagement, l.id, true, 'not_requested'
    from export_line l where l.instrument_version_id = v_instrument;

  -- Eight sessions across seven guides. The sales rep guide runs twice, with
  -- two different reps, because one rep's answers are an anecdote.
  insert into interview (engagement_id, interview_guide_id, status)
  select v_engagement, g.id, 'scheduled'::interview_status
    from interview_guide g where g.instrument_version_id = v_instrument
  union all
  select v_engagement, g.id, 'scheduled'::interview_status
    from interview_guide g
   where g.instrument_version_id = v_instrument
     and g.function_name ilike '%rep%';

  n_tasks := gea_generate_tasks(v_engagement);

  select count(*) into n_scores from score where engagement_id = v_engagement;
  select count(*) into n_requirements
    from engagement_requirement where engagement_id = v_engagement;

  if n_scores <> 48 then
    raise exception 'expected 48 scores, created % — instrument % is incomplete',
      n_scores, p_instrument_label using errcode = 'check_violation';
  end if;
  if n_requirements = 0 then
    raise exception 'instrument % carries no evidence requirements',
      p_instrument_label using errcode = 'check_violation';
  end if;
  if n_tasks = 0 then
    raise exception 'no tasks were generated — the step catalogue is empty'
      using errcode = 'check_violation';
  end if;

  return v_engagement;
end $fn$;

insert into gea_migration (filename, note) values
  ('026_setup_creates_the_work.sql',
   'Engagement setup also creates the export request lines, the eight '
   'interview records and the task board.');
