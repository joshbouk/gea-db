-- 124 A field can be settled another way.
--
-- Capability asks whether each field an analysis needs has a settled
-- mapping to a column. That is right for almost everything and wrong
-- for the one field that is nominated rather than mapped.
--
-- 122 let a consultant say which stage counts as qualified, because no
-- export holds the date. A consultant then nominates the stage on every
-- pipeline, and capability goes on reporting that cost per qualified
-- opportunity cannot run, because qualified_at still has no column
-- against it. The analysis would run; the screen says it cannot; and
-- nobody presses the button.
--
-- So a field settled another way counts as settled. Only one field is
-- settled another way today, and the join says so by name rather than
-- pretending to a generality that does not exist yet.

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
           -- One sentence for everything that would add detail, because
           -- two in a row both ending "would add detail rather than being
           -- needed" reads as a stutter.
           case when a.awaiting_optional is not null
                  or a.optional_missing is not null then
             -- The list is not capitalised. A field key is a name and
             -- account_segment is how it is written everywhere else;
             -- Account_segment is a word that does not exist. The
             -- sentence opens with it rather than reading as a label,
             -- which is the price of leaving names alone.
             format('%s would add detail rather than being needed.',
                    concat_ws(', ',
                      case when a.awaiting_optional is not null then
                        gea_name_a_few(a.awaiting_optional) end,
                      case when a.optional_missing is not null then
                        gea_name_a_few(a.optional_missing) end))
           end), ''),
         case when a.missing_required > 0 then null else a.present end,
         a.awaiting, a.undecided, a.absent
    from (
      select r.analysis_key,
             count(*) filter (where r.is_required and m.id is null) as missing_required,
             count(*) filter (where not r.is_required and m.id is null) as missing_optional,
             array_agg(cf.key order by cf.key) filter (where m.id is not null) as present,
             -- which of the three each missing field is
             -- Only the exports a required field comes from.
             --
             -- Listing every export any field might come from told a
             -- consultant that win and loss analysis was waiting on the
             -- subscriptions export. Every field it takes from there is
             -- optional, and the subscriptions export is the hardest one
             -- to get: it often sits in a billing system nobody in the
             -- room owns. Somebody reading that goes and asks finance for
             -- a file the analysis never needed.
             (select array_agg(distinct x order by x) from unnest(
                array_agg(f.awaiting_ref) filter (where f.awaiting_ref is not null
                                                    and r.is_required)
              ) as x) as awaiting,
             -- Only where nothing required comes from it too. An export
             -- can hold a required field and an optional one, and being
             -- waited on wins: naming it twice told a consultant that
             -- T2-01 both blocked the analysis and would merely add
             -- detail to it.
             (select array_agg(distinct x order by x) from unnest(
                array_agg(f.awaiting_ref) filter (where f.awaiting_ref is not null
                                                    and not r.is_required)
              ) as x
               where x <> all (coalesce((select array_agg(distinct y) from unnest(
                 array_agg(f.awaiting_ref) filter (where f.awaiting_ref is not null
                                                     and r.is_required)) as y),
                 array[]::text[]))
              ) as awaiting_optional,
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
        -- a settled mapping to an actual column, or a field settled
        -- another way
        --
        -- Not everything an assessment needs is in a column. When a
        -- deal became qualified is a stage the business treats as the
        -- point a deal counts, nominated by a consultant on the
        -- pipeline, because no export holds the date. A field settled
        -- that way is as settled as one with a column behind it, and
        -- capability saying otherwise would block the analysis the
        -- nomination exists to unblock.
        left join lateral (
          -- as text, because the branch below is not a mapping status
          -- and a union would otherwise force it into that enum
          select m0.id, m0.status::text
            from field_mapping m0
           where m0.canonical_field_id = r.canonical_field_id
             and m0.engagement_id = p_engagement
             and m0.status in ('confirmed','corrected','auto_accepted')
           union all
          select p.id, 'nominated'::text
            from pipeline p
           where cf.key = 'qualified_at'
             and p.engagement_id = p_engagement
             and p.qualified_at_stage is not null
           limit 1
        ) m on true
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

insert into gea_migration (filename, note) values
  ('124_a_field_can_be_settled_another_way.sql',
   'A nominated qualification stage settles qualified_at, so capability '
   'stops blocking the analysis the nomination unblocks.')
on conflict do nothing;
