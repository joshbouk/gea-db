-- 044 Two gaps the capability screen found.
--
-- 1. Signing off the capability table was restricted to leads in the browser
--    and nowhere else. The table's write policy is membership, so any team
--    member could set signed_off_by by other means. Gate G1 rests on that
--    sign-off, which makes it worth enforcing where it cannot be routed
--    around. This is the third time: the precondition override and the path
--    commitment had the same hole.
--
-- 2. An export request line records its status but not when it was requested,
--    so "waiting 34 days" was counted from engagement creation. Every line is
--    created at setup, so a line sent yesterday looked as old as the
--    engagement. Chasing decisions get made on that figure.

alter table export_request_line
  add column requested_at timestamptz;

comment on column export_request_line.requested_at is
  'When the request actually went to the client. Null until it does. Not the '
  'row creation time, which is engagement setup for every line.';

-- RULE: the clock starts when the line is requested, and does not restart.
create or replace function trg_export_line_requested_at() returns trigger
language plpgsql as $fn$
begin
  if new.status <> 'not_requested' and old.status = 'not_requested'
     and new.requested_at is null then
    new.requested_at := now();
  end if;

  -- Going back to not_requested means it was never really sent.
  if new.status = 'not_requested' and old.status <> 'not_requested' then
    new.requested_at := null;
  end if;
  return new;
end $fn$;

create trigger export_line_requested_at before update on export_request_line
  for each row execute function trg_export_line_requested_at();

-- Signing off ----------------------------------------------------------------

create or replace function gea_sign_off_capability(p_engagement uuid)
returns table (analyses_signed_off integer)
language plpgsql security definer set search_path = public as $fn$
declare v_me uuid; n integer; unresolved integer;
begin
  select id into v_me from app_user
   where auth_subject = auth.uid() and is_active;

  if not app_is_engagement_lead(p_engagement) then
    raise exception
      'only a lead consultant or lead architect on this engagement can sign off '
      'the capability table'
      using errcode = 'insufficient_privilege';
  end if;

  select count(*) into n from analysis_capability where engagement_id = p_engagement;
  if n = 0 then
    raise exception
      'there is nothing to sign off. Recompute the capability table first'
      using errcode = 'check_violation';
  end if;

  -- Signing off a picture drawn from mappings nobody has settled would mean
  -- signing off a guess. Cap-bearing fields are the ones that matter: an
  -- unconfirmed one can still change a verdict.
  select count(*) into unresolved
    from canonical_field cf
    join engagement e on e.id = p_engagement
                     and e.instrument_version_id = cf.instrument_version_id
    left join field_mapping m on m.canonical_field_id = cf.id
                             and m.engagement_id = p_engagement
   where cf.is_cap_bearing
     and coalesce(m.status::text, 'proposed') not in
         ('confirmed','corrected','unmapped','auto_accepted');

  if unresolved > 0 then
    raise exception
      '% cap-bearing field% still undecided. Settle them before signing off: '
      'an unconfirmed one can still change a verdict',
      unresolved, case when unresolved = 1 then ' is' else 's are' end
      using errcode = 'check_violation';
  end if;

  update analysis_capability
     set signed_off_by = v_me
   where engagement_id = p_engagement;

  analyses_signed_off := n;
  return next;
end $fn$;

comment on function gea_sign_off_capability is
  'A lead signs off which analyses the client''s data supports. Refused while '
  'any cap-bearing field is still undecided, because one of those can change '
  'a verdict.';

insert into gea_migration (filename, note) values
  ('044_signoff_and_requested_at.sql',
   'Capability sign-off is a lead''s and requires the cap-bearing fields '
   'settled. Export lines record when they were actually requested.');
