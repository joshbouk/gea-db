-- 064 v0.11: a channel nobody funds.
--
-- The instrument could see how well a company tracks its channels and not
-- whether it invests in them. 3.1 is about allocating budget across the
-- channels you spend on, so a channel receiving nothing is invisible to it.
-- 3.5 is entirely about what comes out of partners, events and community,
-- and asks nothing about what goes in.
--
-- Between the two, a company with a partner channel funded entirely by the
-- partners falls through. It looks efficient — pipeline at almost no cost
-- per qualified opportunity — when what it actually has is pipeline it does
-- not pay for and therefore does not control. A channel you starve is not a
-- predictable asset, and predictability is the thing being assessed.
--
-- Worse, the figure actively misleads. Cost per qualified opportunity on an
-- unfunded channel is low because of the absence of investment, not because
-- of efficiency, and nothing in the number distinguishes the two. A client
-- reading it would conclude they should do more of what they are not doing.
--
-- This extends the anchors of both elements rather than adding a
-- forty-ninth. Forty elements across eight stages plus eight handoffs is the
-- shape of the scorecard and the shape of the story; the question belongs
-- inside two that already exist.

do $$
declare v_old uuid; v_new uuid; v_msg record;
begin
  if exists (select 1 from instrument_version where label = 'v0.11') then
    return;
  end if;
  select id into v_old from instrument_version where label = 'v0.10';
  v_new := gea_clone_instrument(v_old, 'v0.11');

  update instrument_version
     set notes = 'Channel investment enters the maturity model: 3.1 asks '
                 'whether every channel carries a stated investment '
                 'position, and 3.5 asks what the company itself puts into '
                 'partner reach.'
   where id = v_new;

  -- 3.1 Channel portfolio design and budget allocation logic ---------------
  update anchor a set descriptor =
    'Channels have stated roles in a plan and allocation is argued from '
    'channel-level cost per lead. Blend''s analysis finds spend concentrated '
    'in channels whose contribution to qualified pipeline the client cannot '
    'evidence. Channels producing pipeline without company investment are '
    'not in the allocation picture at all.'
    from element e
   where e.id = a.element_id and e.instrument_version_id = v_new
     and e.ref = '3.1' and a.level = 2;

  update anchor a set descriptor =
    'Each channel has a stated job and allocation is argued from cost per '
    'qualified opportunity rather than cost per lead. The portfolio is '
    'reviewed periodically. No payback period is calculated and channel '
    'concentration risk has not been quantified. Channels receiving no '
    'investment are named, but whether that is a decision or an omission is '
    'not recorded.'
    from element e
   where e.id = a.element_id and e.instrument_version_id = v_new
     and e.ref = '3.1' and a.level = 3;

  update anchor a set descriptor =
    'Allocation is set against cost per qualified opportunity and payback by '
    'channel, computed from the client''s own data. Channel concentration is '
    'quantified and stated. Every channel in the portfolio carries a stated '
    'investment position, including those deliberately receiving none. At '
    'least one reallocation decision inside 12 months traces to the analysis.'
    from element e
   where e.id = a.element_id and e.instrument_version_id = v_new
     and e.ref = '3.1' and a.level = 4;

  update anchor a set descriptor =
    'As level 4, and the portfolio is reviewed on a defined cadence against a '
    'single source of channel contribution with a named owner. Owned and paid '
    'reach are planned as a deliberate mix, and the company holds a '
    'documented position on what reach it would still own if paid spend '
    'stopped. A channel carrying pipeline on somebody else''s investment is '
    'revisited on that same cadence rather than treated as free pipeline.'
    from element e
   where e.id = a.element_id and e.instrument_version_id = v_new
     and e.ref = '3.1' and a.level = 5;

  -- 3.5 Partner, event, and community reach --------------------------------
  update anchor a set descriptor =
    'Some contribution tracking exists for events. Partner-sourced and '
    'partner-influenced pipeline are not distinguished, or partner activity '
    'is not recorded in the CRM at all, and no activity has a stated reach '
    'objective. What the company itself puts into partner reach is neither '
    'recorded nor examined.'
    from element e
   where e.id = a.element_id and e.instrument_version_id = v_new
     and e.ref = '3.5' and a.level = 2;

  update anchor a set descriptor =
    'Partner and event contribution is tracked to pipeline and each activity '
    'has a stated objective. Tiering or joint plans exist for the largest '
    'relationships only, and community is unmanaged. Partners fund their own '
    'activity by default, and whether the company should invest alongside '
    'them has not been decided either way.'
    from element e
   where e.id = a.element_id and e.instrument_version_id = v_new
     and e.ref = '3.5' and a.level = 3;

  update anchor a set descriptor =
    'Partner-sourced and partner-influenced pipeline are tracked separately, '
    'event contribution is measured through to qualified opportunity, and '
    'activity selection is argued from prior performance rather than habit. '
    'The company''s own investment in partner reach is stated and argued from '
    'partner-sourced performance, including where that investment is '
    'deliberately nil.'
    from element e
   where e.id = a.element_id and e.instrument_version_id = v_new
     and e.ref = '3.5' and a.level = 4;

  update anchor a set descriptor =
    'As level 4, and reach through partners, events and community is planned '
    'as a portfolio with a named owner and cadence, with partner-facing '
    'messaging drawn from the same governed source as owned channels. Joint '
    'planning and co-investment are managed as part of that portfolio, and a '
    'partner channel carrying pipeline on the partner''s investment alone is '
    'recognised as a dependency rather than a saving.'
    from element e
   where e.id = a.element_id and e.instrument_version_id = v_new
     and e.ref = '3.5' and a.level = 5;

  -- The reason each element is assessed moves with the anchors.
  update element set why_assessed =
    'Budget is allocated across channels that were inherited rather than '
    'chosen, and performance is judged campaign by campaign rather than as a '
    'portfolio. A channel the company does not fund is the easiest one to '
    'miss, and the hardest to rely on.'
   where instrument_version_id = v_new and ref = '3.1';

  update element set why_assessed =
    'Events and partnerships are usually run as line items rather than as a '
    'reach strategy, so their contribution is never compared against the '
    'channels they compete with for budget. Where partners fund their own '
    'activity, the pipeline looks free and is in fact somebody else''s '
    'decision to keep making.'
   where instrument_version_id = v_new and ref = '3.5';

  -- Say what kind of change this is, which the activation gate requires and
  -- which it was right to require: both elements gain a condition that did
  -- not exist, so a company scoring 4 under v0.10 may not score 4 under
  -- v0.11. That is substantive, and a re-score against v0.11 is not
  -- comparable with a score given under v0.10.
  insert into element_version_change (from_instrument_version_id,
                                      to_instrument_version_id, element_ref,
                                      change_type, note)
  values
    (v_old, v_new, '3.1', 'substantive',
     'Levels 2 to 5 now ask whether every channel carries a stated '
     'investment position, including those deliberately receiving none. A '
     'company previously at 4 on tracking alone may now sit lower.'),
    (v_old, v_new, '3.5', 'substantive',
     'Levels 2 to 5 now ask what the company itself puts into partner reach, '
     'not only what it tracks coming out. A partner channel funded entirely '
     'by the partners is a dependency rather than an efficiency.');

  for v_msg in select * from gea_activate_instrument('v0.11') loop
    raise notice '%: %', v_msg.result, v_msg.detail;
  end loop;
end $$;

-- The gate could not say why it blocked -------------------------------------
--
-- Activation reports its failures by reading gea_activation_failures into
-- the function's own result columns, and the function has an out parameter
-- named detail while the query returns a column named detail. PostgreSQL
-- refuses the ambiguity, so every blocked activation failed with a parse
-- error instead of its reasons.
--
-- It has been wrong since activation was written. Nothing noticed because
-- nothing had been blocked before: the first instrument version to fail its
-- own gate was this one.

create or replace function gea_activate_instrument(p_label text)
returns table (result text, detail text)
language plpgsql as $fn$
declare v_id uuid; v_status instrument_status; n integer; r record;
begin
  select id, status into v_id, v_status
    from instrument_version where label = p_label;

  if v_id is null then
    result := 'refused';
    detail := 'no instrument version labelled ' || p_label;
    return next; return;
  end if;

  if v_status <> 'draft' then
    result := 'refused';
    detail := p_label || ' is already ' || v_status::text;
    return next; return;
  end if;

  select count(*) into n from gea_activation_failures(v_id);
  if n > 0 then
    for r in select check_ref, f.detail from gea_activation_failures(v_id) f loop
      result := 'blocked';
      detail := r.check_ref || ': ' || r.detail;
      return next;
    end loop;
    return;
  end if;

  update instrument_version
     set status = 'retired', retired_at = now()
   where status = 'active' and id <> v_id;

  update instrument_version
     set status = 'active', activated_at = now()
   where id = v_id;

  result := 'activated';
  detail := p_label || ' is active and immutable as of ' || now()::text;
  return next;
end $fn$;

comment on function gea_activate_instrument is
  'Activate a draft instrument version and retire the one it replaces. A '
  'blocked activation reports every reason it was blocked.';

insert into gea_migration (filename, note) values
  ('064_instrument_v0_11_channel_investment.sql',
   'v0.11: channel investment enters the maturity model. A channel producing '
   'pipeline on nobody''s investment is a dependency, not an efficiency.');
