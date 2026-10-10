-- 021 What an engagement covers, and what it produces.
--
-- Two oversimplifications, both found when the first engagement screen tried
-- to use the schema.
--
-- 1. engagement.motion_in_scope is a single text field. Real businesses have
--    several products, several customer segments and several routes to market,
--    and the VertexOne SOW already says "for both motions". A model that
--    accepts one motion either refuses that engagement or quietly misrepresents
--    it.
--
--    Scope becomes a set of named dimensions. Scoring stays single: a company
--    either has defined pipeline stages with exit criteria or it does not, and
--    that is not different for the reseller channel. What differs by motion is
--    the evidence underneath the score — conversion rates, cost per qualified
--    opportunity, average sale price, cycle time — and those are cut by
--    dimension.
--
-- 2. Every engagement was assumed to produce all six deliverables. The
--    VertexOne SOW sells four. The release gate checks that every deliverable
--    is traced and marked, so it would have blocked on a Measurement
--    Definition Set nobody bought.
--
--    An engagement now declares what it produces, and separately whether each
--    is promised to the client. Blend produces some for its own use — the
--    re-score baseline, the cost model — without putting them in a contract.

-- Scope ---------------------------------------------------------------------

create type scope_dimension as enum ('product', 'segment', 'channel');

create table engagement_scope (
  id            uuid primary key default gen_random_uuid(),
  engagement_id uuid not null references engagement(id) on delete cascade,
  dimension     scope_dimension not null,
  name          text not null check (length(btrim(name)) > 0),
  note          text,
  created_at    timestamptz not null default now(),
  unique (engagement_id, dimension, name)
);

comment on table engagement_scope is
  'The products, customer segments and routes to market an engagement covers. '
  'Analyses cut by these. Scoring does not: one scorecard per engagement.';

alter table engagement_scope enable row level security;

drop policy if exists engagement_scope_read on engagement_scope;
create policy engagement_scope_read on engagement_scope
  for select to authenticated using (app_is_blend_user());

drop policy if exists engagement_scope_write on engagement_scope;
create policy engagement_scope_write on engagement_scope
  for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));

-- motion_in_scope stays as a short human label for the engagement. It is no
-- longer the scope itself, so it stops being mandatory.
alter table engagement alter column motion_in_scope drop not null;

comment on column engagement.motion_in_scope is
  'A short label for what this engagement covers, for headings and lists. The '
  'actual scope is engagement_scope. Do not compute from this column.';

-- Deliverables --------------------------------------------------------------
-- The waterfall is new and always produced: conversion and volume modelled
-- forward through every channel, with the efficiency layer added where channel
-- spend arrives. handoff_annexe stays in the enum because enum values cannot be
-- withdrawn, but it is no longer a deliverable — the handoff map is an annexe
-- inside the report.

alter type deliverable_kind add value if not exists 'growth_waterfall';

create table engagement_deliverable (
  id                 uuid primary key default gen_random_uuid(),
  engagement_id      uuid not null references engagement(id) on delete cascade,
  kind               deliverable_kind not null,
  promised_to_client boolean not null default false,
  note               text,
  created_at         timestamptz not null default now(),
  unique (engagement_id, kind)
);

comment on table engagement_deliverable is
  'What this engagement produces. promised_to_client separates what the SOW '
  'commits to from what Blend produces for its own use. The release gate '
  'checks only what was promised.';

alter table engagement_deliverable enable row level security;

drop policy if exists engagement_deliverable_read on engagement_deliverable;
create policy engagement_deliverable_read on engagement_deliverable
  for select to authenticated using (app_is_blend_user());

drop policy if exists engagement_deliverable_write on engagement_deliverable;
create policy engagement_deliverable_write on engagement_deliverable
  for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));

insert into gea_migration (filename, note) values
  ('021_scope_and_deliverables.sql',
   'Scope becomes products, segments and channels rather than one motion. An '
   'engagement declares what it produces and what was promised to the client. '
   'The growth waterfall is added as a deliverable.');
