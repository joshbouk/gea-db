-- 076 A score knows what it was given against.
--
-- On a six-week engagement the evidence arrives in pieces. The deals
-- export lands in week two and somebody scores 5.1 from it. The stage
-- history arrives in week four, the conversion analysis is accepted in
-- week five, and nobody looks at 5.1 again, because nothing asks them to.
-- The score is not wrong about the evidence it was given against. It
-- predates evidence that would have changed it, and the scorecard cannot
-- tell the difference.
--
-- The same shape, less often, in the other direction: a file is removed
-- and a score that rested on it keeps standing.
--
-- So removal was never the special case it looked like. The rule is that
-- a score is given against a state of the evidence, and it should know
-- which state. Anything that changes the evidence serving an element —
-- a file arriving or going, an analysis accepted or discarded, an
-- interview synthesised — marks that element as scored before the change.
--
-- Not wrong. Not reset. Needing a look, with the change named. Scoring is
-- judgement against anchors and nothing here pretends otherwise; what the
-- system can do is put the element back in front of a person and say what
-- happened since.
--
-- The freeze is where it has teeth. A scorecard cannot be published while
-- an element was scored before half its evidence turned up.

create table score_evidence_change (
  id            uuid primary key default gen_random_uuid(),
  engagement_id uuid not null references engagement(id) on delete cascade,
  element_id    uuid not null references element(id),
  happened_at   timestamptz not null default now(),
  what          text not null,
  reviewed_at   timestamptz,
  reviewed_by   uuid references app_user(id),
  still_stands  boolean
);

comment on table score_evidence_change is
  'Something changed about the evidence serving an element after it was '
  'scored. Cleared by a person looking at the element again and saying '
  'whether the score still stands.';

comment on column score_evidence_change.what is
  'What changed, in words a scorer can act on: which file arrived, which '
  'analysis was accepted. "The evidence changed" sends somebody hunting.';

create index score_evidence_change_open
    on score_evidence_change (engagement_id, element_id)
 where reviewed_at is null;

alter table score_evidence_change enable row level security;
create policy score_evidence_change_member on score_evidence_change
  for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));

-- Noticing ---------------------------------------------------------------

create or replace function gea_evidence_changed(
  p_engagement uuid, p_elements uuid[], p_what text)
returns integer
language plpgsql security definer set search_path = public as $fn$
declare n integer := 0;
begin
  -- Only elements that already carry a score. An unscored element is
  -- about to be looked at anyway, and flagging it would be noise.
  insert into score_evidence_change (engagement_id, element_id, what)
  select s.engagement_id, s.element_id, p_what
    from score s
   where s.engagement_id = p_engagement
     and s.element_id = any (p_elements)
     and s.state <> 'unscored'
     and s.excluded is null
     -- Not twice for the same change.
     and not exists (select 1 from score_evidence_change c
                      where c.engagement_id = s.engagement_id
                        and c.element_id = s.element_id
                        and c.what = p_what
                        and c.reviewed_at is null);
  get diagnostics n = row_count;
  return n;
end $fn$;

comment on function gea_evidence_changed is
  'Mark the scored elements an evidence change touches. Silent on elements '
  'nobody has scored yet.';

-- Which elements an export line serves, and which an analysis serves.
create or replace function gea_elements_of_export(p_engagement uuid, p_ref text)
returns uuid[]
language sql stable as $fn$
  select coalesce(array_agg(distinct x.element_id), array[]::uuid[])
    from export_line el
    join export_line_element x on x.export_line_id = el.id
    join engagement e on e.id = p_engagement
                     and e.instrument_version_id = el.instrument_version_id
   where el.ref = p_ref;
$fn$;

create or replace function gea_elements_of_analysis(p_engagement uuid, p_key text)
returns uuid[]
language sql stable as $fn$
  select coalesce(array_agg(distinct evr.element_id), array[]::uuid[])
    from evidence_requirement evr
    join engagement e on e.id = p_engagement
                     and e.instrument_version_id = evr.instrument_version_id
   where evr.analysis_key = p_key;
$fn$;

-- Looking again -----------------------------------------------------------

create or replace function gea_score_still_stands(
  p_engagement uuid, p_element_ref text, p_stands boolean,
  p_note text default null)
returns integer
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; v_el uuid; n integer;
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  select e.id into v_el
    from element e
    join engagement en on en.id = p_engagement
                      and en.instrument_version_id = e.instrument_version_id
   where e.ref = p_element_ref;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  -- Saying it still stands is a judgement somebody made, so it goes on
  -- the record like any other. A score nobody re-examined and a score
  -- somebody confirmed should not look alike afterwards.
  update score_evidence_change
     set reviewed_at = now(), reviewed_by = v_me, still_stands = p_stands
   where engagement_id = p_engagement and element_id = v_el
     and reviewed_at is null;
  get diagnostics n = row_count;

  if p_stands and n > 0 then
    update score set scored_at = now(), scored_by = v_me,
                     scoring_note = coalesce(nullif(btrim(p_note), ''),
                                             scoring_note)
     where engagement_id = p_engagement and element_id = v_el;
  end if;
  return n;
end $fn$;

comment on function gea_score_still_stands is
  'A person has looked at an element again after its evidence changed and '
  'says whether the score holds. Confirming re-dates the score, because it '
  'has now been given against the evidence as it stands.';

insert into gea_migration (filename, note) values
  ('076_a_score_knows_what_it_was_given_against.sql',
   'A score is given against a state of the evidence. When that state '
   'changes the element needs looking at again, and the freeze refuses '
   'until somebody has.');

-- Wiring it to the things that change evidence --------------------------------

-- A file arriving against an export line.
create or replace function trg_file_changes_the_evidence() returns trigger
language plpgsql as $fn$
declare v_ref text; v_eng uuid; v_file text;
begin
  select el.ref, erl.engagement_id, new.original_filename
    into v_ref, v_eng, v_file
    from export_request_line erl
    join export_line el on el.id = erl.export_line_id
   where erl.id = new.export_request_line_id;
  if v_ref is null then return new; end if;

  if tg_op = 'INSERT' then
    perform gea_evidence_changed(
      v_eng, gea_elements_of_export(v_eng, v_ref),
      format('%s arrived against %s after this was scored.',
             coalesce(v_file, 'A file'), v_ref));
  elsif new.purged_at is not null and old.purged_at is null then
    perform gea_evidence_changed(
      v_eng, gea_elements_of_export(v_eng, v_ref),
      format('%s was removed from %s after this was scored.',
             coalesce(v_file, 'A file'), v_ref));
  end if;
  return new;
end $fn$;

create trigger file_changes_the_evidence
  after insert or update of purged_at on artefact
  for each row execute function trg_file_changes_the_evidence();

-- An analysis accepted or discarded.
create or replace function trg_run_changes_the_evidence() returns trigger
language plpgsql as $fn$
declare v_key text; v_said text;
begin
  if new.job_type not like 'analysis:%' and new.job_type not like 'classify:%'
     and new.job_type <> 'synthesise_interview' then
    return new;
  end if;
  v_key := split_part(new.job_type, ':', 2);

  if new.accepted_at is not null and old.accepted_at is null then
    v_said := format('The %s analysis was accepted after this was scored.',
                     replace(v_key, '_', ' '));
  elsif new.is_stale and not old.is_stale then
    v_said := format('The %s analysis behind this became stale, because the '
                     'file it read was removed.', replace(v_key, '_', ' '));
  elsif new.discarded_reason is not null and old.discarded_reason is null then
    v_said := format('The %s analysis was discarded after this was scored.',
                     replace(v_key, '_', ' '));
  else
    return new;
  end if;

  perform gea_evidence_changed(
    new.engagement_id, gea_elements_of_analysis(new.engagement_id, v_key),
    v_said);
  return new;
end $fn$;

create trigger run_changes_the_evidence
  after update on analysis_run
  for each row execute function trg_run_changes_the_evidence();

-- A citation that points at a removed file ------------------------------------
--
-- The one part of removal that is genuinely about removal. Citing a file
-- nobody can produce is indefensible, and a final score with no citation
-- left cannot stay final: the trigger that requires one is right.

create or replace function trg_purged_file_loses_its_citations() returns trigger
language plpgsql as $fn$
declare r record;
begin
  if new.purged_at is null or old.purged_at is not null then
    return new;
  end if;

  for r in
    select s.id as score_id, s.state, e.ref
      from score_citation c
      join score s on s.id = c.score_id
      join element e on e.id = s.element_id
     where c.artefact_id = new.id
  loop
    delete from score_citation
     where score_id = r.score_id and artefact_id = new.id;

    -- Nothing left to stand on. The score goes back to provisional rather
    -- than to nothing: the judgement was made and may well be right, but
    -- it cannot be final with no evidence behind it.
    if not exists (select 1 from score_citation c2 where c2.score_id = r.score_id)
       and r.state = 'final' then
      update score set state = 'provisional' where id = r.score_id;
      insert into score_evidence_change (engagement_id, element_id, what)
      select s.engagement_id, s.element_id,
             format('The only evidence cited here was %s, which has been '
                    'removed. The score is no longer final.',
                    coalesce(new.original_filename, 'a file'))
        from score s where s.id = r.score_id;
    end if;
  end loop;
  return new;
end $fn$;

create trigger purged_file_loses_its_citations
  after update of purged_at on artefact
  for each row execute function trg_purged_file_loses_its_citations();

comment on function trg_purged_file_loses_its_citations is
  'A citation to a removed file goes, and a final score left with no '
  'citation drops to provisional. Nothing survives the evidence it was '
  'about.';

-- And the freeze refuses while anything is unreviewed -------------------------

create or replace function gea_freeze_scores(p_engagement uuid)
returns table (frozen_at timestamptz, elements integer, reported_as_absent integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_me      uuid;
  v_unmet   text[] := array[]::text[];
  n         integer;
  v_total   integer;
  v_ne      integer;
  v_stages  text;
  v_els     text;
begin
  if not app_is_engagement_lead(p_engagement) then
    raise exception
      'only a lead consultant or lead architect can freeze the scorecard'
      using errcode = 'insufficient_privilege';
  end if;

  if (select score_frozen_at from engagement where id = p_engagement) is not null then
    raise exception 'this scorecard was already frozen'
      using errcode = 'check_violation';
  end if;

  select count(*) into n from score
   where engagement_id = p_engagement and state <> 'final' and excluded is null;
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s element%s not final yet.', n, case when n = 1 then ' is' else 's are' end);
  end if;

  select count(*) into n from score
   where engagement_id = p_engagement and not_evidenced
     and (ne_reason is null or length(btrim(ne_reason)) = 0);
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s element%s marked not evidenced with no reason given.',
      n, case when n = 1 then '' else 's' end);
  end if;

  select count(*) into n from score s
   where s.engagement_id = p_engagement and s.excluded is null
     and not exists (select 1 from score_citation c where c.score_id = s.id);
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s score%s with nothing cited.', n, case when n = 1 then '' else 's' end);
  end if;

  select count(*) into n
    from score_citation c
    join score s on s.id = c.score_id
    join analysis_run r on r.id = c.analysis_run_id
   where s.engagement_id = p_engagement and r.is_stale;
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s citation%s pointing at a run that has been superseded.',
      n, case when n = 1 then '' else 's' end);
  end if;

  select count(*) into n from challenge
   where engagement_id = p_engagement and disposition = 'open';
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s challenge%s still open.', n, case when n = 1 then ' is' else 's are' end);
  end if;

  -- An element scored before its evidence finished arriving. The commonest
  -- way a six-week engagement publishes a figure nobody would stand behind.
  select string_agg(distinct e.ref, ', ' order by e.ref), count(distinct e.ref)
    into v_els, n
    from score_evidence_change c
    join element e on e.id = c.element_id
   where c.engagement_id = p_engagement and c.reviewed_at is null;
  if n > 0 then
    v_unmet := v_unmet || format(
      '%s element%s scored before %s evidence changed and %s not been looked '
      'at since: %s.', n, case when n = 1 then '' else 's' end,
      case when n = 1 then 'its' else 'their' end,
      case when n = 1 then 'has' else 'have' end, v_els);
  end if;

  select string_agg(stage_code, ', ' order by stage_code) into v_stages
    from engagement_stage_score
   where engagement_id = p_engagement and scored = 0;
  if v_stages is not null then
    v_unmet := v_unmet || format(
      'Nothing was scored in stage %s. A score covering seven stages cannot '
      'be published as though it covered eight.', v_stages);
  end if;

  if not exists (select 1 from honesty_test where engagement_id = p_engagement) then
    v_unmet := v_unmet || 'The honesty test has not been answered.'::text;
  end if;

  if array_length(v_unmet, 1) is not null then
    raise exception 'the scorecard is not ready to freeze. %',
      array_to_string(v_unmet, ' ')
      using errcode = 'check_violation';
  end if;

  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  update engagement
     set score_frozen_at = now(), frozen_by = v_me
   where id = p_engagement;

  insert into gate_passage (engagement_id, gate_ref, passed_by)
       values (p_engagement, 'G3', v_me)
  on conflict do nothing;

  select count(*), count(*) filter (where excluded is not null)
    into v_total, v_ne
    from score where engagement_id = p_engagement;

  frozen_at := (select score_frozen_at from engagement where id = p_engagement);
  elements := v_total;
  reported_as_absent := v_ne;
  return next;
end $fn$;

comment on function gea_freeze_scores is
  'Freeze the scorecard, which is gate G3. Every unmet condition is named, '
  'including an element scored before its evidence finished arriving.';

-- What a scorer needs to see --------------------------------------------------

create or replace view score_needs_another_look
with (security_invoker = true) as
select c.engagement_id, e.ref as element_ref, e.name as element_name,
       s.value, s.not_evidenced, s.state::text, s.scored_at,
       count(*) as changes,
       array_agg(c.what order by c.happened_at) as what_changed,
       min(c.happened_at) as first_changed,
       max(c.happened_at) as last_changed
  from score_evidence_change c
  join element e on e.id = c.element_id
  join score s on s.element_id = c.element_id
              and s.engagement_id = c.engagement_id
 where c.reviewed_at is null
 group by c.engagement_id, e.ref, e.name, s.value, s.not_evidenced,
          s.state, s.scored_at;

comment on view score_needs_another_look is
  'Elements scored before something about their evidence changed, with what '
  'changed. Not wrong: scored against a state of the evidence that has '
  'since moved.';
