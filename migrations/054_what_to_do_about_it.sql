-- 054 What to do about it.
--
-- A step with a completion rule told the person: "It closes on its own once
-- everything under Still to come is cleared." That describes a mechanism. It
-- does not say what to do, where to go, or who does it, and a consultant
-- reading it learns nothing.
--
-- Each rule knows what would satisfy it, so each rule carries its own
-- instruction and the screen it belongs on. The same thing blocking_reason
-- does for a precondition.

alter table step_completion
  add column action      text,
  add column destination text;

comment on column step_completion.action is
  'What a person does about this, in the imperative. Not a description of how '
  'the task closes.';
comment on column step_completion.destination is
  'Where that is done, as a screen the application knows: exports, '
  'field_mapping, evidence, run_review, revenue_paths, scoring. Null where '
  'there is nowhere to send them yet.';

update step_completion set action = v.action, destination = v.destination
  from (values
    ('export_lines_owned',
     'Name a client owner and a date for each export line.', 'exports'),
    ('exports_all_resolved',
     'Load the exports still outstanding, or record them as refused or absent.',
     'exports'),
    ('fields_all_settled',
     'Decide the fields still waiting.', 'field_mapping'),
    ('analysis_accepted',
     'Read the records behind the run, then accept it.', 'run_review'),
    ('supported_analyses_done',
     'Read the records behind each run, then accept it.', 'run_review'),
    ('ready_elements_scored',
     'Score the elements whose evidence is in.', 'scoring'),
    ('requirements_resolved',
     'Satisfy each outstanding requirement, or waive it with a reason.',
     'evidence')
  ) as v(kind, action, destination)
 where step_completion.kind::text = v.kind;

-- Nothing in the application can start an analysis run.
--
-- The runs screen once had a control for it. It was removed deliberately,
-- because choosing "propose_mappings" from a dropdown is not work a consultant
-- should do, and nothing replaced it for the analyses that a person genuinely
-- does decide to run.
--
-- So steps 2.1, 2.2 and 2.3 wait on runs that cannot be started, and telling
-- someone to accept a run that does not exist would be worse than saying
-- nothing. Until a way to start one exists, these say what has to happen
-- rather than pretending there is a screen for it.
update step_completion
   set action = 'Run the ' || replace(value, '_', ' ')
                || ' analysis, then accept it.',
       destination = null
 where kind = 'analysis_accepted';

update step_completion
   set action = 'Run each analysis the data supports, then accept it.',
       destination = null
 where kind = 'supported_analyses_done';

-- One rule, checked alone. 051 could only answer for a whole step, so a step
-- with two rules showed both instructions when only one was outstanding.
create or replace function gea_rule_unmet(
  p_engagement uuid, p_kind completion_kind, p_value text)
returns text
language plpgsql stable as $fn$
declare v_iv uuid; n integer; m integer;
begin
  select e.instrument_version_id into v_iv from engagement e where e.id = p_engagement;
    case p_kind

      when 'export_lines_owned' then
        select count(*) into n from export_request_line
         where engagement_id = p_engagement and included
           and (client_owner_name is null or due_date is null)
           and status = 'not_requested';
        if n > 0 then
          return format(
            '%s export line%s still has no owner or no date.',
            n, case when n = 1 then '' else 's' end);
        end if;

      when 'exports_all_resolved' then
        select count(*) into n from export_request_line
         where engagement_id = p_engagement and included
           and status in ('not_requested','requested');
        if n > 0 then
          return format(
            '%s export%s not arrived, and not recorded as refused or absent.',
            n, case when n = 1 then ' has' else 's have' end);
        end if;

      when 'fields_all_settled' then
        -- only fields whose export has actually arrived; the rest are not
        -- this step's problem yet.
        select count(*) into n
          from canonical_field cf
          left join field_mapping fm on fm.canonical_field_id = cf.id
                                    and fm.engagement_id = p_engagement
         where cf.instrument_version_id = v_iv
           and coalesce(fm.status::text,'proposed')
               not in ('confirmed','corrected','auto_accepted','unmapped')
           and exists (
             select 1 from unnest(cf.source_export_refs) as want(ref)
               join export_line el on el.ref = want.ref and el.instrument_version_id = v_iv
               join export_request_line erl on erl.export_line_id = el.id
                                           and erl.engagement_id = p_engagement
              where erl.status in ('received','partial','substituted'));
        if n > 0 then
          return format(
            '%s field%s from an export that has arrived still needs a decision.',
            n, case when n = 1 then '' else 's' end);
        end if;

      when 'analysis_accepted' then
        if not exists (select 1 from analysis_run
                        where engagement_id = p_engagement
                          and job_type = 'analysis:' || p_value
                          and accepted_at is not null) then
          return format(
            'The %s run has not been accepted.', replace(p_value, '_', ' '));
        end if;

      when 'supported_analyses_done' then
        select count(*) into n from analysis_capability c
         where c.engagement_id = p_engagement
           and c.verdict in ('supported','partial')
           and not exists (select 1 from analysis_run ar
                            where ar.engagement_id = p_engagement
                              and ar.job_type = 'analysis:' || c.analysis_key
                              and ar.accepted_at is not null);
        select count(*) into m from analysis_capability
         where engagement_id = p_engagement;
        if m = 0 then
          return 'The capability table has not been computed.';
        elsif n > 0 then
          return format(
            '%s analys%s the data supports %s no accepted run.',
            n, case when n = 1 then 'is' else 'es' end,
            case when n = 1 then 'has' else 'have' end);
        end if;

      when 'ready_elements_scored' then
        -- An element is ready to score when its evidence is all in. Elements
        -- still waiting are not this step's failure, and the task reopens
        -- when their evidence lands, because there is then more to score.
        select count(*) into n
          from element e
          join score s on s.element_id = e.id and s.engagement_id = p_engagement
         where e.instrument_version_id = v_iv
           and s.state = 'unscored'
           and not exists (
             select 1 from engagement_requirement er
               join evidence_requirement evr on evr.id = er.evidence_requirement_id
              where er.engagement_id = p_engagement
                and evr.element_id = e.id
                and er.state = 'outstanding');
        if n > 0 then
          return format(
            '%s element%s whose evidence is in %s no score yet.',
            n, case when n = 1 then '' else 's' end,
            case when n = 1 then 'has' else 'have' end);
        end if;

      when 'requirements_resolved' then
        select count(*) into n from engagement_requirement
         where engagement_id = p_engagement and state = 'outstanding';
        if n > 0 then
          return format(
            '%s evidence requirement%s still outstanding.',
            n, case when n = 1 then ' is' else 's are' end);
        end if;
    end case;
  return null;
end $fn$;

comment on function gea_rule_unmet is
  'What is outstanding on one completion rule, or null when it is satisfied.';

create or replace function gea_step_is_done(p_engagement uuid, p_step_ref text)
returns table (done boolean, unmet text[])
language plpgsql stable as $fn$
declare v_version text; r record; reasons text[] := array[]::text[]; any_rule boolean := false; u text;
begin
  select s.runbook_version into v_version from methodology_step s where s.ref = p_step_ref limit 1;
  for r in select * from step_completion
            where runbook_version = v_version and step_ref = p_step_ref loop
    any_rule := true;
    u := gea_rule_unmet(p_engagement, r.kind, r.value);
    if u is not null then reasons := reasons || u; end if;
  end loop;
  done := any_rule and array_length(reasons, 1) is null;
  unmet := case when array_length(reasons, 1) is null then null else reasons end;
  return next;
end $fn$;

-- Hand the instruction back with the outstanding items, so the screen never
-- has to work out what a rule means.
create or replace function gea_step_actions(p_engagement uuid, p_step_ref text)
returns table (unmet text, action text, destination text)
language sql stable as $fn$
  select gea_rule_unmet(p_engagement, c.kind, c.value), c.action, c.destination
    from step_completion c
    join methodology_step s on s.ref = c.step_ref
                           and s.runbook_version = c.runbook_version
   where s.ref = p_step_ref
     and gea_rule_unmet(p_engagement, c.kind, c.value) is not null
   order by c.action;
$fn$;

comment on function gea_step_actions is
  'What to do about a step whose work is not finished, and where. Empty once '
  'the step is done.';

insert into gea_migration (filename, note) values
  ('054_what_to_do_about_it.sql',
   'Each completion rule carries its own instruction and the screen it belongs '
   'on, instead of the screen describing how a task closes.');
