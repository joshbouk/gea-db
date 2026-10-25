-- 110 A proposal is what the files are for.
--
-- Keyed on how many files have been placed and when the newest arrived,
-- which misses the thing that most often changes: a file moved from one
-- export line to another. The count is the same and the arrival time is
-- the same, so the key matches, so nothing runs — and the consultant who
-- just corrected a misplacement watches the screen not change.
--
-- That is the fourth shape of the same mistake. A timestamp matches
-- nothing, no key matches everything, a count misses a move. The rule
-- holds and the application of it keeps being too narrow: the key is
-- what the job is about, and proposing mappings is about which file
-- answers which line, not how many files there are.

create or replace function gea_enqueue_mapping_proposals(p_engagement uuid)
returns table (run_id uuid, was_created boolean, anything_new boolean)
language plpgsql security definer set search_path = public as $fn$
declare v_what text; v_params jsonb; v_existing uuid;
begin
  if not (app_is_member(p_engagement) or app_is_service()
          or auth.uid() is null) then
    raise exception
      'you are not on this engagement''s team, so nothing was started'
      using errcode = 'insufficient_privilege';
  end if;

  -- Every placed file and the line it answers, in order. Moving one
  -- changes this; adding one changes this; removing one changes this.
  select string_agg(el.ref || ':' || a.id::text, ',' order by a.id)
    into v_what
    from artefact a
    join dataset d on d.artefact_id = a.id
    join export_request_line erl on erl.id = a.export_request_line_id
    join export_line el on el.id = erl.export_line_id
   where a.engagement_id = p_engagement
     and a.purged_at is null
     and d.parse_status = 'parsed';

  if v_what is null then
    raise exception
      'no file has been placed against an export line yet, so there are '
      'no columns to match against. Place them on the Files screen'
      using errcode = 'check_violation';
  end if;

  v_params := jsonb_build_object('placed', md5(v_what));

  select id into v_existing from analysis_run
   where engagement_id = p_engagement and job_type = 'propose_mappings'
     and parameters = v_params
     and status not in ('failed', 'discarded') and not is_stale;

  return query
    select e.run_id, e.was_created, v_existing is null
      from gea_enqueue_run(p_engagement, 'propose_mappings', null, null,
                           null, null, v_params) e;
end $fn$;

comment on function gea_enqueue_mapping_proposals is
  'Queue the mapping proposals, keyed on which file answers which export '
  'line. Moving a file to a different line is new work; pressing twice '
  'over the same arrangement is not.';

insert into gea_migration (filename, note) values
  ('110_a_proposal_is_what_the_files_are_for.sql',
   'The key is which file answers which line, so correcting a '
   'misplacement runs the proposals again.')
on conflict do nothing;
