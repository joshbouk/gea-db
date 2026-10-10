-- 024 Activating v0.6, and holding prompts to their contract.
--
-- Two things, both surfaced by activating the instrument on the live database.
--
-- 1. The prompt activation gate only fired on the transition into active:
--    `new.status = 'active' and old.status <> 'active'`. Once a prompt was
--    active, its discard conditions could be emptied and nothing refused it.
--    The analysis service would then run that prompt with no validators, which
--    is the failure the gate exists to prevent. It now applies whenever a
--    prompt is active, not only when it becomes active.
--
-- 2. A cold rebuild left v0.6 in draft, so a rebuilt database could not create
--    an engagement — an engagement can only pin an active version. A rebuild
--    should produce a working database, not one that needs a manual step
--    nobody has written down. Activation happens here.
--
--    Both statements are written to do nothing when they have already run, so
--    this is safe against the live database where activation was done by hand.

create or replace function trg_prompt_activation_gate() returns trigger
language plpgsql as $fn$
begin
  -- Applies while active, not only on becoming active. A prompt that loses its
  -- contract after activation is the same problem as one that never had it.
  if new.status = 'active' then
    if new.template is null or length(btrim(new.template)) = 0 then
      raise exception 'prompt % cannot be active without a template', new.ref
        using errcode = 'check_violation';
    end if;
    if new.output_contract = '{}'::jsonb then
      raise exception 'prompt % cannot be active without an output contract', new.ref
        using errcode = 'check_violation';
    end if;
    if jsonb_array_length(new.discard_conditions) = 0 then
      raise exception 'prompt % cannot be active without a discard condition', new.ref
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $fn$;

-- Activation ----------------------------------------------------------------
-- Prompts first: the instrument gate requires every prompt referenced by a
-- step to have an active version.

update prompt_version set status = 'active' where status <> 'active';

-- The activation gate runs as a trigger on this update and refuses it if any
-- of the seven checks fail, so this is the gate doing the work rather than a
-- statement bypassing it.
update instrument_version
   set status = 'active', activated_at = coalesce(activated_at, now())
 where label = 'v0.6' and status = 'draft';

insert into gea_migration (filename, note) values
  ('024_activate_and_hold_prompts.sql',
   'The prompt contract is enforced while active, not only on activation. '
   'Instrument v0.6 is activated as part of the migration set so a rebuild '
   'produces a usable database.');
