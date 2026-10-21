-- =================================================================
-- OFFICE LORE — THE CHALLENGE ENGINE (Daily & Weekly Challenges)
-- =================================================================
-- One generic engine for
--   ☀️ personal_daily   🌟 group_daily   📅 personal_weekly
--   🤝 group_weekly     ⚔️ rebellion
--
-- DEFINITION vs ASSIGNMENT
--   challenge_definitions  WHAT a challenge is ("Rate 3 nicknames": event type,
--                          target, rewards ...). Adding content = INSERT rows.
--   challenge_assignments  WHO has it WHEN ("Elien, 2026-10-04, 2/3"): a frozen
--                          snapshot of the definition plus progress. A personal
--                          assignment has a user_id, a group one has none (the
--                          whole workspace shares one progress counter).
--
-- AUTOMATIC PROGRESS (nobody presses "I did it")
--   Existing tables get AFTER INSERT triggers that call
--   _challenge_event(user, event_type, amount, dedupe_key, meta, source_key).
--   Events: nickname_created, nickname_rated, nickname_anecdote_added,
--   quote_added, anecdote_added, poem_created, poem_rated, poem_commented,
--   poetry_daily_completed, battle_created, battle_voted, battle_participated,
--   battle_won, beer_added, beer_rated, beer_session_participated,
--   perfect_pour, perfect_pour_given, daily_completed (the engine's own).
--   quiz_*, prediction_*, chaos_* have no source feature yet; the same hook
--   will serve them. There is deliberately NO client-callable event RPC: the
--   server derives progress from real rows, so it cannot be forged.
--   * a trigger never fails the original action (errors are swallowed)
--   * only active Office Lore members count (app scoping)
--   * source_key makes a replayed event a no-op; dedupe_key makes "rate 3
--     nicknames" mean 3 DIFFERENT nicknames (vote toggling cannot farm it)
--
-- REWARDS (modular): a reward is {"lines":[{kind, amount, category?}, ...]}.
--   _grant_challenge_reward dispatches on kind:
--     player_xp, category_xp   a row in the grant ledger (the ledger IS the XP)
--     gauntlet_fragments       fragments; every N (config) become a Royal Gauntlet
--     mystery / cosmetic / achievement   recorded as 'pending' until built
--   A new reward kind = one more WHEN branch.
--
-- CLAIMING is idempotent at the database: a unique claim row per
-- (assignment, user) and a unique grant per (assignment, user, line) mean a
-- double click, refresh, realtime echo, second tab or race can never pay twice.
--
-- RESET without cron: ensure_challenge_assignments() is called by the app on
-- first visit of a day/week and creates what is missing (deterministic
-- pick per user+period, conflict-safe). Day/week boundaries use one timezone
-- (_challenge_tz(), Europe/Brussels), weeks start on Monday (ISO weeks).
-- Completed-but-unclaimed challenges stay claimable after they expire.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0047.
-- =================================================================

-- =================================================================
-- SECTION 1 — config
-- =================================================================
create or replace function public._challenge_tz() returns text as $$ select 'Europe/Brussels'::text; $$ language sql immutable;
create or replace function public._fragments_per_gauntlet() returns int as $$ select 3; $$ language sql immutable;
-- how many of each type a user (or the group) gets per period
create or replace function public._challenge_slots(p_type text) returns int as $$
  select case p_type when 'personal_daily' then 3 when 'group_daily' then 1 when 'personal_weekly' then 2
                     when 'group_weekly' then 1 when 'rebellion' then 1 else 0 end;
$$ language sql immutable;

-- =================================================================
-- SECTION 2 — tables
-- =================================================================
create table if not exists public.challenge_definitions (
  id text primary key,
  app_id text not null default 'officelore',
  type text not null check (type in ('personal_daily', 'group_daily', 'personal_weekly', 'group_weekly', 'rebellion')),
  category text not null check (category in ('nickname', 'poetry', 'beer', 'battle', 'lore', 'quiz', 'social', 'chaos', 'mixed')),
  title text not null,
  description text not null,
  difficulty text not null default 'normal' check (difficulty in ('easy', 'normal', 'hard', 'special')),
  event_type text not null,
  target int not null check (target > 0),
  requirements jsonb not null default '{}',   -- e.g. {"min_rating": 8} against the event's meta
  reward jsonb not null default '{"lines":[]}',
  audience text not null default 'everyone' check (audience in ('everyone', 'non_lord', 'lord')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.challenge_assignments (
  id uuid primary key default gen_random_uuid(),
  app_id text not null default 'officelore',
  definition_id text not null references public.challenge_definitions(id),
  user_id uuid references public.profiles(id),      -- null = a group challenge
  type text not null,
  category text not null,
  title text not null,
  description text not null,
  difficulty text not null,
  event_type text not null,
  requirements jsonb not null default '{}',
  reward jsonb not null default '{"lines":[]}',
  target int not null,
  progress int not null default 0 check (progress >= 0),
  period_key text not null,                          -- '2026-10-04' or '2026-W41'
  starts_at timestamptz not null,
  expires_at timestamptz not null,
  completed_at timestamptz,
  claimed_at timestamptz,                            -- personal challenges (group claims live in challenge_claims)
  status text not null default 'active' check (status in ('active', 'completed', 'claimed', 'expired')),
  created_at timestamptz not null default now()
);
-- one assignment per definition per owner per period: generation is race-safe
create unique index if not exists challenge_assignments_unique
  on public.challenge_assignments (app_id, definition_id, (coalesce(user_id::text, 'group')), period_key);
create index if not exists challenge_assignments_user on public.challenge_assignments (user_id, status);
create index if not exists challenge_assignments_event on public.challenge_assignments (app_id, event_type, status);

create table if not exists public.challenge_contributions (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  amount int not null default 0,
  primary key (assignment_id, user_id)
);

-- every progress event ever seen (audit; source_key makes replays harmless)
create table if not exists public.challenge_events (
  id uuid primary key default gen_random_uuid(),
  app_id text not null default 'officelore',
  user_id uuid not null references public.profiles(id),
  event_type text not null,
  amount int not null default 1,
  dedupe_key text,
  source_key text,
  meta jsonb not null default '{}',
  occurred_at timestamptz not null default now()
);
create unique index if not exists challenge_events_source on public.challenge_events (source_key) where source_key is not null;
create index if not exists challenge_events_user on public.challenge_events (user_id, occurred_at desc);

-- "count each nickname once per challenge"
create table if not exists public.challenge_progress_marks (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null,
  dedupe_key text not null,
  primary key (assignment_id, user_id, dedupe_key)
);

create table if not exists public.challenge_claims (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  claimed_at timestamptz not null default now(),
  primary key (assignment_id, user_id)
);

-- the reward ledger: one row per reward line actually paid out
create table if not exists public.challenge_reward_grants (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  line_no int not null,
  kind text not null,
  amount int not null default 0,
  category text,
  status text not null default 'applied' check (status in ('applied', 'pending')),
  created_at timestamptz not null default now(),
  unique (assignment_id, user_id, line_no)
);

create table if not exists public.gauntlet_fragments (
  user_id uuid primary key references public.profiles(id),
  fragments int not null default 0 check (fragments >= 0),
  updated_at timestamptz not null default now()
);

-- Gauntlet ledger: converting fragments
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.royal_gauntlet_ledger'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%reason%';
  if v_name is not null then execute format('alter table public.royal_gauntlet_ledger drop constraint %I', v_name); end if;
end $$;
alter table public.royal_gauntlet_ledger add constraint royal_gauntlet_ledger_reason_check
  check (reason in ('admin_grant', 'throne_challenge', 'throne_refund', 'throne_coup', 'coup_refund', 'fragment_convert'));

-- =================================================================
-- SECTION 3 — RLS (reads only; every write goes through the functions below)
-- =================================================================
alter table public.challenge_definitions enable row level security;
alter table public.challenge_assignments enable row level security;
alter table public.challenge_contributions enable row level security;
alter table public.challenge_events enable row level security;
alter table public.challenge_progress_marks enable row level security;   -- no policy: private
alter table public.challenge_claims enable row level security;
alter table public.challenge_reward_grants enable row level security;
alter table public.gauntlet_fragments enable row level security;

drop policy if exists "Challenge definitions: read" on public.challenge_definitions;
create policy "Challenge definitions: read" on public.challenge_definitions for select to authenticated
  using (public.is_app_member(app_id));
drop policy if exists "Challenge assignments: read" on public.challenge_assignments;
create policy "Challenge assignments: read" on public.challenge_assignments for select to authenticated
  using (public.is_app_member(app_id) and (user_id is null or user_id = auth.uid()));
drop policy if exists "Challenge contributions: read" on public.challenge_contributions;
create policy "Challenge contributions: read" on public.challenge_contributions for select to authenticated
  using (exists (select 1 from public.challenge_assignments a where a.id = assignment_id and public.is_app_member(a.app_id)));
drop policy if exists "Challenge events: read own" on public.challenge_events;
create policy "Challenge events: read own" on public.challenge_events for select to authenticated
  using (user_id = auth.uid() and public.is_app_member(app_id));
drop policy if exists "Challenge claims: read own" on public.challenge_claims;
create policy "Challenge claims: read own" on public.challenge_claims for select to authenticated
  using (user_id = auth.uid());
drop policy if exists "Challenge grants: read own" on public.challenge_reward_grants;
create policy "Challenge grants: read own" on public.challenge_reward_grants for select to authenticated
  using (user_id = auth.uid());
drop policy if exists "Gauntlet fragments: read own" on public.gauntlet_fragments;
create policy "Gauntlet fragments: read own" on public.gauntlet_fragments for select to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

do $$
declare
  t text;
begin
  foreach t in array array['challenge_assignments', 'challenge_contributions', 'challenge_claims', 'challenge_reward_grants', 'gauntlet_fragments'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- =================================================================
-- SECTION 4 — the engine
-- =================================================================
-- requirement filter: {"min_rating": 8} needs meta.rating >= 8, {"eq_style": "Tripel"} needs meta.style = 'Tripel'
create or replace function public._challenge_requirements_met(p_req jsonb, p_meta jsonb)
returns boolean as $$
  select coalesce(bool_and(
    case when r.k like 'min\_%' then coalesce((p_meta->>substr(r.k, 5))::numeric, -1e18) >= r.v::numeric
         when r.k like 'eq\_%'  then (p_meta->>substr(r.k, 4)) = r.v
         else true end), true)
  from jsonb_each_text(coalesce(p_req, '{}'::jsonb)) as r(k, v);
$$ language sql immutable;

create or replace function public._challenge_event(
  p_user uuid, p_event text, p_amount int default 1, p_dedupe text default null,
  p_meta jsonb default '{}'::jsonb, p_source text default null)
returns void as $$
declare
  a record;
  v_add int;
  v_done boolean;
begin
  if p_user is null or p_amount is null or p_amount <= 0 then return; end if;
  -- app scoping: only active Office Lore members ever make progress here
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return;
  end if;

  insert into public.challenge_events (app_id, user_id, event_type, amount, dedupe_key, source_key, meta)
    values ('officelore', p_user, p_event, p_amount, p_dedupe, p_source, coalesce(p_meta, '{}'::jsonb))
    on conflict (source_key) where source_key is not null do nothing;
  if not found then return; end if;   -- this very event was already processed

  for a in
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements
    from public.challenge_assignments asg
    where asg.app_id = 'officelore' and asg.status = 'active' and asg.event_type = p_event
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
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- creates what is missing for p_user at moment p_at (the public RPC passes now();
-- internal so tests can step into another day or week)
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
  v_wk_key text := to_char(v_local, 'IYYY-"W"IW');
  v_lord uuid := (select user_id from public.abt_reigns where ended_at is null limit 1);
  v_type text;
  v_key text; v_from timestamptz; v_to timestamptz;
  v_owner uuid;
  v_have int; v_want int; v_created int := 0; v_n int;
begin
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return 0;
  end if;
  perform pg_advisory_xact_lock(hashtext('challenge_gen:' || p_user::text));

  -- what is over is over (completed ones stay claimable)
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

    -- deterministic pick (same on refresh and in a second tab), never a definition already assigned
    insert into public.challenge_assignments
      (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, requirements, reward,
       target, period_key, starts_at, expires_at)
    select 'officelore', d.id, v_owner, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.requirements, d.reward,
           d.target, v_key, v_from, v_to
    from public.challenge_definitions d
    where d.app_id = 'officelore' and d.is_active and d.type = v_type
      and (d.audience = 'everyone'
           or (d.audience = 'non_lord' and p_user is distinct from v_lord)
           or (d.audience = 'lord' and p_user is not distinct from v_lord))
      and not exists (select 1 from public.challenge_assignments x
                      where x.app_id = 'officelore' and x.definition_id = d.id and x.period_key = v_key and x.user_id is not distinct from v_owner)
    order by md5(d.id || coalesce(v_owner::text, 'group') || v_key)
    limit v_want - v_have
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_created := v_created + v_n;
  end loop;
  return v_created;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.ensure_challenge_assignments()
returns jsonb as $$
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  return jsonb_build_object('created', public._ensure_challenge_assignments_for(auth.uid(), now()));
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — rewards (modular) and claiming (idempotent)
-- =================================================================
create or replace function public._grant_challenge_reward(p_user uuid, p_assignment uuid, p_line jsonb, p_line_no int)
returns void as $$
declare
  v_kind text := p_line->>'kind';
  v_amount int := coalesce((p_line->>'amount')::int, 0);
  v_status text := case when v_kind in ('player_xp', 'category_xp', 'gauntlet_fragments') then 'applied' else 'pending' end;
  v_frag int;
  v_per int := public._fragments_per_gauntlet();
begin
  -- the unique (assignment, user, line) is the last line of defence against a double payout
  insert into public.challenge_reward_grants (assignment_id, user_id, line_no, kind, amount, category, status)
    values (p_assignment, p_user, p_line_no, v_kind, v_amount, p_line->>'category', v_status)
    on conflict (assignment_id, user_id, line_no) do nothing;
  if not found then return; end if;

  if v_kind = 'gauntlet_fragments' and v_amount > 0 then
    insert into public.gauntlet_fragments (user_id, fragments) values (p_user, v_amount)
      on conflict (user_id) do update set fragments = public.gauntlet_fragments.fragments + excluded.fragments, updated_at = now()
      returning fragments into v_frag;
    -- every N fragments are forged into a Royal Gauntlet
    while v_frag >= v_per loop
      update public.gauntlet_fragments set fragments = fragments - v_per, updated_at = now() where user_id = p_user returning fragments into v_frag;
      insert into public.royal_gauntlet_balances (user_id, balance) values (p_user, 1)
        on conflict (user_id) do update set balance = public.royal_gauntlet_balances.balance + 1, updated_at = now();
      insert into public.royal_gauntlet_ledger (user_id, delta, reason, note) values (p_user, 1, 'fragment_convert', v_per || ' fragments');
    end loop;
  end if;
  -- player_xp / category_xp: the grant row IS the ledger entry.
  -- mystery / cosmetic / achievement: stored as 'pending' until their handler is built.
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.claim_challenge(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_line jsonb;
  v_no int := 0;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  -- serialize: two tabs / a double click queue up here, the second finds the claim and pays nothing
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
    perform public._grant_challenge_reward(auth.uid(), a.id, v_line, v_no);
  end loop;

  if a.user_id is not null then
    update public.challenge_assignments set status = 'claimed', claimed_at = now() where id = a.id;
  end if;
  return jsonb_build_object('status', 'claimed', 'lines', coalesce(a.reward->'lines', '[]'::jsonb));
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — event triggers on the existing features
-- =================================================================
-- Each one swallows its own errors: a challenge must never break a nickname, a poem or a beer.
create or replace function public._ch_t_nickname() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'nickname_created', 1, null, jsonb_build_object('nickname_id', new.id), 'nicknames:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_nickname_anecdote() returns trigger as $$
begin
  begin
    if coalesce(btrim(old.anecdote), '') = '' and coalesce(btrim(new.anecdote), '') <> '' then
      perform public._challenge_event(coalesce(new.updated_by_user_id, new.created_by_user_id), 'nickname_anecdote_added', 1, null,
        jsonb_build_object('nickname_id', new.id), 'nickname_anecdote:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_nickname_vote() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'nickname_rated', 1, 'nickname:' || new.nickname_id,
      jsonb_build_object('nickname_id', new.nickname_id, 'vote', new.vote_type), 'nickname_votes:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_quote() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'quote_added', 1, null, '{}'::jsonb, 'quotes:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_anecdote() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'anecdote_added', 1, null, '{}'::jsonb, 'anecdotes:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_poem() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.author_user_id, 'poem_created', 1, null, jsonb_build_object('poem_id', new.id, 'mood', new.mood), 'poems:' || new.id);
    if new.is_daily_challenge then
      perform public._challenge_event(new.author_user_id, 'poetry_daily_completed', 1, null, jsonb_build_object('poem_id', new.id), 'poems_daily:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_poem_reaction() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'poem_rated', 1, 'poem:' || new.poem_id,
      jsonb_build_object('poem_id', new.poem_id, 'reaction', new.reaction_type), 'poem_reactions:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_poem_comment() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'poem_commented', 1, null, jsonb_build_object('poem_id', new.poem_id), 'poem_comments:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_battle() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'battle_created', 1, null, jsonb_build_object('battle_id', new.id), 'battles:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_battle_vote() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'battle_voted', 1, 'battle:' || new.battle_id, jsonb_build_object('battle_id', new.battle_id), 'battle_votes:' || new.id);
    perform public._challenge_event(new.user_id, 'battle_participated', 1, 'battle:' || new.battle_id, jsonb_build_object('battle_id', new.battle_id), 'battle_part:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

-- a battle is WON by the person who created the winning nickname
create or replace function public._ch_t_battle_finished() returns trigger as $$
declare
  v_owner uuid;
begin
  begin
    if new.status = 'finished' and old.status is distinct from 'finished' and new.winner_nickname_id is not null then
      select created_by_user_id into v_owner from public.nicknames where id = new.winner_nickname_id;
      perform public._challenge_event(v_owner, 'battle_won', 1, null, jsonb_build_object('battle_id', new.id), 'battle_won:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_beer() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'beer_added', 1, null, jsonb_build_object('beer_id', new.id), 'beers:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_beer_rating() returns trigger as $$
begin
  begin
    if new.rating is not null then
      perform public._challenge_event(new.user_id, 'beer_rated', 1, 'beer:' || new.beer_id,
        jsonb_build_object('beer_id', new.beer_id, 'rating', new.rating), 'beer_ratings:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_session_participant() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'beer_session_participated', 1, 'session:' || new.session_id,
      jsonb_build_object('session_id', new.session_id), 'session_part:' || new.session_id || ':' || new.user_id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_perfect_pour() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.received_by_user_id, 'perfect_pour', 1, null, jsonb_build_object('session_id', new.session_id), 'pp_recv:' || new.id);
    perform public._challenge_event(new.given_by_user_id, 'perfect_pour_given', 1, null, jsonb_build_object('session_id', new.session_id), 'pp_give:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_ch_nickname on public.nicknames;
create trigger trg_ch_nickname after insert on public.nicknames for each row execute procedure public._ch_t_nickname();
drop trigger if exists trg_ch_nickname_anecdote on public.nicknames;
create trigger trg_ch_nickname_anecdote after update of anecdote on public.nicknames for each row execute procedure public._ch_t_nickname_anecdote();
drop trigger if exists trg_ch_nickname_vote on public.nickname_votes;
create trigger trg_ch_nickname_vote after insert on public.nickname_votes for each row execute procedure public._ch_t_nickname_vote();
drop trigger if exists trg_ch_quote on public.quotes;
create trigger trg_ch_quote after insert on public.quotes for each row execute procedure public._ch_t_quote();
drop trigger if exists trg_ch_anecdote on public.anecdotes;
create trigger trg_ch_anecdote after insert on public.anecdotes for each row execute procedure public._ch_t_anecdote();
drop trigger if exists trg_ch_poem on public.poems;
create trigger trg_ch_poem after insert on public.poems for each row execute procedure public._ch_t_poem();
drop trigger if exists trg_ch_poem_reaction on public.poem_reactions;
create trigger trg_ch_poem_reaction after insert on public.poem_reactions for each row execute procedure public._ch_t_poem_reaction();
drop trigger if exists trg_ch_poem_comment on public.poem_comments;
create trigger trg_ch_poem_comment after insert on public.poem_comments for each row execute procedure public._ch_t_poem_comment();
drop trigger if exists trg_ch_battle on public.nickname_battles;
create trigger trg_ch_battle after insert on public.nickname_battles for each row execute procedure public._ch_t_battle();
drop trigger if exists trg_ch_battle_vote on public.nickname_battle_votes;
create trigger trg_ch_battle_vote after insert on public.nickname_battle_votes for each row execute procedure public._ch_t_battle_vote();
drop trigger if exists trg_ch_battle_finished on public.nickname_battles;
create trigger trg_ch_battle_finished after update of status on public.nickname_battles for each row execute procedure public._ch_t_battle_finished();
drop trigger if exists trg_ch_beer on public.beers;
create trigger trg_ch_beer after insert on public.beers for each row execute procedure public._ch_t_beer();
drop trigger if exists trg_ch_beer_rating on public.beer_ratings;
create trigger trg_ch_beer_rating after insert on public.beer_ratings for each row execute procedure public._ch_t_beer_rating();
drop trigger if exists trg_ch_session_participant on public.beer_session_participants;
create trigger trg_ch_session_participant after insert on public.beer_session_participants for each row execute procedure public._ch_t_session_participant();
drop trigger if exists trg_ch_perfect_pour on public.perfect_pours;
create trigger trg_ch_perfect_pour after insert on public.perfect_pours for each row execute procedure public._ch_t_perfect_pour();

-- =================================================================
-- SECTION 7 — a few TEST definitions (content comes later: just INSERT more rows)
-- =================================================================
insert into public.challenge_definitions (id, type, category, title, description, difficulty, event_type, target, reward, audience) values
  ('d_nick_rate_3', 'personal_daily', 'nickname', 'Rate 3 nicknames', 'React to three different nicknames on the Nickname Wall.', 'easy', 'nickname_rated', 3,
     '{"lines":[{"kind":"player_xp","amount":10},{"kind":"category_xp","category":"nickname","amount":5}]}', 'everyone'),
  ('d_beer_rate_1', 'personal_daily', 'beer', 'Rate a beer', 'Rate any beer you have tried.', 'easy', 'beer_rated', 1,
     '{"lines":[{"kind":"player_xp","amount":8},{"kind":"category_xp","category":"beer","amount":4}]}', 'everyone'),
  ('d_poem_react_1', 'personal_daily', 'poetry', 'React to a poem', 'Leave a reaction on a poem on the Poetry Wall.', 'easy', 'poem_rated', 1,
     '{"lines":[{"kind":"player_xp","amount":8},{"kind":"category_xp","category":"poetry","amount":4}]}', 'everyone'),
  ('d_battle_vote_1', 'personal_daily', 'battle', 'Cast a battle vote', 'Vote in a Nickname Battle.', 'normal', 'battle_voted', 1,
     '{"lines":[{"kind":"player_xp","amount":12},{"kind":"gauntlet_fragments","amount":1}]}', 'everyone'),
  ('d_nick_new_1', 'personal_daily', 'nickname', 'Invent a nickname', 'Add a brand-new nickname to the Wall.', 'normal', 'nickname_created', 1,
     '{"lines":[{"kind":"player_xp","amount":15}]}', 'everyone'),
  ('g_beer_rate_5', 'group_daily', 'beer', 'Together: rate 5 beers', 'The whole team: five beer ratings today.', 'normal', 'beer_rated', 5,
     '{"lines":[{"kind":"player_xp","amount":15},{"kind":"gauntlet_fragments","amount":1}]}', 'everyone'),
  ('w_nick_new_3', 'personal_weekly', 'nickname', 'Three new nicknames', 'Add three new nicknames this week.', 'normal', 'nickname_created', 3,
     '{"lines":[{"kind":"player_xp","amount":40},{"kind":"category_xp","category":"nickname","amount":15}]}', 'everyone'),
  ('w_dailies_5', 'personal_weekly', 'mixed', 'Daily devotion', 'Complete five Daily Challenges this week.', 'hard', 'daily_completed', 5,
     '{"lines":[{"kind":"player_xp","amount":50},{"kind":"gauntlet_fragments","amount":2}]}', 'everyone'),
  ('w_poem_write_2', 'personal_weekly', 'poetry', 'Two poems', 'Write two poems this week.', 'normal', 'poem_created', 2,
     '{"lines":[{"kind":"player_xp","amount":40},{"kind":"category_xp","category":"poetry","amount":15}]}', 'everyone'),
  ('gw_poem_react_8', 'group_weekly', 'poetry', 'The Poetry Wall lives', 'Together: eight reactions on the Poetry Wall this week.', 'normal', 'poem_rated', 8,
     '{"lines":[{"kind":"player_xp","amount":30},{"kind":"gauntlet_fragments","amount":1}]}', 'everyone'),
  ('gw_sessions_2', 'group_weekly', 'beer', 'Raise a glass together', 'Take part in two Beer Sessions this week.', 'hard', 'beer_session_participated', 2,
     '{"lines":[{"kind":"player_xp","amount":40},{"kind":"gauntlet_fragments","amount":2}]}', 'everyone'),
  ('r_rebel_votes_5', 'rebellion', 'battle', 'Rebellion: the people vote', 'You are not the Abt Lord. Cast five battle votes this week and stir the realm.', 'special', 'battle_voted', 5,
     '{"lines":[{"kind":"player_xp","amount":40},{"kind":"gauntlet_fragments","amount":3}]}', 'non_lord')
on conflict (id) do update set
  type = excluded.type, category = excluded.category, title = excluded.title, description = excluded.description,
  difficulty = excluded.difficulty, event_type = excluded.event_type, target = excluded.target, reward = excluded.reward, audience = excluded.audience;

-- =================================================================
-- SECTION 8 — grants
-- =================================================================
revoke all on function public._challenge_tz() from public, anon, authenticated;
revoke all on function public._fragments_per_gauntlet() from public, anon, authenticated;
revoke all on function public._challenge_slots(text) from public, anon, authenticated;
revoke all on function public._challenge_requirements_met(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public._challenge_event(uuid, text, int, text, jsonb, text) from public, anon, authenticated;
revoke all on function public._ensure_challenge_assignments_for(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public._grant_challenge_reward(uuid, uuid, jsonb, int) from public, anon, authenticated;

revoke all on function public.ensure_challenge_assignments() from public, anon;
revoke all on function public.claim_challenge(uuid) from public, anon;
grant execute on function public.ensure_challenge_assignments() to authenticated;
grant execute on function public.claim_challenge(uuid) to authenticated;
