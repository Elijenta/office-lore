-- =================================================================
-- OFFICE LORE — TITLES under your name
-- =================================================================
-- A title is a small line under your name in My Room (and on the Quest Board banner).
-- You earn them two ways:
--   * MILESTONE titles (unlock_kind claims / sweeps / boxes): claim N quests of a family
--     (Lore, Poetry, Beer discovery, Battles, Chaos, Quizzes, Rebellion, Group Daily, Group
--     Quests, Adventurer, Completionist, Social Creature, all Dailies, all Weeklies), claim
--     Daily Sweeps, or open Mystery Rewards. Three or four steps per family: common, rare,
--     epic (and one legendary for 250 Dailies). Granted inside the idempotent claim.
--   * DROP titles (unlock_kind drop): funny office titles that Mystery Rewards can contain
--     (common to legendary), unowned ones first; with none left it is an XP bonus.
-- set_room_title(id) wears one you own (null = none). Beer titles reward discovery, never drinking.
-- Additive + idempotent. Run after 0074.
-- =================================================================
create table if not exists public.character_titles (
  id text primary key,
  text text not null,
  rarity text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  family text not null,
  unlock_kind text not null check (unlock_kind in ('claims', 'sweeps', 'boxes', 'drop')),
  defs jsonb not null default '[]',
  threshold int,
  hint text not null,
  sort_order int not null default 0,
  is_active boolean not null default true
);
create table if not exists public.user_character_titles (
  user_id uuid not null references public.profiles(id),
  title_id text not null references public.character_titles(id),
  source text,
  granted_at timestamptz not null default now(),
  primary key (user_id, title_id)
);
alter table public.character_titles enable row level security;
alter table public.user_character_titles enable row level security;
drop policy if exists "Titles: read" on public.character_titles;
create policy "Titles: read" on public.character_titles for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "My titles: read own" on public.user_character_titles;
create policy "My titles: read own" on public.user_character_titles for select to authenticated using (user_id = auth.uid());

insert into public.character_titles (id, text, rarity, family, unlock_kind, defs, threshold, hint, sort_order) values
  ('lore_1', 'Lore Apprentice', 'common', 'Lore & Nicknames', 'claims', '["pd_name_thy_victim", "pd_lore_keeper", "pd_quote_hunter", "pd_the_critic", "pd_memory_lane", "pw_lorekeeper", "gw_nickname_factory"]'::jsonb, 1, 'Claim 1 Lore & Nicknames quest.', 1),
  ('lore_2', 'The Lorekeeper', 'rare', 'Lore & Nicknames', 'claims', '["pd_name_thy_victim", "pd_lore_keeper", "pd_quote_hunter", "pd_the_critic", "pd_memory_lane", "pw_lorekeeper", "gw_nickname_factory"]'::jsonb, 10, 'Claim 10 Lore & Nicknames quests.', 2),
  ('lore_3', 'Archivist of the Office', 'epic', 'Lore & Nicknames', 'claims', '["pd_name_thy_victim", "pd_lore_keeper", "pd_quote_hunter", "pd_the_critic", "pd_memory_lane", "pw_lorekeeper", "gw_nickname_factory"]'::jsonb, 40, 'Claim 40 Lore & Nicknames quests.', 3),
  ('poetry_1', 'Verse Rookie', 'common', 'Poetry', 'claims', '["pd_poet_for_a_day", "pd_poetry_critic", "pw_poet_laureate", "gw_poets", "gd_poetry_showdown", "rb_pamphlet"]'::jsonb, 1, 'Claim 1 Poetry quest.', 4),
  ('poetry_2', 'Poet Laureate', 'rare', 'Poetry', 'claims', '["pd_poet_for_a_day", "pd_poetry_critic", "pw_poet_laureate", "gw_poets", "gd_poetry_showdown", "rb_pamphlet"]'::jsonb, 10, 'Claim 10 Poetry quests.', 5),
  ('poetry_3', 'Bard of the Break Room', 'epic', 'Poetry', 'claims', '["pd_poet_for_a_day", "pd_poetry_critic", "pw_poet_laureate", "gw_poets", "gd_poetry_showdown", "rb_pamphlet"]'::jsonb, 40, 'Claim 40 Poetry quests.', 6),
  ('beer_1', 'Taproom Newcomer', 'common', 'Beer discovery', 'claims', '["pd_beer_scholar", "pd_new_brew", "pd_one_for_the_books", "pw_beer_explorer", "gw_gathering"]'::jsonb, 1, 'Claim 1 Beer discovery quest.', 7),
  ('beer_2', 'Beer Explorer', 'rare', 'Beer discovery', 'claims', '["pd_beer_scholar", "pd_new_brew", "pd_one_for_the_books", "pw_beer_explorer", "gw_gathering"]'::jsonb, 10, 'Claim 10 Beer discovery quests.', 8),
  ('beer_3', 'Guide of the Taproom', 'epic', 'Beer discovery', 'claims', '["pd_beer_scholar", "pd_new_brew", "pd_one_for_the_books", "pw_beer_explorer", "gw_gathering"]'::jsonb, 40, 'Claim 40 Beer discovery quests.', 9),
  ('battle_1', 'Arena Regular', 'common', 'Battles', 'claims', '["pd_pick_a_side", "pw_battle_hardened", "rb_storm", "rb_seeds"]'::jsonb, 1, 'Claim 1 Battles quest.', 10),
  ('battle_2', 'Battle Hardened', 'rare', 'Battles', 'claims', '["pd_pick_a_side", "pw_battle_hardened", "rb_storm", "rb_seeds"]'::jsonb, 8, 'Claim 8 Battles quests.', 11),
  ('battle_3', 'Champion of the Arena', 'epic', 'Battles', 'claims', '["pd_pick_a_side", "pw_battle_hardened", "rb_storm", "rb_seeds"]'::jsonb, 30, 'Claim 30 Battles quests.', 12),
  ('chaos_1', 'Troublemaker', 'common', 'Chaos', 'claims', '["pd_royal_decree", "pd_draw_this", "pd_office_safari", "pd_the_impostor", "pd_emoji_lore", "pd_five_seconds", "pd_the_photographer", "pd_tiny_quest", "pw_agent_of_chaos", "gd_daily_chaos", "gd_emoji_showdown"]'::jsonb, 1, 'Claim 1 Chaos quest.', 13),
  ('chaos_2', 'Agent of Chaos', 'rare', 'Chaos', 'claims', '["pd_royal_decree", "pd_draw_this", "pd_office_safari", "pd_the_impostor", "pd_emoji_lore", "pd_five_seconds", "pd_the_photographer", "pd_tiny_quest", "pw_agent_of_chaos", "gd_daily_chaos", "gd_emoji_showdown"]'::jsonb, 10, 'Claim 10 Chaos quests.', 14),
  ('chaos_3', 'Lord of Misrule', 'epic', 'Chaos', 'claims', '["pd_royal_decree", "pd_draw_this", "pd_office_safari", "pd_the_impostor", "pd_emoji_lore", "pd_five_seconds", "pd_the_photographer", "pd_tiny_quest", "pw_agent_of_chaos", "gd_daily_chaos", "gd_emoji_showdown"]'::jsonb, 40, 'Claim 40 Chaos quests.', 15),
  ('quiz_1', 'Quiz Taker', 'common', 'Quizzes', 'claims', '["pd_lore_master", "pd_perfect_score", "pd_know_thy_friends", "pw_keeper_knowledge", "gw_council", "gd_lore_quiz"]'::jsonb, 1, 'Claim 1 Quizzes quest.', 16),
  ('quiz_2', 'Know-It-All', 'rare', 'Quizzes', 'claims', '["pd_lore_master", "pd_perfect_score", "pd_know_thy_friends", "pw_keeper_knowledge", "gw_council", "gd_lore_quiz"]'::jsonb, 8, 'Claim 8 Quizzes quests.', 17),
  ('quiz_3', 'Quiz Master', 'epic', 'Quizzes', 'claims', '["pd_lore_master", "pd_perfect_score", "pd_know_thy_friends", "pw_keeper_knowledge", "gw_council", "gd_lore_quiz"]'::jsonb, 30, 'Claim 30 Quizzes quests.', 18),
  ('rebel_1', 'Whisperer of Dissent', 'common', 'Rebellion', 'claims', '["rb_seeds", "rb_pamphlet", "rb_storm"]'::jsonb, 1, 'Claim 1 Rebellion quest.', 19),
  ('rebel_2', 'Rebel Leader', 'rare', 'Rebellion', 'claims', '["rb_seeds", "rb_pamphlet", "rb_storm"]'::jsonb, 5, 'Claim 5 Rebellion quests.', 20),
  ('rebel_3', 'Voice of the People', 'epic', 'Rebellion', 'claims', '["rb_seeds", "rb_pamphlet", "rb_storm"]'::jsonb, 15, 'Claim 15 Rebellion quests.', 21),
  ('gdaily_1', 'Team Player', 'common', 'Group Daily', 'claims', '["gd_nickname_of_the_day", "gd_poetry_showdown", "gd_emoji_showdown", "gd_daily_chaos", "gd_lore_quiz"]'::jsonb, 1, 'Claim 1 Group Daily quest.', 22),
  ('gdaily_2', 'Daily Companion', 'rare', 'Group Daily', 'claims', '["gd_nickname_of_the_day", "gd_poetry_showdown", "gd_emoji_showdown", "gd_daily_chaos", "gd_lore_quiz"]'::jsonb, 15, 'Claim 15 Group Daily quests.', 23),
  ('gdaily_3', 'Heart of the Office', 'epic', 'Group Daily', 'claims', '["gd_nickname_of_the_day", "gd_poetry_showdown", "gd_emoji_showdown", "gd_daily_chaos", "gd_lore_quiz"]'::jsonb, 50, 'Claim 50 Group Daily quests.', 24),
  ('gweekly_1', 'Fellow', 'common', 'Group Quests', 'claims', '["gw_fellowship", "gw_gathering", "gw_poets", "gw_nickname_factory", "gw_council"]'::jsonb, 1, 'Claim 1 Group Quests quest.', 25),
  ('gweekly_2', 'Fellowship Member', 'rare', 'Group Quests', 'claims', '["gw_fellowship", "gw_gathering", "gw_poets", "gw_nickname_factory", "gw_council"]'::jsonb, 8, 'Claim 8 Group Quests quests.', 26),
  ('gweekly_3', 'Pillar of the Office', 'epic', 'Group Quests', 'claims', '["gw_fellowship", "gw_gathering", "gw_poets", "gw_nickname_factory", "gw_council"]'::jsonb, 25, 'Claim 25 Group Quests quests.', 27),
  ('adv_1', 'Day Tripper', 'common', 'The Adventurer', 'claims', '["pw_adventurer"]'::jsonb, 1, 'Claim 1 The Adventurer quest.', 28),
  ('adv_2', 'The Adventurer', 'rare', 'The Adventurer', 'claims', '["pw_adventurer"]'::jsonb, 5, 'Claim 5 The Adventurer quests.', 29),
  ('adv_3', 'Wayfarer of Office Lore', 'epic', 'The Adventurer', 'claims', '["pw_adventurer"]'::jsonb, 15, 'Claim 15 The Adventurer quests.', 30),
  ('comp_1', 'Star Collector', 'common', 'The Completionist', 'claims', '["pw_completionist"]'::jsonb, 1, 'Claim 1 The Completionist quest.', 31),
  ('comp_2', 'The Completionist', 'rare', 'The Completionist', 'claims', '["pw_completionist"]'::jsonb, 3, 'Claim 3 The Completionist quests.', 32),
  ('comp_3', 'Hall of Famer', 'epic', 'The Completionist', 'claims', '["pw_completionist"]'::jsonb, 10, 'Claim 10 The Completionist quests.', 33),
  ('social_1', 'Social Butterfly', 'common', 'Social Creature', 'claims', '["pw_social_creature"]'::jsonb, 1, 'Claim 1 Social Creature quest.', 34),
  ('social_2', 'Social Creature', 'rare', 'Social Creature', 'claims', '["pw_social_creature"]'::jsonb, 5, 'Claim 5 Social Creature quests.', 35),
  ('social_3', 'Office Celebrity', 'epic', 'Social Creature', 'claims', '["pw_social_creature"]'::jsonb, 15, 'Claim 15 Social Creature quests.', 36),
  ('dailies_1', 'Quest Taker', 'common', 'All Dailies', 'claims', '["pd_name_thy_victim", "pd_lore_keeper", "pd_quote_hunter", "pd_the_critic", "pd_pick_a_side", "pd_poet_for_a_day", "pd_poetry_critic", "pd_beer_scholar", "pd_new_brew", "pd_one_for_the_books", "pd_lore_master", "pd_perfect_score", "pd_know_thy_friends", "pd_office_oracle", "pd_memory_lane", "pd_royal_decree", "pd_draw_this", "pd_office_safari", "pd_the_impostor", "pd_emoji_lore", "pd_five_seconds", "pd_the_photographer", "pd_tiny_quest"]'::jsonb, 1, 'Claim 1 All Dailies quest.', 37),
  ('dailies_2', 'Daily Regular', 'rare', 'All Dailies', 'claims', '["pd_name_thy_victim", "pd_lore_keeper", "pd_quote_hunter", "pd_the_critic", "pd_pick_a_side", "pd_poet_for_a_day", "pd_poetry_critic", "pd_beer_scholar", "pd_new_brew", "pd_one_for_the_books", "pd_lore_master", "pd_perfect_score", "pd_know_thy_friends", "pd_office_oracle", "pd_memory_lane", "pd_royal_decree", "pd_draw_this", "pd_office_safari", "pd_the_impostor", "pd_emoji_lore", "pd_five_seconds", "pd_the_photographer", "pd_tiny_quest"]'::jsonb, 25, 'Claim 25 All Dailies quests.', 38),
  ('dailies_3', 'Daily Devotee', 'epic', 'All Dailies', 'claims', '["pd_name_thy_victim", "pd_lore_keeper", "pd_quote_hunter", "pd_the_critic", "pd_pick_a_side", "pd_poet_for_a_day", "pd_poetry_critic", "pd_beer_scholar", "pd_new_brew", "pd_one_for_the_books", "pd_lore_master", "pd_perfect_score", "pd_know_thy_friends", "pd_office_oracle", "pd_memory_lane", "pd_royal_decree", "pd_draw_this", "pd_office_safari", "pd_the_impostor", "pd_emoji_lore", "pd_five_seconds", "pd_the_photographer", "pd_tiny_quest"]'::jsonb, 100, 'Claim 100 All Dailies quests.', 39),
  ('dailies_4', 'Centurion of Quests', 'legendary', 'All Dailies', 'claims', '["pd_name_thy_victim", "pd_lore_keeper", "pd_quote_hunter", "pd_the_critic", "pd_pick_a_side", "pd_poet_for_a_day", "pd_poetry_critic", "pd_beer_scholar", "pd_new_brew", "pd_one_for_the_books", "pd_lore_master", "pd_perfect_score", "pd_know_thy_friends", "pd_office_oracle", "pd_memory_lane", "pd_royal_decree", "pd_draw_this", "pd_office_safari", "pd_the_impostor", "pd_emoji_lore", "pd_five_seconds", "pd_the_photographer", "pd_tiny_quest"]'::jsonb, 250, 'Claim 250 All Dailies quests.', 40),
  ('weeklies_1', 'Week Winner', 'common', 'All Weeklies', 'claims', '["pw_lorekeeper", "pw_beer_explorer", "pw_poet_laureate", "pw_battle_hardened", "pw_keeper_knowledge", "pw_agent_of_chaos", "pw_social_creature", "pw_adventurer", "pw_completionist"]'::jsonb, 1, 'Claim 1 All Weeklies quest.', 41),
  ('weeklies_2', 'Weekly Warrior', 'rare', 'All Weeklies', 'claims', '["pw_lorekeeper", "pw_beer_explorer", "pw_poet_laureate", "pw_battle_hardened", "pw_keeper_knowledge", "pw_agent_of_chaos", "pw_social_creature", "pw_adventurer", "pw_completionist"]'::jsonb, 10, 'Claim 10 All Weeklies quests.', 42),
  ('weeklies_3', 'Marathoner', 'epic', 'All Weeklies', 'claims', '["pw_lorekeeper", "pw_beer_explorer", "pw_poet_laureate", "pw_battle_hardened", "pw_keeper_knowledge", "pw_agent_of_chaos", "pw_social_creature", "pw_adventurer", "pw_completionist"]'::jsonb, 40, 'Claim 40 All Weeklies quests.', 43),
  ('sweep_1', 'Clean Sweep', 'common', 'Daily Sweeps', 'sweeps', '[]'::jsonb, 1, 'Claim 1 Daily Sweep.', 44),
  ('sweep_2', 'Sweep Specialist', 'rare', 'Daily Sweeps', 'sweeps', '[]'::jsonb, 10, 'Claim 10 Daily Sweeps.', 45),
  ('sweep_3', 'Sweep Champion', 'epic', 'Daily Sweeps', 'sweeps', '[]'::jsonb, 30, 'Claim 30 Daily Sweeps.', 46),
  ('box_1', 'Box Opener', 'common', 'Mystery Boxes', 'boxes', '[]'::jsonb, 1, 'Open 1 Mystery Reward.', 47),
  ('box_2', 'Treasure Hunter', 'rare', 'Mystery Boxes', 'boxes', '[]'::jsonb, 25, 'Open 25 Mystery Rewards.', 48),
  ('box_3', 'Hoarder of Mysteries', 'epic', 'Mystery Boxes', 'boxes', '[]'::jsonb, 100, 'Open 100 Mystery Rewards.', 49),
  ('drop_coffeeconnoisseur', 'Coffee Connoisseur', 'common', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 50),
  ('drop_replyallsurvivor', 'Reply-All Survivor', 'common', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 51),
  ('drop_printerwhisperer', 'Printer Whisperer', 'common', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 52),
  ('drop_meetingghost', 'Meeting Ghost', 'common', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 53),
  ('drop_biscuitthief', 'Biscuit Thief', 'common', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 54),
  ('drop_deskplantparent', 'Desk Plant Parent', 'common', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 55),
  ('drop_keeperofthelastbiscuit', 'Keeper of the Last Biscuit', 'rare', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 56),
  ('drop_fridgebandit', 'Fridge Bandit', 'rare', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 57),
  ('drop_staplerduke', 'Stapler Duke', 'rare', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 58),
  ('drop_wifiwizard', 'Wi-Fi Wizard', 'rare', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 59),
  ('drop_ministerofsmalltalk', 'Minister of Small Talk', 'rare', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 60),
  ('drop_officelegend', 'Office Legend', 'epic', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 61),
  ('drop_guardianofthegoodchairs', 'Guardian of the Good Chairs', 'epic', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 62),
  ('drop_theonewhoknowsthewifipas', 'The One Who Knows the Wi-Fi Password', 'legendary', 'Mystery find', 'drop', '[]'::jsonb, null, 'Found in a Mystery Reward.', 63)
on conflict (id) do update set text = excluded.text, rarity = excluded.rarity, family = excluded.family, unlock_kind = excluded.unlock_kind,
  defs = excluded.defs, threshold = excluded.threshold, hint = excluded.hint, sort_order = excluded.sort_order, is_active = true;

-- the grant: called inside the claims / the box opening, never from a client
create or replace function public._grant_titles(p_user uuid, p_kind text, p_def text)
returns jsonb as $$
declare
  t public.character_titles;
  v_count int;
  v_out jsonb := '[]'::jsonb;
begin
  v_count := case p_kind
    when 'sweeps' then (select count(*) from public.challenge_sweeps s where s.user_id = p_user and s.claimed_at is not null)
    when 'boxes'  then (select count(*) from public.mystery_boxes b where b.user_id = p_user and b.status = 'opened')
    else null end;
  for t in select * from public.character_titles where is_active and unlock_kind = p_kind order by sort_order loop
    continue when exists (select 1 from public.user_character_titles u where u.user_id = p_user and u.title_id = t.id);
    if p_kind = 'claims' then
      continue when p_def is null or not (t.defs ? p_def);
      select count(*) into v_count from public.challenge_claims c join public.challenge_assignments a on a.id = c.assignment_id
        where c.user_id = p_user and t.defs ? a.definition_id;
    end if;
    if v_count >= t.threshold then
      insert into public.user_character_titles (user_id, title_id, source) values (p_user, t.id, p_kind) on conflict do nothing;
      if found then v_out := v_out || jsonb_build_object('id', t.id, 'text', t.text, 'rarity', t.rarity); end if;
    end if;
  end loop;
  return v_out;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.set_room_title(p_title_id text)
returns jsonb as $$
declare
  v_loadout jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_title_id is not null and not exists (
       select 1 from public.user_character_titles u join public.character_titles t on t.id = u.title_id
       where u.user_id = auth.uid() and u.title_id = p_title_id and t.is_active) then
    raise exception 'You have not earned this title yet';
  end if;
  insert into public.room_profiles (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select loadout into v_loadout from public.room_profiles where user_id = auth.uid() for update;
  v_loadout := coalesce(v_loadout, '{}'::jsonb) - 'title';
  if p_title_id is not null then v_loadout := v_loadout || jsonb_build_object('title', p_title_id); end if;
  update public.room_profiles set loadout = v_loadout where user_id = auth.uid();
  return v_loadout;
end;
$$ language plpgsql security definer set search_path = public;

-- Mystery boxes may now contain a title (for the Abt Lord next to cosmetics, for everybody else instead of them)
update public.challenge_config
  set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes,title}', '30'::jsonb, true), '{pools,sweep,outcomes,title}', '25'::jsonb, true)
  where key = 'mystery_rewards' and not (value->'pools'->'default'->'outcomes' ? 'title');

-- claiming and opening now report the titles they earn
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
    'titles', public._grant_titles(auth.uid(), 'claims', a.definition_id));
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
  return jsonb_build_object('status', 'claimed', 'results', v_results, 'titles', public._grant_titles(auth.uid(), 'sweeps', null));
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

revoke all on function public._grant_titles(uuid, text, text) from public, anon, authenticated;
revoke all on function public.set_room_title(text) from public, anon;
grant execute on function public.set_room_title(text) to authenticated;
revoke all on function public.claim_daily_sweep(uuid) from public, anon;
grant execute on function public.claim_daily_sweep(uuid) to authenticated;
revoke all on function public.open_mystery_box(uuid) from public, anon;
grant execute on function public.open_mystery_box(uuid) to authenticated;
