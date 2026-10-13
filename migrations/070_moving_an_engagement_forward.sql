-- 070 Moving an engagement to the current instrument.
--
-- An engagement pins the instrument version it was created on, and rightly:
-- scores given against one set of anchors must not silently become scores
-- against another. But the methodology has moved six times in a fortnight,
-- and the only way to work on a current engagement was to start a new one
-- and remap every field by hand.
--
-- That is a bad trade in development and a worse one in delivery. An
-- engagement running from October to December will see the instrument
-- change underneath it, and "start again" is not an answer when a client is
-- waiting.
--
-- Everything an engagement holds is keyed to reference data by its natural
-- name — a field by its key, an element by its reference, a guide by its
-- own ref — so re-pointing is mechanical. What is not mechanical is the
-- scores, and that is what element_version_change exists for.
--
--   A wording change leaves the score alone. The anchor says the same thing
--   in better words.
--
--   A substantive or threshold change reopens it. A four under v0.10's
--   anchors is not a four under v0.11's, because v0.11 added a condition
--   that was not there. Carrying it forward would be a score nobody gave,
--   and nobody could defend it in a readout.
--
-- The destination is always the active version. There is no parameter for
-- it, because there is no other sensible answer and a parameter is
-- something to get wrong.

create or replace function gea_migrate_engagement(p_engagement uuid)
returns table (
  moved_to text,
  mappings_kept integer, mappings_dropped integer,
  fields_newly_unmapped integer,
  export_lines_added integer, export_lines_dropped integer,
  requirements_added integer, requirements_dropped integer,
  interviews_added integer,
  scores_kept integer, scores_reopened integer,
  reopened jsonb)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me    uuid;
  v_eng   record;
  v_new   uuid;
  v_label text;
  n       integer;
  r       record;
begin
  if not app_is_engagement_lead(p_engagement) then
    raise exception
      'only a lead consultant or lead architect can move an engagement to a '
      'new instrument. It can reopen scores'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_eng from engagement where id = p_engagement;
  if v_eng.id is null then
    raise exception 'that engagement is not on record'
      using errcode = 'check_violation';
  end if;

  if v_eng.score_frozen_at is not null then
    raise exception
      'this scorecard was frozen on %. Those scores were given against the '
      'instrument it was frozen under, and moving it now would rewrite what '
      'was delivered',
      to_char(v_eng.score_frozen_at, 'DD Mon YYYY')
      using errcode = 'check_violation';
  end if;

  select id, label into v_new, v_label
    from instrument_version where status = 'active';
  if v_new is null then
    raise exception 'no instrument version is active'
      using errcode = 'check_violation';
  end if;
  if v_new = v_eng.instrument_version_id then
    raise exception 'this engagement is already on %', v_label
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  -- Field mappings, by the field's key -------------------------------------
  select count(*) into mappings_kept
    from field_mapping m
    join canonical_field old on old.id = m.canonical_field_id
    join canonical_field new on new.key = old.key
                            and new.instrument_version_id = v_new
   where m.engagement_id = p_engagement;

  select count(*) into mappings_dropped
    from field_mapping m
    join canonical_field old on old.id = m.canonical_field_id
   where m.engagement_id = p_engagement
     and not exists (select 1 from canonical_field new
                      where new.key = old.key
                        and new.instrument_version_id = v_new);

  delete from field_mapping m
   using canonical_field old
   where m.engagement_id = p_engagement
     and old.id = m.canonical_field_id
     and not exists (select 1 from canonical_field new
                      where new.key = old.key
                        and new.instrument_version_id = v_new);

  update field_mapping m
     set canonical_field_id = new.id
    from canonical_field old
    join canonical_field new on new.key = old.key
                            and new.instrument_version_id = v_new
   where m.engagement_id = p_engagement and m.canonical_field_id = old.id;

  -- A field the new instrument asks for that the old one did not is not a
  -- loss, but it is work: it arrives unmapped and somebody has to decide it.
  select count(*) into fields_newly_unmapped
    from canonical_field new
   where new.instrument_version_id = v_new
     and not exists (select 1 from canonical_field old
                      where old.key = new.key
                        and old.instrument_version_id = v_eng.instrument_version_id);

  -- Export lines ------------------------------------------------------------
  select count(*) into export_lines_dropped
    from export_request_line erl
    join export_line old on old.id = erl.export_line_id
   where erl.engagement_id = p_engagement
     and not exists (select 1 from export_line new
                      where new.ref = old.ref
                        and new.instrument_version_id = v_new);

  delete from export_request_line erl
   using export_line old
   where erl.engagement_id = p_engagement
     and old.id = erl.export_line_id
     and not exists (select 1 from export_line new
                      where new.ref = old.ref
                        and new.instrument_version_id = v_new);

  update export_request_line erl
     set export_line_id = new.id
    from export_line old
    join export_line new on new.ref = old.ref
                        and new.instrument_version_id = v_new
   where erl.engagement_id = p_engagement and erl.export_line_id = old.id;

  insert into export_request_line (engagement_id, export_line_id, included)
  select p_engagement, new.id, new.tier = 1
    from export_line new
   where new.instrument_version_id = v_new
     and not exists (select 1 from export_request_line erl
                      where erl.engagement_id = p_engagement
                        and erl.export_line_id = new.id);
  get diagnostics export_lines_added = row_count;

  -- Interviews --------------------------------------------------------------
  update interview i
     set interview_guide_id = new.id
    from interview_guide old
    join interview_guide new on new.ref = old.ref
                            and new.instrument_version_id = v_new
   where i.engagement_id = p_engagement and i.interview_guide_id = old.id;

  insert into interview (engagement_id, interview_guide_id, status)
  select p_engagement, new.id, 'scheduled'
    from interview_guide new
   where new.instrument_version_id = v_new
     and not exists (select 1 from interview i
                      where i.engagement_id = p_engagement
                        and i.interview_guide_id = new.id);
  get diagnostics interviews_added = row_count;

  -- Evidence requirements ---------------------------------------------------
  select count(*) into requirements_dropped
    from engagement_requirement er
    join evidence_requirement old on old.id = er.evidence_requirement_id
    join element oe on oe.id = old.element_id
   where er.engagement_id = p_engagement
     and not exists (select 1 from evidence_requirement new
                       join element ne on ne.id = new.element_id
                      where new.ref = old.ref and ne.ref = oe.ref
                        and new.instrument_version_id = v_new);

  delete from engagement_requirement er
   using evidence_requirement old, element oe
   where er.engagement_id = p_engagement
     and old.id = er.evidence_requirement_id
     and oe.id = old.element_id
     and not exists (select 1 from evidence_requirement new
                       join element ne on ne.id = new.element_id
                      where new.ref = old.ref and ne.ref = oe.ref
                        and new.instrument_version_id = v_new);

  update engagement_requirement er
     set evidence_requirement_id = new.id
    from evidence_requirement old
    join element oe on oe.id = old.element_id
    join element ne on ne.ref = oe.ref and ne.instrument_version_id = v_new
    join evidence_requirement new on new.ref = old.ref
                                 and new.element_id = ne.id
                                 and new.instrument_version_id = v_new
   where er.engagement_id = p_engagement
     and er.evidence_requirement_id = old.id;

  insert into engagement_requirement (engagement_id, evidence_requirement_id,
                                      state)
  select p_engagement, new.id, 'outstanding'
    from evidence_requirement new
   where new.instrument_version_id = v_new
     and not exists (select 1 from engagement_requirement er
                      where er.engagement_id = p_engagement
                        and er.evidence_requirement_id = new.id);
  get diagnostics requirements_added = row_count;

  -- Challenges --------------------------------------------------------------
  delete from challenge c
   using element oe
   where c.engagement_id = p_engagement and oe.id = c.element_id
     and not exists (select 1 from element ne
                      where ne.ref = oe.ref and ne.instrument_version_id = v_new);

  update challenge c
     set element_id = ne.id
    from element oe
    join element ne on ne.ref = oe.ref and ne.instrument_version_id = v_new
   where c.engagement_id = p_engagement and c.element_id = oe.id;

  -- Scores ------------------------------------------------------------------
  delete from score s
   using element oe
   where s.engagement_id = p_engagement and oe.id = s.element_id
     and not exists (select 1 from element ne
                      where ne.ref = oe.ref and ne.instrument_version_id = v_new);

  update score s
     set element_id = ne.id
    from element oe
    join element ne on ne.ref = oe.ref and ne.instrument_version_id = v_new
   where s.engagement_id = p_engagement and s.element_id = oe.id;

  insert into score (engagement_id, element_id, state)
  select p_engagement, ne.id, 'unscored'
    from element ne
   where ne.instrument_version_id = v_new
     and not exists (select 1 from score s
                      where s.engagement_id = p_engagement
                        and s.element_id = ne.id);

  -- The judgement. A changed anchor is a changed question, and a score
  -- given against the old one is not an answer to the new one.
  reopened := '[]'::jsonb;
  scores_reopened := 0;
  for r in
    select s.id, e.ref, e.name, s.value, s.not_evidenced, s.state,
           ch.change_type::text, ch.note
      from score s
      join element e on e.id = s.element_id
      join element_version_change ch
        on ch.element_ref = e.ref
       and ch.from_instrument_version_id = v_eng.instrument_version_id
       and ch.to_instrument_version_id = v_new
       and ch.change_type in ('substantive', 'threshold')
     where s.engagement_id = p_engagement and s.state <> 'unscored'
  loop
    insert into score_revision (score_id, previous_value, new_value,
                                previous_ne, new_ne, reason, changed_by)
         values (r.id, r.value, null, r.not_evidenced, false,
                 format('Reopened on moving to %s. %s', v_label,
                        coalesce(r.note, 'The anchors for this element '
                                 || 'changed substantively.')),
                 v_me);

    delete from score_citation where score_id = r.id;

    update score
       set value = null, not_evidenced = false, ne_reason = null,
           state = 'unscored', confidence = null,
           scored_by = null, scored_at = null,
           row_version = row_version + 1
     where id = r.id;

    reopened := reopened || jsonb_build_object(
      'element', r.ref, 'name', r.name,
      'was', case when r.not_evidenced then 'not evidenced'
                  else r.value::text end,
      'why', coalesce(r.note, 'The anchors changed substantively.'));
    scores_reopened := scores_reopened + 1;
  end loop;

  select count(*) into scores_kept
    from score where engagement_id = p_engagement and state <> 'unscored';

  update engagement set instrument_version_id = v_new where id = p_engagement;

  perform gea_recompute_tasks(p_engagement);

  moved_to := v_label;
  return next;
end $fn$;

comment on function gea_migrate_engagement is
  'Move an engagement to the active instrument, re-pointing its work by '
  'natural key. Scores survive a wording change and are reopened by a '
  'substantive one, because a changed anchor is a changed question.';

insert into gea_migration (filename, note) values
  ('070_moving_an_engagement_forward.sql',
   'An engagement can move to the current instrument without being rebuilt. '
   'Scores reopen only where the anchors changed substantively.');
