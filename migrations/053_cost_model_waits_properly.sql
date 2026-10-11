-- 053 What step 3.4 actually waits for.
--
-- Split from 052 because PostgreSQL will not let a new enum value be used in
-- the same transaction that adds it.

-- Out with the two wrong ones.
delete from step_precondition p
 using methodology_step s
 where s.id = p.methodology_step_id and s.ref = '3.4';

insert into step_precondition (methodology_step_id, kind, value, blocking_reason)
select s.id, 'interview_guide', '6',
       'The finance interview has not been held. The cost lines come out of '
       'that conversation, and the other interviews are not needed for this.'
  from methodology_step s where s.ref = '3.4';

insert into step_precondition (methodology_step_id, kind, value, blocking_reason)
select s.id, 'export_line', 'T3-09',
       'The technology stack inventory has not arrived. The model is built '
       'from it, and without it every figure would be an estimate.'
  from methodology_step s where s.ref = '3.4';

-- Teach the precondition check about a single interview.
create or replace function gea_precondition_met(
  p_engagement uuid, p_kind step_precondition_kind, p_value text)
returns boolean
language plpgsql stable as $fn$
declare v_iv uuid; n integer;
begin
  select instrument_version_id into v_iv from engagement where id = p_engagement;

  case p_kind
    when 'step' then
      return not exists (
        select 1 from task t
         where t.engagement_id = p_engagement and t.step_ref = p_value
           and t.status not in ('complete','waived'));

    when 'gate' then
      return exists (select 1 from gate_passage
                      where engagement_id = p_engagement and gate_ref = p_value);

    when 'export_tier' then
      return exists (
        select 1 from export_request_line erl
          join export_line el on el.id = erl.export_line_id
         where erl.engagement_id = p_engagement and el.tier = p_value::integer
           and erl.status in ('received','partial','substituted'));

    when 'export_line' then
      return exists (
        select 1 from export_request_line erl
          join export_line el on el.id = erl.export_line_id
         where erl.engagement_id = p_engagement and el.ref = p_value
           and (erl.status in ('received','partial','substituted')
                -- A line the client refused or does not have is resolved, not
                -- pending. The work continues with the limitation recorded.
                or erl.status in ('refused','absent') or not erl.included));

    when 'analysis' then
      return exists (
        select 1 from analysis_run
         where engagement_id = p_engagement
           and job_type = 'analysis:' || p_value
           and accepted_at is not null);

    when 'interview_guide' then
      -- Held, or declined. A declined interview is a finding and its
      -- consequence is applied; it does not stop the rest of the engagement.
      return exists (
        select 1 from interview i
          join interview_guide g on g.id = i.interview_guide_id
         where i.engagement_id = p_engagement and g.ref::text = p_value
           and (i.held_at is not null or i.status = 'declined'));
  end case;
  return false;
end $fn$;

comment on function gea_precondition_met is
  'Whether one precondition is satisfied. A refused export and a declined '
  'interview both count as resolved: they are findings, and the engagement '
  'continues with the consequence recorded.';

do $$
declare e record;
begin
  for e in select id from engagement loop
    perform gea_recompute_tasks(e.id);
  end loop;
end $$;

insert into gea_migration (filename, note) values
  ('053_cost_model_waits_properly.sql',
   'Step 3.4 waits for the finance interview and the stack inventory export, '
   'not for all eight interviews and no export.');
