-- =================================================================
-- OFFICE LORE — THE ABT AVATAR & ROYAL WARDROBE
-- =================================================================
-- A visual customization layer on top of the existing Abt Dynasty
-- system (0004_abt_dynasty.sql). Does NOT change how the throne is
-- decided (trg_check_abt_throne / abt_reigns stay untouched except
-- one additive nullable column) — this only reads abt_reigns to
-- figure out (a) who may currently equip/claim, and (b) how many
-- cosmetic rewards a user has earned.
--
-- Only the current Abt Lord may equip an item or claim a Daily Royal
-- Pick — enforced server-side in the two RPCs below, not just in the
-- client. Standard items are available to every current lord from
-- day one and are never stored as "unlocked" rows (see catalog seed
-- below) — only earned daily-pick/milestone items get a
-- user_abt_cosmetics row. Milestones are permanent once earned,
-- independent of current lord status.
--
-- Same app-scoping pattern as every table since 0015: RLS gates on
-- public.is_app_member('officelore'), reusing the existing helper.
-- Run this once in the Supabase SQL Editor, after 0001-0017.
-- =================================================================

-- =================================================================
-- SECTION 1 — abt_cosmetic_items (the static catalog)
-- =================================================================
create table public.abt_cosmetic_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  flavor_text text,
  category text not null check (category in ('hair','headwear','armor','cape','weapon','accessory')),
  rarity text not null check (rarity in ('standard','common','rare','epic','legendary','dynasty')),
  unlock_type text not null check (unlock_type in ('standard','daily_pick','milestone')),
  milestone_days int, -- only set for unlock_type='milestone' (1/7/14/30/50/75/100)
  asset_key text not null, -- maps to the JS SVG shape registry, e.g. 'headwear.silver_crown'
  render_tint text, -- optional hex/CSS color recoloring a shared base silhouette (how variants are built)
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index abt_cosmetic_items_category_idx on public.abt_cosmetic_items (category);

-- =================================================================
-- SECTION 2 — user_abt_cosmetics (permanent per-user unlocks)
-- =================================================================
-- Standard items are NOT rows here — they're implicitly available to
-- every current lord (see catalog seed). Only earned daily-pick /
-- milestone items get a row, and it's permanent (never deleted).
create table public.user_abt_cosmetics (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  cosmetic_item_id uuid not null references public.abt_cosmetic_items(id),
  unlocked_at timestamptz not null default now(),
  unlock_source text not null check (unlock_source in ('daily_pick','milestone')),
  reign_id uuid references public.abt_reigns(id),
  unique (user_id, cosmetic_item_id)
);

create index user_abt_cosmetics_user_id_idx on public.user_abt_cosmetics (user_id);

-- =================================================================
-- SECTION 3 — abt_daily_rewards (the claim ledger)
-- =================================================================
create table public.abt_daily_rewards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  reign_id uuid not null references public.abt_reigns(id),
  reign_day int not null, -- which eligible day of that reign this claim used up
  cosmetic_item_id uuid not null references public.abt_cosmetic_items(id),
  claimed_at timestamptz not null default now(),
  unique (reign_id, reign_day) -- at most one Daily Royal Pick per reign-day, ever
);

create index abt_daily_rewards_user_id_idx on public.abt_daily_rewards (user_id);

-- =================================================================
-- SECTION 4 — abt_avatar_loadouts (current equipped state, one row/user)
-- =================================================================
create table public.abt_avatar_loadouts (
  user_id uuid primary key references public.profiles(id),
  hair_item_id uuid references public.abt_cosmetic_items(id),
  headwear_item_id uuid references public.abt_cosmetic_items(id),
  armor_item_id uuid references public.abt_cosmetic_items(id),
  cape_item_id uuid references public.abt_cosmetic_items(id),
  weapon_item_id uuid references public.abt_cosmetic_items(id),
  accessory_item_id uuid references public.abt_cosmetic_items(id),
  updated_at timestamptz not null default now()
);

create trigger trg_abt_avatar_loadouts_updated_at
  before update on public.abt_avatar_loadouts
  for each row execute procedure public.set_updated_at();

-- =================================================================
-- SECTION 5 — abt_reigns: one additive snapshot column
-- =================================================================
-- Populated automatically inside check_abt_throne() the moment a
-- reign closes (captures the outgoing lord's exact loadout as JSON
-- before closing the row). Purely an extra write in the same trigger
-- transaction — does not touch throne-decision logic at all. Not yet
-- rendered anywhere in the UI (first pass captures the data only, so
-- a future round can visualize historical avatars without a schema
-- change).
alter table public.abt_reigns add column ending_loadout_snapshot jsonb;

create or replace function public.check_abt_throne()
returns trigger as $$
declare
  v_leader_id uuid;
  v_leader_xp int;
  v_current record;
  v_current_lord_xp int;
  v_snapshot jsonb;
begin
  perform pg_advisory_xact_lock(918273645);

  select user_id, beer_xp into v_leader_id, v_leader_xp
  from public.user_xp_totals
  order by beer_xp desc, user_id
  limit 1;

  if v_leader_xp is null or v_leader_xp <= 0 then
    return new;
  end if;

  select * into v_current from public.abt_reigns where ended_at is null limit 1;

  if v_current is null then
    insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
    values (v_leader_id, now(), v_leader_xp);
    return new;
  end if;

  if v_current.user_id = v_leader_id then
    return new;
  end if;

  select beer_xp into v_current_lord_xp
  from public.user_xp_totals where user_id = v_current.user_id;

  if v_leader_xp > coalesce(v_current_lord_xp, 0) then
    select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = v_current.user_id;

    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_current_lord_xp, dethroned_by_user_id = v_leader_id,
          ending_loadout_snapshot = v_snapshot
      where id = v_current.id;

    insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
    values (v_leader_id, now(), v_leader_xp);
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;
-- trg_check_abt_throne (0004) already points at this function by name --
-- no change needed to the trigger itself.

-- =================================================================
-- SECTION 6 — equip_abt_item(): the only write path for loadouts
-- =================================================================
create or replace function public.equip_abt_item(p_category text, p_item_id uuid)
returns void as $$
declare
  v_item public.abt_cosmetic_items;
  v_is_lord boolean;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  select exists (
    select 1 from public.abt_reigns where user_id = auth.uid() and ended_at is null
  ) into v_is_lord;
  if not v_is_lord then
    raise exception 'Only the current Abt Lord may dress the Abt Avatar';
  end if;

  select * into v_item from public.abt_cosmetic_items where id = p_item_id and is_active = true;
  if v_item is null or v_item.category <> p_category then
    raise exception 'Unknown or mismatched cosmetic item';
  end if;

  if v_item.unlock_type <> 'standard' and not exists (
    select 1 from public.user_abt_cosmetics where user_id = auth.uid() and cosmetic_item_id = p_item_id
  ) then
    raise exception 'Item not yet unlocked';
  end if;

  insert into public.abt_avatar_loadouts (user_id) values (auth.uid())
  on conflict (user_id) do nothing;

  execute format('update public.abt_avatar_loadouts set %I = $1, updated_at = now() where user_id = $2', p_category || '_item_id')
    using p_item_id, auth.uid();
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.equip_abt_item(text, uuid) to authenticated;

-- =================================================================
-- SECTION 7 — claim_abt_daily_pick(): the only way to earn a
-- daily_pick item (milestones are granted separately, see section 8)
-- =================================================================
create or replace function public.claim_abt_daily_pick(p_cosmetic_item_id uuid)
returns void as $$
declare
  v_reign record;
  v_item public.abt_cosmetic_items;
  v_eligible_days int;
  v_claimed_days int;
  v_next_day int;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  -- serialize per user -- a fast double-click (or the same
  -- onAuthStateChange double-fire risk noted on sync_abt_milestones)
  -- could otherwise let two concurrent claims compute the same
  -- v_next_day and race into the (reign_id, reign_day) unique
  -- constraint as a raw, unhandled exception instead of being cleanly
  -- serialized. Same technique as check_abt_throne's advisory lock.
  perform pg_advisory_xact_lock(hashtext('claim_abt_daily_pick:' || auth.uid()::text));

  select * into v_reign from public.abt_reigns where user_id = auth.uid() and ended_at is null;
  if v_reign is null then
    raise exception 'Only the current Abt Lord may claim a Royal Pick';
  end if;

  -- eligible days across ALL of this user's reigns (past + current) --
  -- banked picks survive dethronement, matching getReignDays'/
  -- getTotalDaysInPower's exact day-math client-side
  select coalesce(sum(greatest(0, floor(extract(epoch from (coalesce(r.ended_at, now()) - r.started_at)) / 86400))), 0)
    into v_eligible_days
    from public.abt_reigns r where r.user_id = auth.uid();

  select count(*) into v_claimed_days from public.abt_daily_rewards where user_id = auth.uid();

  if v_eligible_days - v_claimed_days <= 0 then
    raise exception 'No Royal Pick available';
  end if;

  select * into v_item from public.abt_cosmetic_items where id = p_cosmetic_item_id and is_active = true;
  if v_item is null or v_item.unlock_type <> 'daily_pick' then
    raise exception 'Item is not a valid Daily Royal Pick choice';
  end if;
  if exists (select 1 from public.user_abt_cosmetics where user_id = auth.uid() and cosmetic_item_id = p_cosmetic_item_id) then
    raise exception 'Item already unlocked';
  end if;

  -- next unclaimed reign-day number, scoped to the CURRENT reign (the
  -- (reign_id, reign_day) unique constraint is the final backstop
  -- against a double-claim race)
  select coalesce(max(reign_day), 0) + 1 into v_next_day
    from public.abt_daily_rewards where reign_id = v_reign.id;

  insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source, reign_id)
    values (auth.uid(), p_cosmetic_item_id, 'daily_pick', v_reign.id);
  insert into public.abt_daily_rewards (user_id, reign_id, reign_day, cosmetic_item_id)
    values (auth.uid(), v_reign.id, v_next_day, p_cosmetic_item_id);
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.claim_abt_daily_pick(uuid) to authenticated;

-- =================================================================
-- SECTION 8 — sync_abt_milestones(): lazy-granted, permanent relics
-- =================================================================
-- No pg_cron in this project, so milestones are evaluated lazily —
-- called once per app load (see index.html) for whichever user is
-- logged in. A milestone "arrives" the next time the app loads after
-- the threshold is crossed, not at the exact millisecond, which is
-- fine since the app re-renders on every realtime change anyway.
-- Based on the LONGEST SINGLE reign (current or historical), per the
-- spec's "Reign 1 = 20 days, Reign 2 = 15 days -> Day 30 NOT unlocked"
-- example — deliberately different from the daily-pick pool, which
-- sums across all reigns.
create or replace function public.sync_abt_milestones()
returns setof public.abt_cosmetic_items as $$
declare
  v_longest_reign record;
  v_item public.abt_cosmetic_items;
  v_inserted uuid;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  -- this app's known onAuthStateChange behavior can call this function
  -- more than once for the same user in quick succession (token
  -- refresh / tab refocus, not just genuine login) -- serialize per
  -- user so two overlapping calls can never both pass the "not
  -- already owned" check and then race each other into the unique
  -- constraint below. Same technique as check_abt_throne's advisory
  -- lock (0004_abt_dynasty.sql).
  perform pg_advisory_xact_lock(hashtext('sync_abt_milestones:' || auth.uid()::text));

  for v_item in
    select * from public.abt_cosmetic_items
    where unlock_type = 'milestone' and is_active = true
    order by milestone_days asc
  loop
    if exists (select 1 from public.user_abt_cosmetics where user_id = auth.uid() and cosmetic_item_id = v_item.id) then
      continue; -- already owned, permanent, never re-evaluated
    end if;

    select r.id, greatest(0, floor(extract(epoch from (coalesce(r.ended_at, now()) - r.started_at)) / 86400)) as days
      into v_longest_reign
      from public.abt_reigns r
      where r.user_id = auth.uid()
      order by days desc
      limit 1;

    if v_longest_reign.days >= v_item.milestone_days then
      -- on conflict do nothing is a defense-in-depth backstop -- the
      -- advisory lock above already makes this practically impossible
      v_inserted := null;
      insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source, reign_id)
        values (auth.uid(), v_item.id, 'milestone', v_longest_reign.id)
        on conflict (user_id, cosmetic_item_id) do nothing
        returning cosmetic_item_id into v_inserted;
      if v_inserted is not null then
        return next v_item;
      end if;
    end if;
  end loop;

  return;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.sync_abt_milestones() to authenticated;

-- =================================================================
-- SECTION 9 — RLS. All 4 new tables: select gated on
-- is_app_member('officelore'); writes are RPC-only (no client
-- insert/update/delete policy anywhere), same "server decides" model
-- as abt_reigns itself.
-- =================================================================
alter table public.abt_cosmetic_items enable row level security;
create policy "Abt cosmetic items: read" on public.abt_cosmetic_items for select to authenticated
  using (public.is_app_member('officelore'));

alter table public.user_abt_cosmetics enable row level security;
create policy "User abt cosmetics: read" on public.user_abt_cosmetics for select to authenticated
  using (public.is_app_member('officelore'));

alter table public.abt_daily_rewards enable row level security;
create policy "Abt daily rewards: read" on public.abt_daily_rewards for select to authenticated
  using (public.is_app_member('officelore'));

alter table public.abt_avatar_loadouts enable row level security;
create policy "Abt avatar loadouts: read" on public.abt_avatar_loadouts for select to authenticated
  using (public.is_app_member('officelore'));

-- =================================================================
-- SECTION 10 — REALTIME
-- =================================================================
alter publication supabase_realtime add table public.user_abt_cosmetics;
alter publication supabase_realtime add table public.abt_daily_rewards;
alter publication supabase_realtime add table public.abt_avatar_loadouts;

-- =================================================================
-- SECTION 11 — catalog seed ("solid starter set")
-- =================================================================
-- Standard items: exactly the categories/examples from the spec,
-- always available to any current lord from day one, no
-- user_abt_cosmetics row needed. asset_key maps 1:1 to the JS
-- AVATAR_*_SHAPES registries in index.html.

-- hair (standard, 5)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Short Hair', 'Low maintenance, high authority.', 'hair', 'standard', 'standard', 'hair.short'),
  ('Long Hair', 'Flowing, dramatic, unnecessary.', 'hair', 'standard', 'standard', 'hair.long'),
  ('Slick Back', 'Combed with the confidence of a man who has never lost a round.', 'hair', 'standard', 'standard', 'hair.slick_back'),
  ('Messy Hair', 'The reigning look of someone who was up late defending the throne.', 'hair', 'standard', 'standard', 'hair.messy'),
  ('Bald', 'Nothing to hide, nothing to lose.', 'hair', 'standard', 'standard', 'hair.bald');

-- headwear (standard, 5)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('No Hat', 'The wind in your hair, the XP in your ledger.', 'headwear', 'standard', 'standard', 'headwear.none'),
  ('Simple Crown', 'A crown of questionable authority.', 'headwear', 'standard', 'standard', 'headwear.simple_crown'),
  ('Monk Hood', 'For the contemplative reign.', 'headwear', 'standard', 'standard', 'headwear.monk_hood'),
  ('Beer Cap', 'A bottle cap, worn with pride.', 'headwear', 'standard', 'standard', 'headwear.beer_cap'),
  ('Basic Knight Helmet', 'Standard-issue tavern-guard steel.', 'headwear', 'standard', 'standard', 'headwear.knight_helmet');

-- armor (standard, 5)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  ('Monk Robes', 'A vow of moderation, rarely kept.', 'armor', 'standard', 'standard', 'armor.robes', '#8a5a35'),
  ('Leather Armor', 'Tavern Guard Armor — smells faintly of hops.', 'armor', 'standard', 'standard', 'armor.leather', '#7a4a2c'),
  ('Basic Knight Armor', 'Knight of the Tap.', 'armor', 'standard', 'standard', 'armor.plate', '#9aa3ad'),
  ('Tavern Outfit', 'Practical. Stain-resistant. Mostly.', 'armor', 'standard', 'standard', 'armor.tunic', '#5a6b7a'),
  ('Royal Tunic', 'Fit for someone who definitely earned it.', 'armor', 'standard', 'standard', 'armor.tunic', '#8a2f3d');

-- cape (standard, 5, one silhouette + render_tint)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  ('No Cape', 'A capeless reign is still a reign.', 'cape', 'standard', 'standard', 'cape.none', null),
  ('Red Cape', 'Crimson, bold, slightly dry-clean-only.', 'cape', 'standard', 'standard', 'cape.base', '#b53a3a'),
  ('Green Cape', 'The color of hops and ambition.', 'cape', 'standard', 'standard', 'cape.base', '#3f7a4a'),
  ('Black Cape', 'Mysterious. Dramatic. Slightly too warm indoors.', 'cape', 'standard', 'standard', 'cape.base', '#2b2320'),
  ('Brown Traveller Cape', 'For the Abt Lord who journeys to the terrace and back.', 'cape', 'standard', 'standard', 'cape.base', '#6b4226');

-- weapon (standard, 6 incl. none, mixed silhouettes)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  ('No Weapon', 'Diplomacy first.', 'weapon', 'standard', 'standard', 'weapon.none', null),
  ('The Bottle Opener', 'Sharper than any sword, in the ways that matter.', 'weapon', 'standard', 'standard', 'weapon.bottle_opener', null),
  ('Sword', 'A blade for a lord with something to prove.', 'weapon', 'standard', 'standard', 'weapon.sword', '#c7ccd1'),
  ('Axe', 'Blunt authority.', 'weapon', 'standard', 'standard', 'weapon.axe', '#c7ccd1'),
  ('Wooden Staff', 'Staff of Fermentation, junior edition.', 'weapon', 'standard', 'standard', 'weapon.staff', '#8a5a35'),
  ('Beer Mug', 'The only weapon that has ever truly won a round.', 'weapon', 'standard', 'standard', 'weapon.mug', '#c98a1f');

-- accessory (standard, 6 incl. none)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  ('None', 'Unaccessorized, undefeated.', 'accessory', 'standard', 'standard', 'accessory.none', null),
  ('Beer Mug', 'Always within reach.', 'accessory', 'standard', 'standard', 'accessory.mug', '#c98a1f'),
  ('Hop Necklace', 'Sacred Beer Token, entry-level.', 'accessory', 'standard', 'standard', 'accessory.necklace', '#6f8a3d'),
  ('Belt', 'Holds absolutely nothing, looks great.', 'accessory', 'standard', 'standard', 'accessory.belt', '#6b4226'),
  ('Small Shield', 'Defends against nothing but criticism.', 'accessory', 'standard', 'standard', 'accessory.shield', '#9aa3ad'),
  ('Tankard', 'Ceremonial, mostly empty.', 'accessory', 'standard', 'standard', 'accessory.tankard', '#cfa53d');

-- Daily-pick pool (common/rare/epic) — color/material variants of a
-- handful of shared base silhouettes, matching the spec's own
-- "items may have variants" guidance. ~19 items, comfortably covers
-- weeks of daily reign; more can be added later via a new seed
-- migration with zero code changes.
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  -- headwear
  ('Silver Crown', 'Another completely necessary symbol of authority.', 'headwear', 'common', 'daily_pick', 'headwear.simple_crown', '#c7ccd1'),
  ('Hop Crown', 'Woven from the finest hops in the fridge.', 'headwear', 'common', 'daily_pick', 'headwear.hop_crown', '#6f8a3d'),
  ('Golden Winged Helmet', 'For a lord with somewhere important to fly.', 'headwear', 'rare', 'daily_pick', 'headwear.winged_helmet', '#cfa53d'),
  ('Crown of Questionable Authority', 'Fits surprisingly well.', 'headwear', 'rare', 'daily_pick', 'headwear.simple_crown', '#c98a1f'),
  -- armor tints
  ('Bronze Armor', 'Knight of the Tap, bronze division.', 'armor', 'common', 'daily_pick', 'armor.plate', '#b08d57'),
  ('Steel Armor', 'A cleaner shine than the standard-issue set.', 'armor', 'common', 'daily_pick', 'armor.plate', '#c7ccd1'),
  ('Dark Iron Armor', 'Armor of the Eternal Tap, junior edition.', 'armor', 'rare', 'daily_pick', 'armor.plate', '#3d3f45'),
  ('Blackened Steel Armor', 'Forged in a beer fridge, allegedly.', 'armor', 'rare', 'daily_pick', 'armor.plate', '#1f2126'),
  ('Golden Abt Plate', 'Reserved for a lord with taste.', 'armor', 'epic', 'daily_pick', 'armor.plate', '#e0b84e'),
  -- cape colors
  ('Burgundy Cape', 'Cape of Questionable Decisions, formal edition.', 'cape', 'common', 'daily_pick', 'cape.base', '#6e2c3a'),
  ('Forest Green Cape', 'Blends in at the terrace, stands out at the bar.', 'cape', 'common', 'daily_pick', 'cape.base', '#2f5233'),
  ('Midnight Cape', 'For late-round decision-making.', 'cape', 'common', 'daily_pick', 'cape.base', '#1b1f2e'),
  ('Navy Cape', 'Last Call Cloak, everyday edition.', 'cape', 'rare', 'daily_pick', 'cape.base', '#1f3a5f'),
  ('Cream Cape', 'Surprisingly hard to keep clean.', 'cape', 'rare', 'daily_pick', 'cape.base', '#f0e6d2'),
  ('Purple Cape', 'Mantle of the High Abt, casual Friday version.', 'cape', 'epic', 'daily_pick', 'cape.base', '#5a3f7a'),
  -- weapon materials
  ('Battle Axe', 'Hammer of Last Call''s cousin.', 'weapon', 'common', 'daily_pick', 'weapon.axe', '#e0b84e'),
  ('Hammer of Last Call', 'When the tap runs dry, this settles it.', 'weapon', 'rare', 'daily_pick', 'weapon.hammer', '#8a5a35'),
  ('Mace', 'The Pintbreaker.', 'weapon', 'rare', 'daily_pick', 'weapon.mace', '#9aa3ad'),
  ('Giant Bottle Opener', 'Same tool, considerably more legendary.', 'weapon', 'epic', 'daily_pick', 'weapon.bottle_opener', '#cfa53d'),
  -- accessories
  ('Golden Tankard', 'Perfect Pour Medal, drinkable edition.', 'accessory', 'common', 'daily_pick', 'accessory.tankard', '#e0b84e'),
  ('Sacred Beer Token', 'Grants no powers. Looks important.', 'accessory', 'rare', 'daily_pick', 'accessory.necklace', '#cfa53d'),
  ('Perfect Pour Medal', 'For services rendered to foam management.', 'accessory', 'epic', 'daily_pick', 'accessory.medal', '#e0b84e');

-- Milestone relics — fully bespoke, gold/gem accents, permanent once
-- earned regardless of current lord status. render_tint carries the
-- signature gold/prestige color; the JS renderer applies extra
-- glow/shimmer purely from rarity ('legendary'/'dynasty'), not from
-- unlock_type, so future non-milestone prestige items could reuse it.
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key, render_tint) values
  ('The First Crown', 'Every dynasty starts somewhere.', 'headwear', 'legendary', 'milestone', 1, 'headwear.first_crown', '#e0b84e'),
  ('Crimson Cape of the Seven Pints', 'A luxury far beyond the standard cape rack.', 'cape', 'legendary', 'milestone', 7, 'cape.seven_pints', '#8a1f2b'),
  ('The Sacred Abt Blade', 'Uniquely shaped. Subtly glowing. Deeply unnecessary.', 'weapon', 'legendary', 'milestone', 14, 'weapon.sacred_blade', '#e0b84e'),
  ('Armor of the Eternal Tap', 'Full plate, brass and gold detailing throughout.', 'armor', 'epic', 'milestone', 30, 'armor.eternal_tap', '#cfa53d'),
  ('Crown of Eternal Foam', 'Grand, gilded, faintly foam-flecked.', 'headwear', 'legendary', 'milestone', 50, 'headwear.eternal_foam', '#f0d98c'),
  ('Mantle of the High Abt', 'A cape and outfit combination reserved for legends.', 'cape', 'legendary', 'milestone', 75, 'cape.high_abt_mantle', '#3d1f5a'),
  ('The Eternal Abt Crown', 'Unmistakable proof: 100 days on the throne.', 'headwear', 'dynasty', 'milestone', 100, 'headwear.eternal_abt', '#f5d76e');
