-- =================================================================
-- OFFICE LORE — 🎁 MYSTERY REWARDS
-- =================================================================
-- A 'mystery' reward line used to be recorded as 'pending'. It now creates a
-- MYSTERY BOX the member opens themselves; the prize is rolled and paid at the
-- moment of opening, by the server, exactly once.
--
-- A BOX comes from a reward line: {"kind":"mystery","amount":1,"chance":0.3,
--      "pool":"default","rarity_floor":"rare"}
--   chance        rolled once at claim (1 = guaranteed, e.g. the Daily Sweep)
--   pool          which weighted pool in challenge_config.mystery_rewards
--   rarity_floor  the rarity of the prize is never below this (hard Weeklies)
--
-- THE PRIZE is rolled in two steps, all weights configurable:
--   1. RARITY   from pool.rarity, restricted to the floor. Rarities are the ones the
--               cosmetic system already has: common < rare < epic < legendary < dynasty
--               ('dynasty' is the top tier and weighs 0 by default: there is no 'uncommon' or
--               'mythic' in the catalogue, and the Dynasty items stay tied to reigns).
--   2. OUTCOME  from pool.outcomes: cosmetic | xp | fragment
--        cosmetic  an unlocked-by-nobody-yet item of that rarity from the mystery-eligible
--                  catalogue (never a duplicate while any unowned one exists at the floor or
--                  above; with nothing left it turns into a Player XP bonus instead)
--        xp        Player XP, amount by rarity (xp_by_rarity)
--        fragment  1 Gauntlet Fragment through _add_fragments (inventory cap and Abt Lord rule
--                  apply). Only from 'rare' up and at most fragment_weekly_cap per ISO week;
--                  beyond that it becomes XP. So Mystery Rewards can never run Gauntlet
--                  progression away.
--
-- The Daily Sweep line is guaranteed (chance 1), the hard Weeklies carry a rarity floor
-- or a guaranteed box. Opening twice returns the same prize and pays nothing again.
--
-- COSMETICS use the existing wardrobe: abt_cosmetic_items / user_abt_cosmetics (unlock_source
-- 'mystery'). Mystery-eligible = the Daily-Pick items plus a small 'Mystery collection' of
-- recoloured variants of existing silhouettes (the same placeholder technique as the
-- Beer XP milestone items, so no new art is needed). No special-collectible system exists
-- in the app, so there is no such prize type yet.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0055.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
alter table public.abt_cosmetic_items add column if not exists mystery_eligible boolean not null default false;
do $$
declare v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.abt_cosmetic_items'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%unlock_type%';
  if v_name is not null then execute format('alter table public.abt_cosmetic_items drop constraint %I', v_name); end if;
  select conname into v_name from pg_constraint
    where conrelid = 'public.user_abt_cosmetics'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%unlock_source%';
  if v_name is not null then execute format('alter table public.user_abt_cosmetics drop constraint %I', v_name); end if;
end $$;
alter table public.abt_cosmetic_items add constraint abt_cosmetic_items_unlock_type_check
  check (unlock_type in ('standard', 'daily_pick', 'milestone', 'beer_xp', 'mystery'));
alter table public.user_abt_cosmetics add constraint user_abt_cosmetics_unlock_source_check
  check (unlock_source in ('daily_pick', 'milestone', 'beer_xp', 'mystery'));

create table if not exists public.mystery_boxes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  grant_id uuid references public.challenge_reward_grants(id) on delete cascade,
  n int not null default 1,
  pool text not null default 'default',
  rarity_floor text,
  status text not null default 'unopened' check (status in ('unopened', 'opened')),
  prize jsonb,
  created_at timestamptz not null default now(),
  opened_at timestamptz,
  unique (grant_id, n)                                  -- one box per reward line and number: a replayed claim can not add one
);
create index if not exists mystery_boxes_user on public.mystery_boxes (user_id, status);
alter table public.mystery_boxes enable row level security;
drop policy if exists "Mystery boxes: read own" on public.mystery_boxes;
create policy "Mystery boxes: read own" on public.mystery_boxes for select to authenticated using (user_id = auth.uid());
do $$
begin
  begin
    alter publication supabase_realtime add table public.mystery_boxes;
  exception when duplicate_object then null;
  end;
end $$;

-- =================================================================
-- SECTION 2 — configuration and the catalogue
-- =================================================================
insert into public.challenge_config (key, value) values
  ('mystery_rewards', '{
      "rarity_order": ["common", "rare", "epic", "legendary", "dynasty"],
      "xp_by_rarity": {"common": 10, "rare": 20, "epic": 35, "legendary": 60, "dynasty": 100},
      "fragment_weekly_cap": 2,
      "pools": {
        "default": {"outcomes": {"cosmetic": 50, "xp": 43, "fragment": 7},
                    "rarity":   {"common": 52, "rare": 30, "epic": 14, "legendary": 4, "dynasty": 0}},
        "sweep":   {"outcomes": {"cosmetic": 50, "xp": 40, "fragment": 10},
                    "rarity":   {"common": 45, "rare": 32, "epic": 17, "legendary": 6, "dynasty": 0}}
      }
   }'::jsonb)
on conflict (key) do nothing;

update public.abt_cosmetic_items set mystery_eligible = true where unlock_type = 'daily_pick';

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint, mystery_eligible)
select v.name, v.flavor_text, v.category, v.rarity, 'mystery', v.asset_key, v.tint, true
from (values
  ('Copper Tankard', 'Dull on the outside, honest on the inside. (placeholder art)', 'accessory', 'common', 'accessory.tankard', '#b87333'),
  ('Midnight Mug Platter', 'Ten tankards, one blue-black mood. (placeholder art)', 'accessory', 'rare', 'accessory.mug_platter', '#2b3a6b'),
  ('Emerald Hop Crown', 'Greener than the competition. (placeholder art)', 'headwear', 'rare', 'headwear.hop_crown', '#2e8b57'),
  ('Obsidian Lionheart', 'The mane went dark. The attitude did not. (placeholder art)', 'armor', 'epic', 'armor.lion', '#2a2a33'),
  ('Amethyst Golden Cloak', 'Threads of gold in a very purple mood. (placeholder art)', 'cape', 'epic', 'cape.golden_threads', '#6b3fa0'),
  ('Moonlit Warbow', 'Fires only at midnight. Misses on purpose. (placeholder art)', 'weapon', 'epic', 'weapon.hunting_bow', null),
  ('Phantom Crown of Foam', 'Cold, pale, impossible to spill. (placeholder art)', 'headwear', 'legendary', 'headwear.ice_crystal_tiara', null),
  ('Ember Sacred Blade', 'Glows like the last tap of the night. (placeholder art)', 'weapon', 'legendary', 'weapon.sword', null),
  ('Diadem of the Night Taproom', 'Worn by nobody, owed to everybody. (placeholder art)', 'accessory', 'legendary', 'accessory.diadem', '#b388ff')
) as v(name, flavor_text, category, rarity, asset_key, tint)
where not exists (select 1 from public.abt_cosmetic_items i where i.unlock_type = 'mystery' and i.name = v.name);

-- a pool for the Sweep, and rarity floors / guarantees for the hard Weeklies
update public.challenge_config
  set value = jsonb_set(value, '{lines}', '[ {"kind":"player_xp","amount":25}, {"kind":"mystery","amount":1,"pool":"sweep"} ]'::jsonb)
  where key = 'daily_sweep' and not (value::text like '%"pool"%');
update public.challenge_config set value = value || jsonb_build_object(
    'pw_completionist', '[ {"kind":"player_xp","amount":90}, {"kind":"gauntlet_fragments","amount":3}, {"kind":"mystery","amount":1,"rarity_floor":"rare"} ]'::jsonb,
    'pw_adventurer',    '[ {"kind":"player_xp","amount":50}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.5,"rarity_floor":"rare"} ]'::jsonb,
    'gw_council',       '[ {"kind":"player_xp","amount":45}, {"kind":"gauntlet_fragments","amount":2}, {"kind":"mystery","amount":1,"chance":0.6,"rarity_floor":"rare"} ]'::jsonb)
  where key = 'weekly_rewards' and not ((value->'pw_completionist')::text like '%rarity_floor%');

-- =================================================================
-- SECTION 3 — the grant creates a box
-- =================================================================
create or replace function public._grant_challenge_reward2(p_user uuid, p_assignment uuid, p_sweep uuid, p_line jsonb, p_line_no int)
returns jsonb as $$
declare
  v_kind text := p_line->>'kind';
  v_amount int := coalesce((p_line->>'amount')::int, 0);
  v_chance numeric := coalesce((p_line->>'chance')::numeric, 1);
  v_hit boolean;
  v_status text;
  v_gid uuid;
  v_frag jsonb := '{}'::jsonb;
  v_boxes int := 0;
begin
  v_hit := v_chance >= 1 or random() < v_chance;     -- rolled once: the grant row below records it
  v_status := case when not v_hit then 'missed'
                   when v_kind in ('player_xp', 'category_xp', 'gauntlet_fragments', 'mystery') then 'applied'
                   else 'pending' end;
  insert into public.challenge_reward_grants (assignment_id, sweep_id, user_id, line_no, kind, amount, category, status)
    values (p_assignment, p_sweep, p_user, p_line_no, v_kind, case when v_hit then v_amount else 0 end, p_line->>'category', v_status)
    on conflict do nothing
    returning id into v_gid;
  if v_gid is null then
    return jsonb_build_object('kind', v_kind, 'duplicate', true);
  end if;

  -- only reached when this very grant row was just created: a replay never gets here
  if v_hit and v_kind = 'gauntlet_fragments' and v_amount > 0 then
    v_frag := public._add_fragments(p_user, v_amount);
  elsif v_hit and v_kind = 'mystery' and v_amount > 0 then
    insert into public.mystery_boxes (user_id, grant_id, n, pool, rarity_floor)
      select p_user, v_gid, g, coalesce(p_line->>'pool', 'default'), p_line->>'rarity_floor' from generate_series(1, v_amount) g
      on conflict do nothing;
    v_boxes := v_amount;
  end if;
  return jsonb_build_object('kind', v_kind, 'amount', v_amount, 'category', p_line->>'category', 'hit', v_hit, 'chance', v_chance, 'status', v_status,
                            'boxes', v_boxes, 'rarity_floor', p_line->>'rarity_floor') || v_frag;
end;
$$ language plpgsql security definer set search_path = public;

-- boxes for Mystery lines that were earlier recorded as 'pending'
insert into public.mystery_boxes (user_id, grant_id, n, pool)
  select g.user_id, g.id, n, 'default' from public.challenge_reward_grants g, generate_series(1, greatest(g.amount, 1)) n
  where g.kind = 'mystery' and g.status = 'pending' and g.amount > 0
  on conflict do nothing;
update public.challenge_reward_grants set status = 'applied' where kind = 'mystery' and status = 'pending';

-- =================================================================
-- SECTION 4 — opening a box
-- =================================================================
create or replace function public._weighted_pick(w jsonb)
returns text as $$
declare
  v_total numeric; v_r numeric; v_acc numeric := 0; k text; v numeric; v_last text;
begin
  select coalesce(sum(value::numeric), 0) into v_total from jsonb_each_text(w) where value::numeric > 0;
  if v_total <= 0 then return null; end if;
  v_r := random() * v_total;
  for k, v in select key, value::numeric from jsonb_each_text(w) where value::numeric > 0 order by key loop
    v_acc := v_acc + v; v_last := k;
    if v_r <= v_acc then return k; end if;
  end loop;
  return v_last;
end;
$$ language plpgsql;

create or replace function public.open_mystery_box(p_box_id uuid)
returns jsonb as $$
declare
  b public.mystery_boxes;
  v_cfg jsonb := public._challenge_config('mystery_rewards', '{}'::jsonb);
  v_pool jsonb;
  v_order jsonb := coalesce(v_cfg->'rarity_order', '["common","rare","epic","legendary","dynasty"]'::jsonb);
  v_floor_i int; v_rar text; v_rar_i int; v_outcome text; v_outcomes jsonb; v_weights jsonb;
  v_week_start timestamptz := date_trunc('week', now() at time zone 'Europe/Brussels') at time zone 'Europe/Brussels';
  v_frags_week int; v_cap int := coalesce((v_cfg->>'fragment_weekly_cap')::int, 2);
  it public.abt_cosmetic_items;
  v_prize jsonb; v_try int; v_dup boolean := false; v_xp int; v_res jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into b from public.mystery_boxes where id = p_box_id for update;
  if b.id is null or b.user_id is distinct from auth.uid() then raise exception 'This is not your Mystery Reward'; end if;
  if b.status = 'opened' then return jsonb_build_object('status', 'already_opened', 'prize', b.prize); end if;

  v_pool := coalesce(v_cfg->'pools'->b.pool, v_cfg->'pools'->'default');
  v_floor_i := coalesce((select ord - 1 from jsonb_array_elements_text(v_order) with ordinality t(val, ord) where val = coalesce(b.rarity_floor, 'common')), 0);

  -- 1. rarity: the pool's weights, nothing below the floor
  select jsonb_object_agg(e.key, e.value) into v_weights
    from jsonb_each_text(v_pool->'rarity') e
    where coalesce((select ord - 1 from jsonb_array_elements_text(v_order) with ordinality t(val, ord) where val = e.key), -1) >= v_floor_i and e.value::numeric > 0;
  v_rar := public._weighted_pick(coalesce(v_weights, jsonb_build_object(v_order->>v_floor_i, 1)));
  v_rar_i := (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality t(val, ord) where val = v_rar);

  -- 2. outcome: a Fragment only from rare up, and only within the weekly cap
  v_outcomes := v_pool->'outcomes';
  select count(*) into v_frags_week from public.mystery_boxes x
    where x.user_id = b.user_id and x.status = 'opened' and x.prize->>'type' = 'fragment' and x.opened_at >= v_week_start;
  if v_rar_i < 1 or v_frags_week >= v_cap then v_outcomes := v_outcomes - 'fragment'; end if;
  v_outcome := coalesce(public._weighted_pick(v_outcomes), 'xp');

  if v_outcome = 'cosmetic' then
    -- an unowned item: the rolled rarity first, then the others from the floor upwards (lower ones first)
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select i.* into it from public.abt_cosmetic_items i
        where i.is_active and i.mystery_eligible
          and i.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality t(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.user_abt_cosmetics u where u.user_id = b.user_id and u.cosmetic_item_id = i.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality t(val, ord) where val = i.rarity) >= v_floor_i
        order by random() limit 1;
      exit when it.id is not null;
    end loop;
    if it.id is null then
      v_outcome := 'xp'; v_dup := true;                       -- nothing new left at this tier: no frustrating duplicate, a bonus instead
    else
      insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source) values (b.user_id, it.id, 'mystery') on conflict do nothing;
      v_prize := jsonb_build_object('type', 'cosmetic', 'rarity', it.rarity, 'item_id', it.id, 'name', it.name, 'category', it.category, 'flavor', it.flavor_text);
    end if;
  end if;

  if v_outcome = 'fragment' then
    v_res := public._add_fragments(b.user_id, 1);
    v_prize := jsonb_build_object('type', 'fragment', 'rarity', v_rar, 'amount', 1, 'stored', v_res->'stored', 'forged', v_res->'forged', 'lord', v_res->'lord');
  elsif v_outcome = 'xp' then
    v_xp := coalesce((v_cfg->'xp_by_rarity'->>v_rar)::int, 10);
    v_prize := jsonb_build_object('type', 'xp', 'rarity', v_rar, 'amount', v_xp, 'duplicate_bonus', v_dup);
  end if;

  update public.mystery_boxes set status = 'opened', prize = v_prize, opened_at = now() where id = b.id;
  return jsonb_build_object('status', 'opened', 'prize', v_prize);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array['_grant_challenge_reward2(uuid, uuid, uuid, jsonb, int)', '_weighted_pick(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  revoke all on function public.open_mystery_box(uuid) from public, anon;
  grant execute on function public.open_mystery_box(uuid) to authenticated;
end $$;
