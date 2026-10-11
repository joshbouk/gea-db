-- 050 Why an analysis cannot run, separated into its three real cases.
--
-- The capability table said "not supported: the client has no stage_entered_at"
-- on an engagement three days old where the stage history export simply had not
-- been sent yet. That reads as a finding about the client when it is a note
-- about the post.
--
-- Three different things were being reported as one:
--
--   the export has not arrived        a chase list, and the commonest case early on
--   it arrived, nobody has decided    work for the person doing the mapping
--   it arrived and the field is not   a genuine finding, and the only one of the
--   in it                             three that caps a score
--
-- The verdict stays as it was, because an analysis that cannot run cannot run
-- whatever the reason. What changes is that the reason now says which of the
-- three, and the fields are recorded separately so a screen can group them
-- without parsing a sentence.
--
-- The reason also stops repeating the analysis key. It was written to stand
-- alone and every screen showed it prefixed with its own subject.

alter table analysis_capability
  add column awaiting_export_refs text[],
  add column undecided_field_keys text[],
  add column absent_field_keys    text[];

comment on column analysis_capability.awaiting_export_refs is
  'Exports this analysis needs that have not arrived. Not a finding about the '
  'client: a list of what to chase.';
comment on column analysis_capability.absent_field_keys is
  'Fields confirmed as not being in the export that carries them. This is the '
  'finding, and the only one of the three that caps a score.';

-- Naming four things and counting the rest reads; naming twelve does not.
create or replace function gea_name_a_few(p_items text[], p_show integer default 4)
returns text language sql immutable as $fn$
  select case
    when p_items is null or array_length(p_items, 1) = 0 then ''
    when array_length(p_items, 1) <= p_show
      then array_to_string(p_items, ', ')
    else array_to_string(p_items[1:p_show], ', ')
         || format(' and %s more', array_length(p_items, 1) - p_show)
  end
$fn$;

create or replace function gea_compute_capability(p_engagement uuid)
returns table (analysis_key text, verdict capability_verdict, reason text)
language plpgsql security definer set search_path = public as $fn$
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
                                            and coalesce(m2.status::text,'') <> 'unmapped')
              ) as x) as undecided,
             (select array_agg(distinct x order by x) from unnest(
                array_agg(cf.key) filter (where m.id is null and f.awaiting_ref is null
                                            and coalesce(m2.status::text,'') = 'unmapped')
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
end $fn$;

comment on function gea_compute_capability is
  'Work out which analyses the client''s confirmed fields can support, and why '
  'not where they cannot: waiting on an export, not yet mapped, or genuinely '
  'not in the client''s data. Only the third is a finding.';

insert into gea_migration (filename, note) values
  ('050_why_an_analysis_cannot_run.sql',
   'Capability separates waiting on an export from not yet mapped from the '
   'client not having the field, and stops the reason repeating the analysis '
   'name.');
