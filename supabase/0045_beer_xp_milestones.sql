-- =================================================================
-- OFFICE LORE — 🍺 BEER XP MILESTONES (a progression apart from the throne)
-- =================================================================
-- Beer XP stays valuable whoever sits on the Abt throne. Reaching Beer XP
-- milestones permanently unlocks cosmetics, exactly like the Abt Lord's
-- day milestones do, but based on the user's total Beer XP:
--
--    250  Brewer's Tankard            1500  St. Bernard Companion
--    500  Hop Crown                   2000  High Brewmaster Armor
--    750  Brewmaster Apron            3000  Legendary Brewery Set (3 pieces)
--   1000  Brewer's Shield
--
-- CONFIGURABLE: the thresholds live in the table beer_xp_milestones (one row
-- per milestone: xp_required, title, flavor_text). Rewards are
-- abt_cosmetic_items rows with unlock_type = 'beer_xp' and milestone_xp = the
-- threshold, so a milestone can grant one item or several (the Legendary
-- Brewery Set grants three). Change or add milestones with plain SQL; no code
-- change. Every reward below is a PLACEHOLDER (flat art drawn by the client)
-- until real illustrations exist; swap the art by changing the asset_key.
--
-- PERMANENT: a reward is a row in user_abt_cosmetics. Nothing ever deletes or
-- re-evaluates it, so losing the #1 Beer XP spot (or the throne) never takes a
-- milestone cosmetic away.
--
-- LAZY (no pg_cron): sync_beer_xp_milestones() grants everything the caller's
-- current Beer XP has reached and returns only what is NEW, so the client can
-- celebrate it exactly once. Beer XP is read from user_xp_totals, the same
-- number the whole app shows.
--
-- The temporary 🍺 HIGH BREWMASTER title for the current #1 is derived live in
-- the client (it needs no storage); this migration only adds the permanent part.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0044.
-- =================================================================

-- =================================================================
-- SECTION 1 — config table
-- =================================================================
create table if not exists public.beer_xp_milestones (
  xp_required int primary key check (xp_required > 0),
  title text not null,
  flavor_text text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.beer_xp_milestones enable row level security;
drop policy if exists "Beer XP milestones: read" on public.beer_xp_milestones;
create policy "Beer XP milestones: read" on public.beer_xp_milestones for select to authenticated
  using (public.is_app_member('officelore'));

-- =================================================================
-- SECTION 2 — cosmetics: a new unlock type
-- =================================================================
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.abt_cosmetic_items'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%unlock_type%';
  if v_name is not null then execute format('alter table public.abt_cosmetic_items drop constraint %I', v_name); end if;

  select conname into v_name from pg_constraint
    where conrelid = 'public.user_abt_cosmetics'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%unlock_source%';
  if v_name is not null then execute format('alter table public.user_abt_cosmetics drop constraint %I', v_name); end if;
end $$;

alter table public.abt_cosmetic_items add constraint abt_cosmetic_items_unlock_type_check
  check (unlock_type in ('standard', 'daily_pick', 'milestone', 'beer_xp'));
alter table public.user_abt_cosmetics add constraint user_abt_cosmetics_unlock_source_check
  check (unlock_source in ('daily_pick', 'milestone', 'beer_xp'));
alter table public.abt_cosmetic_items add column if not exists milestone_xp int references public.beer_xp_milestones(xp_required);

-- =================================================================
-- SECTION 3 — the milestones and their (placeholder) rewards
-- =================================================================
insert into public.beer_xp_milestones (xp_required, title, flavor_text) values
  (250, 'Brewer''s Tankard', 'A sturdy tankard, dented by honest work.'),
  (500, 'Hop Crown', 'Green cones, golden pride.'),
  (750, 'Brewmaster Apron', 'Splashes of three hundred batches. Wear them proudly.'),
  (1000, 'Brewer''s Shield', 'Guards against warm beer and bad opinions.'),
  (1500, 'St. Bernard Companion', 'Always carries a small barrel. Never lost, never thirsty.'),
  (2000, 'High Brewmaster Armor', 'Forged in the tuns of a legendary brewery.'),
  (3000, 'Legendary Brewery Set', 'A crown, a scepter and a banner. The brewery bows to you.')
on conflict (xp_required) do update set title = excluded.title, flavor_text = excluded.flavor_text;

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_xp, asset_key, render_tint)
select v.name, v.flavor_text, v.category, v.rarity, 'beer_xp', v.xp, v.asset_key, v.tint
from (values
  ('Brewer''s Tankard', 'A sturdy tankard, dented by honest work. (placeholder art)', 'accessory', 'common', 250, 'accessory.tankard', '#d9a441'),
  ('Hop Crown', 'Green cones, golden pride. (placeholder art)', 'headwear', 'rare', 500, 'headwear.hop_crown', null),
  ('Brewmaster Apron', 'Splashes of three hundred batches. (placeholder art)', 'armor', 'rare', 750, 'armor.brewmaster_apron', null),
  ('Brewer''s Shield', 'Guards against warm beer and bad opinions. (placeholder art)', 'accessory', 'epic', 1000, 'accessory.shield', '#c98a1f'),
  ('St. Bernard', 'Always carries a small barrel. (placeholder art)', 'companion', 'epic', 1500, 'companion.st_bernard', null),
  ('High Brewmaster Armor', 'Forged in the tuns of a legendary brewery. (placeholder art)', 'armor', 'legendary', 2000, 'armor.high_brewmaster_armor', null),
  ('Legendary Brewery Crown', 'Part of the Legendary Brewery Set. (placeholder art)', 'headwear', 'legendary', 3000, 'headwear.brewery_set_crown', null),
  ('Legendary Brewery Scepter', 'Part of the Legendary Brewery Set. (placeholder art)', 'weapon', 'legendary', 3000, 'weapon.brewery_set_scepter', null),
  ('Legendary Brewery Banner', 'Part of the Legendary Brewery Set. (placeholder art)', 'accessory', 'legendary', 3000, 'accessory.brewery_set_banner', null)
) as v(name, flavor_text, category, rarity, xp, asset_key, tint)
where not exists (
  select 1 from public.abt_cosmetic_items i where i.unlock_type = 'beer_xp' and i.asset_key = v.asset_key and i.milestone_xp = v.xp
);

-- =================================================================
-- SECTION 4 — grant (lazy, idempotent, permanent)
-- =================================================================
-- Returns the milestones that became NEW rewards during this call.
create or replace function public.sync_beer_xp_milestones()
returns table (xp_required int, title text, flavor_text text, item_ids uuid[]) as $$
declare
  v_xp int;
  m public.beer_xp_milestones;
  v_ids uuid[];
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  -- a quick double fire (token refresh, tab refocus) must not race itself
  perform pg_advisory_xact_lock(hashtext('sync_beer_xp_milestones:' || auth.uid()::text));

  select coalesce(beer_xp, 0) into v_xp from public.user_xp_totals where user_id = auth.uid();
  v_xp := coalesce(v_xp, 0);

  for m in
    select * from public.beer_xp_milestones b where b.is_active and b.xp_required <= v_xp order by b.xp_required
  loop
    with ins as (
      insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source)
      select auth.uid(), i.id, 'beer_xp'
      from public.abt_cosmetic_items i
      where i.unlock_type = 'beer_xp' and i.milestone_xp = m.xp_required and i.is_active
      on conflict (user_id, cosmetic_item_id) do nothing
      returning cosmetic_item_id
    )
    select array_agg(cosmetic_item_id) into v_ids from ins;

    if v_ids is not null then
      xp_required := m.xp_required; title := m.title; flavor_text := m.flavor_text; item_ids := v_ids;
      return next;
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.sync_beer_xp_milestones() from public, anon;
grant execute on function public.sync_beer_xp_milestones() to authenticated;
