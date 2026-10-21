-- =================================================================
-- OFFICE LORE — 🌟 TODAY'S GROUP CHALLENGE
-- =================================================================
-- Next to the 3 Personal Dailies, the whole workspace gets exactly ONE shared
-- Daily Challenge a day. Everyone sees the same one. It is a normal
-- group_daily assignment (so the generation, the reset, the timezone and the
-- "exactly one per day" rule are the engine's), plus a ROUND on top of it:
--
--   🏷️ Nickname of the Day   invent a nickname for an object, then vote
--   ✍️ Poetry Showdown        everyone writes to the same Poetry prompt, then vote
--   😀 Emoji Showdown         describe the same Office Lore item with <= 5 emoji, then vote
--   🎭 Daily Chaos            the same safe Chaos prompt (a decree or an objects-only photo), then vote
--   🧠 Daily Lore Quiz        the same 5 questions; highest score wins, fastest valid run breaks a tie
--   (🔮 Office Oracle is not part of this: predictions need a result that is determined later.)
--
-- PARTICIPATION vs WINNING
--   * every valid entry earns the PARTICIPATION reward (default: Player XP), claimed
--     through the existing claim_challenge (the entry makes you a contributor)
--   * the WINNER (decided when the day ends) claims the WINNER reward through
--     claim_group_winner: bonus XP + a Mystery Reward chance. No Gauntlet Fragment by
--     default, so a winner cannot farm one daily. Both are lines in
--     challenge_config.group_daily_rewards.
--   * a winner needs at least min_participants entries (default 2). Nobody wins alone.
--
-- FAIRNESS
--   * one entry per user; one vote per user and round, final; no vote for yourself
--   * entries are shown ANONYMOUSLY and in a per-viewer shuffled order while voting;
--     counts and authors appear only when the round ends
--   * ties on votes: co-winners. Quiz: score, then the server-measured run time
--   * the quiz answers live in a private table; the clock starts at start_group_quiz
--     and stops at submit_group_quiz, both on the server; one attempt, resumable
--   * everything is written by the RPCs below; clients only read
--   * persistent, and live: the round/participants/winners tables are in realtime
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0050.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
create table if not exists public.group_daily_rounds (
  id uuid primary key default gen_random_uuid(),
  app_id text not null default 'officelore',
  assignment_id uuid not null unique references public.challenge_assignments(id) on delete cascade,
  kind text not null check (kind in ('nickname', 'poetry', 'emoji', 'chaos', 'quiz')),
  day_key text not null,
  prompt jsonb not null default '{}',
  questions jsonb,                                   -- quiz questions WITHOUT answers
  winner_lines jsonb not null default '[]',          -- snapshot of the winner reward
  min_participants int not null default 2,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'open' check (status in ('open', 'finalized')),
  entry_count int not null default 0,
  vote_count int not null default 0,
  finalized_at timestamptz,
  no_winner_reason text,
  updated_at timestamptz not null default now()
);
create table if not exists public.group_daily_participants (
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  entered_at timestamptz not null default now(),
  primary key (round_id, user_id)
);
create table if not exists public.group_daily_entries (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  content jsonb not null default '{}',
  media text,
  score int,
  duration_ms int,
  content_hash text,
  created_at timestamptz not null default now(),
  unique (round_id, user_id)                          -- ONE entry per user and round
);
create unique index if not exists group_daily_entries_no_copy on public.group_daily_entries (round_id, content_hash) where content_hash is not null;
create table if not exists public.group_daily_votes (
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  voter_id uuid not null references public.profiles(id),
  entry_id uuid not null references public.group_daily_entries(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (round_id, voter_id)                    -- ONE vote per user and round
);
create table if not exists public.group_daily_secrets (
  round_id uuid primary key references public.group_daily_rounds(id) on delete cascade,
  answers jsonb not null
);
create table if not exists public.group_daily_attempts (
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  started_at timestamptz not null default clock_timestamp(),
  primary key (round_id, user_id)
);
create table if not exists public.group_daily_winners (
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  entry_id uuid references public.group_daily_entries(id) on delete set null,
  claimed_at timestamptz,
  primary key (round_id, user_id)
);

alter table public.group_daily_rounds enable row level security;
alter table public.group_daily_participants enable row level security;
alter table public.group_daily_entries enable row level security;
alter table public.group_daily_votes enable row level security;
alter table public.group_daily_secrets enable row level security;     -- deliberately NO policy
alter table public.group_daily_attempts enable row level security;    -- deliberately NO policy
alter table public.group_daily_winners enable row level security;
drop policy if exists "Group rounds: read" on public.group_daily_rounds;
create policy "Group rounds: read" on public.group_daily_rounds for select to authenticated using (public.is_app_member(app_id));
drop policy if exists "Group participants: read" on public.group_daily_participants;
create policy "Group participants: read" on public.group_daily_participants for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "Group winners: read" on public.group_daily_winners;
create policy "Group winners: read" on public.group_daily_winners for select to authenticated using (public.is_app_member('officelore'));
-- entries and votes are read through the RPC only (anonymity); a user may read their own
drop policy if exists "Group entries: read own" on public.group_daily_entries;
create policy "Group entries: read own" on public.group_daily_entries for select to authenticated using (user_id = auth.uid());
drop policy if exists "Group votes: read own" on public.group_daily_votes;
create policy "Group votes: read own" on public.group_daily_votes for select to authenticated using (voter_id = auth.uid());

do $$
declare t text;
begin
  foreach t in array array['group_daily_rounds', 'group_daily_participants', 'group_daily_winners'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- =================================================================
-- SECTION 2 — config and curated subjects
-- =================================================================
insert into public.challenge_config (key, value) values
  ('group_daily_rewards', '{
      "participation": [ {"kind":"player_xp","amount":15} ],
      "winner":        [ {"kind":"player_xp","amount":30}, {"kind":"mystery","amount":1,"chance":0.25} ],
      "min_participants": 2
   }'::jsonb)
on conflict (key) do nothing;

insert into public.chaos_prompts (kind, text) values
  ('group_nickname', 'the coffee machine'), ('group_nickname', 'the office printer'), ('group_nickname', 'the meeting room without windows'),
  ('group_nickname', 'the office plant'), ('group_nickname', 'a Monday morning'), ('group_nickname', 'the last biscuit'),
  ('group_nickname', 'the broken chair'), ('group_nickname', 'the shared fridge'), ('group_nickname', 'the stapler'), ('group_nickname', 'the Wi-Fi')
on conflict (kind, text) do nothing;

-- =================================================================
-- SECTION 3 — engine hooks: availability, the shared pick, rewards, one-per-day generation
-- =================================================================
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
    -- 0051: the shared Daily needs real data to ask about / write about
    when 'group_quiz_data' then (select count(distinct btrim(person_real_name)) from public.nicknames where status = 'Actief' and btrim(person_real_name) <> '') >= 4
    when 'poetry_prompt_data' then exists (select 1 from public.poetry_prompts where is_active and is_daily_eligible)
    else coalesce((select f.enabled from public.challenge_features f where f.key = d.requires), false)
  end;
end;
$$ language plpgsql stable security definer set search_path = public;

-- the ONE shared pick (the same for everybody: it is stored once on the group assignment)
create or replace function public._group_payload(d public.challenge_definitions, p_key text)
returns jsonb as $$
declare
  v_kind text := split_part(d.completion, ':', 2);
  v_row jsonb;
  v_cfg jsonb := public._challenge_config('group_daily_rewards', '{}'::jsonb);
begin
  if v_kind = 'nickname' then
    select jsonb_build_object('text', 'Invent a nickname for: ' || p.text) into v_row
      from public.chaos_prompts p where p.kind = 'group_nickname' and p.is_active order by md5(p.id::text || p_key) limit 1;
  elsif v_kind = 'poetry' then
    select jsonb_build_object('text', pp.prompt_text) into v_row
      from public.poetry_prompts pp where pp.is_active and pp.is_daily_eligible order by md5(pp.id::text || p_key) limit 1;
  elsif v_kind = 'emoji' then
    select jsonb_build_object('nickname_id', n.id, 'text', n.nickname) into v_row
      from public.nicknames n where n.status = 'Actief' order by md5(n.id::text || p_key) limit 1;
  elsif v_kind = 'chaos' then
    select jsonb_build_object('text', p.text, 'sub', case p.kind when 'decree_topic' then 'decree' else 'photo' end) into v_row
      from public.chaos_prompts p where p.kind in ('decree_topic', 'safari', 'tiny_quest', 'photographer') and p.is_active
      order by md5(p.id::text || p_key) limit 1;
  end if;
  return coalesce(v_row, '{}'::jsonb) || jsonb_build_object(
    'winner', coalesce(v_cfg->'winner', '[]'::jsonb),
    'min_participants', coalesce((v_cfg->>'min_participants')::int, 2));
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public._chaos_payload(d public.challenge_definitions, p_user uuid, p_key text)
returns jsonb as $$
declare
  v_kind text := split_part(d.completion, ':', 2);
  v_row jsonb;
begin
  if d.completion = 'auto' then return '{}'::jsonb; end if;
  if d.completion like 'group:%' then return public._group_payload(d, p_key); end if;
  if v_kind in ('draw', 'emoji') then
    select jsonb_build_object('nickname_id', n.id, 'text', n.nickname) into v_row
      from public.nicknames n where n.status = 'Actief' order by md5(n.id::text || p_user::text || p_key) limit 1;
  elsif d.prompt_kind is not null then
    select jsonb_build_object('text', p.text, 'verify', p.verify) into v_row
      from public.chaos_prompts p where p.kind = d.prompt_kind and p.is_active
        and (p.verify is null
             or (p.verify = 'nicknames' and (select count(*) from public.nicknames where status = 'Actief') >= 3)
             or (p.verify = 'beers' and (select count(*) from public.beers) >= 3))
      order by md5(p.id::text || p_user::text || p_key) limit 1;
  end if;
  return coalesce(v_row, '{}'::jsonb);
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public._assignment_reward(d public.challenge_definitions)
returns jsonb as $$
  select case
    when d.completion like 'group:%' then jsonb_build_object('lines', coalesce(public._challenge_config('group_daily_rewards', '{}'::jsonb) -> 'participation', '[]'::jsonb))
    when d.reward_key is not null then jsonb_build_object('lines', coalesce(public._challenge_config(d.reward_key, '{}'::jsonb) -> d.difficulty, '[]'::jsonb))
    when d.reward_from_difficulty then public._difficulty_reward(d.difficulty)
    else d.reward end;
$$ language sql stable security definer set search_path = public;

-- generation: the same as before, but the shared Group Daily avoids yesterday's
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
        order by (v_type = 'group_daily' and exists (select 1 from public.challenge_assignments y
                         where y.app_id = 'officelore' and y.definition_id = d.id and y.user_id is null and y.period_key = v_prev_key)),     -- not the same Group Daily two days in a row
                 md5(d.id || coalesce(v_owner::text, 'group') || v_key)
        limit v_want - v_have) x;
    end if;
    continue when cardinality(v_ids) = 0;

    insert into public.challenge_assignments
      (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
       target, period_key, starts_at, expires_at, completion, payload)
    select 'officelore', d.id, v_owner, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.event_types, d.icon, d.requirements,
           public._assignment_reward(d),
           d.target, v_key, v_from, v_to, d.completion, public._chaos_payload(d, p_user, v_key)
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
-- SECTION 4 — rounds and the quiz
-- =================================================================
create or replace function public._gq_item(p_q text, p_correct text, p_pool text[], p_seed text, out item jsonb, out ans int) as $$
declare
  v_opts text[];
begin
  select array_agg(w.x order by md5(w.x || p_seed)) into v_opts from (
    select p_correct as x
    union all
    (select y from unnest(p_pool) y where y is not null and y <> p_correct group by y order by md5(y || p_seed || 'p') limit 3)
  ) w;
  item := jsonb_build_object('q', p_q, 'options', to_jsonb(v_opts));
  ans := array_position(v_opts, p_correct) - 1;
end;
$$ language plpgsql immutable;

create or replace function public._gq_count(p_q text, p_count int, p_seed text, out item jsonb, out ans int) as $$
declare
  v_pool text[];
begin
  select array_agg(c::text) into v_pool from unnest(array[p_count - 3, p_count - 2, p_count - 1, p_count + 1, p_count + 2, p_count + 3, p_count + 5, p_count + 8]) c where c >= 0;
  select * into item, ans from public._gq_item(p_q, p_count::text, v_pool, p_seed);
end;
$$ language plpgsql immutable;

-- 5 questions, the same for everybody, built from the day's key
create or replace function public._group_quiz(p_key text, out questions jsonb, out answers jsonb) as $$
declare
  n1 record; n2 record;
  v_items jsonb := '[]'::jsonb; v_ans jsonb := '[]'::jsonb;
  r record;
begin
  select nickname, btrim(person_real_name) as person into n1
    from public.nicknames where status = 'Actief' and btrim(person_real_name) <> '' order by md5(id::text || p_key || '1') limit 1;
  select * into r from public._gq_item('Who is known as “' || n1.nickname || '”?', n1.person,
    (select array_agg(distinct btrim(person_real_name)) from public.nicknames where status = 'Actief' and btrim(person_real_name) <> ''), p_key || 'q1');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);

  select nickname, btrim(person_real_name) as person into n2
    from public.nicknames where status = 'Actief' and btrim(person_real_name) <> '' and btrim(person_real_name) <> n1.person order by md5(id::text || p_key || '2') limit 1;
  select * into r from public._gq_item('Which nickname belongs to ' || n2.person || '?', n2.nickname,
    (select array_agg(nickname) from public.nicknames where status = 'Actief' and btrim(person_real_name) <> n2.person), p_key || 'q2');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);

  select * into r from public._gq_count('How many nicknames were on the Wall when today began?', (select count(*) from public.nicknames)::int, p_key || 'q3');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);
  select * into r from public._gq_count('How many beers were registered when today began?', (select count(*) from public.beers)::int, p_key || 'q4');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);
  select * into r from public._gq_count('How many poems were on the Poetry Wall when today began?', (select count(*) from public.poems)::int, p_key || 'q5');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);
  questions := v_items; answers := v_ans;
end;
$$ language plpgsql stable security definer set search_path = public;

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
  v_kind := split_part(a.completion, ':', 2);
  if v_kind = 'quiz' then select g.questions, g.answers into v_q, v_ans from public._group_quiz(a.period_key) g; end if;
  insert into public.group_daily_rounds (app_id, assignment_id, kind, day_key, prompt, questions, winner_lines, min_participants, starts_at, ends_at)
    values (a.app_id, a.id, v_kind, a.period_key, a.payload - 'winner' - 'min_participants', v_q,
            coalesce(a.payload->'winner', '[]'::jsonb), coalesce((a.payload->>'min_participants')::int, 2), a.starts_at, a.expires_at)
    returning * into r;
  if v_ans is not null then insert into public.group_daily_secrets (round_id, answers) values (r.id, v_ans); end if;
  return r;
end;
$$ language plpgsql security definer set search_path = public;

-- the entry makes the member a contributor of the group assignment, which is what lets them claim the participation reward
create or replace function public._group_participated(p_round uuid, p_user uuid)
returns void as $$
declare
  r public.group_daily_rounds;
begin
  select * into r from public.group_daily_rounds where id = p_round;
  insert into public.group_daily_participants (round_id, user_id) values (p_round, p_user) on conflict do nothing;
  update public.challenge_assignments set progress = target, status = case when status = 'active' then 'completed' else status end,
         completed_at = coalesce(completed_at, now())
    where id = r.assignment_id;
  insert into public.challenge_contributions (assignment_id, user_id, amount) values (r.assignment_id, p_user, 1)
    on conflict (assignment_id, user_id) do nothing;
  update public.group_daily_rounds set entry_count = entry_count + 1, updated_at = now() where id = p_round;
end;
$$ language plpgsql security definer set search_path = public;

-- winners: decided once, when the day has ended
create or replace function public._finalize_group_round(p_round uuid)
returns void as $$
declare
  r public.group_daily_rounds;
  v_top int; v_top_ms int;
begin
  select * into r from public.group_daily_rounds where id = p_round for update;
  if r.id is null or r.status <> 'open' or r.ends_at > now() then return; end if;

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

create or replace function public._finalize_due_group_rounds()
returns void as $$
declare
  x uuid;
begin
  for x in select id from public.group_daily_rounds where status = 'open' and ends_at <= now() and app_id = 'officelore' loop
    perform public._finalize_group_round(x);
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — reading
-- =================================================================
create or replace function public._group_round_json(r public.group_daily_rounds, p_uid uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_entries jsonb;
begin
  select * into a from public.challenge_assignments where id = r.assignment_id;
  if r.status = 'open' then
    v_entries := case when r.kind = 'quiz' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'content', e.content, 'has_media', e.media is not null, 'mine', e.user_id = p_uid)
                       order by md5(e.id::text || p_uid::text))
      from public.group_daily_entries e where e.round_id = r.id), '[]'::jsonb) end;
  else
    v_entries := coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'user_id', e.user_id, 'content', e.content, 'has_media', e.media is not null,
                                          'score', e.score, 'duration_ms', e.duration_ms,
                                          'votes', (select count(*) from public.group_daily_votes v where v.entry_id = e.id),
                                          'winner', exists (select 1 from public.group_daily_winners w where w.round_id = r.id and w.user_id = e.user_id))
                       order by e.score desc nulls last, e.duration_ms, (select count(*) from public.group_daily_votes v where v.entry_id = e.id) desc, e.created_at)
      from public.group_daily_entries e where e.round_id = r.id), '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'id', r.id, 'assignment_id', r.assignment_id, 'kind', r.kind, 'day_key', r.day_key, 'prompt', r.prompt, 'questions', r.questions,
    'status', r.status, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'entry_count', r.entry_count, 'vote_count', r.vote_count,
    'min_participants', r.min_participants, 'no_winner_reason', r.no_winner_reason,
    'reward', jsonb_build_object('participation', coalesce(a.reward->'lines', '[]'::jsonb), 'winner', r.winner_lines),
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'entered', exists (select 1 from public.group_daily_participants p where p.round_id = r.id and p.user_id = m.user_id))
                       order by pr.display_name)
      from public.app_memberships m join public.profiles pr on pr.id = m.user_id
      where m.app_id = 'officelore' and m.is_active), '[]'::jsonb),
    'my_entry', (select jsonb_build_object('id', e.id, 'content', e.content, 'has_media', e.media is not null, 'score', e.score, 'duration_ms', e.duration_ms)
                 from public.group_daily_entries e where e.round_id = r.id and e.user_id = p_uid),
    'my_vote', (select v.entry_id from public.group_daily_votes v where v.round_id = r.id and v.voter_id = p_uid),
    'quiz_started_at', (select t.started_at from public.group_daily_attempts t where t.round_id = r.id and t.user_id = p_uid),
    'entries', v_entries,
    'winners', coalesce((select jsonb_agg(w.user_id) from public.group_daily_winners w where w.round_id = r.id), '[]'::jsonb),
    'winner_claimed', (select w.claimed_at is not null from public.group_daily_winners w where w.round_id = r.id and w.user_id = p_uid)
  );
end;
$$ language plpgsql stable security definer set search_path = public;

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
    order by ends_at desc limit 1;
  if p.id is not null then v_prev := public._group_round_json(p, auth.uid()); end if;
  return jsonb_build_object('current', v_cur, 'previous', v_prev);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.get_group_media(p_entry_id uuid)
returns text as $$
  select e.media from public.group_daily_entries e join public.group_daily_rounds r on r.id = e.round_id
  where e.id = p_entry_id and r.app_id = 'officelore' and public.is_app_member('officelore');
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 6 — writing: enter, vote, quiz, claim
-- =================================================================
create or replace function public.submit_group_entry(p_round_id uuid, p_content jsonb, p_media text default null)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  v_text text; v_content jsonb := '{}'::jsonb; v_media text := null; v_hash text;
  v_sub text; v_id uuid;
  v_max int := coalesce((public._challenge_config('chaos_rules', '{}'::jsonb)->>'media_max_chars')::int, 900000);
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.group_daily_rounds where id = p_round_id for update;
  if r.id is null or r.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if r.status <> 'open' or r.ends_at <= now() then raise exception 'This challenge has ended'; end if;
  if r.kind = 'quiz' then raise exception 'Take the quiz instead'; end if;
  if exists (select 1 from public.group_daily_entries where round_id = r.id and user_id = auth.uid()) then raise exception 'You already entered'; end if;

  v_text := btrim(coalesce(p_content->>'text', p_content->>'emoji', ''));
  if r.kind = 'nickname' then
    if length(v_text) not between 2 and 30 or v_text !~ '[[:alpha:]]' then raise exception 'A nickname needs 2 to 30 characters, with letters'; end if;
    v_content := jsonb_build_object('text', v_text); v_hash := md5(lower(v_text));
  elsif r.kind = 'poetry' then
    if length(v_text) not between 20 and 400 then raise exception 'A poem needs 20 to 400 characters'; end if;
    if array_length(regexp_split_to_array(v_text, '\s+'), 1) < 6 then raise exception 'A poem needs at least 6 words'; end if;
    v_content := jsonb_build_object('text', v_text); v_hash := md5(lower(v_text));
  elsif r.kind = 'emoji' then
    if v_text ~ '[A-Za-z0-9]' or length(translate(v_text, chr(65039) || chr(8205) || ' ', '')) not between 1 and 5 then raise exception 'Use emoji only, at most 5'; end if;
    v_content := jsonb_build_object('emoji', v_text); v_hash := md5(v_text);
  elsif r.kind = 'chaos' then
    v_sub := r.prompt->>'sub';
    if v_sub = 'decree' then
      if length(v_text) not between 15 and 280 or array_length(regexp_split_to_array(v_text, '\s+'), 1) < 5 then raise exception 'A decree needs 15 to 280 characters and at least 5 words'; end if;
      v_content := jsonb_build_object('text', v_text); v_hash := md5(lower(v_text));
    else
      if p_media is null or p_media !~ '^data:image/(jpeg|png);base64,[A-Za-z0-9+/=]+$' then raise exception 'Add a photo first'; end if;
      if length(p_media) > v_max then raise exception 'That image is too large'; end if;
      v_media := p_media; v_content := jsonb_build_object('note', left(btrim(coalesce(p_content->>'note', '')), 120));
      v_hash := md5(substr(p_media, 1, 4000) || length(p_media));
    end if;
  end if;

  begin
    insert into public.group_daily_entries (round_id, user_id, content, media, content_hash) values (r.id, auth.uid(), v_content, v_media, v_hash) returning id into v_id;
  exception when unique_violation then
    raise exception 'Somebody already sent exactly that. Make it your own';
  end;
  perform public._group_participated(r.id, auth.uid());
  return jsonb_build_object('status', 'entered', 'id', v_id);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.vote_group_entry(p_round_id uuid, p_entry_id uuid)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  e public.group_daily_entries;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.group_daily_rounds where id = p_round_id for update;
  if r.id is null or r.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if r.status <> 'open' or r.ends_at <= now() then raise exception 'Voting has ended'; end if;
  if r.kind = 'quiz' then raise exception 'There is nothing to vote on'; end if;
  select * into e from public.group_daily_entries where id = p_entry_id and round_id = r.id;
  if e.id is null then raise exception 'Unknown entry'; end if;
  if e.user_id = auth.uid() then raise exception 'You cannot vote for yourself'; end if;
  begin
    insert into public.group_daily_votes (round_id, voter_id, entry_id) values (r.id, auth.uid(), e.id);
  exception when unique_violation then
    raise exception 'You already voted';
  end;
  update public.group_daily_rounds set vote_count = vote_count + 1, updated_at = now() where id = r.id;
  return jsonb_build_object('status', 'voted');
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.start_group_quiz(p_round_id uuid)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  t public.group_daily_attempts;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.group_daily_rounds where id = p_round_id;
  if r.id is null or r.kind <> 'quiz' or r.app_id <> 'officelore' then raise exception 'Unknown quiz'; end if;
  if r.status <> 'open' or r.ends_at <= now() then raise exception 'This quiz has ended'; end if;
  if exists (select 1 from public.group_daily_entries where round_id = r.id and user_id = auth.uid()) then raise exception 'You already took the quiz'; end if;
  insert into public.group_daily_attempts (round_id, user_id) values (r.id, auth.uid()) on conflict do nothing;
  select * into t from public.group_daily_attempts where round_id = r.id and user_id = auth.uid();
  return jsonb_build_object('questions', r.questions, 'started_at', t.started_at);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.submit_group_quiz(p_round_id uuid, p_answers jsonb)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  t public.group_daily_attempts;
  v_key jsonb;
  v_n int; v_score int := 0; v_ms int; i int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.group_daily_rounds where id = p_round_id for update;
  if r.id is null or r.kind <> 'quiz' or r.app_id <> 'officelore' then raise exception 'Unknown quiz'; end if;
  if r.status <> 'open' or r.ends_at <= now() then raise exception 'This quiz has ended'; end if;
  select * into t from public.group_daily_attempts where round_id = r.id and user_id = auth.uid();
  if t.round_id is null then raise exception 'Start the quiz first'; end if;
  if exists (select 1 from public.group_daily_entries where round_id = r.id and user_id = auth.uid()) then raise exception 'You already took the quiz'; end if;
  select answers into v_key from public.group_daily_secrets where round_id = r.id;
  v_n := jsonb_array_length(v_key);
  if jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) <> v_n then raise exception 'Answer all % questions', v_n; end if;
  for i in 0..v_n - 1 loop
    if p_answers->>i is not null and p_answers->>i = v_key->>i then v_score := v_score + 1; end if;
  end loop;
  v_ms := least(extract(epoch from (clock_timestamp() - t.started_at)) * 1000, 3600000)::int;
  insert into public.group_daily_entries (round_id, user_id, content, score, duration_ms)
    values (r.id, auth.uid(), jsonb_build_object('score', v_score, 'total', v_n), v_score, v_ms);
  perform public._group_participated(r.id, auth.uid());
  return jsonb_build_object('status', 'done', 'score', v_score, 'total', v_n, 'duration_ms', v_ms);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.claim_group_winner(p_round_id uuid)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  w public.group_daily_winners;
  v_line jsonb; v_no int := 100; v_results jsonb := '[]'::jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform public._finalize_due_group_rounds();
  select * into r from public.group_daily_rounds where id = p_round_id;
  if r.id is null or r.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  select * into w from public.group_daily_winners where round_id = r.id and user_id = auth.uid() for update;
  if w.round_id is null then raise exception 'You did not win this one'; end if;
  if w.claimed_at is not null then return jsonb_build_object('status', 'already_claimed'); end if;
  update public.group_daily_winners set claimed_at = now() where round_id = r.id and user_id = auth.uid();
  for v_line in select * from jsonb_array_elements(r.winner_lines) loop
    v_no := v_no + 1;
    v_results := v_results || public._grant_challenge_reward2(auth.uid(), r.assignment_id, null, v_line, v_no);
  end loop;
  return jsonb_build_object('status', 'claimed', 'results', v_results);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 7 — the pool: five shared Dailies, exactly one a day
-- =================================================================
-- the older cooperative samples would add a second Group Daily: retire them
-- (only if nobody has touched today's: nothing is lost)
update public.challenge_definitions set is_active = false where type = 'group_daily' and completion = 'auto';
delete from public.challenge_assignments a
  where a.type = 'group_daily' and a.completion = 'auto' and a.status = 'active' and a.progress = 0
    and not exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id)
    and not exists (select 1 from public.challenge_claims c where c.assignment_id = a.id);

insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, target, requirements, reward_from_difficulty, completion, icon, requires, audience) values
  ('gd_nickname_of_the_day', 'group_daily', 'nickname', 'Nickname of the Day', 'Everyone invents a nickname for the same thing. Then everyone votes. The best one wins.', 'normal', 'group_entry', 1, '{}', false, 'group:nickname', '🏷️', null, 'everyone'),
  ('gd_poetry_showdown', 'group_daily', 'poetry', 'Daily Poetry Showdown', 'Everyone writes to the same Poetry prompt. Vote for the best one.', 'normal', 'group_entry', 1, '{}', false, 'group:poetry', '✍️', 'poetry_prompt_data', 'everyone'),
  ('gd_emoji_showdown', 'group_daily', 'chaos', 'Emoji Showdown', 'Describe the same Office Lore item with at most 5 emoji. Vote for the best description.', 'normal', 'group_entry', 1, '{}', false, 'group:emoji', '😀', 'nicknames_3', 'everyone'),
  ('gd_daily_chaos', 'group_daily', 'chaos', 'Daily Chaos', 'The whole office gets the same safe Chaos prompt. Vote for the best.', 'normal', 'group_entry', 1, '{}', false, 'group:chaos', '🎭', null, 'everyone'),
  ('gd_lore_quiz', 'group_daily', 'quiz', 'Daily Lore Quiz', 'The same 5 questions for everyone. The highest score wins; the fastest run breaks a tie.', 'normal', 'group_entry', 1, '{}', false, 'group:quiz', '🧠', 'group_quiz_data', 'everyone')
on conflict (id) do update set
  title = excluded.title, description = excluded.description, event_type = excluded.event_type, completion = excluded.completion,
  icon = excluded.icon, requires = excluded.requires, is_active = true;

-- =================================================================
-- SECTION 8 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array[
    '_group_payload(public.challenge_definitions, text)', '_chaos_payload(public.challenge_definitions, uuid, text)',
    '_assignment_reward(public.challenge_definitions)', '_challenge_available(public.challenge_definitions, uuid)',
    '_ensure_challenge_assignments_for(uuid, timestamptz)',
    '_gq_item(text, text, text[], text)', '_gq_count(text, int, text)', '_group_quiz(text)', '_ensure_group_round(uuid)',
    '_group_participated(uuid, uuid)', '_finalize_group_round(uuid)', '_finalize_due_group_rounds()', '_group_round_json(public.group_daily_rounds, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['get_group_daily()', 'get_group_media(uuid)', 'submit_group_entry(uuid, jsonb, text)', 'vote_group_entry(uuid, uuid)',
                           'start_group_quiz(uuid)', 'submit_group_quiz(uuid, jsonb)', 'claim_group_winner(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
