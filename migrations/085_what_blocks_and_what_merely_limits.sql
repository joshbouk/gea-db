-- 085 What blocks, and what merely limits.
--
-- An analysis is refused when a required field is unmapped, which is
-- right. The sentence explaining the refusal listed every missing field,
-- required or not, so one genuine blocker read as three:
--
--   "account_segment, stage_history_opportunity_id are not yet mapped to
--    a column. The client has no stage_exited_at."
--
-- Only the middle one stops anything. account_segment is a dimension the
-- analysis cuts by where it exists, and stage_exited_at is an alternative
-- to the entry date it already has. Both are marked optional in the
-- instrument and both were presented as walls.
--
-- A consultant reading that goes looking for three things, finds two of
-- them genuinely absent at the client, and concludes the analysis cannot
-- run. It can.

CREATE OR REPLACE FUNCTION public.gea_compute_capability(p_engagement uuid)
 RETURNS TABLE(analysis_key text, verdict capability_verdict, reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_instrument uuid;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so capability was not recomputed'
      using errcode = 'insufficient_privilege';
  end if;

  select instrument_version_id into v_instrument
    from engagement where id = p_engagement;

  insert into analysis_capability (engagement_id, analysis_key, verdict, reason,
                                   supporting_fields, awaiting_export_refs,
                                   undecided_field_keys, absent_field_keys)
  select p_engagement, a.analysis_key,
         case when a.missing_required > 0 then 'not_supported'::capability_verdict
              when a.missing_optional > 0 then 'partial'::capability_verdict
              else 'supported'::capability_verdict end,
         nullif(concat_ws(' ',
           case when a.awaiting is not null then
             format('Waiting on %s, which %s not arrived.',
                    array_to_string(a.awaiting, ', '),
                    case when array_length(a.awaiting, 1) = 1 then 'has' else 'have' end)
           end,
           -- Field keys stay as they are written everywhere else. A long
           -- list is its own wall, so name a few and count the rest; the
           -- exact set is in undecided_field_keys for a screen that wants it.
           case when a.undecided is not null then
             format('%s %s not yet mapped to a column.',
                    gea_name_a_few(a.undecided),
                    case when array_length(a.undecided, 1) = 1 then 'is' else 'are' end)
           end,
           case when a.absent is not null then
             format('The client has no %s.', gea_name_a_few(a.absent))
           end,
           case when a.optional_missing is not null then
             format('%s %s also missing, which would add detail rather than '
                    || 'being needed.',
                    gea_name_a_few(a.optional_missing),
                    case when array_length(a.optional_missing, 1) = 1
                         then 'is' else 'are' end)
           end), ''),
         case when a.missing_required > 0 then null else a.present end,
         a.awaiting, a.undecided, a.absent
    from (
      select r.analysis_key,
             count(*) filter (where r.is_required and m.id is null) as missing_required,
             count(*) filter (where not r.is_required and m.id is null) as missing_optional,
             array_agg(cf.key order by cf.key) filter (where m.id is not null) as present,
             -- which of the three each missing field is
             (select array_agg(distinct x order by x) from unnest(
                array_agg(f.awaiting_ref) filter (where f.awaiting_ref is not null)
              ) as x) as awaiting,
             (select array_agg(distinct x order by x) from unnest(
                array_agg(cf.key) filter (where m.id is null and f.awaiting_ref is null
                                            and coalesce(m2.status::text,'') <> 'unmapped'
                                            and r.is_required)
              ) as x) as undecided,
             -- Optional fields, kept apart. Listing them beside a blocker
             -- made every one of them look like a blocker: an analysis
             -- refused for one missing field read as refused for three.
             (select array_agg(distinct x order by x) from unnest(
                array_agg(cf.key) filter (where m.id is null and f.awaiting_ref is null
                                            and not r.is_required)
              ) as x) as optional_missing,
             (select array_agg(distinct x order by x) from unnest(
                array_agg(cf.key) filter (where m.id is null and f.awaiting_ref is null
                                            and coalesce(m2.status::text,'') = 'unmapped'
                                            and r.is_required)
              ) as x) as absent
        from analysis_field_requirement r
        join canonical_field cf on cf.id = r.canonical_field_id
        -- a settled mapping to an actual column
        left join field_mapping m
               on m.canonical_field_id = r.canonical_field_id
              and m.engagement_id = p_engagement
              and m.status in ('confirmed','corrected','auto_accepted')
        -- any mapping at all, to tell "decided absent" from "not looked at"
        left join field_mapping m2
               on m2.canonical_field_id = r.canonical_field_id
              and m2.engagement_id = p_engagement
        -- the first export this field comes from that has not arrived
        left join lateral (
          select el.ref as awaiting_ref
            from unnest(cf.source_export_refs) as want(ref)
            join export_line el on el.ref = want.ref
                               and el.instrument_version_id = v_instrument
            left join export_request_line erl
                   on erl.export_line_id = el.id
                  and erl.engagement_id = p_engagement
           where coalesce(erl.status, 'not_requested')
                 not in ('received','partial','substituted')
             and coalesce(erl.included, true)
           limit 1) f on m.id is null
       where r.instrument_version_id = v_instrument
       group by r.analysis_key
    ) a
  on conflict (engagement_id, analysis_key) do update
    set verdict = excluded.verdict,
        reason = excluded.reason,
        supporting_fields = excluded.supporting_fields,
        awaiting_export_refs = excluded.awaiting_export_refs,
        undecided_field_keys = excluded.undecided_field_keys,
        absent_field_keys = excluded.absent_field_keys,
        signed_off_by = null;

  return query
  select c.analysis_key, c.verdict, c.reason
    from analysis_capability c
   where c.engagement_id = p_engagement
   order by c.verdict, c.analysis_key;
end $function$
;

comment on function gea_compute_capability is
  'What each analysis can do on the evidence so far. A required field that '
  'is missing refuses it; an optional one is named separately as detail it '
  'would gain rather than something it waits for.';

insert into gea_migration (filename, note) values
  ('085_what_blocks_and_what_merely_limits.sql',
   'A refusal names the field that blocks it, and lists optional ones '
   'apart so one blocker does not read as three.');
