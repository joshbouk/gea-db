-- 105 The gate knows the third state.
--
-- 104 gave a lead the decision to proceed without a file. The rule that
-- gates the mapping step still counted such a line as pending, so making
-- the decision changed nothing and the step stayed shut.
--
-- A rule and the decision it is meant to recognise, shipped apart, is
-- half a feature.

CREATE OR REPLACE FUNCTION public.gea_rule_unmet(p_engagement uuid, p_kind completion_kind, p_value text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
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
        -- Resolved means decided, not arrived.
        --
        -- A line still in flight used to block this step, and everything
        -- after it, until somebody declared it never coming. On a real
        -- engagement that meant eight files in, twelve being chased, and
        -- nothing scorable — the gate had two states where the work has
        -- three. A lead deciding not to wait is the third, and it
        -- resolves the line without claiming anything false about it.
        select count(*) into n from export_request_line
         where engagement_id = p_engagement and included
           and status in ('not_requested','requested')
           and proceeding_without_at is null;
        if n > 0 then
          return format(
            '%s export%s neither arrived nor been decided about. Either '
            'they are coming, or the assessment proceeds without them.',
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
end $function$
;

insert into gea_migration (filename, note) values
  ('105_the_gate_knows_the_third_state.sql',
   'A line the assessment is deliberately not waiting for counts as '
   'resolved.');
