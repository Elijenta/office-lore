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
