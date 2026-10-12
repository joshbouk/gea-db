-- 062 Reading the records before trusting the classification.
--
-- A classification comes back fluent, structured and plausible whether or
-- not it is true. Counting cannot be confidently wrong; this can, and
-- nothing downstream would notice: the rates look like rates, the
-- distribution looks like a distribution, and a report gets written on top.
--
-- The methodology's answer is one validation pass per engagement. A person
-- reads ten records, labels them by hand, and the agreement with the model
-- is computed. GEA-P13 makes it a discard condition in as many words:
-- accepting the classification requires a validation set with the verdict
-- trust.
--
-- So a classification run cannot be accepted without one. Not a warning on
-- a screen — the database refuses it, the same way it refuses a score above
-- its cap.
--
-- The thresholds are the methodology's: at or above eighty per cent the
-- classification is trusted; between sixty and eighty it is retried with a
-- changed prompt; below sixty it is abandoned and the elements it would
-- have served are scored from something else.

create or replace function gea_record_validation(
  p_run uuid, p_human_labels jsonb, p_note text default null)
returns table (records_reviewed integer, agreement_rate numeric,
               verdict text, consequence text)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me       uuid;
  v_run      record;
  v_model    jsonb;
  v_agreed   integer := 0;
  v_compared integer := 0;
  v_rate     numeric;
  v_verdict  validation_verdict;
  rec        record;
begin
  select * into v_run from analysis_run where id = p_run;
  if v_run.id is null then
    raise exception 'that run is not on record' using errcode = 'check_violation';
  end if;

  if not app_is_member(v_run.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  if v_run.status <> 'succeeded' then
    raise exception
      'only a run that succeeded can be validated. This one is %', v_run.status
      using errcode = 'check_violation';
  end if;

  v_model := v_run.compute_output -> 'to_check_by_hand';
  if v_model is null or jsonb_array_length(v_model) = 0 then
    raise exception
      'this run offered no records to check, so there is nothing to validate '
      'against'
      using errcode = 'check_violation';
  end if;

  -- Compare only the records the run actually offered, and only the labels
  -- it actually returned. A human label on a record the model never saw
  -- says nothing about the model.
  for rec in
    select m.value ->> 'record_id' as rid, m.value -> 'labels' as model_labels
      from jsonb_array_elements(v_model) m
  loop
    if p_human_labels ? rec.rid then
      declare
        human jsonb := p_human_labels -> rec.rid;
        k     text;
        same  boolean := true;
      begin
        for k in select jsonb_object_keys(rec.model_labels) loop
          if not (human ? k) then
            continue;
          end if;
          if lower(human ->> k) is distinct from lower(rec.model_labels ->> k) then
            same := false;
          end if;
        end loop;
        v_compared := v_compared + 1;
        if same then
          v_agreed := v_agreed + 1;
        end if;
      end;
    end if;
  end loop;

  if v_compared < 10 then
    raise exception
      'read ten of the records before deciding whether to trust the rest. '
      '% so far', v_compared
      using errcode = 'check_violation';
  end if;

  v_rate := round(v_agreed::numeric / v_compared, 4);
  v_verdict := case
    when v_rate >= 0.80 then 'trust'
    when v_rate >= 0.60 then 'retry'
    else 'abandon' end::validation_verdict;

  insert into validation_set (analysis_run_id, records_reviewed, human_labels,
                              model_labels, agreement_rate, verdict, reviewed_by)
       values (p_run, v_compared, p_human_labels, v_model, v_rate, v_verdict, v_me)
  on conflict (analysis_run_id) do update
    set records_reviewed = excluded.records_reviewed,
        human_labels = excluded.human_labels,
        model_labels = excluded.model_labels,
        agreement_rate = excluded.agreement_rate,
        verdict = excluded.verdict,
        reviewed_by = excluded.reviewed_by;

  records_reviewed := v_compared;
  agreement_rate := v_rate;
  verdict := v_verdict::text;
  consequence := case v_verdict
    when 'trust' then
      'The classification can be accepted and the rates used.'
    when 'retry' then
      'Close enough to be worth another attempt with a changed prompt, and '
      'not close enough to use. Redo the run.'
    else
      'The classification is not usable. Abandon it and score the elements '
      'it would have served from other evidence, recording the limitation.'
  end;
  return next;
end $fn$;

comment on function gea_record_validation is
  'Record what a person found when they read the records, and compute the '
  'agreement with the model. Trust at 80 per cent, retry at 60, abandon '
  'below.';

-- One validation per run, so re-reading replaces rather than accumulates.
create unique index if not exists validation_set_one_per_run
  on validation_set (analysis_run_id);

-- A classification cannot be accepted on nobody's word -----------------------

create or replace function gea_accept_run(p_run uuid, p_note text default null)
returns table (requirements_satisfied integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me  uuid;
  v_run record;
  v_key text;
  v_val record;
  n     integer := 0;
begin
  select * into v_run from analysis_run where id = p_run;
  if v_run.id is null then
    raise exception 'that run is not on record' using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;
  if v_me is null and not app_is_service() then
    raise exception 'only an active Blend user can accept a run'
      using errcode = 'insufficient_privilege';
  end if;

  if not app_is_member(v_run.engagement_id) then
    raise exception
      'you are not on this engagement''s team, so the run was not accepted'
      using errcode = 'insufficient_privilege';
  end if;

  if v_run.status <> 'succeeded' then
    raise exception
      'only a run that succeeded can be accepted. This one is %', v_run.status
      using errcode = 'check_violation';
  end if;

  if v_run.accepted_at is not null then
    raise exception 'that run was already accepted'
      using errcode = 'check_violation';
  end if;

  if v_run.model_name = 'stub' then
    raise exception
      'this analysis has not been built yet. The run produced a placeholder, '
      'not a result, and accepting it would turn an invented figure into '
      'evidence'
      using errcode = 'check_violation';
  end if;

  -- A run that classified what people wrote needs somebody to have read
  -- some of it. The model is fluent whether or not it is right, and the
  -- rates it produces look identical either way.
  if v_run.compute_output ? 'to_check_by_hand' then
    select * into v_val from validation_set where analysis_run_id = p_run;
    if v_val.id is null then
      raise exception
        'read the ten records this run set aside before accepting it. A '
        'classification nobody checked is a figure nobody can defend'
        using errcode = 'check_violation';
    end if;
    if v_val.verdict <> 'trust' then
      raise exception
        'the records were read and the agreement was %. The verdict was %, '
        'not trust, so this classification cannot be used as evidence',
        to_char(v_val.agreement_rate * 100, 'FM999') || '%', v_val.verdict
        using errcode = 'check_violation';
    end if;
  end if;

  -- A census that did not complete describes the part it reached.
  if coalesce((v_run.compute_output ->> 'census_complete')::boolean, true) is false then
    raise exception
      'this was meant to read every record and did not. Redo it, or accept '
      'that the rates describe only part of the client'
      using errcode = 'check_violation';
  end if;

  update analysis_run
     set accepted_by = v_me, accepted_at = now(),
         review_note = coalesce(p_note, review_note)
   where id = p_run;

  if v_run.job_type like 'analysis:%' or v_run.job_type like 'classify:%' then
    v_key := split_part(v_run.job_type, ':', 2);
    update engagement_requirement er
       set state = 'satisfied', satisfied_by_run_id = p_run
      from evidence_requirement evr, engagement e
     where er.evidence_requirement_id = evr.id
       and e.id = er.engagement_id
       and er.engagement_id = v_run.engagement_id
       and er.state = 'outstanding'
       and evr.instrument_version_id = e.instrument_version_id
       and evr.source_kind = 'analysis'
       and evr.analysis_key = v_key;
    get diagnostics n = row_count;
  end if;

  requirements_satisfied := n;
  return next;
end $fn$;

comment on function gea_accept_run is
  'A person has read the records behind a run and accepts it. A '
  'classification additionally needs a validation set with the verdict '
  'trust, and a census that did not complete cannot be accepted at all.';

insert into gea_migration (filename, note) values
  ('062_reading_the_records.sql',
   'A classification cannot become evidence until somebody has read ten of '
   'its records and the agreement holds.');
