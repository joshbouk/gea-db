-- 027 Revenue paths, and who may override a precondition.
--
-- Two things.
--
-- 1. Scope was three independent lists — products, segments, routes to market.
--    The real combinations are sparse, not a cross product. Two products, two
--    segments and three routes gives twelve possibilities and perhaps five
--    that exist. One product might sell to one segment through two routes
--    while another sells to a different segment through a third.
--
--    And the revenue motion was never a choice. New business and growth of the
--    existing base are both always in scope, because that is what the revenue
--    lifecycle is: stages one to eight run from acquisition to retention.
--    engagement.motion_in_scope asked a question with only one answer.
--
--    A revenue path is one real way the business creates revenue: a motion, a
--    product, a segment, a route. Any dimension may be left open where it does
--    not discriminate — base growth is rarely product-specific.
--
--    Scoring does not change. One scorecard per engagement: whether a company
--    has defined pipeline stages is not different for the reseller channel.
--    Paths are how the evidence underneath is cut, and they are what the
--    growth waterfall is built from. A new-business path through a reseller
--    and an expansion path through the base are different funnels, and
--    averaging them describes nothing.
--
-- 2. The override on a task precondition was writable by any team member. It
--    is how a blocked assessment gets unblocked and the record of why, so it
--    belongs to a lead. The application already enforced that; the database
--    did not, which means it was not enforced.

create type revenue_motion as enum ('new_business', 'expansion', 'renewal');

create table revenue_path (
  id            uuid primary key default gen_random_uuid(),
  engagement_id uuid not null references engagement(id) on delete cascade,
  motion        revenue_motion not null,
  product_id    uuid references engagement_scope(id) on delete restrict,
  segment_id    uuid references engagement_scope(id) on delete restrict,
  channel_id    uuid references engagement_scope(id) on delete restrict,
  note          text,
  created_at    timestamptz not null default now(),
  unique (engagement_id, motion, product_id, segment_id, channel_id)
);

comment on table revenue_path is
  'One real way this business creates revenue. A null dimension means the path '
  'is not specific to it. The growth waterfall is built per path and rolled up.';

comment on column revenue_path.motion is
  'New business, expansion or renewal. Not a choice about scope: the lifecycle '
  'covers all three, and a path names which one it belongs to.';

-- RULE: a path's dimensions belong to its own engagement, and each is the
-- right kind. Without this a path could point at another client's product.
create or replace function trg_path_dimensions_belong() returns trigger
language plpgsql as $fn$
declare r record;
begin
  for r in
    select 'product' as want, new.product_id as id
    union all select 'segment', new.segment_id
    union all select 'channel', new.channel_id
  loop
    if r.id is not null then
      if not exists (
        select 1 from engagement_scope s
         where s.id = r.id
           and s.engagement_id = new.engagement_id
           and s.dimension::text = r.want)
      then
        raise exception
          'the % on this path is not a % of this engagement', r.want, r.want
          using errcode = 'check_violation';
      end if;
    end if;
  end loop;
  return new;
end $fn$;

create trigger path_dimensions_belong
  before insert or update on revenue_path
  for each row execute function trg_path_dimensions_belong();

alter table revenue_path enable row level security;

create policy revenue_path_read on revenue_path
  for select to authenticated using (app_is_blend_user());

create policy revenue_path_write on revenue_path
  for all to authenticated
  using (app_is_member(engagement_id)) with check (app_is_member(engagement_id));

-- A readable form for screens and for the waterfall, so no caller has to join
-- engagement_scope three times and guess at the labels.
create or replace view revenue_path_named
with (security_invoker = true) as
select p.id, p.engagement_id, p.motion,
       coalesce(pr.name, 'Any product')  as product,
       coalesce(sg.name, 'Any segment')  as segment,
       coalesce(ch.name, 'Any route')    as route_to_market,
       p.product_id, p.segment_id, p.channel_id, p.note
  from revenue_path p
  left join engagement_scope pr on pr.id = p.product_id
  left join engagement_scope sg on sg.id = p.segment_id
  left join engagement_scope ch on ch.id = p.channel_id;

-- The motion field is superseded ---------------------------------------------
-- It asked which motion was in scope, and the answer is always all of them.
-- Dropped rather than left to mislead the next person who reads the table.

alter table engagement drop column motion_in_scope;

-- The override belongs to a lead ---------------------------------------------

create or replace function app_is_engagement_lead(p_engagement uuid)
returns boolean language sql stable security definer set search_path = public as $fn$
  select app_is_service() or exists (
    select 1
      from engagement_member m
      join app_user u on u.id = m.app_user_id
     where m.engagement_id = p_engagement
       and u.auth_subject = auth.uid()
       and u.is_active
       and m.to_date is null
       and m.engagement_role in ('lead_consultant','lead_architect'))
$fn$;

drop policy if exists task_override_write on task_precondition_override;

create policy task_override_write on task_precondition_override
  for all to authenticated
  using (exists (select 1 from task t
                  where t.id = task_id and app_is_engagement_lead(t.engagement_id)))
  with check (exists (select 1 from task t
                       where t.id = task_id and app_is_engagement_lead(t.engagement_id)));

insert into gea_migration (filename, note) values
  ('027_revenue_paths.sql',
   'Scope becomes revenue paths: a motion, a product, a segment and a route, '
   'declared as the combinations that exist rather than a cross product. '
   'motion_in_scope dropped. Overriding a precondition is a lead''s to do.');
