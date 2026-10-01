-- 005 Triggers. Rules that span tables and cannot be expressed as check constraints.
-- Each of these exists to be inconvenient. Do not weaken one to make a feature work.

-- R1 ------------------------------------------------------------------------
-- An activated instrument version is immutable. Engagements point at it and
-- scores were awarded against its anchor text.

create or replace function trg_reference_draft_only() returns trigger
language plpgsql as $$
declare
  v_id uuid;
  v_status instrument_status;
  rec jsonb;
begin
  rec := to_jsonb(coalesce(new, old));

  if tg_table_name = 'instrument_version' then
    v_id := (rec ->> 'id')::uuid;
  elsif tg_table_name = 'anchor' then
    select instrument_version_id into v_id
      from element where id = (rec ->> 'element_id')::uuid;
  else
    v_id := (rec ->> 'instrument_version_id')::uuid;
  end if;

  if v_id is null then
    return coalesce(new, old);
  end if;

  select status into v_status from instrument_version where id = v_id;

  -- The version row's own lifecycle transitions are the permitted exception.
  if tg_table_name = 'instrument_version' and tg_op = 'UPDATE' then
    if (to_jsonb(old) ->> 'status') = 'draft' then
      return new;
    end if;
    if (to_jsonb(old) ->> 'status') = 'active'
       and (to_jsonb(new) ->> 'status') = 'retired'
       and (to_jsonb(old) ->> 'label') is not distinct from (to_jsonb(new) ->> 'label') then
      return new;
    end if;
  end if;

  if v_status <> 'draft' then
    raise exception
      'instrument version % is % and is immutable: % on % rejected',
      v_id, v_status, tg_op, tg_table_name
      using errcode = 'check_violation';
  end if;

  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'instrument_version','element','anchor','canonical_field','export_line',
    'interview_guide','evidence_requirement','aeo_prompt_template',
    'measurement_definition_template'
  ] loop
    execute format(
      'create trigger %I before insert or update or delete on %I
         for each row execute function trg_reference_draft_only()',
      t || '_draft_only', t);
  end loop;
end $$;

-- R2 ------------------------------------------------------------------------
-- Not Evidenced is refused where the instrument forbids it.

create or replace function trg_score_ne_permitted() returns trigger
language plpgsql as $$
declare v_ok boolean; v_ref text;
begin
  if new.not_evidenced then
    select ne_permitted, ref into v_ok, v_ref from element where id = new.element_id;
    if not v_ok then
      raise exception 'element % does not permit Not Evidenced', v_ref
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create trigger score_ne_permitted before insert or update on score
  for each row execute function trg_score_ne_permitted();

-- R3 ------------------------------------------------------------------------
-- A tier-dependent element may not exceed the evidence tier's ceiling.

create or replace function trg_score_tier_ceiling() returns trigger
language plpgsql as $$
declare v_dep boolean; v_ref text; v_ceiling smallint;
begin
  if new.value is null then return new; end if;
  select tier_dependent, ref into v_dep, v_ref from element where id = new.element_id;
  if v_dep then
    select score_ceiling into v_ceiling from evidence_tier
      where engagement_id = new.engagement_id;
    if v_ceiling is not null and new.value > v_ceiling then
      raise exception 'element % is tier-dependent and capped at % by the evidence tier',
        v_ref, v_ceiling using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create trigger score_tier_ceiling before insert or update on score
  for each row execute function trg_score_tier_ceiling();

-- R4 ------------------------------------------------------------------------
-- A score cannot be final without an accepted citation, and cannot be final
-- while citing a stale run.

create or replace function trg_score_final_requires_citation() returns trigger
language plpgsql as $$
declare n integer; n_stale integer;
begin
  if new.state = 'final' then
    select count(*) into n from score_citation where score_id = new.id;
    if n = 0 then
      raise exception 'a final score requires at least one citation'
        using errcode = 'check_violation';
    end if;
    select count(*) into n_stale
      from score_citation c join analysis_run r on r.id = c.analysis_run_id
     where c.score_id = new.id and r.is_stale;
    if n_stale > 0 then
      raise exception 'a final score cannot cite a stale run (% found)', n_stale
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create constraint trigger score_final_requires_citation
  after insert or update on score
  deferrable initially deferred
  for each row execute function trg_score_final_requires_citation();

-- R5 ------------------------------------------------------------------------
-- An analysis run is append-only once it has completed. A correction is a new
-- run that supersedes the old one, never an edit.

create or replace function trg_run_append_only() returns trigger
language plpgsql as $$
begin
  if old.status in ('succeeded','failed') then
    if (new.compute_output      is distinct from old.compute_output)
    or (new.model_output_text   is distinct from old.model_output_text)
    or (new.model_output_parsed is distinct from old.model_output_parsed)
    or (new.parameters          is distinct from old.parameters)
    or (new.input_hashes        is distinct from old.input_hashes)
    or (new.input_artefact_ids  is distinct from old.input_artefact_ids)
    or (new.status              is distinct from old.status)
    then
      raise exception 'analysis_run % is % and its inputs and outputs are append-only',
        old.id, old.status using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create trigger run_append_only before update on analysis_run
  for each row execute function trg_run_append_only();

-- R6 ------------------------------------------------------------------------
-- A classification run cannot be accepted without a validation set the
-- reviewer has marked trustworthy.

create or replace function trg_run_classification_gate() returns trigger
language plpgsql as $$
declare n integer;
begin
  if new.accepted_at is not null and old.accepted_at is null
     and new.job_type like 'classify:%' then
    select count(*) into n from validation_set
     where analysis_run_id = new.id and verdict = 'trust';
    if n = 0 then
      raise exception 'classification run % cannot be accepted without a trusted validation set',
        new.id using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create trigger run_classification_gate before update on analysis_run
  for each row execute function trg_run_classification_gate();

-- R7 ------------------------------------------------------------------------
-- Only an accepted run may be cited by a score.

create or replace function trg_citation_requires_accepted_run() returns trigger
language plpgsql as $$
declare v_accepted timestamptz;
begin
  if new.analysis_run_id is not null then
    select accepted_at into v_accepted from analysis_run where id = new.analysis_run_id;
    if v_accepted is null then
      raise exception 'run % has not been accepted and cannot be cited', new.analysis_run_id
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create trigger citation_requires_accepted_run before insert or update on score_citation
  for each row execute function trg_citation_requires_accepted_run();

-- R8 ------------------------------------------------------------------------
-- A frozen scorecard cannot be changed without an explicit unfreeze.

create or replace function trg_score_frozen() returns trigger
language plpgsql as $$
declare v_frozen timestamptz;
begin
  select score_frozen_at into v_frozen from engagement
    where id = coalesce(new.engagement_id, old.engagement_id);
  if v_frozen is not null then
    raise exception 'engagement scorecard was frozen at % — unfreeze before changing a score',
      v_frozen using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end $$;

create trigger score_frozen before insert or update or delete on score
  for each row execute function trg_score_frozen();

-- R9 ------------------------------------------------------------------------
-- Freezing requires every challenge dispositioned and the honesty test complete.

create or replace function trg_engagement_freeze_gate() returns trigger
language plpgsql as $$
declare n_open integer; n_honesty integer; n_unscored integer;
begin
  if new.score_frozen_at is not null and old.score_frozen_at is null then
    select count(*) into n_open from challenge
      where engagement_id = new.id and disposition = 'open';
    if n_open > 0 then
      raise exception 'cannot freeze: % challenge(s) still open', n_open
        using errcode = 'check_violation';
    end if;
    select count(*) into n_honesty from honesty_test where engagement_id = new.id;
    if n_honesty = 0 then
      raise exception 'cannot freeze: the honesty test is not complete'
        using errcode = 'check_violation';
    end if;
    select count(*) into n_unscored from score
      where engagement_id = new.id and state = 'unscored';
    if n_unscored > 0 then
      raise exception 'cannot freeze: % element(s) unscored', n_unscored
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create trigger engagement_freeze_gate before update on engagement
  for each row execute function trg_engagement_freeze_gate();

-- R10 -----------------------------------------------------------------------
-- An engagement always has at least one active lead architect.

create or replace function trg_member_lead_architect() returns trigger
language plpgsql as $$
declare n integer; v_engagement uuid;
begin
  v_engagement := coalesce(new.engagement_id, old.engagement_id);
  select count(*) into n from engagement_member
    where engagement_id = v_engagement
      and engagement_role = 'lead_architect'
      and to_date is null;
  if n = 0 and exists (select 1 from engagement_member where engagement_id = v_engagement) then
    raise exception 'an engagement must retain at least one active lead architect'
      using errcode = 'check_violation';
  end if;
  return null;
end $$;

create constraint trigger member_lead_architect
  after update or delete on engagement_member
  deferrable initially deferred
  for each row execute function trg_member_lead_architect();
