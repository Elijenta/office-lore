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
