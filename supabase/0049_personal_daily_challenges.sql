-- =================================================================
-- OFFICE LORE — ☀️ PERSONAL DAILY CHALLENGES (the real pool)
-- =================================================================
-- Builds on the Challenge Engine (0048).
--
-- EVERY USER, EVERY DAY: 3 Personal Daily Challenges
--   * picked pseudo-randomly but DETERMINISTICALLY per (user, day), so a refresh
--     or a second tab sees the same three
--   * VARIETY: three different categories whenever the pool allows, at most one
--     'hard', and yesterday's exact challenges are avoided where there is an
--     alternative (three passes: strict -> relax the category rule -> relax all)
--   * FEASIBLE: a definition is only assignable when the app can actually let
--     the user do it right now (see _challenge_available): "Pick a side" needs an
--     open battle the user has not voted in, "Beer scholar" needs a beer the
--     user has not rated yet, "Lore keeper" needs a nickname without anecdote,
--     "Memory lane" needs old content, "The critic" needs 3 nicknames, ...
--   * FEATURE FLAGS: the three quiz challenges and the prediction challenge
--     need features that do not exist yet. They are defined and ready, but stay
--     unassignable until `challenge_features` says enabled = true.
--   * NOT included, by request: anything about the Interior Designer, room,
--     outfits or companions (only the Abt Lord can dress the Abt Avatar).
--   * Beer challenges are about ratings, discovery, data and sessions. Nothing
--     counts or rewards how much anyone drinks.
--
-- REWARDS are central config, not magic numbers in code (table challenge_config):
--   difficulty_rewards: easy / normal / hard / special -> reward lines
--   daily_sweep: the 3/3 bonus
--   A reward line may carry "chance" (0..1): it is rolled ONCE, at claim time,
--   inside the idempotent claim, and the roll is recorded ('missed' when it
--   misses), so a refresh can never re-roll it.
--
-- 🎁 DAILY SWEEP: when all 3 Personal Dailies of a day are complete, one
-- challenge_sweeps row appears for (user, day) (unique, so at most once a day),
-- claimable once: bonus Player XP + 1 Mystery Reward.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0048.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
alter table public.challenge_definitions
  add column if not exists icon text,
  add column if not exists requires text,                    -- availability rule, see _challenge_available
  add column if not exists event_types text[],               -- several events may count (default: just event_type)
  add column if not exists reward_from_difficulty boolean not null default false;
alter table public.challenge_assignments
  add column if not exists icon text,
  add column if not exists event_types text[];

-- central configuration
create table if not exists public.challenge_config (
  key text primary key,
  value jsonb not null
);
alter table public.challenge_config enable row level security;
drop policy if exists "Challenge config: read" on public.challenge_config;
create policy "Challenge config: read" on public.challenge_config for select to authenticated using (public.is_app_member('officelore'));

-- switches for challenges that depend on features that may not exist yet
create table if not exists public.challenge_features (
  key text primary key,
  enabled boolean not null default false,
  note text
);
alter table public.challenge_features enable row level security;
drop policy if exists "Challenge features: read" on public.challenge_features;
create policy "Challenge features: read" on public.challenge_features for select to authenticated using (public.is_app_member('officelore'));
insert into public.challenge_features (key, enabled, note) values
  ('quiz', false, 'Office Lore Quiz: the three quiz Dailies stay unassigned until a standalone quiz exists and this is set to true'),
  ('prediction', false, 'Prediction system: the Office Oracle Daily stays unassigned until it exists')
on conflict (key) do nothing;

insert into public.challenge_config (key, value) values
  ('difficulty_rewards', '{
      "easy":    [ {"kind":"player_xp","amount":10} ],
      "normal":  [ {"kind":"player_xp","amount":18}, {"kind":"mystery","amount":1,"chance":0.15} ],
      "hard":    [ {"kind":"player_xp","amount":30}, {"kind":"gauntlet_fragments","amount":1,"chance":0.5} ],
      "special": [ {"kind":"player_xp","amount":40}, {"kind":"gauntlet_fragments","amount":1} ]
   }'::jsonb),
  ('daily_sweep', '{"lines":[ {"kind":"player_xp","amount":25}, {"kind":"mystery","amount":1} ]}'::jsonb)
on conflict (key) do nothing;

-- the Daily Sweep, one per user per day
create table if not exists public.challenge_sweeps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  period_key text not null,
  reward jsonb not null,
  completed_at timestamptz not null default now(),
  claimed_at timestamptz,
  unique (user_id, period_key)
);
alter table public.challenge_sweeps enable row level security;
drop policy if exists "Challenge sweeps: read own" on public.challenge_sweeps;
create policy "Challenge sweeps: read own" on public.challenge_sweeps for select to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));
do $$
begin
  begin
    alter publication supabase_realtime add table public.challenge_sweeps;
  exception when duplicate_object then null;
  end;
end $$;

-- the reward ledger can now belong to a Sweep, and can record a missed roll
alter table public.challenge_reward_grants alter column assignment_id drop not null;
alter table public.challenge_reward_grants add column if not exists sweep_id uuid references public.challenge_sweeps(id) on delete cascade;
create unique index if not exists challenge_grants_sweep_line on public.challenge_reward_grants (sweep_id, user_id, line_no) where sweep_id is not null;
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.challenge_reward_grants'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%status%';
  if v_name is not null then execute format('alter table public.challenge_reward_grants drop constraint %I', v_name); end if;
end $$;
alter table public.challenge_reward_grants add constraint challenge_reward_grants_status_check check (status in ('applied', 'pending', 'missed'));
alter table public.challenge_reward_grants drop constraint if exists challenge_reward_grants_owner_check;
alter table public.challenge_reward_grants add constraint challenge_reward_grants_owner_check check (assignment_id is not null or sweep_id is not null);

-- =================================================================
-- SECTION 2 — config helpers + availability
-- =================================================================
create or replace function public._challenge_config(p_key text, p_default jsonb)
returns jsonb as $$
  select coalesce((select value from public.challenge_config where key = p_key), p_default);
$$ language sql stable security definer set search_path = public;

create or replace function public._difficulty_reward(p_difficulty text)
returns jsonb as $$
  select jsonb_build_object('lines', coalesce(public._challenge_config('difficulty_rewards', '{}'::jsonb) -> p_difficulty, '[]'::jsonb));
$$ language sql stable security definer set search_path = public;

-- can this user actually DO this challenge today?
create or replace function public._challenge_available(d public.challenge_definitions, p_user uuid)
returns boolean as $$
begin
  if d.requires is null then return true; end if;
  return case d.requires
    -- an open battle the user has not voted in yet
    when 'open_battle' then exists (
      select 1 from public.nickname_battles b
      where b.status = 'open'
        and not exists (select 1 from public.nickname_battle_votes v where v.battle_id = b.id and v.user_id = p_user))
    -- a beer the user has never personally rated
    when 'unrated_beer' then exists (
      select 1 from public.beers b
      where not exists (select 1 from public.beer_ratings r where r.beer_id = b.id and r.user_id = p_user and r.rating is not null))
    -- a nickname that still has no anecdote (anyone may add one)
    when 'anecdote_target' then exists (select 1 from public.nicknames n where coalesce(btrim(n.anecdote), '') = '')
    -- content older than a week to revisit
    when 'old_content' then exists (select 1 from public.poems p where p.created_at < now() - interval '7 days')
                         or exists (select 1 from public.nicknames n where n.created_at < now() - interval '7 days')
    when 'nicknames_3' then (select count(*) from public.nicknames) >= 3
    when 'poems_2' then (select count(*) from public.poems) >= 2
    -- everything else is a feature flag
    else coalesce((select f.enabled from public.challenge_features f where f.key = d.requires), false)
  end;
end;
$$ language plpgsql stable security definer set search_path = public;

-- =================================================================
-- SECTION 3 — the engine (replaces 0048's): several event types, the Daily Sweep
-- =================================================================
create or replace function public._challenge_event(
  p_user uuid, p_event text, p_amount int default 1, p_dedupe text default null,
  p_meta jsonb default '{}'::jsonb, p_source text default null)
returns void as $$
declare
  a record;
  v_add int;
  v_done boolean;
  v_complete int;
begin
  if p_user is null or p_amount is null or p_amount <= 0 then return; end if;
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return;
  end if;

  insert into public.challenge_events (app_id, user_id, event_type, amount, dedupe_key, source_key, meta)
    values ('officelore', p_user, p_event, p_amount, p_dedupe, p_source, coalesce(p_meta, '{}'::jsonb))
    on conflict (source_key) where source_key is not null do nothing;
  if not found then return; end if;

  for a in
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements, asg.period_key
    from public.challenge_assignments asg
    where asg.app_id = 'officelore' and asg.status = 'active'
      and p_event = any (coalesce(asg.event_types, array[asg.event_type]))
      and asg.starts_at <= now() and asg.expires_at > now()
      and (asg.user_id = p_user or asg.user_id is null)
    order by asg.id
    for update
  loop
    continue when not public._challenge_requirements_met(a.requirements, p_meta);
    if p_dedupe is not null then
      insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, p_dedupe)
        on conflict do nothing;
      continue when not found;
    end if;
    v_add := least(p_amount, a.target - a.progress);
    continue when v_add <= 0;
    v_done := a.progress + v_add >= a.target;
    update public.challenge_assignments
      set progress = progress + v_add,
          status = case when v_done then 'completed' else status end,
          completed_at = case when v_done then now() else completed_at end
      where id = a.id;
    if a.user_id is null then
      insert into public.challenge_contributions (assignment_id, user_id, amount) values (a.id, p_user, v_add)
        on conflict (assignment_id, user_id) do update set amount = public.challenge_contributions.amount + excluded.amount;
    end if;
    if v_done and a.type = 'personal_daily' then
      perform public._challenge_event(p_user, 'daily_completed', 1, a.id::text, '{}'::jsonb, 'daily_completed:' || a.id::text);
      -- 🎁 DAILY SWEEP: every Personal Daily of that day is complete (the unique key makes it once a day)
      select count(*) into v_complete from public.challenge_assignments x
        where x.app_id = 'officelore' and x.user_id = a.user_id and x.type = 'personal_daily'
          and x.period_key = a.period_key and x.status in ('completed', 'claimed');
      if v_complete >= public._challenge_slots('personal_daily') then
        insert into public.challenge_sweeps (user_id, period_key, reward)
          values (a.user_id, a.period_key, public._challenge_config('daily_sweep', '{"lines":[]}'::jsonb))
          on conflict (user_id, period_key) do nothing;
      end if;
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — generation with variety
-- =================================================================
-- picks p_missing Personal Daily definitions for the user and day
create or replace function public._pick_personal_dailies(p_user uuid, p_key text, p_prev_key text, p_lord uuid, p_missing int)
returns text[] as $$
declare
  v_list jsonb;
  v_chosen text[] := '{}';
  v_cats text[];
  v_hard int;
  el jsonb;
  v_pass int;
begin
  -- what the user already has today (generation can be partial)
  select coalesce(array_agg(category), '{}'), count(*) filter (where difficulty = 'hard')
    into v_cats, v_hard
    from public.challenge_assignments
    where app_id = 'officelore' and user_id = p_user and type = 'personal_daily' and period_key = p_key;

  -- every definition that is assignable right now; yesterday's last, then a stable per-user shuffle
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'cat', d.category, 'diff', d.difficulty)
           order by (exists (select 1 from public.challenge_assignments y
                             where y.app_id = 'officelore' and y.user_id = p_user and y.period_key = p_prev_key and y.definition_id = d.id)),
                    md5(d.id || p_user::text || p_key)), '[]'::jsonb)
    into v_list
    from public.challenge_definitions d
    where d.app_id = 'officelore' and d.is_active and d.type = 'personal_daily'
      and (d.audience = 'everyone'
           or (d.audience = 'non_lord' and p_user is distinct from p_lord)
           or (d.audience = 'lord' and p_user is not distinct from p_lord))
      and public._challenge_available(d, p_user)
      and not exists (select 1 from public.challenge_assignments x
                      where x.app_id = 'officelore' and x.user_id = p_user and x.period_key = p_key and x.definition_id = d.id);

  for v_pass in 1..3 loop
    for el in select * from jsonb_array_elements(v_list) loop
      exit when cardinality(v_chosen) >= p_missing;
      continue when (el->>'id') = any (v_chosen);
      if v_pass = 1 and ((el->>'cat') = any (v_cats) or ((el->>'diff') = 'hard' and v_hard >= 1)) then continue; end if;   -- strict: new category, one hard at most
      if v_pass = 2 and ((el->>'diff') = 'hard' and v_hard >= 1) then continue; end if;                                    -- relax the category rule
      v_chosen := v_chosen || (el->>'id');
      v_cats := v_cats || (el->>'cat');
      if (el->>'diff') = 'hard' then v_hard := v_hard + 1; end if;
    end loop;
  end loop;
  return v_chosen;
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public._ensure_challenge_assignments_for(p_user uuid, p_at timestamptz)
returns int as $$
declare
  v_tz text := public._challenge_tz();
  v_local timestamp := p_at at time zone v_tz;
  v_day_start timestamptz := date_trunc('day', v_local) at time zone v_tz;
  v_day_end timestamptz := (date_trunc('day', v_local) + interval '1 day') at time zone v_tz;
  v_wk_start timestamptz := date_trunc('week', v_local) at time zone v_tz;
  v_wk_end timestamptz := (date_trunc('week', v_local) + interval '7 days') at time zone v_tz;
  v_day_key text := to_char(v_local, 'YYYY-MM-DD');
  v_prev_key text := to_char(v_local - interval '1 day', 'YYYY-MM-DD');
  v_wk_key text := to_char(v_local, 'IYYY-"W"IW');
  v_lord uuid := (select user_id from public.abt_reigns where ended_at is null limit 1);
  v_type text;
  v_key text; v_from timestamptz; v_to timestamptz;
  v_owner uuid;
  v_have int; v_want int; v_created int := 0; v_n int;
  v_ids text[];
begin
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return 0;
  end if;
  perform pg_advisory_xact_lock(hashtext('challenge_gen:' || p_user::text));

  update public.challenge_assignments set status = 'expired'
    where app_id = 'officelore' and status = 'active' and expires_at <= p_at and (user_id = p_user or user_id is null);

  foreach v_type in array array['personal_daily', 'group_daily', 'personal_weekly', 'group_weekly', 'rebellion'] loop
    if v_type in ('personal_daily', 'group_daily') then v_key := v_day_key; v_from := v_day_start; v_to := v_day_end;
    else v_key := v_wk_key; v_from := v_wk_start; v_to := v_wk_end; end if;
    v_owner := case when v_type in ('group_daily', 'group_weekly') then null else p_user end;
    v_want := public._challenge_slots(v_type);
    if v_owner is null then perform pg_advisory_xact_lock(hashtext('challenge_group:' || v_type || ':' || v_key)); end if;

    select count(*) into v_have from public.challenge_assignments
      where app_id = 'officelore' and type = v_type and period_key = v_key and user_id is not distinct from v_owner;
    continue when v_have >= v_want;

    if v_type = 'personal_daily' then
      v_ids := public._pick_personal_dailies(p_user, v_key, v_prev_key, v_lord, v_want - v_have);
    else
      select coalesce(array_agg(x.id), '{}') into v_ids from (
        select d.id from public.challenge_definitions d
        where d.app_id = 'officelore' and d.is_active and d.type = v_type
          and (d.audience = 'everyone'
               or (d.audience = 'non_lord' and p_user is distinct from v_lord)
               or (d.audience = 'lord' and p_user is not distinct from v_lord))
          and public._challenge_available(d, p_user)
          and not exists (select 1 from public.challenge_assignments x2
                          where x2.app_id = 'officelore' and x2.definition_id = d.id and x2.period_key = v_key and x2.user_id is not distinct from v_owner)
        order by md5(d.id || coalesce(v_owner::text, 'group') || v_key)
        limit v_want - v_have) x;
    end if;
    continue when cardinality(v_ids) = 0;

    insert into public.challenge_assignments
      (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
       target, period_key, starts_at, expires_at)
    select 'officelore', d.id, v_owner, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.event_types, d.icon, d.requirements,
           case when d.reward_from_difficulty then public._difficulty_reward(d.difficulty) else d.reward end,
           d.target, v_key, v_from, v_to
    from public.challenge_definitions d
    where d.id = any (v_ids)
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_created := v_created + v_n;
  end loop;
  return v_created;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — rewards with chance, claims, the sweep
-- =================================================================
-- one reward line. Returns what happened so the UI can tell the player.
create or replace function public._grant_challenge_reward2(p_user uuid, p_assignment uuid, p_sweep uuid, p_line jsonb, p_line_no int)
returns jsonb as $$
declare
  v_kind text := p_line->>'kind';
  v_amount int := coalesce((p_line->>'amount')::int, 0);
  v_chance numeric := coalesce((p_line->>'chance')::numeric, 1);
  v_hit boolean;
  v_status text;
  v_frag int;
  v_per int := public._fragments_per_gauntlet();
begin
  v_hit := v_chance >= 1 or random() < v_chance;     -- rolled once: the grant row below records it
  v_status := case when not v_hit then 'missed'
                   when v_kind in ('player_xp', 'category_xp', 'gauntlet_fragments') then 'applied'
                   else 'pending' end;
  insert into public.challenge_reward_grants (assignment_id, sweep_id, user_id, line_no, kind, amount, category, status)
    values (p_assignment, p_sweep, p_user, p_line_no, v_kind, case when v_hit then v_amount else 0 end, p_line->>'category', v_status)
    on conflict do nothing;
  if not found then
    return jsonb_build_object('kind', v_kind, 'duplicate', true);
  end if;

  if v_hit and v_kind = 'gauntlet_fragments' and v_amount > 0 then
    insert into public.gauntlet_fragments (user_id, fragments) values (p_user, v_amount)
      on conflict (user_id) do update set fragments = public.gauntlet_fragments.fragments + excluded.fragments, updated_at = now()
      returning fragments into v_frag;
    while v_frag >= v_per loop
      update public.gauntlet_fragments set fragments = fragments - v_per, updated_at = now() where user_id = p_user returning fragments into v_frag;
      insert into public.royal_gauntlet_balances (user_id, balance) values (p_user, 1)
        on conflict (user_id) do update set balance = public.royal_gauntlet_balances.balance + 1, updated_at = now();
      insert into public.royal_gauntlet_ledger (user_id, delta, reason, note) values (p_user, 1, 'fragment_convert', v_per || ' fragments');
    end loop;
  end if;
  return jsonb_build_object('kind', v_kind, 'amount', v_amount, 'category', p_line->>'category', 'hit', v_hit, 'chance', v_chance, 'status', v_status);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.claim_challenge(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_line jsonb;
  v_no int := 0;
  v_results jsonb := '[]'::jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if a.status not in ('completed', 'claimed') then raise exception 'This challenge is not complete yet'; end if;
  if a.user_id is not null and a.user_id <> auth.uid() then raise exception 'This is not your challenge'; end if;
  if a.user_id is null and not exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id and c.user_id = auth.uid() and c.amount > 0) then
    raise exception 'Only members who contributed can claim a group reward';
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
  return jsonb_build_object('status', 'claimed', 'results', v_results);
end;
$$ language plpgsql security definer set search_path = public;

-- 🎁 claim the Daily Sweep (once)
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
  return jsonb_build_object('status', 'claimed', 'results', v_results);
end;
$$ language plpgsql security definer set search_path = public;

drop function if exists public._grant_challenge_reward(uuid, uuid, jsonb, int);

-- =================================================================
-- SECTION 6 — richer events from the existing features
-- =================================================================
-- age_days: how old the content was (Memory Lane). first: the user's FIRST rating of that beer (Beer Scholar).
create or replace function public._ch_t_nickname_vote() returns trigger as $$
declare v_age int;
begin
  begin
    select floor(extract(epoch from (now() - created_at)) / 86400)::int into v_age from public.nicknames where id = new.nickname_id;
    perform public._challenge_event(new.user_id, 'nickname_rated', 1, 'nickname:' || new.nickname_id,
      jsonb_build_object('nickname_id', new.nickname_id, 'vote', new.vote_type, 'age_days', coalesce(v_age, 0)), 'nickname_votes:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_nickname_anecdote() returns trigger as $$
begin
  begin
    if coalesce(btrim(old.anecdote), '') = '' and coalesce(btrim(new.anecdote), '') <> '' then
      perform public._challenge_event(coalesce(new.updated_by_user_id, new.created_by_user_id), 'nickname_anecdote_added', 1, null,
        jsonb_build_object('nickname_id', new.id, 'age_days', floor(extract(epoch from (now() - new.created_at)) / 86400)::int),
        'nickname_anecdote:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_poem_reaction() returns trigger as $$
declare v_age int;
begin
  begin
    select floor(extract(epoch from (now() - created_at)) / 86400)::int into v_age from public.poems where id = new.poem_id;
    perform public._challenge_event(new.user_id, 'poem_rated', 1, 'poem:' || new.poem_id,
      jsonb_build_object('poem_id', new.poem_id, 'reaction', new.reaction_type, 'age_days', coalesce(v_age, 0)), 'poem_reactions:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

-- a comment counts like a reaction: "2 DIFFERENT poems" is one poem whichever way you respond
create or replace function public._ch_t_poem_comment() returns trigger as $$
declare v_age int;
begin
  begin
    select floor(extract(epoch from (now() - created_at)) / 86400)::int into v_age from public.poems where id = new.poem_id;
    perform public._challenge_event(new.user_id, 'poem_commented', 1, 'poem:' || new.poem_id,
      jsonb_build_object('poem_id', new.poem_id, 'age_days', coalesce(v_age, 0)), 'poem_comments:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_beer_rating() returns trigger as $$
begin
  begin
    if new.rating is not null then
      perform public._challenge_event(new.user_id, 'beer_rated', 1, 'beer:' || new.beer_id,
        jsonb_build_object('beer_id', new.beer_id, 'rating', new.rating,
          'first', case when exists (select 1 from public.beer_ratings r where r.beer_id = new.beer_id and r.user_id = new.user_id and r.rating is not null and r.id <> new.id) then 0 else 1 end),
        'beer_ratings:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 7 — the Daily pool
-- =================================================================
-- the 0048 sample dailies make way for the real pool (the weekly/group/rebellion samples stay)
update public.challenge_definitions set is_active = false where id in ('d_nick_rate_3', 'd_beer_rate_1', 'd_poem_react_1', 'd_battle_vote_1', 'd_nick_new_1');

insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, event_types, target, requirements, reward_from_difficulty, icon, requires, audience) values
  -- NICKNAME / LORE
  ('pd_name_thy_victim', 'personal_daily', 'nickname', 'Name Thy Victim', 'Add 1 new nickname to the Nickname Wall.', 'normal', 'nickname_created', null, 1, '{}', true, '🏷️', null, 'everyone'),
  ('pd_lore_keeper', 'personal_daily', 'nickname', 'Lore Keeper', 'Add an anecdote to an existing nickname that has none yet.', 'normal', 'nickname_anecdote_added', null, 1, '{}', true, '📖', 'anecdote_target', 'everyone'),
  ('pd_quote_hunter', 'personal_daily', 'lore', 'Quote Hunter', 'Add a quote to the Lore.', 'easy', 'quote_added', null, 1, '{}', true, '💬', null, 'everyone'),
  ('pd_the_critic', 'personal_daily', 'nickname', 'The Critic', 'Rate 3 different nicknames.', 'easy', 'nickname_rated', null, 3, '{}', true, '⭐', 'nicknames_3', 'everyone'),
  ('pd_pick_a_side', 'personal_daily', 'battle', 'Pick a Side', 'Cast your vote in an open Nickname Battle.', 'easy', 'battle_voted', null, 1, '{}', true, '⚔️', 'open_battle', 'everyone'),
  -- POETRY
  ('pd_poet_for_a_day', 'personal_daily', 'poetry', 'Poet for a Day', 'Complete Today''s Poetry Challenge.', 'hard', 'poetry_daily_completed', null, 1, '{}', true, '✍️', null, 'everyone'),
  ('pd_poetry_critic', 'personal_daily', 'poetry', 'Poetry Critic', 'React to, or comment on, 2 different poems.', 'easy', 'poem_rated', array['poem_rated', 'poem_commented'], 2, '{}', true, '❤️', 'poems_2', 'everyone'),
  -- BEER (ratings, discovery, data, sessions: never quantity)
  ('pd_beer_scholar', 'personal_daily', 'beer', 'Beer Scholar', 'Rate a beer you have not rated yet.', 'easy', 'beer_rated', null, 1, '{"min_first": 1}', true, '🍺', 'unrated_beer', 'everyone'),
  ('pd_new_brew', 'personal_daily', 'beer', 'New Brew', 'Add a new beer to the Beer Fridge.', 'normal', 'beer_added', null, 1, '{}', true, '🆕', null, 'everyone'),
  ('pd_one_for_the_books', 'personal_daily', 'beer', 'One for the Books', 'Take part in a Beer Session that gets logged.', 'normal', 'beer_session_participated', null, 1, '{}', true, '🍻', null, 'everyone'),
  -- QUIZ / LORE (waiting for the quiz feature)
  ('pd_lore_master', 'personal_daily', 'quiz', 'Lore Master', 'Complete an Office Lore Quiz.', 'normal', 'quiz_completed', null, 1, '{}', true, '🧠', 'quiz', 'everyone'),
  ('pd_perfect_score', 'personal_daily', 'quiz', 'Perfect Score', 'Score at least 80% on an Office Lore Quiz.', 'hard', 'quiz_completed', null, 1, '{"min_pct": 80}', true, '🎯', 'quiz', 'everyone'),
  ('pd_know_thy_friends', 'personal_daily', 'quiz', 'Know Thy Friends', 'Answer a question about another member.', 'normal', 'quiz_about_friend', null, 1, '{}', true, '👀', 'quiz', 'everyone'),
  -- OTHER
  ('pd_office_oracle', 'personal_daily', 'social', 'Office Oracle', 'Make one prediction.', 'easy', 'prediction_created', null, 1, '{}', true, '🔮', 'prediction', 'everyone'),
  -- MEMORY LANE counts: reacting to or commenting on a poem that is more than a week old, reacting to a nickname more than a week old, or adding an anecdote to a nickname more than a week old
  ('pd_memory_lane', 'personal_daily', 'lore', 'Memory Lane', 'Revisit old content: react to or comment on a poem, or react to a nickname, or add a story to a nickname, that is more than a week old.', 'normal',
     'poem_rated', array['poem_rated', 'poem_commented', 'nickname_rated', 'nickname_anecdote_added'], 1, '{"min_age_days": 7}', true, '📚', 'old_content', 'everyone')
on conflict (id) do update set
  type = excluded.type, category = excluded.category, title = excluded.title, description = excluded.description, difficulty = excluded.difficulty,
  event_type = excluded.event_type, event_types = excluded.event_types, target = excluded.target, requirements = excluded.requirements,
  reward_from_difficulty = excluded.reward_from_difficulty, icon = excluded.icon, requires = excluded.requires, audience = excluded.audience, is_active = true;

-- =================================================================
-- SECTION 8 — grants
-- =================================================================
revoke all on function public._challenge_config(text, jsonb) from public, anon, authenticated;
revoke all on function public._difficulty_reward(text) from public, anon, authenticated;
revoke all on function public._challenge_available(public.challenge_definitions, uuid) from public, anon, authenticated;
revoke all on function public._pick_personal_dailies(uuid, text, text, uuid, int) from public, anon, authenticated;
revoke all on function public._grant_challenge_reward2(uuid, uuid, uuid, jsonb, int) from public, anon, authenticated;
revoke all on function public._challenge_event(uuid, text, int, text, jsonb, text) from public, anon, authenticated;
revoke all on function public._ensure_challenge_assignments_for(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.claim_challenge(uuid) from public, anon;
revoke all on function public.claim_daily_sweep(uuid) from public, anon;
grant execute on function public.claim_challenge(uuid) to authenticated;
grant execute on function public.claim_daily_sweep(uuid) to authenticated;
