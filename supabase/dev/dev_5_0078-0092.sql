-- DEV bundle part 5/5: migrations 0078 to 0092. Run the parts in order, each once, in a NEW empty Supabase project (never in production).

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

-- =========== 0083_seasonal_outfits.sql ===========
-- =================================================================
-- OFFICE LORE / TRIPEL TALES — SEASONAL OUTFITS (Halloween first)
-- =================================================================
-- A seasonal outfit can be worn by EVERYBODY while its season lasts, no quest needed. Each has a window (starts_on .. ends_on, Brussels
-- date). After the window nobody can newly choose it; whoever is wearing it keeps it until they change. The pictures are in the app
-- (supabase/tools/build_seasonal_images.py); this table says which codes exist, for which body, and when.
--   hw1  Pirate   (female + male)      hw2  Vampire (female)      hw3  Zombie (male)
-- Halloween runs until the 15th of November 2026. A next season = new rows (and pictures), no code change.
-- Additive + idempotent. Run after 0082.
-- =================================================================
create table if not exists public.character_seasonal_outfits (
  id text primary key check (id ~ '^[a-z]{2}[0-9]{1,2}$'),
  name text not null,
  season text not null,
  genders text[] not null default '{f,m}',
  starts_on date not null,
  ends_on date not null,
  sort_order int not null default 0,
  is_active boolean not null default true
);
alter table public.character_seasonal_outfits enable row level security;
drop policy if exists "Seasonal outfits: read" on public.character_seasonal_outfits;
create policy "Seasonal outfits: read" on public.character_seasonal_outfits for select to authenticated using (public.is_app_member('officelore'));
insert into public.character_seasonal_outfits (id, name, season, genders, starts_on, ends_on, sort_order) values
  ('hw1', 'Pirate',  'halloween', '{f,m}', date '2026-10-01', date '2026-11-15', 10),
  ('hw2', 'Vampire', 'halloween', '{f}',   date '2026-10-01', date '2026-11-15', 20),
  ('hw3', 'Zombie',  'halloween', '{m}',   date '2026-10-01', date '2026-11-15', 30)
on conflict (id) do update set name = excluded.name, season = excluded.season, genders = excluded.genders, starts_on = excluded.starts_on,
  ends_on = excluded.ends_on, sort_order = excluded.sort_order;

-- wearing: seasonal outfits are allowed inside their window (otherwise unchanged from 0066)
create or replace function public.set_room_character(p_base text, p_outfit text default null)
returns jsonb as $$
declare
  v_loadout jsonb;
  v_set text;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_base not in ('female', 'male') then raise exception 'Choose a female or male base'; end if;
  if p_outfit is not null then
    if p_outfit !~ '^[fm]([0-9]{1,2}|[a-z]{2}[0-9]{1,2})$' then raise exception 'Unknown outfit'; end if;
    if left(p_outfit, 1) <> left(p_base, 1) then raise exception 'That outfit does not belong to this base'; end if;
    v_set := substr(p_outfit, 2);
    if v_set !~ '^[0-9]+$' then                                   -- a special set or a seasonal outfit
      if exists (select 1 from public.character_seasonal_outfits s where s.id = v_set and s.is_active) then
        -- seasonal: everybody may pick it while its season lasts (Brussels date); whoever already wears it may keep it afterwards
        if not exists (select 1 from public.character_seasonal_outfits s
                       where s.id = v_set and s.is_active and left(p_outfit, 1) = any (s.genders)
                         and (now() at time zone 'Europe/Brussels')::date between s.starts_on and s.ends_on)
           and (select loadout->>'outfit' from public.room_profiles where user_id = auth.uid()) is distinct from p_outfit then
          raise exception 'This seasonal outfit is not available right now';
        end if;
      else
        if not exists (select 1 from public.character_outfit_sets where id = v_set and is_active) then raise exception 'Unknown outfit'; end if;
        if not exists (select 1 from public.user_character_outfits u where u.user_id = auth.uid() and u.set_id = v_set) then
          raise exception 'You have not unlocked this outfit yet';
        end if;
      end if;
    end if;
  end if;
  insert into public.room_profiles (user_id, body_type) values (auth.uid(), p_base) on conflict (user_id) do nothing;
  select loadout into v_loadout from public.room_profiles where user_id = auth.uid() for update;
  v_loadout := coalesce(v_loadout, '{}'::jsonb) - 'outfit';
  if p_outfit is not null then v_loadout := v_loadout || jsonb_build_object('outfit', p_outfit); end if;
  update public.room_profiles set body_type = p_base, loadout = v_loadout where user_id = auth.uid();
  return jsonb_build_object('body_type', p_base, 'loadout', v_loadout);
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.set_room_character(text, text) from public, anon;
grant execute on function public.set_room_character(text, text) to authenticated;

-- =========== 0084_taproom_wall.sql ===========
-- =================================================================
-- TRIPEL TALES — THE TAPROOM WALL (shared by the whole group)
-- =================================================================
--   * NEON SIGNS: seven signs that drop from quests / Mystery Rewards. A sign is found ONCE for the whole group (wall_found_neons, with who
--     found it); the group hangs two of the found signs (wall_settings 'hung_neons', set_wall_neons).
--   * TAP HANDLES: eight different handles; every completed 'The Gathering' (any week) unlocks the next one (wall_progress 'gatherings').
--   * PENNANT FLAG: hangs after the first completed 'Nickname Factory' (wall_progress 'factory').
--   * STARTER PACK (once): PROOST! and OPEN hang on the wall, plus the two best-rated beers as coasters, so day one is not bare.
--   * BIERVILTJES (coasters): one per beer in the Beer Fridge (wall_coasters, with who found it). They drop from beer quests and boxes;
--     a drop is a random beer that does not hang yet. A new beer in the app = a new coaster to find.
-- Everything is granted inside the idempotent claim / box opening, clients can only call set_wall_neons. Additive + idempotent. Run after 0083.
-- =================================================================
create table if not exists public.wall_neon_signs (
  id text primary key,
  name text not null,
  rarity text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  sources jsonb not null default '[]',
  pity_after int,
  hint text not null,
  sort_order int not null default 0,
  is_active boolean not null default true
);
create table if not exists public.wall_found_neons (
  neon_id text primary key references public.wall_neon_signs(id),
  found_by uuid references public.profiles(id),
  found_at timestamptz not null default now()
);
create table if not exists public.wall_coasters (
  beer_id uuid primary key references public.beers(id) on delete cascade,
  found_by uuid references public.profiles(id),
  found_at timestamptz not null default now()
);
create table if not exists public.wall_progress (
  key text primary key,
  value int not null default 0
);
create table if not exists public.wall_events (
  assignment_id uuid primary key,
  kind text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.wall_settings (
  key text primary key,
  value jsonb not null default '[]'
);
create table if not exists public.wall_pity (
  user_id uuid not null references public.profiles(id),
  key text not null,
  misses int not null default 0,
  primary key (user_id, key)
);
alter table public.wall_neon_signs enable row level security;
alter table public.wall_found_neons enable row level security;
alter table public.wall_coasters enable row level security;
alter table public.wall_progress enable row level security;
alter table public.wall_events enable row level security;          -- no policy: private bookkeeping
alter table public.wall_settings enable row level security;
alter table public.wall_pity enable row level security;            -- no policy: private
do $$
declare t text;
begin
  foreach t in array array['wall_neon_signs', 'wall_found_neons', 'wall_coasters', 'wall_progress', 'wall_settings'] loop
    execute format('drop policy if exists "Wall: read" on public.%I', t);
    execute format('create policy "Wall: read" on public.%I for select to authenticated using (public.is_app_member(%L))', t, 'officelore');
  end loop;
  foreach t in array array['wall_found_neons', 'wall_coasters', 'wall_progress', 'wall_settings'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then null; end;
  end loop;
end $$;

insert into public.wall_neon_signs (id, name, rarity, sources, pity_after, hint, sort_order) values
  ('prost', 'PROOST!', 'common', '[{"def": "gd_daily_chaos", "chance": 0.08}, {"def": "gd_emoji_showdown", "chance": 0.08}, {"def": "gd_nickname_of_the_day", "chance": 0.08}, {"def": "gd_poetry_showdown", "chance": 0.08}, {"def": "gd_lore_quiz", "chance": 0.08}, {"def": "gw_fellowship", "chance": 0.15}]'::jsonb, 10, 'Drops from Group Daily quests and The Fellowship.', 10),
  ('open', 'OPEN', 'common', '[{"def": "pd_the_critic", "chance": 0.04}, {"def": "pd_name_thy_victim", "chance": 0.04}, {"def": "pd_pick_a_side", "chance": 0.04}, {"def": "pd_lore_master", "chance": 0.04}, {"def": "pd_office_oracle", "chance": 0.04}, {"def": "pd_poetry_critic", "chance": 0.04}]'::jsonb, 20, 'Drops from daily quests.', 20),
  ('abt12', 'ABT 12 TIME', 'common', '[{"def": "pw_beer_explorer", "chance": 0.12}, {"def": "gw_gathering", "chance": 0.15}, {"def": "pd_beer_scholar", "chance": 0.04}, {"def": "pd_new_brew", "chance": 0.04}, {"def": "pd_one_for_the_books", "chance": 0.04}]'::jsonb, 15, 'Drops from beer discovery quests.', 30),
  ('tournee', 'TOURNEE GENERAL', 'rare', '[{"def": "gw_gathering", "chance": 0.12}, {"def": "gw_fellowship", "chance": 0.12}, {"def": "gw_nickname_factory", "chance": 0.1}, {"def": "gw_poets", "chance": 0.1}, {"def": "gw_council", "chance": 0.1}]'::jsonb, 12, 'Drops from Group Quests.', 40),
  ('terras', 'TERRASJE?', 'rare', '[{"def": "gw_gathering", "chance": 0.1}, {"def": "pw_beer_explorer", "chance": 0.08}, {"def": "pw_social_creature", "chance": 0.08}]'::jsonb, 20, 'Drops from The Gathering, Beer Explorer and Social Creature.', 50),
  ('pul', 'DE PUL', 'epic', '[{"def": "pw_completionist", "chance": 0.1}, {"def": "gw_council", "chance": 0.1}, {"def": "pw_adventurer", "chance": 0.06}]'::jsonb, 30, 'A rare drop from the big weekly and Group Quests.', 60),
  ('tripel', 'TRIPEL TALES', 'epic', '[{"def": "pw_completionist", "chance": 0.06}, {"def": "gw_council", "chance": 0.08}, {"def": "pw_poet_laureate", "chance": 0.05}, {"def": "pw_keeper_knowledge", "chance": 0.05}, {"def": "rb_pamphlet", "chance": 0.04}]'::jsonb, 40, 'A rare drop from the hardest quests.', 70)
on conflict (id) do update set name = excluded.name, rarity = excluded.rarity, sources = excluded.sources, pity_after = excluded.pity_after, hint = excluded.hint, sort_order = excluded.sort_order;
insert into public.wall_progress (key, value) values ('gatherings', 0), ('factory', 0) on conflict do nothing;
insert into public.wall_settings (key, value) values ('hung_neons', '[]') on conflict do nothing;
insert into public.challenge_config (key, value) values ('wall_coasters', '{"sources": {"pw_beer_explorer": 0.3, "gw_gathering": 0.35, "pd_beer_scholar": 0.1, "pd_new_brew": 0.1, "pd_one_for_the_books": 0.1}, "pity_after": 8}') on conflict (key) do nothing;
-- boxes may contain something for the wall
update public.challenge_config set value = jsonb_set(value, '{pools,default,outcomes,wall}', '12'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'default' and not (value->'pools'->'default'->'outcomes' ? 'wall');
update public.challenge_config set value = jsonb_set(value, '{pools,sweep,outcomes,wall}', '12'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'sweep' and not (value->'pools'->'sweep'->'outcomes' ? 'wall');

-- group progress: a completed Group Quest counts once (tap handles / flag), also for the past
create or replace function public._wall_count(p_assignment uuid, p_def text)
returns void as $$
declare v_kind text := case p_def when 'gw_gathering' then 'gatherings' when 'gw_nickname_factory' then 'factory' else null end;
begin
  if v_kind is null then return; end if;
  insert into public.wall_events (assignment_id, kind) values (p_assignment, v_kind) on conflict do nothing;
  if found then
    insert into public.wall_progress (key, value) values (v_kind, 1) on conflict (key) do update set value = public.wall_progress.value + 1;
  end if;
end;
$$ language plpgsql security definer set search_path = public;
create or replace function public._wall_on_group_completed()
returns trigger as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' and new.definition_id in ('gw_gathering', 'gw_nickname_factory') then
    begin perform public._wall_count(new.id, new.definition_id);
    exception when others then raise warning 'wall count failed: %', sqlerrm; end;
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
drop trigger if exists trg_wall_group_completed on public.challenge_assignments;
create trigger trg_wall_group_completed after update of status on public.challenge_assignments
  for each row execute function public._wall_on_group_completed();
-- the past: Gatherings and Nickname Factories that were already completed
insert into public.wall_events (assignment_id, kind)
  select a.id, case a.definition_id when 'gw_gathering' then 'gatherings' else 'factory' end
  from public.challenge_assignments a
  where a.definition_id in ('gw_gathering', 'gw_nickname_factory') and a.status in ('completed', 'claimed')
on conflict do nothing;
update public.wall_progress p set value = (select count(*) from public.wall_events e where e.kind = p.key) where p.key in ('gatherings', 'factory');

-- the starter pack, once: PROOST! and OPEN hang on the wall, plus the two best-rated beers as coasters (so the wall is not bare on day one)
create or replace function public._wall_starter_pack()
returns void as $$
begin
  if exists (select 1 from public.wall_settings where key = 'starter_given') then return; end if;
  insert into public.wall_found_neons (neon_id, found_by) values ('prost', null), ('open', null) on conflict do nothing;
  update public.wall_settings set value = '["prost","open"]'::jsonb where key = 'hung_neons';
  insert into public.wall_coasters (beer_id, found_by)
    select b.id, null
    from public.beers b
    left join (select beer_id, avg(rating) as a, count(rating) as c from public.beer_ratings where rating is not null group by beer_id) r on r.beer_id = b.id
    order by r.a desc nulls last, r.c desc nulls last, b.created_at asc, b.name asc
    limit 2
  on conflict do nothing;
  insert into public.wall_settings (key, value) values ('starter_given', 'true'::jsonb) on conflict do nothing;
end;
$$ language plpgsql security definer set search_path = public;
select public._wall_starter_pack();

-- the drop hook, called once per successful claim (never from a client)
create or replace function public._wall_hook(p_user uuid, p_def text)
returns jsonb as $$
declare
  n public.wall_neon_signs; src jsonb; v_miss int; v_hit boolean; v_out jsonb := '[]'::jsonb;
  v_cfg jsonb := public._challenge_config('wall_coasters', '{"sources": {}, "pity_after": 8}'::jsonb);
  v_chance numeric; v_pity int; b public.beers;
begin
  if p_def is null then return v_out; end if;
  perform pg_advisory_xact_lock(hashtext('wall_found'));
  -- neon signs the group does not have yet
  for n in select * from public.wall_neon_signs s where s.is_active and not exists (select 1 from public.wall_found_neons f where f.neon_id = s.id) order by s.sort_order loop
    select e into src from jsonb_array_elements(n.sources) e where e->>'def' = p_def limit 1;
    continue when src is null;
    insert into public.wall_pity (user_id, key) values (p_user, 'n:' || n.id) on conflict do nothing;
    select misses into v_miss from public.wall_pity where user_id = p_user and key = 'n:' || n.id for update;
    v_hit := random() < coalesce((src->>'chance')::numeric, 0) or (n.pity_after is not null and v_miss + 1 >= n.pity_after);
    update public.wall_pity set misses = case when v_hit then 0 else v_miss + 1 end where user_id = p_user and key = 'n:' || n.id;
    if v_hit then
      insert into public.wall_found_neons (neon_id, found_by) values (n.id, p_user) on conflict do nothing;
      if found then v_out := v_out || jsonb_build_object('kind', 'neon', 'id', n.id, 'name', n.name, 'rarity', n.rarity); end if;
    end if;
  end loop;
  -- a bierviltje of a beer that does not hang yet
  v_chance := (v_cfg->'sources'->>p_def)::numeric;
  if v_chance is not null and exists (select 1 from public.beers x where not exists (select 1 from public.wall_coasters c where c.beer_id = x.id)) then
    v_pity := nullif(v_cfg->>'pity_after', '')::int;
    insert into public.wall_pity (user_id, key) values (p_user, 'coaster') on conflict do nothing;
    select misses into v_miss from public.wall_pity where user_id = p_user and key = 'coaster' for update;
    v_hit := random() < v_chance or (v_pity is not null and v_miss + 1 >= v_pity);
    update public.wall_pity set misses = case when v_hit then 0 else v_miss + 1 end where user_id = p_user and key = 'coaster';
    if v_hit then
      select * into b from public.beers x where not exists (select 1 from public.wall_coasters c where c.beer_id = x.id) order by random() limit 1;
      insert into public.wall_coasters (beer_id, found_by) values (b.id, p_user) on conflict do nothing;
      if found then v_out := v_out || jsonb_build_object('kind', 'coaster', 'id', b.id, 'name', b.name, 'rarity', 'common'); end if;
    end if;
  end if;
  return v_out;
end;
$$ language plpgsql security definer set search_path = public;

-- the group chooses which found neon signs hang on the wall (at most 2)
create or replace function public.set_wall_neons(p_ids text[])
returns jsonb as $$
declare v_ids text[] := coalesce(p_ids, '{}');
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if cardinality(v_ids) > 2 then raise exception 'At most 2 neon signs fit on the wall'; end if;
  if (select count(distinct x) from unnest(v_ids) x) <> cardinality(v_ids) then raise exception 'Pick every sign only once'; end if;
  if exists (select 1 from unnest(v_ids) x where not exists (select 1 from public.wall_found_neons f where f.neon_id = x)) then raise exception 'That sign has not been found yet'; end if;
  insert into public.wall_settings (key, value) values ('hung_neons', to_jsonb(v_ids)) on conflict (key) do update set value = excluded.value;
  return to_jsonb(v_ids);
end;
$$ language plpgsql security definer set search_path = public;

-- claiming and opening a box now also report what they put on the wall (otherwise unchanged from 0082)
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
    'frames', public._frame_hook(auth.uid(), a.definition_id),
    'wall', public._wall_hook(auth.uid(), a.definition_id));
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
  wn public.wall_neon_signs; wb public.beers;
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

  if v_outcome = 'wall' then
    -- something for the Taproom wall that the group does not have yet: a neon sign of the rolled rarity (the other tiers from the floor upwards), else a bierviltje
    perform pg_advisory_xact_lock(hashtext('wall_found'));
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select n.* into wn from public.wall_neon_signs n
        where n.is_active
          and n.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.wall_found_neons f where f.neon_id = n.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = n.rarity) >= v_floor_i
        order by random() limit 1;
      exit when wn.id is not null;
    end loop;
    if wn.id is not null then
      insert into public.wall_found_neons (neon_id, found_by) values (wn.id, b.user_id) on conflict do nothing;
      v_prize := jsonb_build_object('type', 'wall', 'kind', 'neon', 'rarity', wn.rarity, 'id', wn.id, 'name', wn.name);
    elsif v_floor_i = 0 then
      select * into wb from public.beers x where not exists (select 1 from public.wall_coasters c where c.beer_id = x.id) order by random() limit 1;
      if wb.id is not null then
        insert into public.wall_coasters (beer_id, found_by) values (wb.id, b.user_id) on conflict do nothing;
        v_prize := jsonb_build_object('type', 'wall', 'kind', 'coaster', 'rarity', 'common', 'id', wb.id, 'name', wb.name);
      end if;
    end if;
    if v_prize is null or v_prize->>'type' is distinct from 'wall' then v_outcome := 'xp'; v_dup := true; end if;
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

revoke all on function public._wall_starter_pack() from public, anon, authenticated;
revoke all on function public._wall_count(uuid, text) from public, anon, authenticated;
revoke all on function public._wall_on_group_completed() from public, anon, authenticated;
revoke all on function public._wall_hook(uuid, text) from public, anon, authenticated;
revoke all on function public.set_wall_neons(text[]) from public, anon;
grant execute on function public.set_wall_neons(text[]) to authenticated;
revoke all on function public.claim_challenge(uuid) from public, anon;
grant execute on function public.claim_challenge(uuid) to authenticated;
revoke all on function public.open_mystery_box(uuid) from public, anon;
grant execute on function public.open_mystery_box(uuid) to authenticated;

-- =========== 0085_wall_one_neon.sql ===========
-- =================================================================
-- 0085 — The Taproom wall hangs ONE neon sign (a big one), not two
--
-- The other signs stay in the collection; the group chooses which single sign hangs (set_wall_neons, at most 1). If 0084 already hung two,
-- only the first stays. The starter pack now hangs PROOST! (OPEN is in the collection). Safe to run whether or not 0084 was run before 0085.
-- Additive + idempotent. Run after 0084.
-- =================================================================
create or replace function public.set_wall_neons(p_ids text[])
returns jsonb as $$
declare v_ids text[] := coalesce(p_ids, '{}');
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if cardinality(v_ids) > 1 then raise exception 'Only 1 neon sign fits on the wall'; end if;
  if exists (select 1 from unnest(v_ids) x where not exists (select 1 from public.wall_found_neons f where f.neon_id = x)) then raise exception 'That sign has not been found yet'; end if;
  insert into public.wall_settings (key, value) values ('hung_neons', to_jsonb(v_ids)) on conflict (key) do update set value = excluded.value;
  return to_jsonb(v_ids);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._wall_starter_pack()
returns void as $$
begin
  if exists (select 1 from public.wall_settings where key = 'starter_given') then return; end if;
  insert into public.wall_found_neons (neon_id, found_by) values ('prost', null), ('open', null) on conflict do nothing;
  update public.wall_settings set value = '["prost"]'::jsonb where key = 'hung_neons';
  insert into public.wall_coasters (beer_id, found_by)
    select b.id, null
    from public.beers b
    left join (select beer_id, avg(rating) as a, count(rating) as c from public.beer_ratings where rating is not null group by beer_id) r on r.beer_id = b.id
    order by r.a desc nulls last, r.c desc nulls last, b.created_at asc, b.name asc
    limit 2
  on conflict do nothing;
  insert into public.wall_settings (key, value) values ('starter_given', 'true'::jsonb) on conflict do nothing;
end;
$$ language plpgsql security definer set search_path = public;

-- a wall that already hung two: keep the first one
update public.wall_settings set value = jsonb_build_array(value->0) where key = 'hung_neons' and jsonb_array_length(value) > 1;

revoke all on function public._wall_starter_pack() from public, anon, authenticated;
revoke all on function public.set_wall_neons(text[]) from public, anon;
grant execute on function public.set_wall_neons(text[]) to authenticated;

-- =========== 0086_daily_rewards.sql ===========
-- =================================================================
-- 0086 — Fun rewards from the daily quests too
--
-- Until now an easy Daily paid XP only (10), a normal Daily had a 15% Mystery Reward and the Group Daily paid XP to everybody who took part.
-- A Mystery Reward is where the fun things live (pets and pet looks, nickname frames, wall items, titles, fragments, XP), so:
--   easy    10 XP + 10% Mystery Reward         (was: 10 XP)
--   normal  18 XP + 20% Mystery Reward         (was: 15%)
--   hard    30 XP + 50% Gauntlet Fragment + 20% Mystery Reward   (was: no box)
--   Group Daily, taking part: 15 XP + 10% Mystery Reward        (the winner keeps 30 XP + 25%)
-- (Chaos Dailies keep their own, already generous, table: 20 / 30 / 35% boxes.) Together with the Daily Sweep (a guaranteed box at 3 / 3) a
-- player now finds a box roughly every other day from Dailies alone. Tune it later in challenge_config ('difficulty_rewards',
-- 'group_daily_rewards'). New Dailies get these rewards from the next midnight on; a Daily that already exists keeps its old reward.
-- Idempotent.
-- =================================================================
update public.challenge_config set value = jsonb_set(jsonb_set(jsonb_set(value,
    '{easy}',   '[{"kind":"player_xp","amount":10},{"kind":"mystery","amount":1,"chance":0.10}]'::jsonb, true),
    '{normal}', '[{"kind":"player_xp","amount":18},{"kind":"mystery","amount":1,"chance":0.20}]'::jsonb, true),
    '{hard}',   '[{"kind":"player_xp","amount":30},{"kind":"gauntlet_fragments","amount":1,"chance":0.5},{"kind":"mystery","amount":1,"chance":0.20}]'::jsonb, true)
  where key = 'difficulty_rewards';
update public.challenge_config set value = jsonb_set(value, '{participation}', '[{"kind":"player_xp","amount":15},{"kind":"mystery","amount":1,"chance":0.10}]'::jsonb, true)
  where key = 'group_daily_rewards';

-- =========== 0087_poem_backgrounds.sql ===========
-- =================================================================
-- OFFICE LORE / TRIPEL TALES — POEM BACKGROUNDS (earned, never bought)
-- =================================================================
-- Nine looks for a poem: old parchment (everybody's starter gift), typewriter, chalkboard, love letter, treasure map, torn scroll, magic scroll,
-- starry night and an illuminated manuscript (the artwork is CSS in the app). You earn one by claiming the matching quests (a chance per claim + a
-- pity counter, like the nickname frames) or from a Mystery Reward. Once you own a background you can put it on poems YOU wrote: one background
-- can be used on at most 2 of your poems. Everybody sees the background. Granted inside the idempotent claim / box opening, so a refresh or a second
-- click never rolls twice. The assignment lives in its own table, so poems and their triggers stay untouched.
-- Additive + idempotent. Run after 0086.
-- =================================================================
create table if not exists public.poem_backgrounds (
  id text primary key,
  name text not null,
  tag text not null,
  rarity text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  sources jsonb not null default '[]',
  pity_after int,
  hint text not null,
  sort_order int not null default 0,
  is_starter boolean not null default false,     -- every member owns it from the start (no row needed)
  is_active boolean not null default true
);
create table if not exists public.user_poem_backgrounds (
  user_id uuid not null references public.profiles(id),
  background_id text not null references public.poem_backgrounds(id),
  source text,
  granted_at timestamptz not null default now(),
  primary key (user_id, background_id)
);
create table if not exists public.poem_background_pity (
  user_id uuid not null references public.profiles(id),
  background_id text not null references public.poem_backgrounds(id),
  misses int not null default 0,
  primary key (user_id, background_id)
);
create table if not exists public.poem_background_assignments (
  poem_id uuid primary key references public.poems(id) on delete cascade,
  background_id text not null references public.poem_backgrounds(id),
  user_id uuid not null references public.profiles(id),
  assigned_at timestamptz not null default now()
);
create index if not exists poem_background_assignments_user_idx on public.poem_background_assignments (user_id, background_id);
alter table public.poem_backgrounds enable row level security;
alter table public.user_poem_backgrounds enable row level security;
alter table public.poem_background_pity enable row level security;             -- no policy: private
alter table public.poem_background_assignments enable row level security;
drop policy if exists "Poem backgrounds: read" on public.poem_backgrounds;
create policy "Poem backgrounds: read" on public.poem_backgrounds for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "My poem backgrounds: read own" on public.user_poem_backgrounds;
create policy "My poem backgrounds: read own" on public.user_poem_backgrounds for select to authenticated using (user_id = auth.uid());
drop policy if exists "Poem background assignments: read" on public.poem_background_assignments;
create policy "Poem background assignments: read" on public.poem_background_assignments for select to authenticated using (public.is_app_member('officelore'));
-- no client write policy anywhere: everything goes through the functions below

do $$ begin
  alter publication supabase_realtime add table public.poem_background_assignments;
exception when duplicate_object then null; when others then null; end $$;

insert into public.poem_backgrounds (id, name, tag, rarity, sources, pity_after, hint, sort_order, is_starter) values
  ('parch', 'Oud perkament', '📜 Klassiek', 'common', '[]'::jsonb, null, 'Everybody starts with this one.', 10, true),
  ('type', 'Typemachine', '⌨️ Getikt', 'common', '[{"def": "pd_poet_for_a_day", "chance": 0.15}, {"def": "pd_poetry_critic", "chance": 0.12}, {"def": "pd_the_critic", "chance": 0.08}, {"def": "pd_lore_keeper", "chance": 0.08}, {"def": "pd_name_thy_victim", "chance": 0.08}, {"def": "pd_quote_hunter", "chance": 0.06}]'::jsonb, 12, 'Drops from the everyday quests.', 20, false),
  ('chalk', 'Krijtbord', '🧑‍🏫 Krijt', 'common', '[{"def": "pd_lore_master", "chance": 0.1}, {"def": "pd_know_thy_friends", "chance": 0.1}, {"def": "pd_office_oracle", "chance": 0.08}, {"def": "pd_memory_lane", "chance": 0.08}, {"def": "pd_quote_hunter", "chance": 0.08}, {"def": "pd_five_seconds", "chance": 0.08}]'::jsonb, 12, 'Drops from the everyday quests.', 30, false),
  ('love', 'Liefdesbrief', '💌 Lakzegel', 'rare', '[{"def": "pd_poet_for_a_day", "chance": 0.1}, {"def": "pd_poetry_critic", "chance": 0.08}, {"def": "pd_pick_a_side", "chance": 0.05}, {"def": "pd_perfect_score", "chance": 0.05}, {"def": "pd_know_thy_friends", "chance": 0.04}]'::jsonb, 20, 'Drops from daily quests.', 40, false),
  ('map', 'Schatkaart', '🗺️ X markeert', 'rare', '[{"def": "pd_office_safari", "chance": 0.1}, {"def": "pd_the_photographer", "chance": 0.08}, {"def": "pd_draw_this", "chance": 0.06}, {"def": "pd_new_brew", "chance": 0.05}, {"def": "pd_tiny_quest", "chance": 0.05}, {"def": "pd_the_impostor", "chance": 0.05}]'::jsonb, 20, 'Drops from daily quests.', 50, false),
  ('torn', 'Gescheurde scroll', '🩹 Gehavend', 'rare', '[{"def": "gw_poets", "chance": 0.1}, {"def": "rb_pamphlet", "chance": 0.1}, {"def": "gw_fellowship", "chance": 0.08}, {"def": "rb_storm", "chance": 0.08}, {"def": "gw_council", "chance": 0.06}, {"def": "rb_seeds", "chance": 0.06}]'::jsonb, 12, 'Drops from Group Quests and Rebellions.', 60, false),
  ('magic', 'Magische scroll', '✨ Betoverd', 'epic', '[{"def": "pw_poet_laureate", "chance": 0.1}, {"def": "pw_keeper_knowledge", "chance": 0.08}, {"def": "pw_completionist", "chance": 0.06}, {"def": "gw_poets", "chance": 0.06}, {"def": "gw_council", "chance": 0.06}, {"def": "pw_adventurer", "chance": 0.05}]'::jsonb, 25, 'Drops from the big weekly and Group Quests.', 70, false),
  ('night', 'Sterrenhemel', '🌙 Nachtpoëzie', 'epic', '[{"def": "pw_agent_of_chaos", "chance": 0.08}, {"def": "pw_social_creature", "chance": 0.08}, {"def": "pw_battle_hardened", "chance": 0.06}, {"def": "pw_beer_explorer", "chance": 0.06}, {"def": "gw_gathering", "chance": 0.06}, {"def": "rb_storm", "chance": 0.05}]'::jsonb, 25, 'Drops from the big weekly and Group Quests.', 80, false),
  ('manu', 'Verlucht manuscript', '🕯️ Middeleeuws', 'legendary', '[{"def": "gd_poetry_showdown", "chance": 0.06}, {"def": "pw_poet_laureate", "chance": 0.04}]'::jsonb, 40, 'Almost only from Mystery Rewards, and now and then from the Poetry Showdown.', 90, false)
on conflict (id) do update set name = excluded.name, tag = excluded.tag, rarity = excluded.rarity, sources = excluded.sources,
  pity_after = excluded.pity_after, hint = excluded.hint, sort_order = excluded.sort_order, is_starter = excluded.is_starter;

-- Mystery boxes may contain a poem background
update public.challenge_config set value = jsonb_set(value, '{pools,default,outcomes,poem_bg}', '10'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'default' and not (value->'pools'->'default'->'outcomes' ? 'poem_bg');
update public.challenge_config set value = jsonb_set(value, '{pools,sweep,outcomes,poem_bg}', '10'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'sweep' and not (value->'pools'->'sweep'->'outcomes' ? 'poem_bg');

-- the hook: called once per successful claim (never from a client)
create or replace function public._poem_bg_hook(p_user uuid, p_def text)
returns jsonb as $$
declare
  f public.poem_backgrounds; src jsonb; v_miss int; v_hit boolean;
  v_out jsonb := '[]'::jsonb;
begin
  if p_def is null then return v_out; end if;
  for f in select * from public.poem_backgrounds where is_active and not is_starter order by sort_order loop
    select e into src from jsonb_array_elements(f.sources) e where e->>'def' = p_def limit 1;
    continue when src is null;
    continue when exists (select 1 from public.user_poem_backgrounds u where u.user_id = p_user and u.background_id = f.id);
    insert into public.poem_background_pity (user_id, background_id) values (p_user, f.id) on conflict do nothing;
    select misses into v_miss from public.poem_background_pity where user_id = p_user and background_id = f.id for update;
    v_hit := random() < coalesce((src->>'chance')::numeric, 0) or (f.pity_after is not null and v_miss + 1 >= f.pity_after);
    update public.poem_background_pity set misses = case when v_hit then 0 else v_miss + 1 end where user_id = p_user and background_id = f.id;
    if v_hit then
      insert into public.user_poem_backgrounds (user_id, background_id, source) values (p_user, f.id, p_def) on conflict do nothing;
      if found then v_out := v_out || jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag, 'rarity', f.rarity); end if;
    end if;
  end loop;
  return v_out;
end;
$$ language plpgsql security definer set search_path = public;

-- putting a background on one of YOUR poems (null = take it off). A background can be on at most 2 of your poems.
create or replace function public.set_poem_background(p_poem_id uuid, p_background_id text)
returns jsonb as $$
declare
  p public.poems;
  v_used int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into p from public.poems where id = p_poem_id;
  if p.id is null then raise exception 'Unknown poem'; end if;
  if p.author_user_id is distinct from auth.uid() then raise exception 'You can only choose a background for a poem you wrote'; end if;
  perform pg_advisory_xact_lock(hashtext('poem_bg_assign:' || auth.uid()::text));
  if p_background_id is null then
    delete from public.poem_background_assignments where poem_id = p_poem_id;
    return jsonb_build_object('poem_id', p_poem_id, 'background_id', null);
  end if;
  if not exists (select 1 from public.poem_backgrounds b where b.id = p_background_id and b.is_active) then raise exception 'Unknown background'; end if;
  if not exists (select 1 from public.poem_backgrounds b where b.id = p_background_id and b.is_starter)
     and not exists (select 1 from public.user_poem_backgrounds u where u.user_id = auth.uid() and u.background_id = p_background_id) then
    raise exception 'You have not earned this background yet';
  end if;
  select count(*) into v_used from public.poem_background_assignments a where a.user_id = auth.uid() and a.background_id = p_background_id and a.poem_id <> p_poem_id;
  if v_used >= 2 then raise exception 'This background is already on 2 of your poems'; end if;
  insert into public.poem_background_assignments (poem_id, background_id, user_id) values (p_poem_id, p_background_id, auth.uid())
    on conflict (poem_id) do update set background_id = excluded.background_id, assigned_at = now();
  return jsonb_build_object('poem_id', p_poem_id, 'background_id', p_background_id);
end;
$$ language plpgsql security definer set search_path = public;

-- claiming and opening a box now also report the poem backgrounds they earn (otherwise unchanged from 0084)
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
    'frames', public._frame_hook(auth.uid(), a.definition_id),
    'wall', public._wall_hook(auth.uid(), a.definition_id),
    'poem_bgs', public._poem_bg_hook(auth.uid(), a.definition_id));
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
  wn public.wall_neon_signs; wb public.beers;
  pb public.poem_backgrounds;
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

  if v_outcome = 'wall' then
    -- something for the Taproom wall that the group does not have yet: a neon sign of the rolled rarity (the other tiers from the floor upwards), else a bierviltje
    perform pg_advisory_xact_lock(hashtext('wall_found'));
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select n.* into wn from public.wall_neon_signs n
        where n.is_active
          and n.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.wall_found_neons f where f.neon_id = n.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = n.rarity) >= v_floor_i
        order by random() limit 1;
      exit when wn.id is not null;
    end loop;
    if wn.id is not null then
      insert into public.wall_found_neons (neon_id, found_by) values (wn.id, b.user_id) on conflict do nothing;
      v_prize := jsonb_build_object('type', 'wall', 'kind', 'neon', 'rarity', wn.rarity, 'id', wn.id, 'name', wn.name);
    elsif v_floor_i = 0 then
      select * into wb from public.beers x where not exists (select 1 from public.wall_coasters c where c.beer_id = x.id) order by random() limit 1;
      if wb.id is not null then
        insert into public.wall_coasters (beer_id, found_by) values (wb.id, b.user_id) on conflict do nothing;
        v_prize := jsonb_build_object('type', 'wall', 'kind', 'coaster', 'rarity', 'common', 'id', wb.id, 'name', wb.name);
      end if;
    end if;
    if v_prize is null or v_prize->>'type' is distinct from 'wall' then v_outcome := 'xp'; v_dup := true; end if;
  end if;

  if v_outcome = 'poem_bg' then
    -- a poem background you do not own yet: the rolled rarity first, then the other tiers from the floor upwards; nothing left = an XP bonus
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select p.* into pb from public.poem_backgrounds p
        where p.is_active and not p.is_starter
          and p.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.user_poem_backgrounds u where u.user_id = b.user_id and u.background_id = p.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = p.rarity) >= v_floor_i
        order by random() limit 1;
      exit when pb.id is not null;
    end loop;
    if pb.id is null then
      v_outcome := 'xp'; v_dup := true;
    else
      insert into public.user_poem_backgrounds (user_id, background_id, source) values (b.user_id, pb.id, 'box') on conflict do nothing;
      v_prize := jsonb_build_object('type', 'poem_bg', 'rarity', pb.rarity, 'background_id', pb.id, 'name', pb.name);
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

revoke all on function public._poem_bg_hook(uuid, text) from public, anon, authenticated;
revoke all on function public.set_poem_background(uuid, text) from public, anon;
grant execute on function public.set_poem_background(uuid, text) to authenticated;
revoke all on function public.claim_challenge(uuid) from public, anon;
grant execute on function public.claim_challenge(uuid) to authenticated;
revoke all on function public.open_mystery_box(uuid) from public, anon;
grant execute on function public.open_mystery_box(uuid) to authenticated;

-- =========== 0088_room_furniture.sql ===========
-- =================================================================
-- OFFICE LORE / TRIPEL TALES — ROOM FURNITURE (earned, never bought)
-- =================================================================
-- "Mijn Hoekje" is a furnished room. Every piece of furniture is a SLOT (desk now; wardrobe, chest, ... later) with VARIANTS you can earn.
-- First slot: the desk. Only the Oak starter exists for now (everybody has it): more desks are added later as rows here, with their own artwork.
-- You earn a variant from the matching quests (a chance per claim + a pity counter, like the frames and poem backgrounds) or from a Mystery
-- Reward. The one you pick is stored in your room (room_profiles.loadout.furniture.<slot>) and everybody who visits sees it.
-- A new slot or variant is just a row here (+ a PNG in furniture-images/, see supabase/tools/build_furniture_images.py): nothing else changes.
-- Additive + idempotent. Run after 0087.
-- =================================================================
create table if not exists public.room_furniture_items (
  id text primary key,
  slot text not null,
  name text not null,
  tag text not null,
  rarity text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  sources jsonb not null default '[]',
  pity_after int,
  hint text not null,
  sort_order int not null default 0,
  is_starter boolean not null default false,     -- every member owns it from the start (no row needed)
  is_active boolean not null default true
);
create index if not exists room_furniture_items_slot_idx on public.room_furniture_items (slot, sort_order);
create table if not exists public.user_room_furniture (
  user_id uuid not null references public.profiles(id),
  item_id text not null references public.room_furniture_items(id),
  source text,
  granted_at timestamptz not null default now(),
  primary key (user_id, item_id)
);
create table if not exists public.room_furniture_pity (
  user_id uuid not null references public.profiles(id),
  item_id text not null references public.room_furniture_items(id),
  misses int not null default 0,
  primary key (user_id, item_id)
);
alter table public.room_furniture_items enable row level security;
alter table public.user_room_furniture enable row level security;
alter table public.room_furniture_pity enable row level security;             -- no policy: private
drop policy if exists "Room furniture: read" on public.room_furniture_items;
create policy "Room furniture: read" on public.room_furniture_items for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "My room furniture: read own" on public.user_room_furniture;
create policy "My room furniture: read own" on public.user_room_furniture for select to authenticated using (user_id = auth.uid());
-- no client write policy: everything goes through the functions below

insert into public.room_furniture_items (id, slot, name, tag, rarity, sources, pity_after, hint, sort_order, is_starter) values
  ('desk-classic', 'desk', 'Klassiek bureau', '🪑 Eik', 'common', '[]'::jsonb, null, 'Everybody starts with this desk.', 10, true)
on conflict (id) do update set slot = excluded.slot, name = excluded.name, tag = excluded.tag, rarity = excluded.rarity, sources = excluded.sources,
  pity_after = excluded.pity_after, hint = excluded.hint, sort_order = excluded.sort_order, is_starter = excluded.is_starter;

-- Mystery boxes may contain furniture
update public.challenge_config set value = jsonb_set(value, '{pools,default,outcomes,furniture}', '8'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'default' and not (value->'pools'->'default'->'outcomes' ? 'furniture');
update public.challenge_config set value = jsonb_set(value, '{pools,sweep,outcomes,furniture}', '8'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'sweep' and not (value->'pools'->'sweep'->'outcomes' ? 'furniture');

-- the hook: called once per successful claim (never from a client)
create or replace function public._furniture_hook(p_user uuid, p_def text)
returns jsonb as $$
declare
  f public.room_furniture_items; src jsonb; v_miss int; v_hit boolean;
  v_out jsonb := '[]'::jsonb;
begin
  if p_def is null then return v_out; end if;
  for f in select * from public.room_furniture_items where is_active and not is_starter order by slot, sort_order loop
    select e into src from jsonb_array_elements(f.sources) e where e->>'def' = p_def limit 1;
    continue when src is null;
    continue when exists (select 1 from public.user_room_furniture u where u.user_id = p_user and u.item_id = f.id);
    insert into public.room_furniture_pity (user_id, item_id) values (p_user, f.id) on conflict do nothing;
    select misses into v_miss from public.room_furniture_pity where user_id = p_user and item_id = f.id for update;
    v_hit := random() < coalesce((src->>'chance')::numeric, 0) or (f.pity_after is not null and v_miss + 1 >= f.pity_after);
    update public.room_furniture_pity set misses = case when v_hit then 0 else v_miss + 1 end where user_id = p_user and item_id = f.id;
    if v_hit then
      insert into public.user_room_furniture (user_id, item_id, source) values (p_user, f.id, p_def) on conflict do nothing;
      if found then v_out := v_out || jsonb_build_object('id', f.id, 'slot', f.slot, 'name', f.name, 'tag', f.tag, 'rarity', f.rarity); end if;
    end if;
  end loop;
  return v_out;
end;
$$ language plpgsql security definer set search_path = public;

-- choosing which variant of a slot stands in YOUR room (null = back to the starter). Other loadout keys are kept.
create or replace function public.set_room_furniture(p_slot text, p_item text)
returns jsonb as $$
declare
  v_loadout jsonb; v_furn jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_slot is null or length(p_slot) = 0 then raise exception 'Unknown slot'; end if;
  if p_item is not null then
    if not exists (select 1 from public.room_furniture_items i where i.id = p_item and i.slot = p_slot and i.is_active) then raise exception 'Unknown furniture'; end if;
    if not exists (select 1 from public.room_furniture_items i where i.id = p_item and i.is_starter)
       and not exists (select 1 from public.user_room_furniture u where u.user_id = auth.uid() and u.item_id = p_item) then
      raise exception 'You have not earned this furniture yet';
    end if;
  end if;
  insert into public.room_profiles (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select loadout into v_loadout from public.room_profiles where user_id = auth.uid() for update;
  v_loadout := coalesce(v_loadout, '{}'::jsonb);
  v_furn := coalesce(v_loadout->'furniture', '{}'::jsonb) - p_slot;
  if p_item is not null then v_furn := v_furn || jsonb_build_object(p_slot, p_item); end if;
  v_loadout := case when v_furn = '{}'::jsonb then v_loadout - 'furniture' else v_loadout || jsonb_build_object('furniture', v_furn) end;
  update public.room_profiles set loadout = v_loadout where user_id = auth.uid();
  return v_loadout;
end;
$$ language plpgsql security definer set search_path = public;

-- claiming and opening a box now also report the furniture they earn (otherwise unchanged from 0087)
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
    'frames', public._frame_hook(auth.uid(), a.definition_id),
    'wall', public._wall_hook(auth.uid(), a.definition_id),
    'poem_bgs', public._poem_bg_hook(auth.uid(), a.definition_id),
    'furniture', public._furniture_hook(auth.uid(), a.definition_id));
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
  wn public.wall_neon_signs; wb public.beers;
  pb public.poem_backgrounds;
  fi public.room_furniture_items;
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

  if v_outcome = 'wall' then
    -- something for the Taproom wall that the group does not have yet: a neon sign of the rolled rarity (the other tiers from the floor upwards), else a bierviltje
    perform pg_advisory_xact_lock(hashtext('wall_found'));
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select n.* into wn from public.wall_neon_signs n
        where n.is_active
          and n.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.wall_found_neons f where f.neon_id = n.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = n.rarity) >= v_floor_i
        order by random() limit 1;
      exit when wn.id is not null;
    end loop;
    if wn.id is not null then
      insert into public.wall_found_neons (neon_id, found_by) values (wn.id, b.user_id) on conflict do nothing;
      v_prize := jsonb_build_object('type', 'wall', 'kind', 'neon', 'rarity', wn.rarity, 'id', wn.id, 'name', wn.name);
    elsif v_floor_i = 0 then
      select * into wb from public.beers x where not exists (select 1 from public.wall_coasters c where c.beer_id = x.id) order by random() limit 1;
      if wb.id is not null then
        insert into public.wall_coasters (beer_id, found_by) values (wb.id, b.user_id) on conflict do nothing;
        v_prize := jsonb_build_object('type', 'wall', 'kind', 'coaster', 'rarity', 'common', 'id', wb.id, 'name', wb.name);
      end if;
    end if;
    if v_prize is null or v_prize->>'type' is distinct from 'wall' then v_outcome := 'xp'; v_dup := true; end if;
  end if;

  if v_outcome = 'poem_bg' then
    -- a poem background you do not own yet: the rolled rarity first, then the other tiers from the floor upwards; nothing left = an XP bonus
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select p.* into pb from public.poem_backgrounds p
        where p.is_active and not p.is_starter
          and p.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.user_poem_backgrounds u where u.user_id = b.user_id and u.background_id = p.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = p.rarity) >= v_floor_i
        order by random() limit 1;
      exit when pb.id is not null;
    end loop;
    if pb.id is null then
      v_outcome := 'xp'; v_dup := true;
    else
      insert into public.user_poem_backgrounds (user_id, background_id, source) values (b.user_id, pb.id, 'box') on conflict do nothing;
      v_prize := jsonb_build_object('type', 'poem_bg', 'rarity', pb.rarity, 'background_id', pb.id, 'name', pb.name);
    end if;
  end if;

  if v_outcome = 'furniture' then
    -- a piece of furniture you do not own yet: the rolled rarity first, then the other tiers from the floor upwards; nothing left = an XP bonus
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select i.* into fi from public.room_furniture_items i
        where i.is_active and not i.is_starter
          and i.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality x(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.user_room_furniture u where u.user_id = b.user_id and u.item_id = i.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality x(val, ord) where val = i.rarity) >= v_floor_i
        order by random() limit 1;
      exit when fi.id is not null;
    end loop;
    if fi.id is null then
      v_outcome := 'xp'; v_dup := true;
    else
      insert into public.user_room_furniture (user_id, item_id, source) values (b.user_id, fi.id, 'box') on conflict do nothing;
      v_prize := jsonb_build_object('type', 'furniture', 'rarity', fi.rarity, 'item_id', fi.id, 'slot', fi.slot, 'name', fi.name);
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

revoke all on function public._furniture_hook(uuid, text) from public, anon, authenticated;
revoke all on function public.set_room_furniture(text, text) from public, anon;
grant execute on function public.set_room_furniture(text, text) to authenticated;
revoke all on function public.claim_challenge(uuid) from public, anon;
grant execute on function public.claim_challenge(uuid) to authenticated;
revoke all on function public.open_mystery_box(uuid) from public, anon;
grant execute on function public.open_mystery_box(uuid) to authenticated;

-- =========== 0089_more_poem_reactions.sql ===========
-- =================================================================
-- OFFICE LORE / TRIPEL TALES — MORE POEM REACTIONS
-- =================================================================
-- A poem could only get 9 fixed reactions: the table had a CHECK with that exact list, so every new reaction needed a migration.
-- That list now lives in the app (POEM_REACTION_TYPES in index.html): the database only checks that the key looks sane
-- (lowercase letters and underscores). Everything else stays as it was: a unique reaction per person per poem, at most 3
-- different reactions per person per poem, +1 Poetry XP for the author per reaction, the 'actually_good' bonus.
-- Additive + idempotent. Run after 0088.
-- =================================================================
do $$
declare c text;
begin
  for c in
    select con.conname from pg_constraint con
    where con.conrelid = 'public.poem_reactions'::regclass and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%reaction_type%' and pg_get_constraintdef(con.oid) ilike '%charming%'
  loop
    execute format('alter table public.poem_reactions drop constraint %I', c);
  end loop;
end $$;
alter table public.poem_reactions drop constraint if exists poem_reactions_type_format;
alter table public.poem_reactions add constraint poem_reactions_type_format check (reaction_type ~ '^[a-z][a-z_]{1,29}$');

-- =========== 0090_home_xp_public.sql ===========
-- =================================================================
-- OFFICE LORE / TRIPEL TALES — PUBLIC PLAYER XP + "WHO IS DONE TODAY"
-- =================================================================
-- Quest XP (the challenge reward ledger) is private: everybody can only read their OWN rows. That is right for the ledger, but it means
-- the app could not know how much XP the others have earned from quests, so every other person's level and any ranking was too low.
-- Two small read-only functions fix that without opening the ledger:
--   player_challenge_xp()  -> per active member: the Player XP they earned from quests (+ XP from opened Mystery Rewards)
--   sweep_done_today()     -> per active member: has this member completed today's Daily Sweep (Europe/Brussels day)?
-- Used by the Home terrace: the group's growth, the VIP seats (most XP), level auras and the "everybody is done" party.
-- Additive + idempotent. Run after 0089.
-- =================================================================
create or replace function public.player_challenge_xp()
returns table (user_id uuid, challenge_xp int) as $$
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  return query
    select m.user_id,
           (coalesce((select sum(g.amount) from public.challenge_reward_grants g where g.user_id = m.user_id and g.kind = 'player_xp'), 0)
          + coalesce((select sum((b.prize->>'amount')::int) from public.mystery_boxes b
                      where b.user_id = m.user_id and b.status = 'opened' and b.prize->>'type' = 'xp'), 0))::int
    from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active
    order by m.user_id;
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public.sweep_done_today()
returns table (user_id uuid, done boolean) as $$
declare v_today text := to_char(now() at time zone 'Europe/Brussels', 'YYYY-MM-DD');
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  return query
    select m.user_id, exists (select 1 from public.challenge_sweeps s where s.user_id = m.user_id and s.period_key = v_today)
    from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active
    order by m.user_id;
end;
$$ language plpgsql stable security definer set search_path = public;

revoke all on function public.player_challenge_xp() from public, anon;
grant execute on function public.player_challenge_xp() to authenticated;
revoke all on function public.sweep_done_today() from public, anon;
grant execute on function public.sweep_done_today() to authenticated;

-- =========== 0091_outfit_beer3.sql ===========
-- =================================================================
-- OFFICE LORE — outfit set 'be3' "Barista's Brew" (beer discovery)
-- =================================================================
-- A third beer outfit, for both bases. Random drop (its own pity counter, like the other random sets) when you claim a beer quest:
-- Beer Explorer (weekly), The Gathering (Group Quest), Beer Scholar, New Brew, One for the Books (Dailies) and the Group Weekly with 2 sessions.
-- Codes: fbe3 (female) / mbe3 (male). Additive + idempotent. Run after 0090.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('be3', 'Barista''s Brew', 'Drops from beer quests.', 'random_drop',
   '[{"def":"pw_beer_explorer","chance":0.20},{"def":"gw_gathering","chance":0.15},{"def":"gw_sessions_2","chance":0.12},{"def":"pd_beer_scholar","chance":0.06},{"def":"pd_new_brew","chance":0.06},{"def":"pd_one_for_the_books","chance":0.06}]', 10, 25)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- =========== 0092_outfit_legend3.sql ===========
-- =================================================================
-- OFFICE LORE — LEGENDARY outfit set 'lg3' "Gala Night"
-- =================================================================
-- Third legendary set, for both bases (the red gala dress with the big hat / the pinstripe three-piece with the fedora).
-- Legendary but not ultra-rare (the other two legendary sets are): 6 to 15% per claim and a guarantee after 15 claims. Drops from the social and big quests:
-- Social Creature, Completionist, Adventurer, the Group Quests and the Rebellion quests (daily quests never roll for it).
-- Codes: flg3 (female) / mlg3 (male). Additive + idempotent. Run after 0091.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('lg3', 'Gala Night', 'Legendary. Drops from the social, group and rebellion quests.', 'random_drop',
   '[{"def":"pw_social_creature","chance":0.15},{"def":"pw_completionist","chance":0.15},{"def":"pw_adventurer","chance":0.12},
     {"def":"gw_fellowship","chance":0.12},{"def":"gw_gathering","chance":0.10},{"def":"gw_nickname_factory","chance":0.10},{"def":"gw_council","chance":0.12},
     {"def":"rb_storm","chance":0.10},{"def":"rb_seeds","chance":0.10},{"def":"rb_pamphlet","chance":0.10},{"def":"gd_nickname_of_the_day","chance":0.06}]', 15, 120)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
