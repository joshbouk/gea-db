-- 078 Which systems the client runs.
--
-- engagement.crm holds one name, and the assumption underneath it is that
-- a client has a CRM. Blend's clients routinely run HubSpot for marketing
-- and Salesforce for sales, so the deals are in one, the forms and the
-- sessions in the other, and the subscriptions in Zuora. Asking which one
-- they use has no answer.
--
-- So the engagement records the systems rather than the system, and the
-- export request shows the steps for every system the client has. A
-- HubSpot-only client stops seeing Salesforce steps, which was the point;
-- a client with both sees both, which is correct rather than noisy,
-- because for several lines the honest answer is that it depends which one
-- they put it in.
--
-- The stack cost of ownership model needs this list anyway.

alter table engagement
  add column systems text[] not null default array[]::text[];

comment on column engagement.systems is
  'The systems this client runs that hold revenue data: hubspot, '
  'salesforce, and whatever else they named. Decides which retrieval steps '
  'the export request shows, and seeds the stack cost model.';

-- Anything already recorded in the single field becomes the first entry,
-- so nothing recorded is lost.
update engagement
   set systems = array[lower(btrim(crm))]
 where crm is not null and btrim(crm) <> '';

comment on column engagement.crm is
  'Superseded by systems, which holds more than one. Kept so nothing that '
  'reads it breaks; new work should read systems.';

create or replace function gea_set_systems(
  p_engagement uuid, p_systems text[])
returns text[]
language plpgsql security definer set search_path = public as $fn$
declare v_clean text[];
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;

  -- Lower case and deduplicated, because the screen matches on the name
  -- and "Salesforce" and "salesforce" are the same system.
  select coalesce(array_agg(distinct lower(btrim(s))), array[]::text[])
    into v_clean
    from unnest(coalesce(p_systems, array[]::text[])) s
   where btrim(s) <> '';

  update engagement
     set systems = v_clean,
         crm = v_clean[1]
   where id = p_engagement;

  return v_clean;
end $fn$;

comment on function gea_set_systems is
  'Record which systems the client runs. Changing it changes which '
  'retrieval steps are shown and nothing else.';

insert into gea_migration (filename, note) values
  ('078_the_clients_stack.sql',
   'An engagement records the systems the client runs, not one CRM. '
   'HubSpot for marketing and Salesforce for sales is ordinary.');
