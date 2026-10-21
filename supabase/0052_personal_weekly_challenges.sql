-- =================================================================
-- OFFICE LORE — 📅 PERSONAL WEEKLY CHALLENGES
-- =================================================================
-- Every member gets a small set per ISO week (Monday 00:00 to Monday 00:00,
-- Europe/Brussels): by default 2 NORMAL weeklies + 1 BIG/mixed one
-- (challenge_config.weekly_slots). The pool:
--
--   NORMAL                                           BIG / MIXED
--   🏷️ The Lorekeeper    2 contributions, 2 anecdotes/quotes, 3 ratings    🌍 Social Creature   3 different app categories
--   🍺 Beer Explorer     2 DIFFERENT beer activities (no volume)           🧭 The Adventurer    5 DIFFERENT Personal Dailies
--   ✍️ Poet Laureate     3 poem activities                                 🏆 The Completionist 5 different categories
--   ⚔️ Battle Hardened   3 battles (a win gives 1 bonus step, once)
--   🧠 Keeper of Knowledge 3 quizzes averaging >= 70%  (needs the quiz switch)
--   🎭 Agent of Chaos    3 Chaos challenges
--
-- NEW IN THE ENGINE (all generic, all data-driven)
--   * parts       a challenge made of several counters, each with its own events and
--                 target (the Lorekeeper); optional per-event cap (a win counts once) and
--                 optional average rule (Keeper of Knowledge)
--   * distinct_by a challenge that counts DIFFERENT values: different Dailies, different
--                 categories, different beer activity types
--   * the 'activity' event: every real event that belongs to an app category
--                 (challenge_event_categories) also emits one 'activity' with its category
--   * weekly_slots / weekly_rewards / weekly_consolation in challenge_config
--
-- PROGRESS is persistent for the whole week: the assignment row is the memory.
--
-- EXPIRY. When the week ends the challenge closes. An unfinished weekly pays
-- NO full reward and NEVER a Gauntlet Fragment. Above 50% (configurable) it
-- offers a small CONSOLATION in Player XP, claimable once. Nothing else.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0051.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema and config
-- =================================================================
alter table public.challenge_definitions
  add column if not exists weekly_tier text check (weekly_tier in ('normal', 'big')),
  add column if not exists parts jsonb,
  add column if not exists distinct_by text,
  add column if not exists unit text;
alter table public.challenge_assignments
  add column if not exists parts jsonb,
  add column if not exists part_progress jsonb not null default '{}',
  add column if not exists distinct_by text,
  add column if not exists unit text;

create table if not exists public.challenge_event_categories (
  event_type text primary key,
  category text not null
);
alter table public.challenge_event_categories enable row level security;   -- server-side only
insert into public.challenge_event_categories (event_type, category) values
  ('nickname_created', 'nickname'), ('nickname_rated', 'nickname'), ('nickname_anecdote_added', 'nickname'),
  ('quote_added', 'lore'), ('anecdote_added', 'lore'),
  ('poem_created', 'poetry'), ('poem_rated', 'poetry'), ('poem_commented', 'poetry'),
  ('beer_added', 'beer'), ('beer_rated', 'beer'), ('beer_session_participated', 'beer'), ('perfect_pour', 'beer'), ('perfect_pour_given', 'beer'),
  ('battle_created', 'battle'), ('battle_voted', 'battle'),
  ('quiz_completed', 'quiz'),
  ('chaos_completed', 'chaos'), ('chaos_guess', 'chaos'),
  ('group_entry', 'social')
on conflict (event_type) do nothing;

insert into public.challenge_config (key, value) values
  ('weekly_slots', '{"normal": 2, "big": 1}'::jsonb),
  ('weekly_consolation', '{"min_pct": 0.5, "normal": [{"kind":"player_xp","amount":5}], "big": [{"kind":"player_xp","amount":10}]}'::jsonb),
  ('weekly_rewards', '{
      "pw_lorekeeper":       [ {"kind":"player_xp","amount":40}, {"kind":"gauntlet_fragments","amount":2} ],
      "pw_beer_explorer":    [ {"kind":"player_xp","amount":30}, {"kind":"mystery","amount":1,"chance":0.35} ],
      "pw_poet_laureate":    [ {"kind":"player_xp","amount":35}, {"kind":"gauntlet_fragments","amount":2} ],
      "pw_battle_hardened":  [ {"kind":"player_xp","amount":35}, {"kind":"mystery","amount":1,"chance":0.25} ],
      "pw_keeper_knowledge": [ {"kind":"player_xp","amount":40}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "pw_agent_of_chaos":   [ {"kind":"player_xp","amount":35}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "pw_social_creature":  [ {"kind":"player_xp","amount":45}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "pw_adventurer":       [ {"kind":"player_xp","amount":50}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "pw_completionist":    [ {"kind":"player_xp","amount":90}, {"kind":"gauntlet_fragments","amount":3}, {"kind":"mystery","amount":1,"chance":0.50} ]
   }'::jsonb)
on conflict (key) do nothing;

-- =================================================================
-- SECTION 2 — slots, rewards, availability, snapshots
-- =================================================================
create or replace function public._challenge_slots(p_type text) returns int as $$
  select case p_type
    when 'personal_daily' then 3 when 'group_daily' then 1
    when 'personal_weekly' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'normal')::int, 2) + coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'big')::int, 1)
    when 'group_weekly' then 1 when 'rebellion' then 1 else 0 end;
$$ language sql stable security definer set search_path = public;

create or replace function public._assignment_reward(d public.challenge_definitions)
returns jsonb as $$
  select case
    when d.completion like 'group:%' then jsonb_build_object('lines', coalesce(public._challenge_config('group_daily_rewards', '{}'::jsonb) -> 'participation', '[]'::jsonb))
    when d.reward_key = 'weekly_rewards' then jsonb_build_object('lines', coalesce(public._challenge_config('weekly_rewards', '{}'::jsonb) -> d.id, '[]'::jsonb))
    when d.reward_key is not null then jsonb_build_object('lines', coalesce(public._challenge_config(d.reward_key, '{}'::jsonb) -> d.difficulty, '[]'::jsonb))
    when d.reward_from_difficulty then public._difficulty_reward(d.difficulty)
    else d.reward end;
$$ language sql stable security definer set search_path = public;

-- what the weekly remembers about its own consolation
create or replace function public._weekly_payload(d public.challenge_definitions)
returns jsonb as $$
  select case when d.type = 'personal_weekly' then jsonb_build_object(
      'tier', coalesce(d.weekly_tier, 'normal'),
      'consolation', coalesce(public._challenge_config('weekly_consolation', '{}'::jsonb) -> coalesce(d.weekly_tier, 'normal'), '[]'::jsonb),
      'consolation_min_pct', coalesce((public._challenge_config('weekly_consolation', '{}'::jsonb)->>'min_pct')::numeric, 0.5))
    else '{}'::jsonb end;
$$ language sql stable security definer set search_path = public;

create or replace function public._challenge_available(d public.challenge_definitions, p_user uuid)
returns boolean as $$
begin
  if d.requires is null then return true; end if;
  return case d.requires
    when 'open_battle' then exists (
      select 1 from public.nickname_battles b
      where b.status = 'open'
        and not exists (select 1 from public.nickname_battle_votes v where v.battle_id = b.id and v.user_id = p_user))
    when 'unrated_beer' then exists (
      select 1 from public.beers b
      where not exists (select 1 from public.beer_ratings r where r.beer_id = b.id and r.user_id = p_user and r.rating is not null))
    when 'anecdote_target' then exists (select 1 from public.nicknames n where coalesce(btrim(n.anecdote), '') = '')
    when 'old_content' then exists (select 1 from public.poems p where p.created_at < now() - interval '7 days')
                         or exists (select 1 from public.nicknames n where n.created_at < now() - interval '7 days')
    when 'nicknames_3' then (select count(*) from public.nicknames) >= 3
    when 'poems_2' then (select count(*) from public.poems) >= 2
    when 'group_quiz_data' then (select count(distinct btrim(person_real_name)) from public.nicknames where status = 'Actief' and btrim(person_real_name) <> '') >= 4
    when 'poetry_prompt_data' then exists (select 1 from public.poetry_prompts where is_active and is_daily_eligible)
    -- 0052: battles must exist to take part in
    when 'battle_activity' then exists (select 1 from public.nickname_battles b where b.status = 'open' or b.created_at > now() - interval '14 days')
    else coalesce((select f.enabled from public.challenge_features f where f.key = d.requires), false)
  end;
end;
$$ language plpgsql stable security definer set search_path = public;

-- the ONE place an assignment is snapshotted from its definition
create or replace function public._new_assignment(d public.challenge_definitions, p_owner uuid, p_user uuid, p_key text, p_from timestamptz, p_to timestamptz)
returns uuid as $$
declare
  v_id uuid;
begin
  insert into public.challenge_assignments
    (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
     target, period_key, starts_at, expires_at, completion, payload, parts, distinct_by, unit)
  values ('officelore', d.id, p_owner, d.type, d.category, d.title, d.description, d.difficulty, d.event_type,
          case when d.parts is not null then (select array_agg(distinct ev) from jsonb_array_elements(d.parts) pt, jsonb_array_elements_text(pt->'events') ev) else d.event_types end,
          d.icon, d.requirements, public._assignment_reward(d),
          case when d.parts is not null then (select sum((pt->>'target')::int) from jsonb_array_elements(d.parts) pt) else d.target end,
          p_key, p_from, p_to, d.completion,
          public._chaos_payload(d, p_user, p_key) || public._weekly_payload(d), d.parts, d.distinct_by, d.unit)
  on conflict do nothing
  returning id into v_id;
  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- tier-aware pick for the week: not last week's, available, a stable per-user shuffle
create or replace function public._pick_personal_weeklies(p_user uuid, p_key text, p_prev_key text, p_lord uuid)
returns text[] as $$
declare
  v_cfg jsonb := public._challenge_config('weekly_slots', '{"normal":2,"big":1}'::jsonb);
  v_tier text; v_want int; v_have int;
  v_ids text[] := '{}';
begin
  foreach v_tier in array array['normal', 'big'] loop
    v_want := coalesce((v_cfg->>v_tier)::int, 0);
    select count(*) into v_have from public.challenge_assignments x
      join public.challenge_definitions dd on dd.id = x.definition_id
      where x.app_id = 'officelore' and x.user_id = p_user and x.type = 'personal_weekly' and x.period_key = p_key
        and coalesce(dd.weekly_tier, 'normal') = v_tier;
    continue when v_have >= v_want;
    v_ids := v_ids || coalesce((
      select array_agg(q.id) from (
        select d.id from public.challenge_definitions d
        where d.app_id = 'officelore' and d.is_active and d.type = 'personal_weekly' and coalesce(d.weekly_tier, 'normal') = v_tier
          and (d.audience = 'everyone' or (d.audience = 'non_lord' and p_user is distinct from p_lord) or (d.audience = 'lord' and p_user is not distinct from p_lord))
          and public._challenge_available(d, p_user)
          and not exists (select 1 from public.challenge_assignments x2 where x2.app_id = 'officelore' and x2.user_id = p_user and x2.definition_id = d.id and x2.period_key = p_key)
        order by (exists (select 1 from public.challenge_assignments y where y.app_id = 'officelore' and y.user_id = p_user and y.definition_id = d.id and y.period_key = p_prev_key)),
                 md5(d.id || p_user::text || p_key)
        limit v_want - v_have) q), '{}');
  end loop;
  return v_ids;
end;
$$ language plpgsql stable security definer set search_path = public;

-- generation: weekly tiers + one snapshot helper
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
  v_prev_wk_key text := to_char(v_local - interval '7 days', 'IYYY-"W"IW');
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
    elsif v_type = 'personal_weekly' then
      v_ids := public._pick_personal_weeklies(p_user, v_key, v_prev_wk_key, v_lord);
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
        order by (v_type = 'group_daily' and exists (select 1 from public.challenge_assignments y
                         where y.app_id = 'officelore' and y.definition_id = d.id and y.user_id is null and y.period_key = v_prev_key)),     -- not the same Group Daily two days in a row
                 md5(d.id || coalesce(v_owner::text, 'group') || v_key)
        limit v_want - v_have) x;
    end if;
    continue when cardinality(v_ids) = 0;

    select count(public._new_assignment(d, v_owner, p_user, v_key, v_from, v_to)) into v_n
      from public.challenge_definitions d where d.id = any (v_ids);
    v_created := v_created + v_n;
  end loop;
  return v_created;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — the engine: parts, distinct counts, the 'activity' event
-- =================================================================
create or replace function public._after_personal_daily_completed(p_user uuid, p_assignment uuid, p_period text)
returns void as $$
declare
  v_complete int;
  v_def text;
begin
  select definition_id into v_def from public.challenge_assignments where id = p_assignment;
  perform public._challenge_event(p_user, 'daily_completed', 1, p_assignment::text, jsonb_build_object('definition_id', v_def), 'daily_completed:' || p_assignment::text);
  select count(*) into v_complete from public.challenge_assignments x
    where x.app_id = 'officelore' and x.user_id = p_user and x.type = 'personal_daily'
      and x.period_key = p_period and x.status in ('completed', 'claimed');
  if v_complete >= 3 then
    insert into public.challenge_sweeps (user_id, period_key, reward)
      values (p_user, p_period, public._challenge_config('daily_sweep', '{"lines":[]}'::jsonb))
      on conflict (user_id, period_key) do nothing;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._challenge_event(
  p_user uuid, p_event text, p_amount int default 1, p_dedupe text default null,
  p_meta jsonb default '{}'::jsonb, p_source text default null)
returns void as $$
declare
  a record;
  prt jsonb;
  v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
  v_pp jsonb; v_changed boolean; v_key text; v_cap int; v_n int; v_ev_n int; v_prog int; v_all boolean;
  v_val text; v_add int; v_done boolean; v_cat text;
begin
  if p_user is null or p_amount is null or p_amount <= 0 then return; end if;
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return;
  end if;

  if p_event <> 'activity' then
    insert into public.challenge_events (app_id, user_id, event_type, amount, dedupe_key, source_key, meta)
      values ('officelore', p_user, p_event, p_amount, p_dedupe, p_source, v_meta)
      on conflict (source_key) where source_key is not null do nothing;
    if not found then return; end if;
  end if;

  for a in
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements, asg.period_key, asg.parts, asg.part_progress, asg.distinct_by
    from public.challenge_assignments asg
    where asg.app_id = 'officelore' and asg.status = 'active' and asg.completion = 'auto'
      and p_event = any (coalesce(asg.event_types, array[asg.event_type]))
      and asg.starts_at <= now() and asg.expires_at > now()
      and (asg.user_id = p_user or asg.user_id is null)
    order by asg.id
    for update
  loop
    if a.parts is not null then
      -- a challenge made of several counters
      v_pp := a.part_progress; v_changed := false;
      for prt in select * from jsonb_array_elements(a.parts) loop
        continue when not ((prt->'events') ? p_event);
        continue when not public._challenge_requirements_met(coalesce(prt->'requirements', '{}'::jsonb), v_meta);
        v_key := prt->>'key'; v_cap := (prt->>'target')::int;
        v_n := coalesce((v_pp->>v_key)::int, 0);
        continue when not (prt ? 'avg_key') and v_n >= v_cap;
        if p_dedupe is not null then
          insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, v_key || ':' || p_dedupe) on conflict do nothing;
          continue when not found;
        end if;
        if (prt->'per_event_max') ? p_event then                       -- e.g. a battle win counts as a bonus step only once
          v_ev_n := coalesce((v_pp->>(v_key || ':' || p_event))::int, 0);
          continue when v_ev_n >= (prt->'per_event_max'->>p_event)::int;
          v_pp := v_pp || jsonb_build_object(v_key || ':' || p_event, v_ev_n + 1);
        end if;
        if prt ? 'avg_key' then                                        -- count + running sum, for "average at least X"
          v_pp := v_pp || jsonb_build_object(v_key, v_n + p_amount,
                    v_key || '_sum', coalesce((v_pp->>(v_key || '_sum'))::numeric, 0) + coalesce((v_meta->>(prt->>'avg_key'))::numeric, 0));
        else
          v_pp := v_pp || jsonb_build_object(v_key, least(v_n + p_amount, v_cap));
        end if;
        v_changed := true;
      end loop;
      continue when not v_changed;
      v_prog := 0; v_all := true;
      for prt in select * from jsonb_array_elements(a.parts) loop
        v_n := coalesce((v_pp->>(prt->>'key'))::int, 0);
        v_prog := v_prog + least(v_n, (prt->>'target')::int);
        if v_n < (prt->>'target')::int then v_all := false;
        elsif prt ? 'avg_key' and coalesce((v_pp->>((prt->>'key') || '_sum'))::numeric, 0) / greatest(v_n, 1) < (prt->>'min_avg')::numeric then v_all := false;
        end if;
      end loop;
      update public.challenge_assignments
        set part_progress = v_pp, progress = least(v_prog, target),
            status = case when v_all then 'completed' else status end,
            completed_at = case when v_all then now() else completed_at end
        where id = a.id;

    elsif a.distinct_by is not null then
      -- a challenge that counts DIFFERENT values (Dailies, categories, beer activity types)
      v_val := case when a.distinct_by = '$event' then p_event else v_meta->>a.distinct_by end;
      continue when v_val is null;
      continue when not public._challenge_requirements_met(a.requirements, v_meta);
      insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, 'v:' || v_val) on conflict do nothing;
      continue when not found;
      v_add := least(1, a.target - a.progress);
      continue when v_add <= 0;
      v_done := a.progress + v_add >= a.target;
      update public.challenge_assignments
        set progress = progress + v_add, status = case when v_done then 'completed' else status end,
            completed_at = case when v_done then now() else completed_at end
        where id = a.id;

    else
      continue when not public._challenge_requirements_met(a.requirements, v_meta);
      if p_dedupe is not null then
        insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, p_dedupe) on conflict do nothing;
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
        perform public._after_personal_daily_completed(p_user, a.id, a.period_key);
      end if;
    end if;
  end loop;

  -- every real event that belongs to an app category is also one 'activity' in that category
  if p_event <> 'activity' then
    select category into v_cat from public.challenge_event_categories where event_type = p_event;
    if found then perform public._challenge_event(p_user, 'activity', 1, null, jsonb_build_object('category', v_cat), null); end if;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- group Dailies: the entry is an activity (and a Chaos / quiz one where it fits)
create or replace function public._group_participated(p_round uuid, p_user uuid)
returns void as $$
declare
  r public.group_daily_rounds;
  e public.group_daily_entries;
begin
  select * into r from public.group_daily_rounds where id = p_round;
  insert into public.group_daily_participants (round_id, user_id) values (p_round, p_user) on conflict do nothing;
  update public.challenge_assignments set progress = target, status = case when status = 'active' then 'completed' else status end,
         completed_at = coalesce(completed_at, now())
    where id = r.assignment_id;
  insert into public.challenge_contributions (assignment_id, user_id, amount) values (r.assignment_id, p_user, 1)
    on conflict (assignment_id, user_id) do nothing;
  update public.group_daily_rounds set entry_count = entry_count + 1, updated_at = now() where id = p_round;

  perform public._challenge_event(p_user, 'group_entry', 1, null, jsonb_build_object('kind', r.kind), 'group_entry:' || p_round::text || ':' || p_user::text);
  if r.kind in ('chaos', 'emoji') then
    perform public._challenge_event(p_user, 'chaos_completed', 1, null, jsonb_build_object('kind', 'group'), 'group_chaos:' || p_round::text || ':' || p_user::text);
  elsif r.kind = 'quiz' then
    select * into e from public.group_daily_entries where round_id = p_round and user_id = p_user;
    perform public._challenge_event(p_user, 'quiz_completed', 1, null,
      jsonb_build_object('pct', round(coalesce(e.score, 0) * 100.0 / greatest(coalesce((e.content->>'total')::int, 5), 1)), 'score', e.score), 'group_quiz:' || p_round::text || ':' || p_user::text);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — claiming, including the consolation
-- =================================================================
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

-- =================================================================
-- SECTION 5 — the weekly pool
-- =================================================================
-- retire the 0048 samples: only untouched ones are removed, nobody loses progress
update public.challenge_definitions set is_active = false where type = 'personal_weekly' and parts is null and distinct_by is null and id like 'w\_%';
delete from public.challenge_assignments a
  where a.type = 'personal_weekly' and a.definition_id like 'w\_%' and a.status = 'active' and a.progress = 0
    and not exists (select 1 from public.challenge_claims c where c.assignment_id = a.id);

insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, target, requirements, reward_from_difficulty, reward_key, completion, icon, requires, audience, weekly_tier, parts, distinct_by, unit) values
  ('pw_lorekeeper', 'personal_weekly', 'lore', 'The Lorekeeper', 'Feed the lore: add to the Wall, tell the stories, rate the nicknames.', 'normal', 'nickname_created', 7, '{}', false, 'weekly_rewards', 'auto', '🏷️', 'nicknames_3', 'everyone', 'normal',
     '[{"key":"contrib","label":"Nicknames added","events":["nickname_created"],"target":2},
       {"key":"stories","label":"Anecdotes or quotes","events":["anecdote_added","nickname_anecdote_added","quote_added"],"target":2},
       {"key":"ratings","label":"Nickname ratings","events":["nickname_rated"],"target":3}]'::jsonb, null, 'steps'),
  ('pw_beer_explorer', 'personal_weekly', 'beer', 'Beer Explorer', 'Discover beer in two different ways: register a new beer, rate one, join a session. It is about exploring, never about how much.', 'normal', 'beer_added', 2, '{}', false, 'weekly_rewards', 'auto', '🍺', null, 'everyone', 'normal',
     null, '$event', 'activities'),
  ('pw_poet_laureate', 'personal_weekly', 'poetry', 'Poet Laureate', 'Three poetry activities: write poems, or critique other poets.', 'normal', 'poem_created', 3, '{}', false, 'weekly_rewards', 'auto', '✍️', null, 'everyone', 'normal',
     '[{"key":"poetry","label":"Poetry activities","events":["poem_created","poem_commented"],"target":3}]'::jsonb, null, 'activities'),
  ('pw_battle_hardened', 'personal_weekly', 'battle', 'Battle Hardened', 'Take part in 3 Nickname Battles. A battle won with your nickname gives one bonus step.', 'normal', 'battle_participated', 3, '{}', false, 'weekly_rewards', 'auto', '⚔️', 'battle_activity', 'everyone', 'normal',
     '[{"key":"battles","label":"Battles joined","events":["battle_participated","battle_won"],"target":3,"per_event_max":{"battle_won":1}}]'::jsonb, null, 'battles'),
  ('pw_keeper_knowledge', 'personal_weekly', 'quiz', 'Keeper of Knowledge', 'Complete 3 Office Lore quizzes and average at least 70%.', 'normal', 'quiz_completed', 3, '{}', false, 'weekly_rewards', 'auto', '🧠', 'quiz', 'everyone', 'normal',
     '[{"key":"quizzes","label":"Quizzes completed","events":["quiz_completed"],"target":3,"avg_key":"pct","min_avg":70}]'::jsonb, null, 'quizzes'),
  ('pw_agent_of_chaos', 'personal_weekly', 'chaos', 'Agent of Chaos', 'Complete 3 Chaos challenges this week.', 'normal', 'chaos_completed', 3, '{}', false, 'weekly_rewards', 'auto', '🎭', 'nicknames_3', 'everyone', 'normal',
     '[{"key":"chaos","label":"Chaos challenges","events":["chaos_completed"],"target":3}]'::jsonb, null, 'challenges'),
  ('pw_social_creature', 'personal_weekly', 'social', 'Social Creature', 'Use at least 3 different parts of Office Lore this week.', 'normal', 'activity', 3, '{}', false, 'weekly_rewards', 'auto', '🌍', null, 'everyone', 'big',
     null, 'category', 'categories'),
  ('pw_adventurer', 'personal_weekly', 'mixed', 'The Adventurer', 'Complete 5 DIFFERENT Personal Dailies this week. The same Daily twice only counts once.', 'hard', 'daily_completed', 5, '{}', false, 'weekly_rewards', 'auto', '🧭', null, 'everyone', 'big',
     null, 'definition_id', 'Dailies'),
  ('pw_completionist', 'personal_weekly', 'mixed', 'The Completionist', 'A valid activity in 5 different categories: nicknames, lore, poetry, beer, battles, quizzes, chaos, group challenges.', 'hard', 'activity', 5, '{}', false, 'weekly_rewards', 'auto', '🏆', null, 'everyone', 'big',
     null, 'category', 'categories')
on conflict (id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description, difficulty = excluded.difficulty, event_type = excluded.event_type,
  target = excluded.target, reward_key = excluded.reward_key, icon = excluded.icon, requires = excluded.requires, weekly_tier = excluded.weekly_tier,
  parts = excluded.parts, distinct_by = excluded.distinct_by, unit = excluded.unit, is_active = true;

-- =================================================================
-- SECTION 6 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array[
    '_challenge_slots(text)', '_assignment_reward(public.challenge_definitions)', '_weekly_payload(public.challenge_definitions)',
    '_challenge_available(public.challenge_definitions, uuid)', '_new_assignment(public.challenge_definitions, uuid, uuid, text, timestamptz, timestamptz)',
    '_pick_personal_weeklies(uuid, text, text, uuid)', '_ensure_challenge_assignments_for(uuid, timestamptz)',
    '_after_personal_daily_completed(uuid, uuid, text)', '_challenge_event(uuid, text, int, text, jsonb, text)', '_group_participated(uuid, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
