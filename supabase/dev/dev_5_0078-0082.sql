-- DEV bundle part 5/5: migrations 0078 to 0082. Run the parts in order, each once, in a NEW empty Supabase project (never in production).

-- =========== 0078_pets.sql ===========
-- =================================================================
-- OFFICE LORE — PETS for every personal character (earned, never bought)
-- =================================================================
-- Everybody (the Abt Lord too) can own pets. A pet is shown next to your character in My Room and on the Home page.
--
--   PETS (species): Cat, Golden Retriever, Dobermann, Highland Cow. They drop SLOWLY (a collection for weeks), from ANY claimed quest:
--     a chance per claim by quest type (config key 'pet_drops'), plus a pity counter (after N claims without a pet the
--     next claim gives one), plus Mystery boxes. A species you own is yours for good; the next drop is always a species you
--     do not own yet.
--   PET CLOTHES (pet_outfits): each species has a Classic look (comes with the pet) and clothes tied to a kind of quest or
--     challenge (Battle, Beer discovery, Chaos, Poetry, Quizzes, Lore, Rebellion, one Legendary). They drop like the character
--     outfits do (a chance per claim of the linked quests + pity), but ONLY for a pet you already own, and they can also be
--     found in Mystery boxes (again only clothes you can wear).
--   You wear one pet + one of its looks: set_room_pet(species, outfit). Stored in room_profiles.loadout (pet, petOutfit).
--
-- Paid inside the idempotent claim / box opening (the claim row and the box are unique), so refreshing, double clicking, a
-- second tab or a realtime echo can never grant or roll twice. Additive + idempotent. Run after 0077.
-- =================================================================
create table if not exists public.pet_species (
  id text primary key,
  name text not null,
  hint text not null,
  sort_order int not null default 0,
  is_active boolean not null default true
);
create table if not exists public.pet_outfits (
  id text primary key,
  species_id text not null references public.pet_species(id),
  family text not null,
  name text not null,
  rarity text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  unlock_kind text not null check (unlock_kind in ('standard', 'random_drop')),
  sources jsonb not null default '[]',        -- [{"def": "pw_battle_hardened", "chance": 0.25}]
  pity_after int,
  hint text not null,
  sort_order int not null default 0,
  is_active boolean not null default true
);
create table if not exists public.user_pets (
  user_id uuid not null references public.profiles(id),
  species_id text not null references public.pet_species(id),
  source text,
  granted_at timestamptz not null default now(),
  primary key (user_id, species_id)
);
create table if not exists public.user_pet_outfits (
  user_id uuid not null references public.profiles(id),
  outfit_id text not null references public.pet_outfits(id),
  source text,
  granted_at timestamptz not null default now(),
  primary key (user_id, outfit_id)
);
create table if not exists public.pet_pity (
  user_id uuid not null references public.profiles(id),
  key text not null,
  misses int not null default 0,
  primary key (user_id, key)
);
alter table public.pet_species enable row level security;
alter table public.pet_outfits enable row level security;
alter table public.user_pets enable row level security;
alter table public.user_pet_outfits enable row level security;
alter table public.pet_pity enable row level security;                  -- no policy: private
drop policy if exists "Pet species: read" on public.pet_species;
create policy "Pet species: read" on public.pet_species for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "Pet outfits: read" on public.pet_outfits;
create policy "Pet outfits: read" on public.pet_outfits for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "My pets: read own" on public.user_pets;
create policy "My pets: read own" on public.user_pets for select to authenticated using (user_id = auth.uid());
drop policy if exists "My pet outfits: read own" on public.user_pet_outfits;
create policy "My pet outfits: read own" on public.user_pet_outfits for select to authenticated using (user_id = auth.uid());

insert into public.pet_species (id, name, hint, sort_order) values
  ('kat', 'Cat', 'A cat for your corner of the room.', 10),
  ('golden', 'Golden Retriever', 'A loyal, happy dog.', 20),
  ('dobermann', 'Dobermann', 'A sleek guard dog.', 30),
  ('koe', 'Highland Cow', 'A fluffy little cow.', 40)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, sort_order = excluded.sort_order;

insert into public.pet_outfits (id, species_id, family, name, rarity, unlock_kind, sources, pity_after, hint, sort_order) values
  ('kat-standaard', 'kat', 'standaard', 'Classic', 'common', 'standard', '[]'::jsonb, null, 'Comes with your Cat.', 10),
  ('golden-standaard', 'golden', 'standaard', 'Classic', 'common', 'standard', '[]'::jsonb, null, 'Comes with your Golden Retriever.', 20),
  ('dobermann-standaard', 'dobermann', 'standaard', 'Classic', 'common', 'standard', '[]'::jsonb, null, 'Comes with your Dobermann.', 30),
  ('koe-standaard', 'koe', 'standaard', 'Classic', 'common', 'standard', '[]'::jsonb, null, 'Comes with your Highland Cow.', 40),
  ('kat-battle', 'kat', 'battle', 'Battle Gear', 'epic', 'random_drop', '[{"def": "pw_battle_hardened", "chance": 0.1}, {"def": "rb_storm", "chance": 0.08}, {"def": "rb_seeds", "chance": 0.04}, {"def": "pd_pick_a_side", "chance": 0.03}]'::jsonb, 30, 'A rare drop from Battle quests.', 110),
  ('golden-battle', 'golden', 'battle', 'Battle Gear', 'epic', 'random_drop', '[{"def": "pw_battle_hardened", "chance": 0.1}, {"def": "rb_storm", "chance": 0.08}, {"def": "rb_seeds", "chance": 0.04}, {"def": "pd_pick_a_side", "chance": 0.03}]'::jsonb, 30, 'A rare drop from Battle quests.', 111),
  ('dobermann-battle', 'dobermann', 'battle', 'Battle Gear', 'epic', 'random_drop', '[{"def": "pw_battle_hardened", "chance": 0.1}, {"def": "rb_storm", "chance": 0.08}, {"def": "rb_seeds", "chance": 0.04}, {"def": "pd_pick_a_side", "chance": 0.03}]'::jsonb, 30, 'A rare drop from Battle quests.', 112),
  ('kat-beer-explore', 'kat', 'beer-explore', 'Beer Trekker', 'rare', 'random_drop', '[{"def": "pw_beer_explorer", "chance": 0.25}, {"def": "gw_gathering", "chance": 0.15}, {"def": "pd_beer_scholar", "chance": 0.06}, {"def": "pd_new_brew", "chance": 0.06}, {"def": "pd_one_for_the_books", "chance": 0.06}]'::jsonb, 12, 'Drops from beer discovery quests.', 120),
  ('golden-beer-explore', 'golden', 'beer-explore', 'Beer Trekker', 'rare', 'random_drop', '[{"def": "pw_beer_explorer", "chance": 0.25}, {"def": "gw_gathering", "chance": 0.15}, {"def": "pd_beer_scholar", "chance": 0.06}, {"def": "pd_new_brew", "chance": 0.06}, {"def": "pd_one_for_the_books", "chance": 0.06}]'::jsonb, 12, 'Drops from beer discovery quests.', 121),
  ('kat-chaos', 'kat', 'chaos', 'Chaos Wizard', 'rare', 'random_drop', '[{"def": "pw_agent_of_chaos", "chance": 0.25}, {"def": "gd_daily_chaos", "chance": 0.1}, {"def": "pd_draw_this", "chance": 0.1}, {"def": "pd_the_impostor", "chance": 0.1}, {"def": "pd_the_photographer", "chance": 0.1}, {"def": "pd_royal_decree", "chance": 0.06}, {"def": "pd_office_safari", "chance": 0.06}, {"def": "pd_emoji_lore", "chance": 0.06}, {"def": "pd_five_seconds", "chance": 0.06}, {"def": "pd_tiny_quest", "chance": 0.06}]'::jsonb, 12, 'Drops from Chaos quests.', 130),
  ('kat-poet', 'kat', 'poet', 'Poets Quill', 'rare', 'random_drop', '[{"def": "pw_poet_laureate", "chance": 0.25}, {"def": "gw_poets", "chance": 0.15}, {"def": "gd_poetry_showdown", "chance": 0.1}, {"def": "pd_poet_for_a_day", "chance": 0.1}, {"def": "rb_pamphlet", "chance": 0.1}, {"def": "pd_poetry_critic", "chance": 0.06}]'::jsonb, 12, 'Drops from poetry quests.', 140),
  ('golden-quiz', 'golden', 'quiz', 'Quiz Scholar', 'rare', 'random_drop', '[{"def": "gw_council", "chance": 0.3}, {"def": "pw_keeper_knowledge", "chance": 0.25}, {"def": "pd_perfect_score", "chance": 0.12}, {"def": "gd_lore_quiz", "chance": 0.1}, {"def": "pd_lore_master", "chance": 0.06}, {"def": "pd_know_thy_friends", "chance": 0.06}]'::jsonb, 12, 'Drops from quiz quests.', 150),
  ('koe-lore-keeper', 'koe', 'lore-keeper', 'Scroll Bearer', 'rare', 'random_drop', '[{"def": "pw_lorekeeper", "chance": 0.25}, {"def": "gw_nickname_factory", "chance": 0.15}, {"def": "pd_lore_keeper", "chance": 0.06}, {"def": "pd_quote_hunter", "chance": 0.06}, {"def": "pd_memory_lane", "chance": 0.06}, {"def": "pd_name_thy_victim", "chance": 0.06}]'::jsonb, 12, 'Drops from Lore quests.', 160),
  ('kat-rebellion', 'kat', 'rebellion', 'Rebel Cloak', 'epic', 'random_drop', '[{"def": "rb_seeds", "chance": 0.35}, {"def": "rb_pamphlet", "chance": 0.35}, {"def": "rb_storm", "chance": 0.35}]'::jsonb, 8, 'Drops from Rebellion quests.', 169),
  ('koe-rebellion', 'koe', 'rebellion', 'Rebel Cloak', 'epic', 'random_drop', '[{"def": "rb_seeds", "chance": 0.35}, {"def": "rb_pamphlet", "chance": 0.35}, {"def": "rb_storm", "chance": 0.35}]'::jsonb, 8, 'Drops from Rebellion quests.', 170),
  ('dobermann-legendary', 'dobermann', 'legendary', 'Legendary Guardian', 'legendary', 'random_drop', '[{"def": "pw_completionist", "chance": 0.06}, {"def": "pw_adventurer", "chance": 0.04}, {"def": "pw_social_creature", "chance": 0.04}, {"def": "gw_fellowship", "chance": 0.03}, {"def": "gw_gathering", "chance": 0.03}, {"def": "gw_poets", "chance": 0.03}, {"def": "gw_nickname_factory", "chance": 0.03}, {"def": "gw_council", "chance": 0.04}, {"def": "rb_seeds", "chance": 0.03}, {"def": "rb_pamphlet", "chance": 0.03}, {"def": "rb_storm", "chance": 0.03}]'::jsonb, 100, 'A rare drop from the hardest quests.', 900)
on conflict (id) do update set species_id = excluded.species_id, family = excluded.family, name = excluded.name, rarity = excluded.rarity,
  unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, hint = excluded.hint, sort_order = excluded.sort_order;

-- how fast the pets themselves drop (a chance per claim by quest type; the Daily Sweep counts as 'sweep'); tunable without code
insert into public.challenge_config (key, value) values
  ('pet_drops', '{"chance": {"personal_daily": 0.02, "group_daily": 0.02, "personal_weekly": 0.06, "group_weekly": 0.06, "rebellion": 0.08, "sweep": 0.08}, "pity_after": 40}')
on conflict (key) do nothing;

-- Mystery boxes may now contain a pet or pet clothes
update public.challenge_config
  set value = jsonb_set(value, '{pools,default,outcomes,pet}', '12'::jsonb, true)
  where key = 'mystery_rewards' and not (value->'pools'->'default'->'outcomes' ? 'pet');
update public.challenge_config
  set value = jsonb_set(value, '{pools,sweep,outcomes,pet}', '15'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'sweep' and not (value->'pools'->'sweep'->'outcomes' ? 'pet');

-- the hook: called once per successful claim (never from a client)
create or replace function public._pet_hook(p_user uuid, p_def text, p_type text)
returns jsonb as $$
declare
  v_cfg jsonb := public._challenge_config('pet_drops', '{"chance": {}, "pity_after": 8}'::jsonb);
  v_chance numeric; v_pity int; v_miss int; v_hit boolean;
  v_owned text[];
  o public.pet_outfits; src jsonb; sp public.pet_species;
  v_pets jsonb := '[]'::jsonb; v_outfits jsonb := '[]'::jsonb;
begin
  select coalesce(array_agg(species_id), '{}') into v_owned from public.user_pets where user_id = p_user;

  -- 1. a new pet (any claim can drop one; the species is always one you do not own yet)
  if exists (select 1 from public.pet_species s where s.is_active and not (s.id = any (v_owned))) then
    v_chance := coalesce((v_cfg->'chance'->>p_type)::numeric, 0);
    v_pity := nullif(v_cfg->>'pity_after', '')::int;
    insert into public.pet_pity (user_id, key) values (p_user, 'species') on conflict do nothing;
    select misses into v_miss from public.pet_pity where user_id = p_user and key = 'species' for update;
    v_hit := random() < v_chance or (v_pity is not null and v_miss + 1 >= v_pity);
    update public.pet_pity set misses = case when v_hit then 0 else v_miss + 1 end where user_id = p_user and key = 'species';
    if v_hit then
      select * into sp from public.pet_species s where s.is_active and not (s.id = any (v_owned)) order by random() limit 1;
      insert into public.user_pets (user_id, species_id, source) values (p_user, sp.id, coalesce(p_def, p_type)) on conflict do nothing;
      if found then v_pets := v_pets || jsonb_build_object('id', sp.id, 'name', sp.name); end if;
    end if;
  end if;

  -- 2. clothes linked to this quest, for a pet you owned BEFORE this claim
  if p_def is not null then
    for o in select po.* from public.pet_outfits po join public.pet_species s on s.id = po.species_id
             where po.is_active and s.is_active and po.unlock_kind = 'random_drop' and po.species_id = any (v_owned) order by po.sort_order loop
      select e into src from jsonb_array_elements(o.sources) e where e->>'def' = p_def limit 1;
      continue when src is null;
      continue when exists (select 1 from public.user_pet_outfits u where u.user_id = p_user and u.outfit_id = o.id);
      v_chance := coalesce((src->>'chance')::numeric, 0);
      insert into public.pet_pity (user_id, key) values (p_user, 'o:' || o.id) on conflict do nothing;
      select misses into v_miss from public.pet_pity where user_id = p_user and key = 'o:' || o.id for update;
      v_hit := random() < v_chance or (o.pity_after is not null and v_miss + 1 >= o.pity_after);
      update public.pet_pity set misses = case when v_hit then 0 else v_miss + 1 end where user_id = p_user and key = 'o:' || o.id;
      if v_hit then
        insert into public.user_pet_outfits (user_id, outfit_id, source) values (p_user, o.id, p_def) on conflict do nothing;
        if found then v_outfits := v_outfits || jsonb_build_object('id', o.id, 'name', o.name, 'species_id', o.species_id); end if;
      end if;
    end loop;
  end if;
  return jsonb_build_object('pets', v_pets, 'outfits', v_outfits);
end;
$$ language plpgsql security definer set search_path = public;

-- wearing a pet: you must own the species and the look (Classic is always yours); null = no pet
create or replace function public.set_room_pet(p_species text, p_outfit text default null)
returns jsonb as $$
declare
  v_loadout jsonb;
  o public.pet_outfits;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_species is not null then
    if not exists (select 1 from public.pet_species s where s.id = p_species and s.is_active) then raise exception 'Unknown pet'; end if;
    if not exists (select 1 from public.user_pets u where u.user_id = auth.uid() and u.species_id = p_species) then raise exception 'You do not have this pet yet'; end if;
    if p_outfit is not null then
      select * into o from public.pet_outfits where id = p_outfit and is_active;
      if o.id is null or o.species_id <> p_species then raise exception 'That look does not belong to this pet'; end if;
      if o.unlock_kind <> 'standard' and not exists (select 1 from public.user_pet_outfits u where u.user_id = auth.uid() and u.outfit_id = o.id) then
        raise exception 'You have not unlocked this look yet';
      end if;
    end if;
  end if;
  insert into public.room_profiles (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select loadout into v_loadout from public.room_profiles where user_id = auth.uid() for update;
  v_loadout := coalesce(v_loadout, '{}'::jsonb) - 'pet' - 'petOutfit';
  if p_species is not null then
    v_loadout := v_loadout || jsonb_build_object('pet', p_species);
    if p_outfit is not null and o.unlock_kind <> 'standard' then v_loadout := v_loadout || jsonb_build_object('petOutfit', p_outfit); end if;
  end if;
  update public.room_profiles set loadout = v_loadout where user_id = auth.uid();
  return v_loadout;
end;
$$ language plpgsql security definer set search_path = public;

-- claiming, the Daily Sweep and opening a box now report the pets they earn (otherwise unchanged from 0075)
create or replace function public.claim_challenge(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_line jsonb;
  v_no int := 0;
  v_results jsonb := '[]'::jsonb;
  v_min numeric;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if a.user_id is not null and a.user_id <> auth.uid() then raise exception 'This is not your challenge'; end if;
  -- a Rebellion is for those who do not hold the throne
  if a.type = 'rebellion' and auth.uid() is not distinct from public._current_abt_lord() then raise exception 'The Abt Lord cannot claim a Rebellion reward'; end if;

  if a.status not in ('completed', 'claimed') then
    -- an unfinished Weekly offers a small consolation once the week is over, and only above the threshold
    v_min := coalesce((a.payload->>'consolation_min_pct')::numeric, 0.5);
    if a.type = 'personal_weekly' and (a.status = 'expired' or a.expires_at <= now()) and a.target > 0
       and a.progress::numeric / a.target > v_min and jsonb_array_length(coalesce(a.payload->'consolation', '[]'::jsonb)) > 0 then
      insert into public.challenge_claims (assignment_id, user_id) values (a.id, auth.uid()) on conflict do nothing;
      if not found then return jsonb_build_object('status', 'already_claimed'); end if;
      for v_line in select * from jsonb_array_elements(a.payload->'consolation') loop
        v_no := v_no + 1;
        -- consolation lines are plain Player XP: never a Fragment, never a chance roll
        if v_line->>'kind' = 'player_xp' then
          v_results := v_results || public._grant_challenge_reward2(auth.uid(), a.id, null, v_line, 200 + v_no);
        end if;
      end loop;
      return jsonb_build_object('status', 'consolation', 'results', v_results);
    end if;
    raise exception 'This challenge is not complete yet';
  end if;

  if a.user_id is null and not (
       case when a.group_rule is not null
            then exists (select 1 from public.challenge_member_progress mp where mp.assignment_id = a.id and mp.user_id = auth.uid())
            else exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id and c.user_id = auth.uid() and c.amount > 0) end) then
    raise exception 'Only members who took part in this quest can claim its reward';
  end if;

  insert into public.challenge_claims (assignment_id, user_id) values (a.id, auth.uid()) on conflict do nothing;
  if not found then
    return jsonb_build_object('status', 'already_claimed');
  end if;

  for v_line in select * from jsonb_array_elements(coalesce(a.reward->'lines', '[]'::jsonb)) loop
    v_no := v_no + 1;
    v_results := v_results || public._grant_challenge_reward2(auth.uid(), a.id, null, v_line, v_no);
  end loop;

  if a.user_id is not null then
    update public.challenge_assignments set status = 'claimed', claimed_at = now() where id = a.id;
  end if;
  -- special Personal Character outfits that this very claim earns (once: the claim row above is unique)
  return jsonb_build_object('status', 'claimed', 'results', v_results, 'outfits', public._character_outfit_hook(auth.uid(), a.definition_id),
    'titles', public._grant_titles(auth.uid(), 'claims', a.definition_id),
    'pet', public._pet_hook(auth.uid(), a.definition_id, a.type));
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.claim_daily_sweep(p_sweep_id uuid)
returns jsonb as $$
declare
  s public.challenge_sweeps;
  v_line jsonb;
  v_no int := 0;
  v_results jsonb := '[]'::jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into s from public.challenge_sweeps where id = p_sweep_id for update;
  if s.id is null or s.user_id <> auth.uid() then raise exception 'This is not your Daily Sweep'; end if;
  if s.claimed_at is not null then return jsonb_build_object('status', 'already_claimed'); end if;

  update public.challenge_sweeps set claimed_at = now() where id = s.id;
  for v_line in select * from jsonb_array_elements(coalesce(s.reward->'lines', '[]'::jsonb)) loop
    v_no := v_no + 1;
    v_results := v_results || public._grant_challenge_reward2(auth.uid(), null, s.id, v_line, v_no);
  end loop;
  return jsonb_build_object('status', 'claimed', 'results', v_results, 'titles', public._grant_titles(auth.uid(), 'sweeps', null),
    'pet', public._pet_hook(auth.uid(), null, 'sweep'));
end;
$$ language plpgsql security definer set search_path = public;

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
  tt public.character_titles; v_titles jsonb;
  pc record;
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
  -- cosmetics are Abt Lord gear: for everybody else a box pays XP (or a fragment), nothing is attached to a normal player's character
  if b.user_id is distinct from public._current_abt_lord() then v_outcomes := v_outcomes - 'cosmetic'; end if;
  select count(*) into v_frags_week from public.mystery_boxes x
    where x.user_id = b.user_id and x.status = 'opened' and x.prize->>'type' = 'fragment' and x.opened_at >= v_week_start;
  if v_rar_i < 1 or v_frags_week >= v_cap then v_outcomes := v_outcomes - 'fragment'; end if;
  v_outcome := coalesce(public._weighted_pick(v_outcomes), 'xp');

  if v_outcome = 'cosmetic' then
    -- an unowned item: the rolled rarity first, then the others from the floor upwards (lower ones first)
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select i.* into it from public.abt_cosmetic_items i
        where i.is_active and i.mystery_eligible
          and (not i.lord_only_drop or b.user_id is not distinct from public._current_abt_lord())      -- Abt Lord gear drops for the Abt Lord only
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

  if v_outcome = 'title' then
    -- an owned-nothing-yet title of the rolled rarity, then the other tiers from the floor upwards (lower first); nothing left = an XP bonus
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select t.* into tt from public.character_titles t
        where t.is_active and t.unlock_kind = 'drop'
          and t.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.user_character_titles u where u.user_id = b.user_id and u.title_id = t.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = t.rarity) >= v_floor_i
        order by random() limit 1;
      exit when tt.id is not null;
    end loop;
    if tt.id is null then
      v_outcome := 'xp'; v_dup := true;
    else
      insert into public.user_character_titles (user_id, title_id, source) values (b.user_id, tt.id, 'box') on conflict do nothing;
      v_prize := jsonb_build_object('type', 'title', 'rarity', tt.rarity, 'title_id', tt.id, 'text', tt.text);
    end if;
  end if;

  if v_outcome = 'pet' then
    -- a pet you do not own yet, or clothes for a pet you DO own (never clothes you cannot wear); the rolled rarity first, then the other tiers from the floor upwards
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select * into pc from (
        select 'species'::text as kind, s.id, s.name, s.id as species_id, s.name as species_name, 'common'::text as rarity
          from public.pet_species s
          where s.is_active and not exists (select 1 from public.user_pets u where u.user_id = b.user_id and u.species_id = s.id)
        union all
        select 'outfit', o.id, o.name, o.species_id, s.name, o.rarity
          from public.pet_outfits o join public.pet_species s on s.id = o.species_id
          where o.is_active and s.is_active and o.unlock_kind = 'random_drop'
            and exists (select 1 from public.user_pets u where u.user_id = b.user_id and u.species_id = o.species_id)
            and not exists (select 1 from public.user_pet_outfits u where u.user_id = b.user_id and u.outfit_id = o.id)
      ) cand
      where cand.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                           where ord - 1 = case when v_try = 0 then v_rar_i
                                                else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
        and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = cand.rarity) >= v_floor_i
      order by random() limit 1;
      exit when pc.id is not null;
    end loop;
    if pc.id is null then
      v_outcome := 'xp'; v_dup := true;
    else
      if pc.kind = 'species' then
        insert into public.user_pets (user_id, species_id, source) values (b.user_id, pc.id, 'box') on conflict do nothing;
      else
        insert into public.user_pet_outfits (user_id, outfit_id, source) values (b.user_id, pc.id, 'box') on conflict do nothing;
      end if;
      v_prize := jsonb_build_object('type', 'pet', 'rarity', pc.rarity, 'kind', pc.kind, 'pet_id', pc.id, 'name', pc.name, 'species_id', pc.species_id, 'species_name', pc.species_name);
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
  v_titles := public._grant_titles(b.user_id, 'boxes', null);
  return jsonb_build_object('status', 'opened', 'prize', v_prize, 'titles', v_titles);
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public._pet_hook(uuid, text, text) from public, anon, authenticated;
revoke all on function public.set_room_pet(text, text) from public, anon;
grant execute on function public.set_room_pet(text, text) to authenticated;
revoke all on function public.claim_challenge(uuid) from public, anon;
grant execute on function public.claim_challenge(uuid) to authenticated;
revoke all on function public.claim_daily_sweep(uuid) from public, anon;
grant execute on function public.claim_daily_sweep(uuid) to authenticated;
revoke all on function public.open_mystery_box(uuid) from public, anon;
grant execute on function public.open_mystery_box(uuid) to authenticated;

-- =========== 0079_pet_balance.sql ===========
-- =================================================================
-- 0079 — Pet balance: pets drop slowly, the armor looks are rare
--
-- For a database that already ran the first 0078 (a re-run of the current 0078 gives the same result):
--   * pets: per claim 2% (Dailies) / 6% (Weeklies, Group Weeklies) / 8% (Rebellion, Daily Sweep), pity only after 40 claims
--   * Mystery boxes: a pet is a smaller part of the box (weight 12, Sweep boxes 15)
--   * the Battle Gear (armor) looks are EPIC: 3-10% per claim of Battle quests, pity after 30 claims;
--     the Legendary Guardian pity after 100 claims
-- Tunable afterwards: challenge_config 'pet_drops' and pet_outfits.sources / pity_after. Idempotent.
-- =================================================================
update public.challenge_config set value =
  '{"chance": {"personal_daily": 0.02, "group_daily": 0.02, "personal_weekly": 0.06, "group_weekly": 0.06, "rebellion": 0.08, "sweep": 0.08}, "pity_after": 40}'
  where key = 'pet_drops';
update public.challenge_config set value = jsonb_set(value, '{pools,default,outcomes,pet}', '12'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'default';
update public.challenge_config set value = jsonb_set(value, '{pools,sweep,outcomes,pet}', '15'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'sweep';
update public.pet_outfits set rarity = 'epic', pity_after = 30,
  sources = '[{"def":"pw_battle_hardened","chance":0.1},{"def":"rb_storm","chance":0.08},{"def":"rb_seeds","chance":0.04},{"def":"pd_pick_a_side","chance":0.03}]'::jsonb
  where family = 'battle';
update public.pet_outfits set pity_after = 100 where id = 'dobermann-legendary';

-- =========== 0080_quest_guide.sql ===========
-- =================================================================
-- 0080 — Quest Guide: one overview of every quest, what to do, and what it pays
--
-- get_quest_guide() returns the ACTIVE quest definitions (hidden ones and switched-off features are left out) with the reward
-- lines they really pay (the same resolution the engine uses when an assignment is created), plus the Group Daily winner reward
-- and the Daily Sweep. Read-only, members only; nothing about drop odds of outfits / pets / titles is exposed.
-- The Quest Board reads it for its "Guide" page, so a new or changed quest shows up there without a code change. Idempotent.
-- =================================================================
create or replace function public.get_quest_guide()
returns jsonb as $$
declare
  v_quests jsonb;
  v_gd jsonb := public._challenge_config('group_daily_rewards', '{}'::jsonb);
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select coalesce(jsonb_agg(t.q order by t.ord), '[]'::jsonb) into v_quests from (
    select jsonb_build_object(
             'id', d.id, 'type', d.type, 'category', d.category, 'title', d.title, 'description', d.description,
             'difficulty', d.difficulty, 'icon', d.icon, 'weekly_tier', d.weekly_tier, 'audience', d.audience,
             'target', case when d.parts is not null then (select sum((pt->>'target')::int) from jsonb_array_elements(d.parts) pt) else d.target end,
             'group_mode', d.group_rule->>'mode',
             'parts', (select jsonb_agg(jsonb_build_object('label', pt->>'label', 'target', (pt->>'target')::int)) from jsonb_array_elements(d.parts) pt),
             'reward', coalesce(public._assignment_reward(d)->'lines', '[]'::jsonb)) as q,
           row_number() over (order by
             case d.type when 'personal_daily' then 1 when 'group_daily' then 2 when 'personal_weekly' then 3 when 'group_weekly' then 4 else 5 end,
             d.category,
             case d.difficulty when 'easy' then 1 when 'normal' then 2 when 'hard' then 3 else 4 end, d.title) as ord
    from public.challenge_definitions d
    where d.app_id = 'officelore' and d.is_active
      and (d.requires is null
           or d.requires in ('open_battle', 'unrated_beer', 'anecdote_target', 'old_content', 'nicknames_3', 'poems_2', 'group_quiz_data', 'poetry_prompt_data', 'battle_activity')
           or coalesce((select f.enabled from public.challenge_features f where f.key = d.requires), false))
  ) t;
  return jsonb_build_object(
    'quests', v_quests,
    'group_daily', jsonb_build_object('participation', coalesce(v_gd->'participation', '[]'::jsonb), 'winner', coalesce(v_gd->'winner', '[]'::jsonb), 'min_participants', coalesce((v_gd->>'min_participants')::int, 2)),
    'sweep', coalesce(public._challenge_config('daily_sweep', '{}'::jsonb)->'lines', '[]'::jsonb),
    'weekly_slots', public._challenge_config('weekly_slots', '{"normal":2,"big":1}'::jsonb));
end;
$$ language plpgsql stable security definer set search_path = public;
revoke all on function public.get_quest_guide() from public, anon;
grant execute on function public.get_quest_guide() to authenticated;

-- =========== 0081_pets_cat.sql ===========
-- =================================================================
-- 0081 — The Cat is ready: plain Classic look + its Rebel Cloak
--
-- kat-standaard.png is now a plain cat, so the Cat (switched off in an earlier version of this file) is on again, and the
-- costume that used to be its "Classic" look becomes the Cat's Rebel Cloak (drops from Rebellion quests, like the Highland
-- Cow's). Safe to run whether or not the earlier version of 0081 was run, and safe to run twice.
-- =================================================================
update public.pet_species set is_active = true where id = 'kat';
insert into public.pet_outfits (id, species_id, family, name, rarity, unlock_kind, sources, pity_after, hint, sort_order) values
  ('kat-rebellion', 'kat', 'rebellion', 'Rebel Cloak', 'epic', 'random_drop',
   '[{"def":"rb_seeds","chance":0.35},{"def":"rb_pamphlet","chance":0.35},{"def":"rb_storm","chance":0.35}]'::jsonb, 8, 'Drops from Rebellion quests.', 169)
on conflict (id) do update set species_id = excluded.species_id, family = excluded.family, name = excluded.name, rarity = excluded.rarity,
  unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, hint = excluded.hint, sort_order = excluded.sort_order, is_active = true;

-- =========== 0082_nickname_frames.sql ===========
-- =================================================================
-- OFFICE LORE / TRIPEL TALES — NICKNAME FRAMES (earned, never bought)
-- =================================================================
-- Seven frames for a nickname card: flame, ice, gold throne, hearts, beer foam, confetti, lightning (the artwork is CSS/SVG in the app).
-- You earn a frame by claiming the matching quests (a chance per claim + a pity counter, like the outfits and pet looks) or from a
-- Mystery Reward. Once you own a frame you can put it on nicknames YOU created: a frame can be used on at most 2 of your nicknames.
-- Everybody sees the frame on the nickname. Granted inside the idempotent claim / box opening, so a refresh or a second click never
-- rolls twice. The assignment lives in its own table (nickname_frame_assignments), so nicknames and their triggers stay untouched.
-- Additive + idempotent. Run after 0081.
-- =================================================================
create table if not exists public.nickname_frames (
  id text primary key,
  name text not null,
  tag text not null,
  rarity text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  sources jsonb not null default '[]',        -- [{"def": "pw_battle_hardened", "chance": 0.1}]
  pity_after int,
  hint text not null,
  sort_order int not null default 0,
  is_active boolean not null default true
);
create table if not exists public.user_nickname_frames (
  user_id uuid not null references public.profiles(id),
  frame_id text not null references public.nickname_frames(id),
  source text,
  granted_at timestamptz not null default now(),
  primary key (user_id, frame_id)
);
create table if not exists public.nickname_frame_pity (
  user_id uuid not null references public.profiles(id),
  frame_id text not null references public.nickname_frames(id),
  misses int not null default 0,
  primary key (user_id, frame_id)
);
create table if not exists public.nickname_frame_assignments (
  nickname_id uuid primary key references public.nicknames(id) on delete cascade,
  frame_id text not null references public.nickname_frames(id),
  user_id uuid not null references public.profiles(id),
  assigned_at timestamptz not null default now()
);
create index if not exists nickname_frame_assignments_user_idx on public.nickname_frame_assignments (user_id, frame_id);
alter table public.nickname_frames enable row level security;
alter table public.user_nickname_frames enable row level security;
alter table public.nickname_frame_pity enable row level security;             -- no policy: private
alter table public.nickname_frame_assignments enable row level security;
drop policy if exists "Nickname frames: read" on public.nickname_frames;
create policy "Nickname frames: read" on public.nickname_frames for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "My nickname frames: read own" on public.user_nickname_frames;
create policy "My nickname frames: read own" on public.user_nickname_frames for select to authenticated using (user_id = auth.uid());
drop policy if exists "Frame assignments: read" on public.nickname_frame_assignments;
create policy "Frame assignments: read" on public.nickname_frame_assignments for select to authenticated using (public.is_app_member('officelore'));
-- no client write policy anywhere: everything goes through the functions below

do $$ begin
  alter publication supabase_realtime add table public.nickname_frame_assignments;
exception when duplicate_object then null; when others then null; end $$;

insert into public.nickname_frames (id, name, tag, rarity, sources, pity_after, hint, sort_order) values
  ('flame', 'Vlammen', '🔥 Inferno', 'epic', '[{"def": "pw_battle_hardened", "chance": 0.1}, {"def": "rb_storm", "chance": 0.08}, {"def": "rb_seeds", "chance": 0.04}, {"def": "pd_pick_a_side", "chance": 0.03}]'::jsonb, 30, 'Drops from Battle and Rebellion quests.', 10),
  ('ice', 'IJs', '❄️ Rijp', 'rare', '[{"def": "gw_council", "chance": 0.12}, {"def": "pw_keeper_knowledge", "chance": 0.1}, {"def": "pd_perfect_score", "chance": 0.05}, {"def": "gd_lore_quiz", "chance": 0.04}, {"def": "pd_lore_master", "chance": 0.03}, {"def": "pd_know_thy_friends", "chance": 0.03}]'::jsonb, 25, 'Drops from quiz quests.', 20),
  ('gold', 'Gouden troon', '👑 Majesteit', 'epic', '[{"def": "pw_completionist", "chance": 0.1}, {"def": "pw_adventurer", "chance": 0.08}, {"def": "pw_social_creature", "chance": 0.05}]'::jsonb, 30, 'Drops from The Completionist, The Adventurer and Social Creature.', 30),
  ('heart', 'Hartjes en bloemen', '💖 Lief', 'rare', '[{"def": "pw_poet_laureate", "chance": 0.1}, {"def": "gw_poets", "chance": 0.08}, {"def": "rb_pamphlet", "chance": 0.06}, {"def": "gd_poetry_showdown", "chance": 0.04}, {"def": "pd_poet_for_a_day", "chance": 0.04}, {"def": "pd_poetry_critic", "chance": 0.03}]'::jsonb, 25, 'Drops from poetry quests.', 40),
  ('beer', 'Bierschuim', '🍺 Schuimkraag', 'rare', '[{"def": "pw_beer_explorer", "chance": 0.1}, {"def": "gw_gathering", "chance": 0.08}, {"def": "pd_beer_scholar", "chance": 0.03}, {"def": "pd_new_brew", "chance": 0.03}, {"def": "pd_one_for_the_books", "chance": 0.03}]'::jsonb, 25, 'Drops from beer discovery quests.', 50),
  ('conf', 'Confetti', '🎉 Feest', 'common', '[{"def": "gd_daily_chaos", "chance": 0.06}, {"def": "gd_emoji_showdown", "chance": 0.06}, {"def": "gd_nickname_of_the_day", "chance": 0.06}, {"def": "gd_poetry_showdown", "chance": 0.06}, {"def": "gd_lore_quiz", "chance": 0.06}, {"def": "gw_fellowship", "chance": 0.12}, {"def": "gw_gathering", "chance": 0.1}, {"def": "gw_poets", "chance": 0.1}, {"def": "gw_nickname_factory", "chance": 0.1}, {"def": "gw_council", "chance": 0.1}]'::jsonb, 10, 'Drops from Group Daily and Group Quests.', 60),
  ('bolt', 'Bliksem', '⚡ Chaos', 'rare', '[{"def": "pw_agent_of_chaos", "chance": 0.1}, {"def": "gd_daily_chaos", "chance": 0.04}, {"def": "pd_royal_decree", "chance": 0.04}, {"def": "pd_draw_this", "chance": 0.04}, {"def": "pd_office_safari", "chance": 0.04}, {"def": "pd_the_impostor", "chance": 0.04}, {"def": "pd_emoji_lore", "chance": 0.04}, {"def": "pd_five_seconds", "chance": 0.04}, {"def": "pd_the_photographer", "chance": 0.04}, {"def": "pd_tiny_quest", "chance": 0.03}]'::jsonb, 25, 'Drops from Chaos quests.', 70)
on conflict (id) do update set name = excluded.name, tag = excluded.tag, rarity = excluded.rarity, sources = excluded.sources,
  pity_after = excluded.pity_after, hint = excluded.hint, sort_order = excluded.sort_order;

-- Mystery boxes may contain a frame
update public.challenge_config set value = jsonb_set(value, '{pools,default,outcomes,frame}', '10'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'default' and not (value->'pools'->'default'->'outcomes' ? 'frame');
update public.challenge_config set value = jsonb_set(value, '{pools,sweep,outcomes,frame}', '10'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'sweep' and not (value->'pools'->'sweep'->'outcomes' ? 'frame');

-- the hook: called once per successful claim (never from a client)
create or replace function public._frame_hook(p_user uuid, p_def text)
returns jsonb as $$
declare
  f public.nickname_frames; src jsonb; v_miss int; v_hit boolean;
  v_out jsonb := '[]'::jsonb;
begin
  if p_def is null then return v_out; end if;
  for f in select * from public.nickname_frames where is_active order by sort_order loop
    select e into src from jsonb_array_elements(f.sources) e where e->>'def' = p_def limit 1;
    continue when src is null;
    continue when exists (select 1 from public.user_nickname_frames u where u.user_id = p_user and u.frame_id = f.id);
    insert into public.nickname_frame_pity (user_id, frame_id) values (p_user, f.id) on conflict do nothing;
    select misses into v_miss from public.nickname_frame_pity where user_id = p_user and frame_id = f.id for update;
    v_hit := random() < coalesce((src->>'chance')::numeric, 0) or (f.pity_after is not null and v_miss + 1 >= f.pity_after);
    update public.nickname_frame_pity set misses = case when v_hit then 0 else v_miss + 1 end where user_id = p_user and frame_id = f.id;
    if v_hit then
      insert into public.user_nickname_frames (user_id, frame_id, source) values (p_user, f.id, p_def) on conflict do nothing;
      if found then v_out := v_out || jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag, 'rarity', f.rarity); end if;
    end if;
  end loop;
  return v_out;
end;
$$ language plpgsql security definer set search_path = public;

-- putting a frame on one of YOUR nicknames (null = take it off). A frame can be on at most 2 of your nicknames.
create or replace function public.set_nickname_frame(p_nickname_id uuid, p_frame_id text)
returns jsonb as $$
declare
  n public.nicknames;
  v_used int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into n from public.nicknames where id = p_nickname_id;
  if n.id is null then raise exception 'Unknown nickname'; end if;
  if n.created_by_user_id is distinct from auth.uid() then raise exception 'You can only give a frame to a nickname you created'; end if;
  perform pg_advisory_xact_lock(hashtext('frame_assign:' || auth.uid()::text));
  if p_frame_id is null then
    delete from public.nickname_frame_assignments where nickname_id = p_nickname_id;
    return jsonb_build_object('nickname_id', p_nickname_id, 'frame_id', null);
  end if;
  if not exists (select 1 from public.nickname_frames f where f.id = p_frame_id and f.is_active) then raise exception 'Unknown frame'; end if;
  if not exists (select 1 from public.user_nickname_frames u where u.user_id = auth.uid() and u.frame_id = p_frame_id) then raise exception 'You have not earned this frame yet'; end if;
  select count(*) into v_used from public.nickname_frame_assignments a where a.user_id = auth.uid() and a.frame_id = p_frame_id and a.nickname_id <> p_nickname_id;
  if v_used >= 2 then raise exception 'This frame is already on 2 of your nicknames'; end if;
  insert into public.nickname_frame_assignments (nickname_id, frame_id, user_id) values (p_nickname_id, p_frame_id, auth.uid())
    on conflict (nickname_id) do update set frame_id = excluded.frame_id, assigned_at = now();
  return jsonb_build_object('nickname_id', p_nickname_id, 'frame_id', p_frame_id);
end;
$$ language plpgsql security definer set search_path = public;

-- claiming and opening a box now also report the frames they earn (otherwise unchanged from 0078)
create or replace function public.claim_challenge(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_line jsonb;
  v_no int := 0;
  v_results jsonb := '[]'::jsonb;
  v_min numeric;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if a.user_id is not null and a.user_id <> auth.uid() then raise exception 'This is not your challenge'; end if;
  -- a Rebellion is for those who do not hold the throne
  if a.type = 'rebellion' and auth.uid() is not distinct from public._current_abt_lord() then raise exception 'The Abt Lord cannot claim a Rebellion reward'; end if;

  if a.status not in ('completed', 'claimed') then
    -- an unfinished Weekly offers a small consolation once the week is over, and only above the threshold
    v_min := coalesce((a.payload->>'consolation_min_pct')::numeric, 0.5);
    if a.type = 'personal_weekly' and (a.status = 'expired' or a.expires_at <= now()) and a.target > 0
       and a.progress::numeric / a.target > v_min and jsonb_array_length(coalesce(a.payload->'consolation', '[]'::jsonb)) > 0 then
      insert into public.challenge_claims (assignment_id, user_id) values (a.id, auth.uid()) on conflict do nothing;
      if not found then return jsonb_build_object('status', 'already_claimed'); end if;
      for v_line in select * from jsonb_array_elements(a.payload->'consolation') loop
        v_no := v_no + 1;
        -- consolation lines are plain Player XP: never a Fragment, never a chance roll
        if v_line->>'kind' = 'player_xp' then
          v_results := v_results || public._grant_challenge_reward2(auth.uid(), a.id, null, v_line, 200 + v_no);
        end if;
      end loop;
      return jsonb_build_object('status', 'consolation', 'results', v_results);
    end if;
    raise exception 'This challenge is not complete yet';
  end if;

  if a.user_id is null and not (
       case when a.group_rule is not null
            then exists (select 1 from public.challenge_member_progress mp where mp.assignment_id = a.id and mp.user_id = auth.uid())
            else exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id and c.user_id = auth.uid() and c.amount > 0) end) then
    raise exception 'Only members who took part in this quest can claim its reward';
  end if;

  insert into public.challenge_claims (assignment_id, user_id) values (a.id, auth.uid()) on conflict do nothing;
  if not found then
    return jsonb_build_object('status', 'already_claimed');
  end if;

  for v_line in select * from jsonb_array_elements(coalesce(a.reward->'lines', '[]'::jsonb)) loop
    v_no := v_no + 1;
    v_results := v_results || public._grant_challenge_reward2(auth.uid(), a.id, null, v_line, v_no);
  end loop;

  if a.user_id is not null then
    update public.challenge_assignments set status = 'claimed', claimed_at = now() where id = a.id;
  end if;
  -- special Personal Character outfits that this very claim earns (once: the claim row above is unique)
  return jsonb_build_object('status', 'claimed', 'results', v_results, 'outfits', public._character_outfit_hook(auth.uid(), a.definition_id),
    'titles', public._grant_titles(auth.uid(), 'claims', a.definition_id),
    'pet', public._pet_hook(auth.uid(), a.definition_id, a.type),
    'frames', public._frame_hook(auth.uid(), a.definition_id));
end;
$$ language plpgsql security definer set search_path = public;

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
  tt public.character_titles; v_titles jsonb;
  pc record;
  fr public.nickname_frames;
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
  -- cosmetics are Abt Lord gear: for everybody else a box pays XP (or a fragment), nothing is attached to a normal player's character
  if b.user_id is distinct from public._current_abt_lord() then v_outcomes := v_outcomes - 'cosmetic'; end if;
  select count(*) into v_frags_week from public.mystery_boxes x
    where x.user_id = b.user_id and x.status = 'opened' and x.prize->>'type' = 'fragment' and x.opened_at >= v_week_start;
  if v_rar_i < 1 or v_frags_week >= v_cap then v_outcomes := v_outcomes - 'fragment'; end if;
  v_outcome := coalesce(public._weighted_pick(v_outcomes), 'xp');

  if v_outcome = 'cosmetic' then
    -- an unowned item: the rolled rarity first, then the others from the floor upwards (lower ones first)
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select i.* into it from public.abt_cosmetic_items i
        where i.is_active and i.mystery_eligible
          and (not i.lord_only_drop or b.user_id is not distinct from public._current_abt_lord())      -- Abt Lord gear drops for the Abt Lord only
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

  if v_outcome = 'title' then
    -- an owned-nothing-yet title of the rolled rarity, then the other tiers from the floor upwards (lower first); nothing left = an XP bonus
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select t.* into tt from public.character_titles t
        where t.is_active and t.unlock_kind = 'drop'
          and t.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.user_character_titles u where u.user_id = b.user_id and u.title_id = t.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = t.rarity) >= v_floor_i
        order by random() limit 1;
      exit when tt.id is not null;
    end loop;
    if tt.id is null then
      v_outcome := 'xp'; v_dup := true;
    else
      insert into public.user_character_titles (user_id, title_id, source) values (b.user_id, tt.id, 'box') on conflict do nothing;
      v_prize := jsonb_build_object('type', 'title', 'rarity', tt.rarity, 'title_id', tt.id, 'text', tt.text);
    end if;
  end if;

  if v_outcome = 'pet' then
    -- a pet you do not own yet, or clothes for a pet you DO own (never clothes you cannot wear); the rolled rarity first, then the other tiers from the floor upwards
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select * into pc from (
        select 'species'::text as kind, s.id, s.name, s.id as species_id, s.name as species_name, 'common'::text as rarity
          from public.pet_species s
          where s.is_active and not exists (select 1 from public.user_pets u where u.user_id = b.user_id and u.species_id = s.id)
        union all
        select 'outfit', o.id, o.name, o.species_id, s.name, o.rarity
          from public.pet_outfits o join public.pet_species s on s.id = o.species_id
          where o.is_active and s.is_active and o.unlock_kind = 'random_drop'
            and exists (select 1 from public.user_pets u where u.user_id = b.user_id and u.species_id = o.species_id)
            and not exists (select 1 from public.user_pet_outfits u where u.user_id = b.user_id and u.outfit_id = o.id)
      ) cand
      where cand.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                           where ord - 1 = case when v_try = 0 then v_rar_i
                                                else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
        and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = cand.rarity) >= v_floor_i
      order by random() limit 1;
      exit when pc.id is not null;
    end loop;
    if pc.id is null then
      v_outcome := 'xp'; v_dup := true;
    else
      if pc.kind = 'species' then
        insert into public.user_pets (user_id, species_id, source) values (b.user_id, pc.id, 'box') on conflict do nothing;
      else
        insert into public.user_pet_outfits (user_id, outfit_id, source) values (b.user_id, pc.id, 'box') on conflict do nothing;
      end if;
      v_prize := jsonb_build_object('type', 'pet', 'rarity', pc.rarity, 'kind', pc.kind, 'pet_id', pc.id, 'name', pc.name, 'species_id', pc.species_id, 'species_name', pc.species_name);
    end if;
  end if;

  if v_outcome = 'frame' then
    -- a nickname frame you do not own yet: the rolled rarity first, then the other tiers from the floor upwards; nothing left = an XP bonus
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select f.* into fr from public.nickname_frames f
        where f.is_active
          and f.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.user_nickname_frames u where u.user_id = b.user_id and u.frame_id = f.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = f.rarity) >= v_floor_i
        order by random() limit 1;
      exit when fr.id is not null;
    end loop;
    if fr.id is null then
      v_outcome := 'xp'; v_dup := true;
    else
      insert into public.user_nickname_frames (user_id, frame_id, source) values (b.user_id, fr.id, 'box') on conflict do nothing;
      v_prize := jsonb_build_object('type', 'frame', 'rarity', fr.rarity, 'frame_id', fr.id, 'name', fr.name);
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
  v_titles := public._grant_titles(b.user_id, 'boxes', null);
  return jsonb_build_object('status', 'opened', 'prize', v_prize, 'titles', v_titles);
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public._frame_hook(uuid, text) from public, anon, authenticated;
revoke all on function public.set_nickname_frame(uuid, text) from public, anon;
grant execute on function public.set_nickname_frame(uuid, text) to authenticated;
revoke all on function public.claim_challenge(uuid) from public, anon;
grant execute on function public.claim_challenge(uuid) to authenticated;
revoke all on function public.open_mystery_box(uuid) from public, anon;
grant execute on function public.open_mystery_box(uuid) to authenticated;
