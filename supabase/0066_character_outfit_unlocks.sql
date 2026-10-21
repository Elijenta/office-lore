-- =================================================================
-- OFFICE LORE — special OUTFITS for the Personal Character (earned, never bought)
-- =================================================================
-- The standard outfits (f1.., m1..) are free for everybody (0063). Special outfit SETS
-- are earned through Quests. A set has a female and a male version (codes 'f'+set and
-- 'm'+set, e.g. fbe1 / mbe1); you own the SET and wear the version of your base.
--
--   be1  "Brewfest"       first_completion: you get it the FIRST time you complete
--                         Beer Explorer (and claim it). Guaranteed, once.
--   be2  "Beer Trekker"   random_drop: a chance on every claim of a beer-discovery quest
--                         (Beer Explorer, Gathering, Beer Scholar, New Brew, One for the
--                         Books), with a pity counter: after pity_after claims without a
--                         drop the next claim gives it. Both live in character_outfit_sets.sources.
--
-- It is paid inside the idempotent claim (the claim row is unique), so refreshing, double
-- clicking, a second tab or a realtime echo can never grant or roll twice. Nothing about
-- drinking is rewarded: these are discovery quests. set_room_character only lets you wear
-- a set you own. Additive + idempotent. Run after 0065.
-- =================================================================
create table if not exists public.character_outfit_sets (
  id text primary key,
  name text not null,
  hint text not null,
  unlock_kind text not null check (unlock_kind in ('first_completion', 'random_drop')),
  sources jsonb not null default '[]',        -- [{"def": "pw_beer_explorer", "chance": 0.25}]
  pity_after int,
  sort_order int not null default 0,
  is_active boolean not null default true
);
create table if not exists public.user_character_outfits (
  user_id uuid not null references public.profiles(id),
  set_id text not null references public.character_outfit_sets(id),
  source text,
  granted_at timestamptz not null default now(),
  primary key (user_id, set_id)
);
create table if not exists public.character_outfit_pity (
  user_id uuid not null references public.profiles(id),
  set_id text not null references public.character_outfit_sets(id),
  misses int not null default 0,
  primary key (user_id, set_id)
);
alter table public.character_outfit_sets enable row level security;
alter table public.user_character_outfits enable row level security;
alter table public.character_outfit_pity enable row level security;      -- no policy: private
drop policy if exists "Outfit sets: read" on public.character_outfit_sets;
create policy "Outfit sets: read" on public.character_outfit_sets for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "My outfits: read own" on public.user_character_outfits;
create policy "My outfits: read own" on public.user_character_outfits for select to authenticated using (user_id = auth.uid());

insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('be1', 'Brewfest', 'Complete Beer Explorer for the first time.', 'first_completion', '[{"def":"pw_beer_explorer"}]', null, 10),
  ('be2', 'Beer Trekker', 'Drops from beer discovery quests.', 'random_drop',
     '[{"def":"pw_beer_explorer","chance":0.25},{"def":"gw_gathering","chance":0.15},{"def":"pd_beer_scholar","chance":0.06},{"def":"pd_new_brew","chance":0.06},{"def":"pd_one_for_the_books","chance":0.06}]', 10, 20)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- the hook: called once per successful claim
create or replace function public._character_outfit_hook(p_user uuid, p_def text)
returns jsonb as $$
declare
  s public.character_outfit_sets;
  src jsonb; v_chance numeric; v_miss int; v_hit boolean;
  v_granted jsonb := '[]'::jsonb;
begin
  for s in select * from public.character_outfit_sets where is_active order by sort_order loop
    select e into src from jsonb_array_elements(s.sources) e where e->>'def' = p_def limit 1;
    continue when src is null;
    continue when exists (select 1 from public.user_character_outfits u where u.user_id = p_user and u.set_id = s.id);
    if s.unlock_kind = 'first_completion' then
      v_hit := true;
    else
      v_chance := coalesce((src->>'chance')::numeric, 0);
      insert into public.character_outfit_pity (user_id, set_id) values (p_user, s.id) on conflict do nothing;
      select misses into v_miss from public.character_outfit_pity where user_id = p_user and set_id = s.id for update;
      v_hit := random() < v_chance or (s.pity_after is not null and v_miss + 1 >= s.pity_after);
      update public.character_outfit_pity set misses = case when v_hit then 0 else v_miss + 1 end where user_id = p_user and set_id = s.id;
    end if;
    if v_hit then
      insert into public.user_character_outfits (user_id, set_id, source) values (p_user, s.id, p_def) on conflict do nothing;
      if found then v_granted := v_granted || jsonb_build_object('id', s.id, 'name', s.name); end if;
    end if;
  end loop;
  return v_granted;
end;
$$ language plpgsql security definer set search_path = public;

-- claiming
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
  return jsonb_build_object('status', 'claimed', 'results', v_results, 'outfits', public._character_outfit_hook(auth.uid(), a.definition_id));
end;
$$ language plpgsql security definer set search_path = public;

-- wearing: standard outfits are free, special sets must be owned
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
    if v_set !~ '^[0-9]+$' then                                   -- a special set
      if not exists (select 1 from public.character_outfit_sets where id = v_set and is_active) then raise exception 'Unknown outfit'; end if;
      if not exists (select 1 from public.user_character_outfits u where u.user_id = auth.uid() and u.set_id = v_set) then
        raise exception 'You have not unlocked this outfit yet';
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

revoke all on function public._character_outfit_hook(uuid, text) from public, anon, authenticated;
revoke all on function public.set_room_character(text, text) from public, anon;
grant execute on function public.set_room_character(text, text) to authenticated;
