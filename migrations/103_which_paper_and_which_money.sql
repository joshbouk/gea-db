-- 103 Which paper, and which money.
--
-- An engagement has a locale and nothing reads it. The report needs two
-- more things it cannot work out.
--
-- Which paper. Blend's branded template comes as UK and US: A4 against
-- Letter, the Reading address against the Atlanta one. A report for an
-- American client on A4 with a British registered office is wrong in a
-- way the client notices and nobody at Blend does.
--
-- And which money. A client reporting in dollars does not want pounds,
-- and an assessment spanning both does not want to silently pick one.
-- The figures come out of the client's own data and the report says
-- which currency they are in, because a number with no currency is a
-- number somebody will read as theirs.
--
-- Neither is derivable. A client in Atlanta may report in euros and a
-- British client may run its pipeline in dollars, so this is recorded
-- rather than guessed from the address.

create type report_region as enum ('uk', 'us');

alter table engagement
  add column report_region report_region not null default 'uk',
  add column currency text not null default 'GBP';

comment on column engagement.report_region is
  'Which of Blend''s branded templates the report is built from. Decides '
  'the page size, the registered office in the footer, and the date '
  'format.';

comment on column engagement.currency is
  'The currency the report states its figures in, as a three-letter code. '
  'Not derivable from the address: a client in Atlanta may report in '
  'euros, and a number with no currency gets read as the reader''s own.';

alter table engagement
  add constraint engagement_currency_is_a_code
  check (currency ~ '^[A-Z]{3}$');

-- The ones that have been seen, so a screen can offer them without
-- pretending the list is closed.
create table currency_in_use (
  code    text primary key check (code ~ '^[A-Z]{3}$'),
  name    text not null,
  symbol  text not null
);

insert into currency_in_use (code, name, symbol) values
  ('GBP', 'Pounds sterling', '£'),
  ('USD', 'US dollars', '$'),
  ('EUR', 'Euros', '€'),
  ('CAD', 'Canadian dollars', 'CA$'),
  ('AUD', 'Australian dollars', 'A$'),
  ('SEK', 'Swedish krona', 'kr'),
  ('CHF', 'Swiss francs', 'CHF');

comment on table currency_in_use is
  'Currencies with a symbol to print. A code not in here is still valid '
  'on an engagement and prints as the code, which is correct if plain.';

alter table currency_in_use enable row level security;
create policy currency_in_use_read on currency_in_use
  for select to authenticated using (true);

-- Existing engagements keep the region their locale implies.
update engagement
   set report_region = case when locale = 'en-US' then 'us'::report_region
                            else 'uk'::report_region end,
       currency = case when locale = 'en-US' then 'USD' else 'GBP' end;

create or replace function gea_set_report_settings(
  p_engagement uuid, p_region text, p_currency text, p_locale text default null)
returns table (region text, currency text, locale text)
language plpgsql security definer set search_path = public as $fn$
begin
  if not app_is_member(p_engagement) then
    raise exception
      'you are not on this engagement''s team, so nothing was recorded'
      using errcode = 'insufficient_privilege';
  end if;
  if lower(btrim(p_region)) not in ('uk', 'us') then
    raise exception 'the report is built on either the UK or the US template'
      using errcode = 'check_violation';
  end if;
  if upper(btrim(p_currency)) !~ '^[A-Z]{3}$' then
    raise exception
      'a currency is a three-letter code: GBP, USD, EUR and so on'
      using errcode = 'check_violation';
  end if;

  update engagement
     set report_region = lower(btrim(p_region))::report_region,
         currency = upper(btrim(p_currency)),
         -- The spelling follows the paper unless somebody says otherwise.
         -- A US client reading "organisation" notices.
         locale = coalesce(nullif(btrim(p_locale), ''),
                           case when lower(btrim(p_region)) = 'us'
                                then 'en-US' else 'en-GB' end)
   where id = p_engagement;

  select e.report_region::text, e.currency, e.locale
    into region, currency, locale
    from engagement e where e.id = p_engagement;
  return next;
end $fn$;

comment on function gea_set_report_settings is
  'Which template the report is built from, which currency its figures '
  'are in, and which spelling. The spelling follows the paper unless '
  'somebody says otherwise.';

insert into gea_migration (filename, note) values
  ('103_which_paper_and_which_money.sql',
   'An engagement records which branded template its report uses and '
   'which currency its figures are in.');
