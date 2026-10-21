-- DEV bundle part 4/5: migrations 0052 to 0077. Run the parts in order, each once, in a NEW empty Supabase project (never in production).

-- =========== 0052_personal_weekly_challenges.sql ===========
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

-- =========== 0053_group_weekly_quests.sql ===========
-- =================================================================
-- OFFICE LORE — 🤝 GROUP WEEKLY QUESTS
-- =================================================================
-- Shared weekly quests for ALL active members of the workspace.
--
--   🤝 The Fellowship    every participant completes at least one Personal Daily
--   🍻 The Gathering     members attend ONE shared Beer Session (existing attendance, no drinking needed)
--   ✍️ The Poets         every participant writes at least one poem (named after the head count: The Three Poets)
--   🏭 Nickname Factory  the group together makes 5 nickname/lore contributions
--   🏛️ The Council       everyone plays the same Lore Quiz; the group average must reach 75%
--
-- THE PARTICIPANT SET. When the quest is created the active members of the
-- workspace are written to challenge_member_progress, one row each: that IS the
-- participant set and the per-person progress. Nothing counts for anyone outside
-- it, so somebody who joins later cannot corrupt a running quest (they are in
-- from next week), and nothing is hardcoded to three people: every rule counts
-- the rows. A member who is deactivated during the week is no longer awaited.
--
-- RULES (challenge_definitions.group_rule, data-driven):
--   each           every participant needs per_member events          (Fellowship, Poets)
--   pool           all participants together reach target             (Nickname Factory)
--   shared_session min_attendees participants in the SAME session     (Gathering)
--   avg_quiz       everyone plays once, the average pct >= min_avg    (Council)
--
-- REWARDS. Every participant claims their own: Player XP + 1 Gauntlet Fragment +
-- a Mystery chance (2 Fragments for the harder Council). Rewards live in
-- challenge_config.weekly_rewards; the number of group weeklies a week in
-- weekly_slots.group (default 2). Claiming is once per participant.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0052.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
alter table public.challenge_definitions add column if not exists group_rule jsonb;
alter table public.challenge_assignments add column if not exists group_rule jsonb;

create table if not exists public.challenge_member_progress (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  amount int not null default 0,
  extra jsonb not null default '{}',
  primary key (assignment_id, user_id)
);
alter table public.challenge_member_progress enable row level security;
drop policy if exists "Challenge members: read" on public.challenge_member_progress;
create policy "Challenge members: read" on public.challenge_member_progress for select to authenticated using (public.is_app_member('officelore'));
do $$
begin
  begin
    alter publication supabase_realtime add table public.challenge_member_progress;
  exception when duplicate_object then null;
  end;
end $$;

update public.challenge_config set value = value || '{"group": 2}'::jsonb where key = 'weekly_slots' and not (value ? 'group');

-- =================================================================
-- SECTION 2 — snapshots: the participant set is written with the assignment
-- =================================================================
create or replace function public._challenge_slots(p_type text) returns int as $$
  select case p_type
    when 'personal_daily' then 3 when 'group_daily' then 1
    when 'personal_weekly' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'normal')::int, 2) + coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'big')::int, 1)
    when 'group_weekly' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'group')::int, 2)
    when 'rebellion' then 1 else 0 end;
$$ language sql stable security definer set search_path = public;

create or replace function public._group_title(d public.challenge_definitions, p_n int)
returns text as $$
  select case when d.id = 'gw_poets' and p_n between 1 and 12
    then 'The ' || (array['One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve'])[p_n] || ' Poets'
    else d.title end;
$$ language sql immutable;

create or replace function public._new_assignment(d public.challenge_definitions, p_owner uuid, p_user uuid, p_key text, p_from timestamptz, p_to timestamptz)
returns uuid as $$
declare
  v_id uuid;
  v_n int := 0;
  v_target int;
begin
  if d.group_rule is not null then
    select count(*) into v_n from public.app_memberships m where m.app_id = 'officelore' and m.is_active;
  end if;
  v_target := case
    when d.parts is not null then (select sum((pt->>'target')::int) from jsonb_array_elements(d.parts) pt)
    when d.group_rule->>'mode' in ('each', 'avg_quiz') then greatest(v_n, 1)
    when d.group_rule->>'mode' = 'shared_session' then (d.group_rule->>'min_attendees')::int
    when d.group_rule->>'mode' = 'pool' then (d.group_rule->>'target')::int
    else d.target end;
  insert into public.challenge_assignments
    (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
     target, period_key, starts_at, expires_at, completion, payload, parts, distinct_by, unit, group_rule)
  values ('officelore', d.id, p_owner, d.type, d.category, public._group_title(d, v_n), d.description, d.difficulty, d.event_type,
          case when d.parts is not null then (select array_agg(distinct ev) from jsonb_array_elements(d.parts) pt, jsonb_array_elements_text(pt->'events') ev)
               when d.group_rule is not null then (select array_agg(ev) from jsonb_array_elements_text(d.group_rule->'events') ev)
               else d.event_types end,
          d.icon, d.requirements, public._assignment_reward(d), v_target,
          p_key, p_from, p_to, d.completion,
          public._chaos_payload(d, p_user, p_key) || public._weekly_payload(d), d.parts, d.distinct_by, d.unit, d.group_rule)
  on conflict do nothing
  returning id into v_id;
  if v_id is not null and d.group_rule is not null then
    insert into public.challenge_member_progress (assignment_id, user_id)
      select v_id, m.user_id from public.app_memberships m where m.app_id = 'officelore' and m.is_active
      on conflict do nothing;
  end if;
  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — the engine: group rules
-- =================================================================
create or replace function public._group_rule_apply(p_assignment uuid, p_rule jsonb, p_user uuid, p_event text, p_amount int, p_dedupe text, p_meta jsonb)
returns void as $$
declare
  v_mode text := p_rule->>'mode';
  mp public.challenge_member_progress;
  v_sid text; v_total int; v_done int; v_prog int; v_target int; v_complete boolean := false; v_avg numeric;
begin
  select * into mp from public.challenge_member_progress where assignment_id = p_assignment and user_id = p_user;
  if mp.assignment_id is null then return; end if;                 -- not in this quest's participant set
  if not exists (select 1 from jsonb_array_elements_text(p_rule->'events') e where e = p_event) then return; end if;
  if p_dedupe is not null then
    insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (p_assignment, p_user, p_dedupe) on conflict do nothing;
    if not found then return; end if;
  end if;

  if v_mode in ('each', 'pool') then
    update public.challenge_member_progress set amount = amount + p_amount where assignment_id = p_assignment and user_id = p_user;
  elsif v_mode = 'shared_session' then
    v_sid := p_meta->>'session_id';
    if v_sid is null then return; end if;
    if coalesce(mp.extra->'sessions', '[]'::jsonb) ? v_sid then return; end if;
    update public.challenge_member_progress
      set extra = jsonb_set(extra, '{sessions}', coalesce(extra->'sessions', '[]'::jsonb) || to_jsonb(v_sid), true), amount = amount + 1
      where assignment_id = p_assignment and user_id = p_user;
  elsif v_mode = 'avg_quiz' then
    if mp.amount >= 1 then return; end if;                          -- one play counts
    update public.challenge_member_progress set amount = 1, extra = extra || jsonb_build_object('pct', coalesce((p_meta->>'pct')::numeric, 0))
      where assignment_id = p_assignment and user_id = p_user;
  else
    return;
  end if;

  -- the state is always recomputed from the rows: only members who are still active are awaited
  select count(*) into v_total from public.challenge_member_progress x
    join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active
    where x.assignment_id = p_assignment;
  if v_mode = 'each' then
    select count(*) into v_done from public.challenge_member_progress x
      join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active
      where x.assignment_id = p_assignment and x.amount >= coalesce((p_rule->>'per_member')::int, 1);
    v_prog := v_done; v_target := greatest(v_total, 1); v_complete := v_total > 0 and v_done = v_total;
  elsif v_mode = 'pool' then
    select coalesce(sum(x.amount), 0) into v_done from public.challenge_member_progress x where x.assignment_id = p_assignment;
    v_target := (p_rule->>'target')::int; v_prog := least(v_done, v_target); v_complete := v_done >= v_target;
  elsif v_mode = 'shared_session' then
    select coalesce(max(c), 0) into v_done from (
      select s, count(*) as c from public.challenge_member_progress x
        join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active,
        jsonb_array_elements_text(x.extra->'sessions') s
      where x.assignment_id = p_assignment group by s) q;
    v_target := (p_rule->>'min_attendees')::int; v_prog := least(v_done, v_target); v_complete := v_done >= v_target;
  else
    select count(*) filter (where x.amount >= 1), avg((x.extra->>'pct')::numeric) filter (where x.amount >= 1) into v_done, v_avg
      from public.challenge_member_progress x
      join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active
      where x.assignment_id = p_assignment;
    v_prog := v_done; v_target := greatest(v_total, 1);
    v_complete := v_total > 0 and v_done = v_total and coalesce(v_avg, 0) >= (p_rule->>'min_avg')::numeric;
  end if;
  update public.challenge_assignments
    set progress = least(v_prog, v_target), target = v_target,
        status = case when v_complete and status = 'active' then 'completed' else status end,
        completed_at = case when v_complete then coalesce(completed_at, now()) else completed_at end
    where id = p_assignment;
end;
$$ language plpgsql security definer set search_path = public;

-- the engine, with the group rule branch
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
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements, asg.period_key, asg.parts, asg.part_progress, asg.distinct_by, asg.group_rule
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

    elsif a.group_rule is not null then
      -- a shared quest: per-person rows, one participant set, counted by rule
      perform public._group_rule_apply(a.id, a.group_rule, p_user, p_event, p_amount, p_dedupe, v_meta);

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

-- the weekly Council quiz uses the same round machinery as the Group Daily quiz,
-- but never decides a daily winner and never completes the assignment by itself
create or replace function public._ensure_group_round(p_assignment uuid)
returns public.group_daily_rounds as $$
declare
  a public.challenge_assignments;
  r public.group_daily_rounds;
  v_q jsonb; v_ans jsonb; v_kind text;
begin
  select * into r from public.group_daily_rounds where assignment_id = p_assignment;
  if found then return r; end if;
  perform pg_advisory_xact_lock(hashtext('group_round:' || p_assignment::text));
  select * into r from public.group_daily_rounds where assignment_id = p_assignment;
  if found then return r; end if;
  select * into a from public.challenge_assignments where id = p_assignment;
  v_kind := case when a.group_rule->>'mode' = 'avg_quiz' then 'quiz' else split_part(a.completion, ':', 2) end;
  if v_kind = 'quiz' then select g.questions, g.answers into v_q, v_ans from public._group_quiz(a.period_key) g; end if;
  insert into public.group_daily_rounds (app_id, assignment_id, kind, day_key, prompt, questions, winner_lines, min_participants, starts_at, ends_at)
    values (a.app_id, a.id, v_kind, a.period_key, a.payload - 'winner' - 'min_participants', v_q,
            coalesce(a.payload->'winner', '[]'::jsonb), coalesce((a.payload->>'min_participants')::int, 2), a.starts_at, a.expires_at)
    returning * into r;
  if v_ans is not null then insert into public.group_daily_secrets (round_id, answers) values (r.id, v_ans); end if;
  return r;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._group_participated(p_round uuid, p_user uuid)
returns void as $$
declare
  r public.group_daily_rounds;
  e public.group_daily_entries;
  v_type text;
begin
  select * into r from public.group_daily_rounds where id = p_round;
  select type into v_type from public.challenge_assignments where id = r.assignment_id;
  insert into public.group_daily_participants (round_id, user_id) values (p_round, p_user) on conflict do nothing;
  if v_type = 'group_daily' then
    update public.challenge_assignments set progress = target, status = case when status = 'active' then 'completed' else status end,
           completed_at = coalesce(completed_at, now())
      where id = r.assignment_id;
    insert into public.challenge_contributions (assignment_id, user_id, amount) values (r.assignment_id, p_user, 1)
      on conflict (assignment_id, user_id) do nothing;
  end if;
  update public.group_daily_rounds set entry_count = entry_count + 1, updated_at = now() where id = p_round;

  perform public._challenge_event(p_user, 'group_entry', 1, null, jsonb_build_object('kind', r.kind), 'group_entry:' || p_round::text || ':' || p_user::text);
  if r.kind in ('chaos', 'emoji') then
    perform public._challenge_event(p_user, 'chaos_completed', 1, null, jsonb_build_object('kind', 'group'), 'group_chaos:' || p_round::text || ':' || p_user::text);
  elsif r.kind = 'quiz' then
    select * into e from public.group_daily_entries where round_id = p_round and user_id = p_user;
    perform public._challenge_event(p_user, 'quiz_completed', 1, null,
      jsonb_build_object('pct', round(coalesce(e.score, 0) * 100.0 / greatest(coalesce((e.content->>'total')::int, 5), 1)), 'score', e.score, 'round_id', p_round),
      'group_quiz:' || p_round::text || ':' || p_user::text);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._finalize_group_round(p_round uuid)
returns void as $$
declare
  r public.group_daily_rounds;
  v_top int; v_top_ms int;
begin
  select * into r from public.group_daily_rounds where id = p_round for update;
  if r.id is null or r.status <> 'open' or r.ends_at > now() then return; end if;
  -- the weekly Council round has no winner
  if (select type from public.challenge_assignments where id = r.assignment_id) <> 'group_daily' then
    update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now() where id = r.id;
    return;
  end if;

  if r.entry_count < r.min_participants then
    update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now(),
      no_winner_reason = 'Not enough entries: at least ' || r.min_participants || ' are needed for a winner.' where id = r.id;
    return;
  end if;

  if r.kind = 'quiz' then
    select max(e.score) into v_top from public.group_daily_entries e where e.round_id = r.id;
    if coalesce(v_top, 0) <= 0 then
      update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now(), no_winner_reason = 'Nobody scored a point.' where id = r.id;
      return;
    end if;
    select min(e.duration_ms) into v_top_ms from public.group_daily_entries e where e.round_id = r.id and e.score = v_top;
    insert into public.group_daily_winners (round_id, user_id, entry_id)
      select r.id, e.user_id, e.id from public.group_daily_entries e where e.round_id = r.id and e.score = v_top and e.duration_ms = v_top_ms;
  else
    select max(c) into v_top from (select count(*) as c from public.group_daily_votes v where v.round_id = r.id group by v.entry_id) q;
    if coalesce(v_top, 0) < 1 then
      update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now(), no_winner_reason = 'Nobody voted.' where id = r.id;
      return;
    end if;
    insert into public.group_daily_winners (round_id, user_id, entry_id)
      select r.id, e.user_id, e.id from public.group_daily_entries e
      where e.round_id = r.id and (select count(*) from public.group_daily_votes v where v.entry_id = e.id) = v_top;
  end if;
  update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now() where id = r.id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.get_group_daily()
returns jsonb as $$
declare
  a public.challenge_assignments;
  r public.group_daily_rounds;
  p public.group_daily_rounds;
  v_cur jsonb := null; v_prev jsonb := null;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform public._finalize_due_group_rounds();
  select * into a from public.challenge_assignments
    where app_id = 'officelore' and type = 'group_daily' and user_id is null and completion like 'group:%'
      and starts_at <= now() and expires_at > now() order by starts_at desc limit 1;
  if a.id is not null then
    r := public._ensure_group_round(a.id);
    v_cur := public._group_round_json(r, auth.uid());
  end if;
  select * into p from public.group_daily_rounds
    where app_id = 'officelore' and status = 'finalized' and id is distinct from r.id and ends_at > now() - interval '3 days'
      and exists (select 1 from public.challenge_assignments x where x.id = public.group_daily_rounds.assignment_id and x.type = 'group_daily')
    order by ends_at desc limit 1;
  if p.id is not null then v_prev := public._group_round_json(p, auth.uid()); end if;
  return jsonb_build_object('current', v_cur, 'previous', v_prev);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.get_group_weekly_round(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  r public.group_daily_rounds;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id and app_id = 'officelore' and type = 'group_weekly' and group_rule->>'mode' = 'avg_quiz';
  if a.id is null then raise exception 'Unknown quest'; end if;
  r := public._ensure_group_round(a.id);
  return public._group_round_json(r, auth.uid());
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — claiming: every participant, once
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
  return jsonb_build_object('status', 'claimed', 'results', v_results);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — the pool
-- =================================================================
update public.challenge_definitions set is_active = false where type = 'group_weekly' and group_rule is null;
delete from public.challenge_assignments a
  where a.type = 'group_weekly' and a.group_rule is null and a.status = 'active' and a.progress = 0
    and not exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id)
    and not exists (select 1 from public.challenge_claims c where c.assignment_id = a.id);

insert into public.challenge_config (key, value)
select 'weekly_rewards', '{}'::jsonb where not exists (select 1 from public.challenge_config where key = 'weekly_rewards');
update public.challenge_config set value = value || '{
      "gw_fellowship":       [ {"kind":"player_xp","amount":30}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.25} ],
      "gw_gathering":        [ {"kind":"player_xp","amount":30}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "gw_poets":            [ {"kind":"player_xp","amount":35}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.25} ],
      "gw_nickname_factory": [ {"kind":"player_xp","amount":30}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.25} ],
      "gw_council":          [ {"kind":"player_xp","amount":45}, {"kind":"gauntlet_fragments","amount":2}, {"kind":"mystery","amount":1,"chance":0.35} ]
   }'::jsonb
 where key = 'weekly_rewards' and not (value ? 'gw_fellowship');

insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, target, requirements, reward_from_difficulty, reward_key, completion, icon, requires, audience, group_rule) values
  ('gw_fellowship', 'group_weekly', 'social', 'The Fellowship', 'Every member completes at least one Personal Daily this week. Nobody is left behind.', 'normal', 'daily_completed', 1, '{}', false, 'weekly_rewards', 'auto', '🤝', null, 'everyone',
     '{"mode":"each","events":["daily_completed"],"per_member":1}'::jsonb),
  ('gw_gathering', 'group_weekly', 'beer', 'The Gathering', 'Meet at one shared Beer Session this week. Showing up is enough: nobody has to drink anything.', 'normal', 'beer_session_participated', 2, '{}', false, 'weekly_rewards', 'auto', '🍻', null, 'everyone',
     '{"mode":"shared_session","events":["beer_session_participated"],"min_attendees":2}'::jsonb),
  ('gw_poets', 'group_weekly', 'poetry', 'The Poets', 'Every member writes at least one poem this week.', 'normal', 'poem_created', 1, '{}', false, 'weekly_rewards', 'auto', '✍️', null, 'everyone',
     '{"mode":"each","events":["poem_created"],"per_member":1}'::jsonb),
  ('gw_nickname_factory', 'group_weekly', 'nickname', 'Nickname Factory', 'Together: 5 nickname or lore contributions (new nicknames, anecdotes, quotes).', 'normal', 'nickname_created', 5, '{}', false, 'weekly_rewards', 'auto', '🏭', null, 'everyone',
     '{"mode":"pool","events":["nickname_created","nickname_anecdote_added","anecdote_added","quote_added"],"target":5}'::jsonb),
  ('gw_council', 'group_weekly', 'quiz', 'The Council', 'Everyone plays the same Lore Quiz. The group average has to reach 75%.', 'hard', 'quiz_completed', 1, '{}', false, 'weekly_rewards', 'auto', '🏛️', 'group_quiz_data', 'everyone',
     '{"mode":"avg_quiz","events":["quiz_completed"],"min_avg":75}'::jsonb)
on conflict (id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description, difficulty = excluded.difficulty, event_type = excluded.event_type,
  target = excluded.target, reward_key = excluded.reward_key, icon = excluded.icon, requires = excluded.requires, group_rule = excluded.group_rule, is_active = true;

-- =================================================================
-- SECTION 6 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array[
    '_challenge_slots(text)', '_group_title(public.challenge_definitions, int)',
    '_new_assignment(public.challenge_definitions, uuid, uuid, text, timestamptz, timestamptz)',
    '_group_rule_apply(uuid, jsonb, uuid, text, int, text, jsonb)', '_challenge_event(uuid, text, int, text, jsonb, text)',
    '_ensure_group_round(uuid)', '_group_participated(uuid, uuid)', '_finalize_group_round(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  revoke all on function public.get_group_weekly_round(uuid) from public, anon;
  grant execute on function public.get_group_weekly_round(uuid) to authenticated;
end $$;

-- =========== 0054_gauntlet_fragments_integration.sql ===========
-- =================================================================
-- OFFICE LORE — ROYAL GAUNTLET x CHALLENGES: fragments, forging, inventory cap
-- =================================================================
-- Challenges pay Gauntlet FRAGMENTS. This migration makes the conversion a
-- first-class, centrally configured part of the Royal Gauntlet system.
--
--   challenge_config.gauntlet_rules = {"fragments_per_gauntlet": 5, "max_gauntlets": 2}
--
--   5 fragments  =  1 Royal Gauntlet
--   INVENTORY CAP  at most max_gauntlets (2) Royal Gauntlets are ever FORGED for a
--                  user. At the cap, fragment progress stops at 4/5: no third
--                  Gauntlet appears. Spending a Gauntlet makes room, and stored
--                  fragments forge again.
--   ABT LORD       the current Abt Lord keeps EARNING fragments, more than 5 may be
--                  stored, but nothing is forged while the reign lasts. When the
--                  reign ends, as many Gauntlets as the cap allows are forged at
--                  once; what remains stays stored.
--   FALLEN ABT    keeps Gauntlets and fragments. The challenge cooldown is a
--                  separate check in create_throne_challenge (and the Coup) and a
--                  Gauntlet NEVER skips it.
--
-- SAFETY. Forging is STATE-based, not event-based: _forge_gauntlets(user) looks
-- at the stored fragments and the balance and forges what is allowed, so it can
-- be called any number of times. Both it and _add_fragments take a per-user
-- advisory lock, and fragments are only added by _grant_challenge_reward2 after
-- its unique reward-grant row was inserted: a refresh, a double click, a
-- realtime echo or a second tab can never add a fragment twice.
--
-- Forging happens automatically when:
--   * fragments are granted, * the Abt Lord's reign ends, * a Gauntlet is spent.
-- A refund of a cancelled challenge gives the spent Gauntlet back as before
-- (it restores what was paid and is not capped).
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0053.
-- =================================================================

-- =================================================================
-- SECTION 1 — central config
-- =================================================================
insert into public.challenge_config (key, value) values
  ('gauntlet_rules', '{"fragments_per_gauntlet": 5, "max_gauntlets": 2}'::jsonb)
on conflict (key) do nothing;

create or replace function public._fragments_per_gauntlet() returns int as $$
  select greatest(coalesce((public._challenge_config('gauntlet_rules', '{}'::jsonb)->>'fragments_per_gauntlet')::int, 5), 1);
$$ language sql stable security definer set search_path = public;

create or replace function public._max_gauntlets() returns int as $$
  select greatest(coalesce((public._challenge_config('gauntlet_rules', '{}'::jsonb)->>'max_gauntlets')::int, 2), 1);
$$ language sql stable security definer set search_path = public;

create or replace function public._current_abt_lord() returns uuid as $$
  select user_id from public.abt_reigns where ended_at is null limit 1;
$$ language sql stable security definer set search_path = public;

create or replace function public.get_gauntlet_rules()
returns jsonb as $$
  select jsonb_build_object('fragments_per_gauntlet', public._fragments_per_gauntlet(), 'max_gauntlets', public._max_gauntlets())
  where public.is_app_member('officelore');
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 2 — forging
-- =================================================================
create or replace function public._forge_gauntlets(p_user uuid)
returns int as $$
declare
  v_per int := public._fragments_per_gauntlet();
  v_cap int := public._max_gauntlets();
  v_frag int; v_bal int; v_forged int := 0;
begin
  if p_user is null then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('gauntlet_forge:' || p_user::text));
  -- nothing is forged while the user is the Abt Lord: the fragments wait for the end of the reign
  if p_user is not distinct from public._current_abt_lord() then return 0; end if;
  select fragments into v_frag from public.gauntlet_fragments where user_id = p_user for update;
  if not found then return 0; end if;
  insert into public.royal_gauntlet_balances (user_id) values (p_user) on conflict do nothing;
  select balance into v_bal from public.royal_gauntlet_balances where user_id = p_user for update;
  while v_frag >= v_per and v_bal < v_cap loop
    v_frag := v_frag - v_per; v_bal := v_bal + 1; v_forged := v_forged + 1;
    insert into public.royal_gauntlet_ledger (user_id, delta, reason, note) values (p_user, 1, 'fragment_convert', v_per || ' fragments forged');
  end loop;
  if v_forged > 0 then
    update public.gauntlet_fragments set fragments = v_frag, updated_at = now() where user_id = p_user;
    update public.royal_gauntlet_balances set balance = v_bal, updated_at = now() where user_id = p_user;
  end if;
  return v_forged;
end;
$$ language plpgsql security definer set search_path = public;

-- the only way fragments are added
create or replace function public._add_fragments(p_user uuid, p_n int)
returns jsonb as $$
declare
  v_per int := public._fragments_per_gauntlet();
  v_cap int := public._max_gauntlets();
  v_lord boolean := p_user is not distinct from public._current_abt_lord();
  v_before int; v_after int; v_bal int; v_forged int; v_new int; v_stored int;
begin
  perform pg_advisory_xact_lock(hashtext('gauntlet_forge:' || p_user::text));
  insert into public.gauntlet_fragments (user_id, fragments) values (p_user, 0) on conflict do nothing;
  select fragments into v_before from public.gauntlet_fragments where user_id = p_user for update;
  update public.gauntlet_fragments set fragments = fragments + p_n, updated_at = now() where user_id = p_user;
  v_forged := public._forge_gauntlets(p_user);
  select fragments into v_after from public.gauntlet_fragments where user_id = p_user;
  select coalesce(balance, 0) into v_bal from public.royal_gauntlet_balances where user_id = p_user;
  v_new := v_after;
  -- a full inventory (and not the Abt Lord): progress stops at per-1, but nothing already stored is ever taken away
  if not v_lord and coalesce(v_bal, 0) >= v_cap then
    v_new := greatest(least(v_after, v_per - 1), least(v_before, v_after));
    if v_new <> v_after then update public.gauntlet_fragments set fragments = v_new, updated_at = now() where user_id = p_user; end if;
  end if;
  v_stored := least(p_n, greatest(v_new - (v_before - v_per * v_forged), 0));
  return jsonb_build_object('stored', v_stored, 'wasted', p_n - v_stored, 'forged', v_forged, 'lord', v_lord,
                            'fragments', v_new, 'balance', coalesce(v_bal, 0), 'full', coalesce(v_bal, 0) >= v_cap);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — the reward grant now goes through _add_fragments
-- =================================================================
create or replace function public._grant_challenge_reward2(p_user uuid, p_assignment uuid, p_sweep uuid, p_line jsonb, p_line_no int)
returns jsonb as $$
declare
  v_kind text := p_line->>'kind';
  v_amount int := coalesce((p_line->>'amount')::int, 0);
  v_chance numeric := coalesce((p_line->>'chance')::numeric, 1);
  v_hit boolean;
  v_status text;
  v_frag jsonb := '{}'::jsonb;
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

  -- only reached when this very grant row was just created: a replay never gets here
  if v_hit and v_kind = 'gauntlet_fragments' and v_amount > 0 then
    v_frag := public._add_fragments(p_user, v_amount);
  end if;
  return jsonb_build_object('kind', v_kind, 'amount', v_amount, 'category', p_line->>'category', 'hit', v_hit, 'chance', v_chance, 'status', v_status) || v_frag;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — automatic forging: reign ends, Gauntlet spent
-- =================================================================
create or replace function public._t_forge_on_reign_end() returns trigger as $$
begin
  if old.ended_at is null and new.ended_at is not null then
    -- the old Abt Lord is no longer the Lord (the next reign row is inserted after this update)
    perform public._forge_gauntlets(new.user_id);
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
drop trigger if exists trg_forge_on_reign_end on public.abt_reigns;
create trigger trg_forge_on_reign_end after update of ended_at on public.abt_reigns
  for each row execute procedure public._t_forge_on_reign_end();

create or replace function public._t_forge_on_spend() returns trigger as $$
begin
  if new.balance < old.balance then
    perform public._forge_gauntlets(new.user_id);
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
drop trigger if exists trg_forge_on_spend on public.royal_gauntlet_balances;
create trigger trg_forge_on_spend after update of balance on public.royal_gauntlet_balances
  for each row execute procedure public._t_forge_on_spend();

-- bring everybody in line with the (new) rules once: whatever can be forged is forged
do $$
declare u uuid;
begin
  for u in select user_id from public.gauntlet_fragments loop
    perform public._forge_gauntlets(u);
  end loop;
end $$;

-- =================================================================
-- SECTION 5 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array['_fragments_per_gauntlet()', '_max_gauntlets()', '_current_abt_lord()', '_forge_gauntlets(uuid)', '_add_fragments(uuid, int)',
                           '_grant_challenge_reward2(uuid, uuid, uuid, jsonb, int)', '_t_forge_on_reign_end()', '_t_forge_on_spend()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  revoke all on function public.get_gauntlet_rules() from public, anon;
  grant execute on function public.get_gauntlet_rules() to authenticated;
end $$;

-- =========== 0055_rebellion_quests.sql ===========
-- =================================================================
-- OFFICE LORE — ⚔️ REBELLION QUESTS + LONG REIGN BONUSES
-- =================================================================
-- Only for members who do NOT currently hold the throne.
--
-- 1. REBELLION QUESTS (weekly, type 'rebellion', audience 'non_lord')
--      ⚔️ Seeds of Rebellion   2 Personal Dailies + 1 Lore activity + 1 Battle   -> XP + 2 Gauntlet Fragments
--      📜 The Pamphlet War      1 poem + 3 nickname ratings
--      ⛈️ The Gathering Storm   3 Battles
--    They use the same parts engine as the Personal Weeklies. The Abt Lord is not
--    assigned one, and cannot claim one that was assigned before he took the throne.
--
-- 2. LONG REIGN BONUSES. The longer the same Abt Lord rules WITHOUT interruption
--    (one abt_reigns row), the more the people support a rebellion. Milestones are
--    configuration (challenge_config.rebellion_milestones):
--        14 days  +1 Gauntlet Fragment      30 days  +2 Gauntlet Fragments
--        60 days  a full Royal Gauntlet (only while the inventory cap has room; otherwise it
--                 is DEFERRED and handed over as soon as a Gauntlet has been used)
--    Every eligible member (active, not the ruling Lord) gets each milestone ONCE per
--    reign: rebellion_rewards has UNIQUE (reign_id, user_id, milestone_id) and the
--    reward is only paid when that row was inserted. Nothing is repeated on login.
--    Milestones are awarded lazily (get_rebellion_state, any member's visit) and also
--    when a reign ends, for the days it did reach.
--
-- 3. THE LORD sees REIGN PRESSURE (day count + mood). Informational only: no penalty.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0054.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema and config
-- =================================================================
do $$
declare v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.royal_gauntlet_ledger'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%reason%';
  if v_name is not null then execute format('alter table public.royal_gauntlet_ledger drop constraint %I', v_name); end if;
end $$;
alter table public.royal_gauntlet_ledger add constraint royal_gauntlet_ledger_reason_check
  check (reason in ('admin_grant', 'throne_challenge', 'throne_refund', 'throne_coup', 'coup_refund', 'fragment_convert', 'rebellion_gauntlet'));

create table if not exists public.rebellion_rewards (
  reign_id uuid not null references public.abt_reigns(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  milestone_id text not null,
  status text not null check (status in ('granted', 'deferred')),
  fragments int not null default 0,
  gauntlets int not null default 0,
  created_at timestamptz not null default now(),
  granted_at timestamptz,
  notified_at timestamptz,
  primary key (reign_id, user_id, milestone_id)          -- ONE milestone per reign and member, enforced by the database
);
alter table public.rebellion_rewards enable row level security;
drop policy if exists "Rebellion rewards: read own" on public.rebellion_rewards;
create policy "Rebellion rewards: read own" on public.rebellion_rewards for select to authenticated using (user_id = auth.uid());

insert into public.challenge_config (key, value) values
  ('rebellion_milestones', '[
      {"id":"restless","days":14,"icon":"⚠️","title":"THE PEOPLE ARE RESTLESS","text":"The Abt has ruled for 14 days.","lord_text":"The people are growing restless.","fragments":1},
      {"id":"grows","days":30,"icon":"🔥","title":"REBELLION GROWS","text":"The throne has stood too long.","lord_text":"Rebellion is growing.","fragments":2},
      {"id":"demand","days":60,"icon":"⚔️","title":"THE PEOPLE DEMAND CHANGE","text":"A Royal Gauntlet has been placed in your hands.","lord_text":"The people demand change.","gauntlets":1}
   ]'::jsonb)
on conflict (key) do nothing;
update public.challenge_config set value = value || '{"rebellion": 1}'::jsonb where key = 'weekly_slots' and not (value ? 'rebellion');

create or replace function public._challenge_slots(p_type text) returns int as $$
  select case p_type
    when 'personal_daily' then 3 when 'group_daily' then 1
    when 'personal_weekly' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'normal')::int, 2) + coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'big')::int, 1)
    when 'group_weekly' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'group')::int, 2)
    when 'rebellion' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'rebellion')::int, 1)
    else 0 end;
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 2 — awarding the milestones
-- =================================================================
create or replace function public._grant_rebellion_gauntlet(p_user uuid, p_reign uuid)
returns boolean as $$
declare
  v_cap int := public._max_gauntlets();
  v_bal int;
begin
  perform pg_advisory_xact_lock(hashtext('gauntlet_forge:' || p_user::text));
  insert into public.royal_gauntlet_balances (user_id) values (p_user) on conflict do nothing;
  select balance into v_bal from public.royal_gauntlet_balances where user_id = p_user for update;
  if v_bal >= v_cap then return false; end if;               -- the inventory cap holds for the people too
  update public.royal_gauntlet_balances set balance = balance + 1, updated_at = now() where user_id = p_user;
  insert into public.royal_gauntlet_ledger (user_id, delta, reason, note) values (p_user, 1, 'rebellion_gauntlet', 'reign ' || p_reign::text);
  return true;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._award_rebellion_milestones(p_reign uuid, p_as_of timestamptz)
returns void as $$
declare
  r public.abt_reigns;
  m jsonb; u record; x record;
  v_frags int; v_gaunt int; v_ok boolean;
begin
  select * into r from public.abt_reigns where id = p_reign;
  if r.id is null then return; end if;
  perform pg_advisory_xact_lock(hashtext('rebellion:' || p_reign::text));

  for m in select * from jsonb_array_elements(public._challenge_config('rebellion_milestones', '[]'::jsonb)) loop
    continue when p_as_of < r.started_at + make_interval(days => (m->>'days')::int);
    v_frags := coalesce((m->>'fragments')::int, 0); v_gaunt := coalesce((m->>'gauntlets')::int, 0);
    for u in select mm.user_id from public.app_memberships mm
             where mm.app_id = 'officelore' and mm.is_active and mm.user_id <> r.user_id loop
      -- the unique key makes this a once-only reward: only the insert that wins pays
      insert into public.rebellion_rewards (reign_id, user_id, milestone_id, status, fragments, gauntlets)
        values (p_reign, u.user_id, m->>'id', case when v_gaunt > 0 then 'deferred' else 'granted' end, v_frags, v_gaunt)
        on conflict do nothing;
      if found then
        if v_gaunt = 0 then
          if v_frags > 0 then perform public._add_fragments(u.user_id, v_frags); end if;
          update public.rebellion_rewards set granted_at = now() where reign_id = p_reign and user_id = u.user_id and milestone_id = m->>'id';
        end if;
      end if;
    end loop;
  end loop;

  -- a full Gauntlet that did not fit the inventory is handed over as soon as there is room
  for x in select * from public.rebellion_rewards where reign_id = p_reign and status = 'deferred' order by created_at loop
    v_ok := public._grant_rebellion_gauntlet(x.user_id, p_reign);
    if v_ok then
      update public.rebellion_rewards set status = 'granted', granted_at = now(), notified_at = null
        where reign_id = x.reign_id and user_id = x.user_id and milestone_id = x.milestone_id and status = 'deferred';
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._t_rebellion_on_reign_end() returns trigger as $$
begin
  if old.ended_at is null and new.ended_at is not null then
    perform public._award_rebellion_milestones(new.id, new.ended_at);      -- what the reign reached, even if nobody opened the app
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
drop trigger if exists trg_rebellion_on_reign_end on public.abt_reigns;
create trigger trg_rebellion_on_reign_end after update of ended_at on public.abt_reigns
  for each row execute procedure public._t_rebellion_on_reign_end();

-- =================================================================
-- SECTION 3 — reading, and the ceremony acknowledgement
-- =================================================================
create or replace function public.get_rebellion_state()
returns jsonb as $$
declare
  r public.abt_reigns;
  v_day int; v_ms jsonb; v_out jsonb := '[]'::jsonb; v_unseen jsonb := '[]'::jsonb; v_last jsonb := null;
  m jsonb; x public.rebellion_rewards; v_reached boolean;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.abt_reigns where ended_at is null limit 1;
  if r.id is null then return jsonb_build_object('reign', null); end if;
  perform public._award_rebellion_milestones(r.id, now());
  v_day := floor(extract(epoch from (now() - r.started_at)) / 86400)::int + 1;
  for m in select * from jsonb_array_elements(public._challenge_config('rebellion_milestones', '[]'::jsonb)) order by (value->>'days')::int loop
    v_reached := now() >= r.started_at + make_interval(days => (m->>'days')::int);
    select * into x from public.rebellion_rewards where reign_id = r.id and user_id = auth.uid() and milestone_id = m->>'id';
    if v_reached then v_last := m; end if;
    v_out := v_out || (m || jsonb_build_object('reached', v_reached, 'my_status', x.status,
                        'reach_at', r.started_at + make_interval(days => (m->>'days')::int)));
    if x.status = 'granted' and x.notified_at is null then v_unseen := v_unseen || m; end if;
  end loop;
  return jsonb_build_object(
    'reign', jsonb_build_object('id', r.id, 'user_id', r.user_id, 'started_at', r.started_at, 'day', v_day),
    'i_am_lord', r.user_id = auth.uid(),
    'milestones', v_out,
    'unseen', v_unseen,
    'pressure', coalesce(v_last->>'lord_text', 'The people are content, for now.'),
    'pressure_icon', coalesce(v_last->>'icon', '👑'));
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.ack_rebellion_notice()
returns void as $$
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  update public.rebellion_rewards set notified_at = now() where user_id = auth.uid() and status = 'granted' and notified_at is null;
end;
$$ language plpgsql security definer set search_path = public;

-- claiming: the Abt Lord can not take a Rebellion reward
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
  return jsonb_build_object('status', 'claimed', 'results', v_results);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — the Rebellion quests
-- =================================================================
update public.challenge_definitions set is_active = false where type = 'rebellion' and parts is null;
delete from public.challenge_assignments a
  where a.type = 'rebellion' and a.parts is null and a.status = 'active' and a.progress = 0
    and not exists (select 1 from public.challenge_claims c where c.assignment_id = a.id);

update public.challenge_config set value = value || '{
      "rb_seeds":    [ {"kind":"player_xp","amount":35}, {"kind":"gauntlet_fragments","amount":2} ],
      "rb_pamphlet": [ {"kind":"player_xp","amount":35}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "rb_storm":    [ {"kind":"player_xp","amount":40}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.30} ]
   }'::jsonb
 where key = 'weekly_rewards' and not (value ? 'rb_seeds');

insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, target, requirements, reward_from_difficulty, reward_key, completion, icon, requires, audience, parts, unit) values
  ('rb_seeds', 'rebellion', 'battle', 'Seeds of Rebellion', 'Sow the doubt: finish 2 Personal Dailies, do 1 Lore activity and take part in 1 Battle.', 'special', 'daily_completed', 4, '{}', false, 'weekly_rewards', 'auto', '⚔️', 'battle_activity', 'non_lord',
     '[{"key":"dailies","label":"Personal Dailies","events":["daily_completed"],"target":2},
       {"key":"lore","label":"Lore activity","events":["nickname_created","nickname_anecdote_added","anecdote_added","quote_added","nickname_rated"],"target":1},
       {"key":"battle","label":"Battle joined","events":["battle_participated"],"target":1}]'::jsonb, 'steps'),
  ('rb_pamphlet', 'rebellion', 'social', 'The Pamphlet War', 'Spread the word: write 1 poem and rate 3 nicknames.', 'special', 'poem_created', 4, '{}', false, 'weekly_rewards', 'auto', '📜', 'nicknames_3', 'non_lord',
     '[{"key":"poem","label":"Poems written","events":["poem_created"],"target":1},
       {"key":"ratings","label":"Nickname ratings","events":["nickname_rated"],"target":3}]'::jsonb, 'steps'),
  ('rb_storm', 'rebellion', 'battle', 'The Gathering Storm', 'Stir the realm: take part in 3 Nickname Battles.', 'special', 'battle_participated', 3, '{}', false, 'weekly_rewards', 'auto', '⛈️', 'battle_activity', 'non_lord',
     '[{"key":"battles","label":"Battles joined","events":["battle_participated"],"target":3}]'::jsonb, 'battles')
on conflict (id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description, difficulty = excluded.difficulty, event_type = excluded.event_type,
  target = excluded.target, reward_key = excluded.reward_key, icon = excluded.icon, requires = excluded.requires, audience = excluded.audience,
  parts = excluded.parts, unit = excluded.unit, is_active = true;

-- =================================================================
-- SECTION 5 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array['_challenge_slots(text)', '_grant_rebellion_gauntlet(uuid, uuid)', '_award_rebellion_milestones(uuid, timestamptz)', '_t_rebellion_on_reign_end()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  revoke all on function public.get_rebellion_state() from public, anon;
  grant execute on function public.get_rebellion_state() to authenticated;
  revoke all on function public.ack_rebellion_notice() from public, anon;
  grant execute on function public.ack_rebellion_notice() to authenticated;
end $$;

-- =========== 0056_mystery_rewards.sql ===========
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

-- =========== 0057_audit_fixes.sql ===========
-- =================================================================
-- OFFICE LORE — AUDIT FIXES (reward speed, farming, assignments)
-- =================================================================
-- Found by running every migration and self-test on a real Postgres:
--
--  1. BEER EXPLORER never counted a rating or a session: its assignment only listened
--     to 'beer_added'. It now listens to the three discovery events (new beer,
--     FIRST rating of a beer, session attendance) and still needs two DIFFERENT kinds.
--     New: a definition may set requirements.by_event = {"beer_rated": {"min_first": 1}},
--     the rule applies to that event only.
--  2. REWARD SPEED. challenge_config.gauntlet_rules.weekly_fragment_cap (default 6):
--     at most 6 Gauntlet Fragments a member can STORE per ISO week from challenges,
--     Mystery boxes and the Group quests together. That is at most ~1 Royal
--     Gauntlet every 5 days for a very active member; a normal member lands at
--     about one per 1 to 2 weeks (see the balance report). The once-per-reign Long
--     Reign milestones are outside the cap (they are rare and fixed). Every stored
--     fragment is written to gauntlet_fragment_log, which is also the audit trail.
--  3. NICKNAME FACTORY could be finished by one member spamming nicknames: a single
--     member may now contribute at most per_member_max (3 of the 5).
--  4. PERFECT POURS no longer count as an 'activity' for Social Creature /
--     Completionist: pouring is part of drinking, and challenges reward discovery,
--     ratings, sessions, knowledge and social play, never drinking.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0056.
-- =================================================================

-- ---- 1. Beer Explorer ----
update public.challenge_definitions
  set event_types = array['beer_added', 'beer_rated', 'beer_session_participated'],
      requirements = '{"by_event": {"beer_rated": {"min_first": 1}}}'::jsonb
  where id = 'pw_beer_explorer';
update public.challenge_assignments
  set event_types = array['beer_added', 'beer_rated', 'beer_session_participated'],
      requirements = '{"by_event": {"beer_rated": {"min_first": 1}}}'::jsonb
  where definition_id = 'pw_beer_explorer' and status = 'active';

-- the engine: per-event requirements for distinct counts
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
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements, asg.period_key, asg.parts, asg.part_progress, asg.distinct_by, asg.group_rule
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
      -- requirements may differ per event kind: {"by_event": {"beer_rated": {"min_first": 1}}}
      continue when not public._challenge_requirements_met((a.requirements - 'by_event') || coalesce(a.requirements->'by_event'->p_event, '{}'::jsonb), v_meta);
      insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, 'v:' || v_val) on conflict do nothing;
      continue when not found;
      v_add := least(1, a.target - a.progress);
      continue when v_add <= 0;
      v_done := a.progress + v_add >= a.target;
      update public.challenge_assignments
        set progress = progress + v_add, status = case when v_done then 'completed' else status end,
            completed_at = case when v_done then now() else completed_at end
        where id = a.id;

    elsif a.group_rule is not null then
      -- a shared quest: per-person rows, one participant set, counted by rule
      perform public._group_rule_apply(a.id, a.group_rule, p_user, p_event, p_amount, p_dedupe, v_meta);

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

-- ---- 2. the weekly fragment cap ----
update public.challenge_config set value = value || '{"weekly_fragment_cap": 6}'::jsonb
  where key = 'gauntlet_rules' and not (value ? 'weekly_fragment_cap');

create table if not exists public.gauntlet_fragment_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  amount int not null check (amount > 0),
  source text not null default 'challenge',
  created_at timestamptz not null default now()
);
create index if not exists gauntlet_fragment_log_user on public.gauntlet_fragment_log (user_id, created_at desc);
alter table public.gauntlet_fragment_log enable row level security;
drop policy if exists "Fragment log: read own" on public.gauntlet_fragment_log;
create policy "Fragment log: read own" on public.gauntlet_fragment_log for select to authenticated using (user_id = auth.uid());

drop function if exists public._add_fragments(uuid, int);
create or replace function public._add_fragments(p_user uuid, p_n int, p_source text default 'challenge')
returns jsonb as $$
declare
  v_rules jsonb := public._challenge_config('gauntlet_rules', '{}'::jsonb);
  v_per int := public._fragments_per_gauntlet();
  v_cap int := public._max_gauntlets();
  v_weekly int := coalesce((v_rules->>'weekly_fragment_cap')::int, 6);
  v_lord boolean := p_user is not distinct from public._current_abt_lord();
  v_week_start timestamptz := date_trunc('week', now() at time zone 'Europe/Brussels') at time zone 'Europe/Brussels';
  v_used int := 0; v_n int := p_n;
  v_before int; v_after int; v_bal int; v_forged int; v_new int; v_stored int;
begin
  perform pg_advisory_xact_lock(hashtext('gauntlet_forge:' || p_user::text));
  insert into public.gauntlet_fragments (user_id, fragments) values (p_user, 0) on conflict do nothing;
  select fragments into v_before from public.gauntlet_fragments where user_id = p_user for update;

  -- the weekly allowance (the fixed once-per-reign milestones are outside it)
  if p_source <> 'rebellion' then
    select coalesce(sum(amount), 0) into v_used from public.gauntlet_fragment_log
      where user_id = p_user and created_at >= v_week_start and source <> 'rebellion';
    v_n := least(p_n, greatest(v_weekly - v_used, 0));
  end if;
  if v_n <= 0 then
    select coalesce(balance, 0) into v_bal from public.royal_gauntlet_balances where user_id = p_user;
    return jsonb_build_object('stored', 0, 'wasted', p_n, 'forged', 0, 'lord', v_lord, 'fragments', v_before, 'balance', coalesce(v_bal, 0),
                              'full', coalesce(v_bal, 0) >= v_cap, 'week_capped', true);
  end if;

  update public.gauntlet_fragments set fragments = fragments + v_n, updated_at = now() where user_id = p_user;
  v_forged := public._forge_gauntlets(p_user);
  select fragments into v_after from public.gauntlet_fragments where user_id = p_user;
  select coalesce(balance, 0) into v_bal from public.royal_gauntlet_balances where user_id = p_user;
  v_new := v_after;
  if not v_lord and coalesce(v_bal, 0) >= v_cap then
    v_new := greatest(least(v_after, v_per - 1), least(v_before, v_after));
    if v_new <> v_after then update public.gauntlet_fragments set fragments = v_new, updated_at = now() where user_id = p_user; end if;
  end if;
  v_stored := least(v_n, greatest(v_new - (v_before - v_per * v_forged), 0));
  if v_stored > 0 then
    insert into public.gauntlet_fragment_log (user_id, amount, source) values (p_user, v_stored, p_source);
  end if;
  return jsonb_build_object('stored', v_stored, 'wasted', p_n - v_stored, 'forged', v_forged, 'lord', v_lord,
                            'fragments', v_new, 'balance', coalesce(v_bal, 0), 'full', coalesce(v_bal, 0) >= v_cap, 'week_capped', v_n < p_n);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._award_rebellion_milestones(p_reign uuid, p_as_of timestamptz)
returns void as $$
declare
  r public.abt_reigns;
  m jsonb; u record; x record;
  v_frags int; v_gaunt int; v_ok boolean;
begin
  select * into r from public.abt_reigns where id = p_reign;
  if r.id is null then return; end if;
  perform pg_advisory_xact_lock(hashtext('rebellion:' || p_reign::text));

  for m in select * from jsonb_array_elements(public._challenge_config('rebellion_milestones', '[]'::jsonb)) loop
    continue when p_as_of < r.started_at + make_interval(days => (m->>'days')::int);
    v_frags := coalesce((m->>'fragments')::int, 0); v_gaunt := coalesce((m->>'gauntlets')::int, 0);
    for u in select mm.user_id from public.app_memberships mm
             where mm.app_id = 'officelore' and mm.is_active and mm.user_id <> r.user_id loop
      -- the unique key makes this a once-only reward: only the insert that wins pays
      insert into public.rebellion_rewards (reign_id, user_id, milestone_id, status, fragments, gauntlets)
        values (p_reign, u.user_id, m->>'id', case when v_gaunt > 0 then 'deferred' else 'granted' end, v_frags, v_gaunt)
        on conflict do nothing;
      if found then
        if v_gaunt = 0 then
          if v_frags > 0 then perform public._add_fragments(u.user_id, v_frags, 'rebellion'); end if;
          update public.rebellion_rewards set granted_at = now() where reign_id = p_reign and user_id = u.user_id and milestone_id = m->>'id';
        end if;
      end if;
    end loop;
  end loop;

  -- a full Gauntlet that did not fit the inventory is handed over as soon as there is room
  for x in select * from public.rebellion_rewards where reign_id = p_reign and status = 'deferred' order by created_at loop
    v_ok := public._grant_rebellion_gauntlet(x.user_id, p_reign);
    if v_ok then
      update public.rebellion_rewards set status = 'granted', granted_at = now(), notified_at = null
        where reign_id = x.reign_id and user_id = x.user_id and milestone_id = x.milestone_id and status = 'deferred';
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- ---- 3. Nickname Factory ----
create or replace function public._group_rule_apply(p_assignment uuid, p_rule jsonb, p_user uuid, p_event text, p_amount int, p_dedupe text, p_meta jsonb)
returns void as $$
declare
  v_mode text := p_rule->>'mode';
  mp public.challenge_member_progress;
  v_sid text; v_total int; v_done int; v_prog int; v_target int; v_complete boolean := false; v_avg numeric;
begin
  select * into mp from public.challenge_member_progress where assignment_id = p_assignment and user_id = p_user;
  if mp.assignment_id is null then return; end if;                 -- not in this quest's participant set
  if not exists (select 1 from jsonb_array_elements_text(p_rule->'events') e where e = p_event) then return; end if;
  -- one member can not finish a shared pool alone
  if v_mode = 'pool' and (p_rule ? 'per_member_max') and mp.amount >= (p_rule->>'per_member_max')::int then return; end if;
  if p_dedupe is not null then
    insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (p_assignment, p_user, p_dedupe) on conflict do nothing;
    if not found then return; end if;
  end if;

  if v_mode in ('each', 'pool') then
    update public.challenge_member_progress set amount = amount + p_amount where assignment_id = p_assignment and user_id = p_user;
  elsif v_mode = 'shared_session' then
    v_sid := p_meta->>'session_id';
    if v_sid is null then return; end if;
    if coalesce(mp.extra->'sessions', '[]'::jsonb) ? v_sid then return; end if;
    update public.challenge_member_progress
      set extra = jsonb_set(extra, '{sessions}', coalesce(extra->'sessions', '[]'::jsonb) || to_jsonb(v_sid), true), amount = amount + 1
      where assignment_id = p_assignment and user_id = p_user;
  elsif v_mode = 'avg_quiz' then
    if mp.amount >= 1 then return; end if;                          -- one play counts
    update public.challenge_member_progress set amount = 1, extra = extra || jsonb_build_object('pct', coalesce((p_meta->>'pct')::numeric, 0))
      where assignment_id = p_assignment and user_id = p_user;
  else
    return;
  end if;

  -- the state is always recomputed from the rows: only members who are still active are awaited
  select count(*) into v_total from public.challenge_member_progress x
    join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active
    where x.assignment_id = p_assignment;
  if v_mode = 'each' then
    select count(*) into v_done from public.challenge_member_progress x
      join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active
      where x.assignment_id = p_assignment and x.amount >= coalesce((p_rule->>'per_member')::int, 1);
    v_prog := v_done; v_target := greatest(v_total, 1); v_complete := v_total > 0 and v_done = v_total;
  elsif v_mode = 'pool' then
    select coalesce(sum(x.amount), 0) into v_done from public.challenge_member_progress x where x.assignment_id = p_assignment;
    v_target := (p_rule->>'target')::int; v_prog := least(v_done, v_target); v_complete := v_done >= v_target;
  elsif v_mode = 'shared_session' then
    select coalesce(max(c), 0) into v_done from (
      select s, count(*) as c from public.challenge_member_progress x
        join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active,
        jsonb_array_elements_text(x.extra->'sessions') s
      where x.assignment_id = p_assignment group by s) q;
    v_target := (p_rule->>'min_attendees')::int; v_prog := least(v_done, v_target); v_complete := v_done >= v_target;
  else
    select count(*) filter (where x.amount >= 1), avg((x.extra->>'pct')::numeric) filter (where x.amount >= 1) into v_done, v_avg
      from public.challenge_member_progress x
      join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active
      where x.assignment_id = p_assignment;
    v_prog := v_done; v_target := greatest(v_total, 1);
    v_complete := v_total > 0 and v_done = v_total and coalesce(v_avg, 0) >= (p_rule->>'min_avg')::numeric;
  end if;
  update public.challenge_assignments
    set progress = least(v_prog, v_target), target = v_target,
        status = case when v_complete and status = 'active' then 'completed' else status end,
        completed_at = case when v_complete then coalesce(completed_at, now()) else completed_at end
    where id = p_assignment;
end;
$$ language plpgsql security definer set search_path = public;
update public.challenge_definitions set group_rule = group_rule || '{"per_member_max": 3}'::jsonb where id = 'gw_nickname_factory';
update public.challenge_assignments set group_rule = group_rule || '{"per_member_max": 3}'::jsonb where definition_id = 'gw_nickname_factory' and status = 'active';

-- ---- 4. no drinking-adjacent 'activity' ----
delete from public.challenge_event_categories where event_type in ('perfect_pour', 'perfect_pour_given');

-- ---- grants ----
do $$
declare f text;
begin
  foreach f in array array['_add_fragments(uuid, int, text)', '_challenge_event(uuid, text, int, text, jsonb, text)', '_group_rule_apply(uuid, jsonb, uuid, text, int, text, jsonb)',
                           '_award_rebellion_milestones(uuid, timestamptz)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- ---- 5. the challenge trigger functions are not meant to be callable at all ----
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like '\_ch\_t\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

-- =========== 0058_mystery_cosmetics_fix.sql ===========
-- =================================================================
-- OFFICE LORE — Mystery cosmetics: only what you can actually SEE
-- =================================================================
-- Found while looking at the cosmetics in the app:
--  * three of the new 'Mystery finds' pointed at art keys that have no illustration
--    (headwear.eternal_foam, weapon.sacred_blade, weapon.winged_bow), so they looked
--    like nothing at all. They now use illustrated keys (ice crystal tiara, sword,
--    hunting bow). Tints do not apply to illustrated art, so these carry none.
--  * the cape layer is switched off in the avatar renderer, so a cape prize would show
--    nothing. Capes are not mystery-eligible until that layer is back.
-- Additive + idempotent. Run after 0056.
-- =================================================================
update public.abt_cosmetic_items set asset_key = 'weapon.hunting_bow', render_tint = null where unlock_type = 'mystery' and name = 'Moonlit Warbow';
update public.abt_cosmetic_items set asset_key = 'headwear.ice_crystal_tiara', render_tint = null where unlock_type = 'mystery' and name = 'Phantom Crown of Foam';
update public.abt_cosmetic_items set asset_key = 'weapon.sword', render_tint = null where unlock_type = 'mystery' and name = 'Ember Sacred Blade';
update public.abt_cosmetic_items set mystery_eligible = false where category = 'cape';

-- =========== 0059_personal_character_cosmetics.sql ===========
-- =================================================================
-- OFFICE LORE — Mystery drops for the PERSONAL CHARACTER (My Room)
-- =================================================================
-- Until now a Mystery cosmetic could only be worn by the Abt Lord (the Royal
-- Wardrobe is Lord-only). Everybody has a Personal Character in My Room
-- (room_profiles, a separate system with a reserved, empty `loadout`), and its
-- Wardrobe already has tabs for armor / headwear / weapon / accessory /
-- companion that said "No items yet". Mystery cosmetics now fill them:
--
--   * equip_room_item(category, item): wears an item you OWN from the Mystery pool
--     on your Personal Character (null = take it off). Ownership, category and pool
--     membership are checked on the server; the result is stored in
--     room_profiles.loadout {"headwear": "<item id>", ...}.
--   * the same unlock still works in the Royal Wardrobe when you are the Abt Lord.
--   * the legendary HEADGEAR set (abtlord-images/headgear-legendary-cropped) joins the
--     legendary tier of the Mystery pool. They remain Abt Lord reign milestones too;
--     the one 'dynasty' crown (The Eternal Abt Crown) stays reign-only.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0058.
-- =================================================================

update public.abt_cosmetic_items set mystery_eligible = true
  where is_active and category = 'headwear' and rarity = 'legendary' and unlock_type = 'milestone';

-- the placeholder 'Phantom Crown of Foam' only duplicated Frostglass Tiara's art: the real legendary headgear replaces it
update public.abt_cosmetic_items set is_active = false, mystery_eligible = false where unlock_type = 'mystery' and name = 'Phantom Crown of Foam';

create or replace function public.equip_room_item(p_category text, p_item_id uuid)
returns jsonb as $$
declare
  it public.abt_cosmetic_items;
  v_loadout jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_category not in ('armor', 'headwear', 'weapon', 'accessory', 'companion') then raise exception 'Unknown slot'; end if;
  insert into public.room_profiles (user_id) values (auth.uid()) on conflict do nothing;
  select loadout into v_loadout from public.room_profiles where user_id = auth.uid() for update;
  v_loadout := coalesce(v_loadout, '{}'::jsonb);

  if p_item_id is null then
    v_loadout := v_loadout - p_category;                       -- take it off
  else
    select * into it from public.abt_cosmetic_items where id = p_item_id and is_active;
    if it.id is null or it.category <> p_category then raise exception 'That item does not fit this slot'; end if;
    if not it.mystery_eligible then raise exception 'This item can only be worn by the Abt Lord'; end if;
    if not exists (select 1 from public.user_abt_cosmetics u where u.user_id = auth.uid() and u.cosmetic_item_id = it.id) then
      raise exception 'You have not unlocked this item yet';
    end if;
    v_loadout := jsonb_set(v_loadout, array[p_category], to_jsonb(p_item_id::text), true);
  end if;
  update public.room_profiles set loadout = v_loadout where user_id = auth.uid();
  return v_loadout;
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.equip_room_item(text, uuid) from public, anon;
grant execute on function public.equip_room_item(text, uuid) to authenticated;

-- =========== 0060_lord_gear_drops.sql ===========
-- =================================================================
-- OFFICE LORE — Abt Lord gear in the Mystery pool: the legendary companions
-- =================================================================
-- The four legendary companions (Royal Lion, Frost Tiger, St. Bernardus Hound, Royal
-- T-Rex; abtlord-images/pets-legendary-cropped) join the legendary tier, but they only
-- DROP when the person opening the box is the current Abt Lord (lord_only_drop). Once
-- the Lord has one it is his for good: it appears in the Royal Wardrobe AND in the
-- Wardrobe of his profile (Personal Character), where he can equip it too.
-- They stay reign milestones as well. Additive + idempotent. Run after 0059.
-- =================================================================
alter table public.abt_cosmetic_items add column if not exists lord_only_drop boolean not null default false;
update public.abt_cosmetic_items set mystery_eligible = true, lord_only_drop = true
  where is_active and category = 'companion' and rarity = 'legendary' and unlock_type = 'milestone';

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

revoke all on function public.open_mystery_box(uuid) from public, anon;
grant execute on function public.open_mystery_box(uuid) to authenticated;

-- =========== 0061_no_armor_in_mystery.sql ===========
-- =================================================================
-- OFFICE LORE — armors stay Abt Lord gear
-- =================================================================
-- The armor art (abtlord-images/armors-cropped) belongs to the Abt Lord. The one
-- armor I had put in the Mystery pool ('Obsidian Lionheart', a recoloured Lionheart
-- Armor) is taken out again. Nobody who already has it loses it: it stays owned,
-- it just no longer drops. Additive + idempotent. Run after 0060.
-- =================================================================
update public.abt_cosmetic_items set mystery_eligible = false, is_active = false
  where unlock_type = 'mystery' and category = 'armor';

-- =========== 0062_legendary_headgear_lord_only.sql ===========
-- =================================================================
-- OFFICE LORE — the legendary headgear is Abt Lord gear
-- =================================================================
-- The legendary headgear set (abtlord-images/headgear-legendary-cropped) only DROPS
-- when the person opening the box is the current Abt Lord (lord_only_drop, the same
-- rule as the legendary companions). He keeps what he gets: it shows in the Royal
-- Wardrobe and in the Wardrobe of his profile. Everybody else no longer finds it in
-- boxes (anybody who already owns one keeps it). Additive + idempotent. Run after 0061.
-- =================================================================
update public.abt_cosmetic_items set lord_only_drop = true
  where is_active and category = 'headwear' and rarity = 'legendary' and unlock_type = 'milestone';

-- =========== 0063_personal_character_outfits.sql ===========
-- =================================================================
-- OFFICE LORE — PERSONAL CHARACTER: base + standard outfit (separate from the Abt Lord)
-- =================================================================
-- Every member makes their own little character in My Room: a BASE (female or male,
-- character-images/character/base-*.png) and one of the standard OUTFITS
-- (character-images/outfit/: f1, f2, ... for female, m1, m2, ... for male). This is
-- completely separate from the Abt Lord's Royal Wardrobe; nobody needs to be the Lord.
--
--   set_room_character(base, outfit)   base 'female' | 'male'; outfit null (the plain
--                                      base) or 'f<n>' / 'm<n>' matching the base.
--   stored in room_profiles.body_type (the base) and room_profiles.loadout.outfit.
--
-- New outfits only need an image in the app plus a code in the client list: the server
-- accepts any f<n> / m<n> that matches the base. Mystery drops (headwear, weapon, ...)
-- are worn on top of the outfit and are not touched. Additive + idempotent.
-- Run once in the Supabase SQL Editor, after 0062.
-- =================================================================
create or replace function public.set_room_character(p_base text, p_outfit text default null)
returns jsonb as $$
declare
  v_loadout jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_base not in ('female', 'male') then raise exception 'Choose a female or male base'; end if;
  if p_outfit is not null then
    if p_outfit !~ '^[fm][0-9]{1,2}$' then raise exception 'Unknown outfit'; end if;
    if left(p_outfit, 1) <> left(p_base, 1) then raise exception 'That outfit does not belong to this base'; end if;
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

-- =========== 0064_headwear_paused.sql ===========
-- =================================================================
-- OFFICE LORE — headwear is paused (for now)
-- =================================================================
-- Headwear is taken out of the Mystery drops and cannot be worn on the Personal
-- Character for the time being. Nothing is deleted: the catalogue, the Abt Lord's
-- wardrobe, reign milestones and Daily Picks are untouched, and anything anybody
-- already owns stays owned. To switch it back on:
--     update public.abt_cosmetic_items set mystery_eligible = true where category = 'headwear' and <the sets you want>;
-- (equip_room_item only accepts items that are mystery_eligible, so this one flag is the switch).
-- Additive + idempotent. Run after 0063.
-- =================================================================
update public.abt_cosmetic_items set mystery_eligible = false where category = 'headwear' and mystery_eligible;

-- =========== 0065_normal_players_base_and_outfit_only.sql ===========
-- =================================================================
-- OFFICE LORE — a normal player's character is only: base + outfit
-- =================================================================
-- Regular players choose female or male and one of the standard outfits (0063), and
-- that is all: no loot is attached to their character. So:
--   * Mystery boxes never contain a cosmetic for anybody but the current Abt Lord
--     (his drops are Royal Wardrobe gear). Everybody else's box pays Player XP, or a
--     Gauntlet Fragment under the existing rules.
--   * the Personal Character Wardrobe only shows the gear tabs to somebody who actually
--     owns such gear (in practice: an Abt Lord who has dropped some).
-- Nothing is deleted. Additive + idempotent. Run after 0064.
-- =================================================================
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

revoke all on function public.open_mystery_box(uuid) from public, anon;
grant execute on function public.open_mystery_box(uuid) to authenticated;

-- =========== 0066_character_outfit_unlocks.sql ===========
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

-- =========== 0067_outfit_lorekeeper.sql ===========
-- =================================================================
-- OFFICE LORE — outfit set 'lk1' "Scholar's Archive" (Lorekeeper)
-- =================================================================
-- Random drop (with the same pity counter as the other random sets) when you claim a
-- Lorekeeper-type quest: the Lorekeeper weekly, Lore Keeper, Quote Hunter, Memory Lane,
-- Name Thy Victim and the Nickname Factory group quest. Codes: flk1 (female) / mlk1 (male).
-- Additive + idempotent. Run after 0066.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('lk1', 'Scholar''s Archive', 'Drops from Lorekeeper quests.', 'random_drop',
   '[{"def":"pw_lorekeeper","chance":0.25},{"def":"gw_nickname_factory","chance":0.15},{"def":"pd_lore_keeper","chance":0.06},{"def":"pd_quote_hunter","chance":0.06},{"def":"pd_memory_lane","chance":0.06},{"def":"pd_name_thy_victim","chance":0.06}]', 10, 30)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- =========== 0068_outfit_battle.sql ===========
-- =================================================================
-- OFFICE LORE — outfit set 'bt1' "Office Gladiator" (Battle)
-- =================================================================
-- Random drop (same pity counter as the other random sets) when you claim a battle quest:
-- Battle Hardened (weekly), Pick a Side (daily) and the Rebellion quests Gathering Storm
-- and Seeds of Rebellion. Codes: fbt1 (female) / mbt1 (male). Additive + idempotent.
-- Run after 0067.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('bt1', 'Office Gladiator', 'Drops from battle quests.', 'random_drop',
   '[{"def":"pw_battle_hardened","chance":0.25},{"def":"rb_storm","chance":0.20},{"def":"rb_seeds","chance":0.10},{"def":"pd_pick_a_side","chance":0.08}]', 10, 40)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- =========== 0069_outfit_chaos.sql ===========
-- =================================================================
-- OFFICE LORE — outfit set 'ch1' "Court Jester" (Chaos)
-- =================================================================
-- Random drop (same pity counter as the other random sets) when you claim a Chaos quest:
-- Agent of Chaos (weekly), any of the 8 Chaos Dailies and the Group Daily "Daily Chaos".
-- Codes: fch1 (female) / mch1 (male). Additive + idempotent. Run after 0068.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('ch1', 'Court Jester', 'Drops from Chaos quests.', 'random_drop',
   '[{"def":"pw_agent_of_chaos","chance":0.25},{"def":"gd_daily_chaos","chance":0.10},
     {"def":"pd_draw_this","chance":0.10},{"def":"pd_the_impostor","chance":0.10},{"def":"pd_the_photographer","chance":0.10},
     {"def":"pd_royal_decree","chance":0.06},{"def":"pd_office_safari","chance":0.06},{"def":"pd_emoji_lore","chance":0.06},
     {"def":"pd_five_seconds","chance":0.06},{"def":"pd_tiny_quest","chance":0.06}]', 10, 50)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- =========== 0070_outfit_completionist.sql ===========
-- =================================================================
-- OFFICE LORE — outfit set 'cp1' "Champion's Gala" (Completionist)
-- =================================================================
-- The golden set for people who finish everything. Claiming The Completionist ALWAYS gives
-- it (chance 1, the first time); Adventurer (5 different Dailies) and Social Creature (3
-- parts of the app) can drop it too, with a short pity counter (5 claims) because these
-- quests are rare. Codes: fcp1 (female) / mcp1 (male). Additive + idempotent. Run after 0069.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('cp1', 'Champion''s Gala', 'Complete The Completionist, or find it with Adventurer and Social Creature.', 'random_drop',
   '[{"def":"pw_completionist","chance":1},{"def":"pw_adventurer","chance":0.30},{"def":"pw_social_creature","chance":0.20}]', 5, 60)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- =========== 0071_outfit_poet.sql ===========
-- =================================================================
-- OFFICE LORE — outfit set 'pt1' "Poet's Salon" (Poetry)
-- =================================================================
-- Random drop (same pity counter as the other random sets) when you claim a poetry quest:
-- Poet Laureate (weekly), Poet for a Day and Poetry Critic (Dailies), the Poetry Showdown
-- (Group Daily), The Poets (Group Quest) and the Rebellion quest The Pamphlet War.
-- Codes: fpt1 (female) / mpt1 (male). Additive + idempotent. Run after 0070.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('pt1', 'Poet''s Salon', 'Drops from poetry quests.', 'random_drop',
   '[{"def":"pw_poet_laureate","chance":0.25},{"def":"gw_poets","chance":0.15},{"def":"gd_poetry_showdown","chance":0.10},{"def":"pd_poet_for_a_day","chance":0.10},{"def":"rb_pamphlet","chance":0.10},{"def":"pd_poetry_critic","chance":0.06}]', 10, 70)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- =========== 0072_outfit_quiz.sql ===========
-- =================================================================
-- OFFICE LORE — outfit set 'qz1' "Quiz Master" (Quizzes)
-- =================================================================
-- Random drop (same pity counter as the other random sets) when you claim a quiz quest:
-- Keeper of Knowledge (weekly), The Council (Group Quest), the Daily Lore Quiz (Group Daily)
-- and the personal quiz Dailies. Some of those stay switched off until a free-to-play quiz
-- exists (challenge_features.quiz); the set is ready for the day they come on.
-- Codes: fqz1 (female) / mqz1 (male). Additive + idempotent. Run after 0071.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('qz1', 'Quiz Master', 'Drops from quiz quests.', 'random_drop',
   '[{"def":"gw_council","chance":0.30},{"def":"pw_keeper_knowledge","chance":0.25},{"def":"pd_perfect_score","chance":0.12},{"def":"gd_lore_quiz","chance":0.10},{"def":"pd_lore_master","chance":0.06},{"def":"pd_know_thy_friends","chance":0.06}]', 8, 80)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- =========== 0073_outfit_rebellion.sql ===========
-- =================================================================
-- OFFICE LORE — outfit set 'rb1' "Rebel Banner" (Rebellion)
-- =================================================================
-- Random drop when you claim a Rebellion quest (Seeds of Rebellion, The Pamphlet War,
-- The Gathering Storm). You get at most one Rebellion quest a week and only a member who is
-- not the Abt Lord can claim one, so the chance is high and the pity counter short (4 claims
-- without a drop, so about a month). Codes: frb1 (female) / mrb1 (male).
-- Additive + idempotent. Run after 0072.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('rb1', 'Rebel Banner', 'Drops from Rebellion quests (for everybody but the Abt Lord).', 'random_drop',
   '[{"def":"rb_seeds","chance":0.35},{"def":"rb_pamphlet","chance":0.35},{"def":"rb_storm","chance":0.35}]', 4, 90)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- =========== 0074_outfits_legendary.sql ===========
-- =================================================================
-- OFFICE LORE — two LEGENDARY outfit sets (very low drop chance)
-- =================================================================
--   lg1 "Crimson Court"    red royal regalia. Drops from the big quests: Completionist, Adventurer,
--                          Social Creature, every Group Quest and every Rebellion quest.
--   lg2 "Starlit Scribe"   the starry archmage. Drops from lore, poetry, quiz, chaos, beer and battle
--                          quests and the quiz / poetry group quests.
-- The chance per claim is only 2 to 6%, and the pity counter is 60 claims (about three months of
-- weekly and group quests). Daily quests never roll for them. Codes: flg1 / mlg1 and flg2 / mlg2.
-- Additive + idempotent. Run after 0073.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('lg1', 'Crimson Court', 'Legendary. Very rare drop from the big weekly, group and rebellion quests.', 'random_drop',
   '[{"def":"pw_completionist","chance":0.06},{"def":"pw_adventurer","chance":0.04},{"def":"pw_social_creature","chance":0.04},
     {"def":"gw_fellowship","chance":0.03},{"def":"gw_gathering","chance":0.03},{"def":"gw_poets","chance":0.03},{"def":"gw_nickname_factory","chance":0.03},{"def":"gw_council","chance":0.04},
     {"def":"rb_seeds","chance":0.03},{"def":"rb_pamphlet","chance":0.03},{"def":"rb_storm","chance":0.03}]', 60, 100),
  ('lg2', 'Starlit Scribe', 'Legendary. Very rare drop from lore, poetry, quiz and other weekly quests.', 'random_drop',
   '[{"def":"pw_lorekeeper","chance":0.04},{"def":"pw_poet_laureate","chance":0.04},{"def":"pw_keeper_knowledge","chance":0.04},
     {"def":"pw_agent_of_chaos","chance":0.03},{"def":"pw_beer_explorer","chance":0.03},{"def":"pw_battle_hardened","chance":0.03},
     {"def":"gw_council","chance":0.05},{"def":"gw_poets","chance":0.04},{"def":"gw_nickname_factory","chance":0.04},
     {"def":"gd_lore_quiz","chance":0.02},{"def":"gd_poetry_showdown","chance":0.02}]', 60, 110)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- =========== 0075_titles.sql ===========
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

-- =========== 0076_daily_poem_templates.sql ===========
-- =================================================================
-- 0076 — Daily poem: opdrachten uit een tabel i.p.v. hardcoded
--
-- Tot nu toe zaten de 9 categorieën x 3 sjablonen vast in
-- get_or_create_daily_challenge(). Nu staan ze in
-- public.daily_poem_templates: nieuwe opdracht = nieuwe rij, geen code.
-- Seed = de 27 bestaande + 4 extra per bestaande categorie + 5 nieuwe
-- categorieën (spooky, detective, fairytale, scifi, sports) met 6 elk.
-- %s in een sjabloon wordt het onderwerp (nickname of lid).
--
-- Additief + idempotent. Bestaande daily_poetry_challenges-rijen blijven
-- ongewijzigd. Draai 1x in de Supabase SQL editor (na 0075).
-- =================================================================

create table if not exists public.daily_poem_templates (
  id         uuid primary key default gen_random_uuid(),
  category   text not null check (length(category) between 2 and 40),
  template   text not null check (template like '%\%s%' and length(template) <= 300),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (category, template)
);

alter table public.daily_poem_templates enable row level security;
drop policy if exists "Daily poem templates: read" on public.daily_poem_templates;
create policy "Daily poem templates: read" on public.daily_poem_templates
  for select to authenticated using (public.is_app_member('officelore'));
-- geen insert/update/delete-policy: beheer via SQL editor

-- de oude vaste categorielijst mag nieuwe categorieën niet blokkeren
alter table public.daily_poetry_challenges drop constraint if exists daily_poetry_challenges_category_check;

insert into public.daily_poem_templates (category, template) values
  -- romantic
  ('romantic','Write a romantic poem about %s as if they were the love of your life.'),
  ('romantic','Write a love poem describing an unexpected office encounter with %s.'),
  ('romantic','Write a sonnet about someone hopelessly falling for %s.'),
  ('romantic','Write a love letter in verse to %s, delivered by carrier pigeon.'),
  ('romantic','Write a poem about a first date with %s at the office vending machine.'),
  ('romantic','Write a poem where %s and a half-eaten pizza share a forbidden love.'),
  ('romantic','Write a breakup poem in which %s says "it''s not you, it''s the meeting schedule".'),
  -- tragic
  ('tragic','Write a tragic poem about the day %s lost everything.'),
  ('tragic','Write a tragic poem mourning %s''s greatest defeat.'),
  ('tragic','Write a eulogy-style poem for %s''s fallen dignity.'),
  ('tragic','Write a poem about %s watching their last biscuit roll under the fridge.'),
  ('tragic','Write a tragic ballad of %s and the unsaved document.'),
  ('tragic','Write a farewell poem for %s as they leave the office forever (just for the weekend).'),
  ('tragic','Write a heartbreaking poem about %s and the meeting that could have been an e-mail.'),
  -- office_nonsense
  ('office_nonsense','Write an absurd office poem starring %s in an epic printer battle.'),
  ('office_nonsense','Write about %s discovering a mysterious smell in the office kitchen.'),
  ('office_nonsense','Write a poem about %s becoming an office legend for all the wrong reasons.'),
  ('office_nonsense','Write a poem about %s accidentally replying all.'),
  ('office_nonsense','Write about %s and the mystery of the disappearing lunch from the fridge.'),
  ('office_nonsense','Write a poem about %s trapped in a never-ending video call.'),
  ('office_nonsense','Write an ode to %s''s unreasonably loud keyboard.'),
  -- beer_inspired
  ('beer_inspired','Write an ode to %s discovering the perfect beer.'),
  ('beer_inspired','Write a tragic poem about %s finding the beer fridge empty.'),
  ('beer_inspired','Write a medieval poem about %s and the Abt Lord''s throne.'),
  ('beer_inspired','Write a drinking song about %s and the first sip after a long week.'),
  ('beer_inspired','Write a poem about %s as a sommelier who only reviews tap water.'),
  ('beer_inspired','Write a toast in verse for %s, raised with a very full glass.'),
  ('beer_inspired','Write an epic poem about %s on a quest for the legendary 10/10 beer.'),
  -- absolute_nonsense
  ('absolute_nonsense','Write a poem about %s being elected Supreme Leader by the office printer.'),
  ('absolute_nonsense','Write about %s slowly turning into a sentient stapler.'),
  ('absolute_nonsense','Write an absurd poem about %s versus a rogue PowerPoint presentation.'),
  ('absolute_nonsense','Write a poem about %s discovering that all the chairs are secretly alive.'),
  ('absolute_nonsense','Write about %s hosting a talk show for houseplants.'),
  ('absolute_nonsense','Write a poem in which %s negotiates peace between the coffee machine and the kettle.'),
  ('absolute_nonsense','Write about %s waking up as a rubber duck in a corporate aquarium.'),
  -- dramatic
  ('dramatic','Describe %s losing Wi-Fi as if civilization itself has collapsed.'),
  ('dramatic','Turn %s''s minor office inconvenience into a Shakespearean tragedy.'),
  ('dramatic','Write an epic battle poem starring %s against a broken coffee machine.'),
  ('dramatic','Write a dramatic monologue for %s when the last slice of cake is gone.'),
  ('dramatic','Describe %s walking into the office on a Monday as a hero''s return from war.'),
  ('dramatic','Write a poem narrating %s''s lunch break like a nature documentary.'),
  ('dramatic','Write an opera-style poem about %s and a jammed stapler.'),
  -- abt_dynasty
  ('abt_dynasty','Write a medieval prophecy about %s attempting to seize the Abt throne.'),
  ('abt_dynasty','Turn %s into a legendary knight serving the Abt Lord.'),
  ('abt_dynasty','Write a coronation poem imagining %s as the next Abt Lord.'),
  ('abt_dynasty','Write a royal decree in verse, signed by %s, ruling over the taproom.'),
  ('abt_dynasty','Write a ballad of the court jester %s who tells the Abt Lord the truth.'),
  ('abt_dynasty','Write a poem about %s plotting a quiet rebellion against the Abt Lord.'),
  ('abt_dynasty','Write a chronicle entry about the glorious reign of %s, the Beer-Blessed.'),
  -- deep_thoughts
  ('deep_thoughts','Write a philosophical poem about %s contemplating the meaning of a Monday.'),
  ('deep_thoughts','Write a deep, reflective poem about %s staring at a spreadsheet.'),
  ('deep_thoughts','Write an existential poem from %s''s perspective at 4:59 PM.'),
  ('deep_thoughts','Write a poem about %s wondering why the printer only jams when it matters.'),
  ('deep_thoughts','Write a meditation by %s on whether a hot drink ever stays hot long enough.'),
  ('deep_thoughts','Write a haiku-style poem about %s and the elevator that never comes.'),
  ('deep_thoughts','Write a poem about %s realising that "quick question" is never quick.'),
  -- wholesome
  ('wholesome','Write a wholesome poem about %s making everyone''s day a little better.'),
  ('wholesome','Write a heartwarming poem about %s sharing their lunch.'),
  ('wholesome','Write a sweet poem about %s remembering everyone''s birthday.'),
  ('wholesome','Write a cozy poem about %s bringing coffee to the whole team.'),
  ('wholesome','Write a poem thanking %s for always laughing at our bad jokes.'),
  ('wholesome','Write a gentle lullaby for %s after a very long week.'),
  ('wholesome','Write a poem about %s helping a colleague with a tricky problem without being asked.'),
  -- spooky (nieuw)
  ('spooky','Write a ghost story in verse about %s alone in the office at midnight.'),
  ('spooky','Write a spooky poem about %s hearing the printer whisper their name.'),
  ('spooky','Write a haunted-house poem where %s is the friendly ghost of the break room.'),
  ('spooky','Write a chilling poem about %s and the elevator that stops on floor 13.'),
  ('spooky','Write a poem about %s discovering that the office cat is a vampire.'),
  ('spooky','Write a gothic poem about %s and the cursed coffee mug.'),
  -- detective (nieuw)
  ('detective','Write a noir detective poem in which %s investigates the stolen lunch.'),
  ('detective','Write a poem where %s is the detective hunting the person who always leaves the printer empty.'),
  ('detective','Write a crime-scene poem: %s found a single crumb and nothing will be the same.'),
  ('detective','Write a poem about %s interrogating a suspicious potted plant.'),
  ('detective','Write a mystery in verse: who drank %s''s last beer?'),
  ('detective','Write a courtroom poem in which %s defends the right to a second coffee.'),
  -- fairytale (nieuw)
  ('fairytale','Write a fairy tale in verse about %s and the dragon who guards the beer cellar.'),
  ('fairytale','Write a poem about %s as a prince(ss) who must kiss the right frog to get Wi-Fi back.'),
  ('fairytale','Write a bedtime story in verse about %s lost in the Enchanted Forest of Meetings.'),
  ('fairytale','Write a poem about %s and three wishes granted by a genie in the copy room.'),
  ('fairytale','Write a poem about %s, a wizard whose only spell is "reply later".'),
  ('fairytale','Write a ballad of %s the brave, who slayed the dragon of overdue e-mails.'),
  -- scifi (nieuw)
  ('scifi','Write a space-opera poem about %s commanding the starship Break Room.'),
  ('scifi','Write a poem about %s being abducted by aliens who only want the office snacks.'),
  ('scifi','Write a poem about %s discovering that the coffee machine is an AI plotting world domination.'),
  ('scifi','Write a poem from %s''s perspective as the last human in a robot-run office.'),
  ('scifi','Write a time-travel poem in which %s goes back to avoid one single meeting.'),
  ('scifi','Write a cyberpunk poem about %s hacking the vending machine.'),
  -- sports (nieuw)
  ('sports','Write a sports-commentary poem about %s in the final of the office chair race.'),
  ('sports','Write a poem about %s winning gold in synchronised coffee carrying.'),
  ('sports','Write a play-by-play poem of %s sprinting to the kitchen when lunch is announced.'),
  ('sports','Write a locker-room speech in verse by %s before the big quarterly review.'),
  ('sports','Write a poem about %s as a trainer who coaches the printer to better performance.'),
  ('sports','Write a marathon poem about %s walking to the meeting room at the other end of the building.')
on conflict (category, template) do nothing;

-- ---- get_or_create_daily_challenge(): kiest uit de tabel ----------------
-- Zelfde seeds, zelfde subject-logica, zelfde race-veiligheid als 0015.
create or replace function public.get_or_create_daily_challenge()
returns public.daily_poetry_challenges as $$
declare
  v_today date := current_date;
  v_row public.daily_poetry_challenges;
  v_subject_type text;
  v_nickname_id uuid;
  v_user_id uuid;
  v_subject_text text;
  v_category text;
  v_template text;
  v_prompt_text text;
  v_nickname_count int;
  v_user_count int;
  v_category_count int;
  v_template_count int;
  v_subject_seed bigint := abs(hashtext('daily-challenge-subject:' || v_today::text));
  v_category_seed bigint := abs(hashtext('daily-challenge-category:' || v_today::text));
  v_template_seed bigint := abs(hashtext('daily-challenge-template:' || v_today::text));
begin
  perform pg_advisory_xact_lock(hashtext('daily_poetry_challenge:' || v_today::text));

  select * into v_row from public.daily_poetry_challenges where challenge_date = v_today;
  if found then
    return v_row;
  end if;

  select count(*) into v_nickname_count from public.nicknames;
  select count(*) into v_user_count
  from public.profiles p
  join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active = true;

  if v_nickname_count > 0 and (v_user_count = 0 or v_subject_seed % 2 = 0) then
    v_subject_type := 'nickname';
    select id, nickname into v_nickname_id, v_subject_text
      from public.nicknames order by id offset (v_subject_seed % v_nickname_count) limit 1;
  else
    v_subject_type := 'user';
    select id, display_name into v_user_id, v_subject_text
      from (
        select p.id, p.display_name
        from public.profiles p
        join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active = true
      ) t
      order by id offset (v_subject_seed % greatest(v_user_count, 1)) limit 1;
  end if;

  -- categorie: willekeurig uit de actieve categorieën in de tabel
  select count(distinct category) into v_category_count
    from public.daily_poem_templates where is_active;
  if v_category_count > 0 then
    select category into v_category from (
      select distinct category from public.daily_poem_templates where is_active
    ) c order by category offset (v_category_seed % v_category_count) limit 1;

    select count(*) into v_template_count
      from public.daily_poem_templates where is_active and category = v_category;
    select template into v_template
      from public.daily_poem_templates where is_active and category = v_category
      order by template offset (v_template_seed % v_template_count) limit 1;
  else
    -- noodval als de tabel leeg/uitgeschakeld is
    v_category := 'wholesome';
    v_template := 'Write a wholesome poem about %s making everyone''s day a little better.';
  end if;

  v_prompt_text := format(v_template, v_subject_text);

  insert into public.daily_poetry_challenges (challenge_date, subject_type, nickname_id, user_id, subject_text, category, prompt_text)
  values (v_today, v_subject_type, v_nickname_id, v_user_id, v_subject_text, v_category, v_prompt_text)
  on conflict (challenge_date) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.daily_poetry_challenges where challenge_date = v_today;
  end if;

  return v_row;
end;
$$ language plpgsql security definer set search_path = public;

-- =========== 0077_hide_lore_challenges.sql ===========
-- =================================================================
-- 0077 — Lore-challenges tijdelijk verbergen (te weinig lore in de app)
--
-- Zet de lore-gerelateerde challenge-definities op inactief, zodat ze
-- niet meer getrokken worden voor nieuwe dailies/weeklies:
--   pd_quote_hunter  (Quote Hunter)
--   pd_memory_lane   (Memory Lane)
--   pd_lore_keeper   (Lore Keeper, anekdote bij een nickname)
--   pw_lorekeeper    (The Lorekeeper, weekly)
-- Bestaande assignments (al getrokken) blijven gewoon spelen en
-- claimbaar; niets wordt verwijderd.
--
-- TERUGZETTEN zodra er genoeg lore is:
--   update public.challenge_definitions set is_active = true
--    where id in ('pd_quote_hunter','pd_memory_lane','pd_lore_keeper','pw_lorekeeper');
-- (Let op: 0049/0052 opnieuw draaien zet ze ook weer aan.)
-- Idempotent.
-- =================================================================
update public.challenge_definitions
   set is_active = false
 where id in ('pd_quote_hunter','pd_memory_lane','pd_lore_keeper','pw_lorekeeper');
