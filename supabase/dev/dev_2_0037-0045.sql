-- DEV bundle part 2/5: migrations 0037 to 0045. Run the parts in order, each once, in a NEW empty Supabase project (never in production).

-- =========== 0037_throne_challenges_and_prestige.sql ===========
-- =================================================================
-- OFFICE LORE — THRONE CHALLENGES & THE THREE PRESTIGE POSITIONS
-- =================================================================
-- Until now the Abt Lord was simply "whoever has the most Beer XP":
-- check_abt_throne() (0004, extended in 0018) swapped the open
-- abt_reigns row to the XP leader on every beer xp_events insert.
-- From here on prestige is split in three:
--
--   Abt Lord        = the open abt_reigns row. Only changes through an
--                     official Throne Challenge (below). Beer XP alone
--                     never dethrones anyone.
--   High Brewmaster = highest Beer XP (user_xp_totals.beer_xp). Purely
--                     derived, never challengeable, Beer XP is never
--                     reset or touched.
--   Greatest Abt    = historical dynasty ranking, total days ruled
--                     across all abt_reigns (derived client-side AND in
--                     _sync_absolute_abt() with identical day-math).
--   Absolute Abt    = one user holds all three at once. Derived live
--                     in the client; absolute_abt_periods only records
--                     the history (for future trophies).
--
-- Throne Challenge = a Beer XP duel over a fixed 7-day window. A member
-- who is not the Abt Lord challenges the lord; only Beer XP earned
-- DURING the window counts for either side (summed from xp_events);
-- the challenger must earn strictly more -- a tie keeps the Abt Lord.
-- One active challenge at a time. Resolution is lazy (no pg_cron in
-- this project): _resolve_expired_throne_challenge() runs from the xp
-- trigger and from the client on login, exactly like sync_abt_milestones.
--
-- Additive: nothing is dropped, abt_reigns/Beer XP/sessions/ratings/
-- perfect pours/cosmetics are untouched. The ONE intentional change to
-- throne logic is check_abt_throne() losing its dethrone-by-XP branch
-- (same function name, so trg_check_abt_throne keeps pointing at it).
-- Same app-scoping pattern as every table since 0015.
--
-- Tunable constants: the window ('7 days') lives in
-- create_throne_challenge(); the tie rule lives in
-- _resolve_expired_throne_challenge() ("strictly greater").
--
-- Run this once in the Supabase SQL Editor, after 0036.
-- =================================================================

-- =================================================================
-- SECTION 1 — tables
-- =================================================================
create table public.throne_challenges (
  id uuid primary key default gen_random_uuid(),
  reign_id uuid not null references public.abt_reigns(id),
  defender_user_id uuid not null references public.profiles(id),
  challenger_user_id uuid not null references public.profiles(id),
  status text not null default 'active'
    check (status in ('active', 'challenger_won', 'defender_won', 'cancelled')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  defender_xp_gained int,
  challenger_xp_gained int,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

-- hard guarantee: at most one active challenge, enforced by Postgres
create unique index one_active_throne_challenge on public.throne_challenges ((1)) where status = 'active';

create table public.absolute_abt_periods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index one_open_absolute_abt_period on public.absolute_abt_periods ((1)) where ended_at is null;

alter table public.throne_challenges enable row level security;
create policy "Throne challenges: read" on public.throne_challenges for select to authenticated
  using (public.is_app_member('officelore'));

alter table public.absolute_abt_periods enable row level security;
create policy "Absolute abt periods: read" on public.absolute_abt_periods for select to authenticated
  using (public.is_app_member('officelore'));

-- writes are RPC/trigger-only: no client insert/update/delete policy

alter publication supabase_realtime add table public.throne_challenges;
alter publication supabase_realtime add table public.absolute_abt_periods;

-- =================================================================
-- SECTION 2 — internal: Absolute Abt history sync
-- =================================================================
-- No auth check on purpose (also called from the xp trigger); revoked
-- from every client role below. Public wrapper further down.
create or replace function public._sync_absolute_abt()
returns void as $$
declare
  v_lord uuid;
  v_brew uuid;
  v_greatest uuid;
  v_open record;
begin
  perform pg_advisory_xact_lock(918273645);

  select user_id into v_lord from public.abt_reigns where ended_at is null limit 1;

  select user_id into v_brew from public.user_xp_totals
    where beer_xp > 0 order by beer_xp desc, user_id limit 1;

  -- Greatest Abt = total days ruled (same floor-per-reign day-math as
  -- getReignDays/getTotalDaysInPower client-side); ties: most captures,
  -- then user_id. Someone with 0 full days is not "Greatest".
  select t.user_id into v_greatest from (
    select r.user_id,
           sum(greatest(0, floor(extract(epoch from (coalesce(r.ended_at, now()) - r.started_at)) / 86400))) as days,
           count(*) as captures
    from public.abt_reigns r
    group by r.user_id
  ) t
  where t.days > 0
  order by t.days desc, t.captures desc, t.user_id
  limit 1;

  select * into v_open from public.absolute_abt_periods where ended_at is null limit 1;

  if v_lord is not null and v_lord = v_brew and v_lord = v_greatest then
    if v_open is null then
      insert into public.absolute_abt_periods (user_id) values (v_lord);
    elsif v_open.user_id <> v_lord then
      update public.absolute_abt_periods set ended_at = now() where id = v_open.id;
      insert into public.absolute_abt_periods (user_id) values (v_lord);
    end if;
  else
    if v_open is not null then
      update public.absolute_abt_periods set ended_at = now() where id = v_open.id;
    end if;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — internal: resolve an expired Throne Challenge
-- =================================================================
-- Idempotent. Returns true when a challenge was resolved.
create or replace function public._resolve_expired_throne_challenge()
returns boolean as $$
declare
  v_ch record;
  v_reign record;
  v_def_xp int;
  v_chal_xp int;
  v_def_total int;
  v_chal_total int;
  v_snapshot jsonb;
begin
  perform pg_advisory_xact_lock(918273645);

  select * into v_ch from public.throne_challenges
    where status = 'active' and ends_at <= now() limit 1;
  if v_ch is null then
    return false;
  end if;

  select coalesce(sum(points), 0) into v_def_xp from public.xp_events
    where user_id = v_ch.defender_user_id and xp_type = 'beer'
      and created_at >= v_ch.starts_at and created_at < v_ch.ends_at;
  select coalesce(sum(points), 0) into v_chal_xp from public.xp_events
    where user_id = v_ch.challenger_user_id and xp_type = 'beer'
      and created_at >= v_ch.starts_at and created_at < v_ch.ends_at;

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;

  -- safety net: the challenged reign is no longer the open one
  if v_reign is null or v_reign.id <> v_ch.reign_id then
    update public.throne_challenges
      set status = 'cancelled', defender_xp_gained = v_def_xp, challenger_xp_gained = v_chal_xp, resolved_at = now()
      where id = v_ch.id;
    return true;
  end if;

  if v_chal_xp > v_def_xp then
    select coalesce(beer_xp, 0) into v_def_total from public.user_xp_totals where user_id = v_ch.defender_user_id;
    select coalesce(beer_xp, 0) into v_chal_total from public.user_xp_totals where user_id = v_ch.challenger_user_id;
    select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = v_ch.defender_user_id;

    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_def_total, dethroned_by_user_id = v_ch.challenger_user_id,
          ending_loadout_snapshot = v_snapshot
      where id = v_reign.id;

    insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
    values (v_ch.challenger_user_id, now(), v_chal_total);

    update public.throne_challenges
      set status = 'challenger_won', defender_xp_gained = v_def_xp, challenger_xp_gained = v_chal_xp, resolved_at = now()
      where id = v_ch.id;
  else
    -- tie or fewer XP: the Abt Lord keeps the throne
    update public.throne_challenges
      set status = 'defender_won', defender_xp_gained = v_def_xp, challenger_xp_gained = v_chal_xp, resolved_at = now()
      where id = v_ch.id;
  end if;

  perform public._sync_absolute_abt();
  return true;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — check_abt_throne(): no more dethroning by XP
-- =================================================================
-- Same function name -> trg_check_abt_throne (0004) needs no change.
-- Only the very first coronation (no reign exists yet) still follows
-- Beer XP. After that the throne changes ONLY via a Throne Challenge.
create or replace function public.check_abt_throne()
returns trigger as $$
declare
  v_leader_id uuid;
  v_leader_xp int;
  v_current record;
begin
  perform pg_advisory_xact_lock(918273645);

  select * into v_current from public.abt_reigns where ended_at is null limit 1;

  if v_current is null then
    select user_id, beer_xp into v_leader_id, v_leader_xp
    from public.user_xp_totals
    order by beer_xp desc, user_id
    limit 1;

    if v_leader_xp is not null and v_leader_xp > 0 then
      insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
      values (v_leader_id, now(), v_leader_xp);
    end if;
  end if;

  perform public._resolve_expired_throne_challenge();
  perform public._sync_absolute_abt();

  return new;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — public RPCs (the only client write/maintenance path)
-- =================================================================
create or replace function public.create_throne_challenge()
returns uuid as $$
declare
  v_reign record;
  v_id uuid;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);

  -- an already-expired challenge must not block a new one
  perform public._resolve_expired_throne_challenge();

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;
  if v_reign is null then
    raise exception 'There is no Abt Lord to challenge yet';
  end if;
  if v_reign.user_id = auth.uid() then
    raise exception 'The Abt Lord cannot challenge themselves';
  end if;
  if exists (select 1 from public.throne_challenges where status = 'active') then
    raise exception 'A Throne Challenge is already underway';
  end if;

  insert into public.throne_challenges (reign_id, defender_user_id, challenger_user_id, starts_at, ends_at)
  values (v_reign.id, v_reign.user_id, auth.uid(), now(), now() + interval '7 days')
  returning id into v_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.resolve_throne_challenges()
returns boolean as $$
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;
  return public._resolve_expired_throne_challenge();
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.sync_absolute_abt()
returns void as $$
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;
  perform public._sync_absolute_abt();
end;
$$ language plpgsql security definer set search_path = public;

-- live duel numbers for the active challenge (same source as resolution)
create or replace function public.get_throne_challenge_progress()
returns table (
  challenge_id uuid,
  defender_user_id uuid,
  challenger_user_id uuid,
  defender_xp int,
  challenger_xp int,
  starts_at timestamptz,
  ends_at timestamptz
) as $$
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  return query
  select c.id, c.defender_user_id, c.challenger_user_id,
    (select coalesce(sum(x.points), 0)::int from public.xp_events x
       where x.user_id = c.defender_user_id and x.xp_type = 'beer'
         and x.created_at >= c.starts_at and x.created_at < c.ends_at),
    (select coalesce(sum(x.points), 0)::int from public.xp_events x
       where x.user_id = c.challenger_user_id and x.xp_type = 'beer'
         and x.created_at >= c.starts_at and x.created_at < c.ends_at),
    c.starts_at, c.ends_at
  from public.throne_challenges c
  where c.status = 'active';
end;
$$ language plpgsql security definer set search_path = public;

-- internals are never callable by client roles; public RPCs only for
-- authenticated users (each one also checks is_app_member itself)
revoke all on function public._sync_absolute_abt() from public, anon, authenticated;
revoke all on function public._resolve_expired_throne_challenge() from public, anon, authenticated;

revoke all on function public.create_throne_challenge() from public, anon;
revoke all on function public.resolve_throne_challenges() from public, anon;
revoke all on function public.sync_absolute_abt() from public, anon;
revoke all on function public.get_throne_challenge_progress() from public, anon;
grant execute on function public.create_throne_challenge() to authenticated;
grant execute on function public.resolve_throne_challenges() to authenticated;
grant execute on function public.sync_absolute_abt() to authenticated;
grant execute on function public.get_throne_challenge_progress() to authenticated;

-- =================================================================
-- SECTION 6 — one-time transition: the throne goes to the current
-- Beer XP leader, closed the normal way (same semantics as the OLD
-- trigger: strictly greater Beer XP) so Dynasty history stays correct.
-- After this, only a Throne Challenge can change the throne.
-- =================================================================
do $$
declare
  v_leader_id uuid;
  v_leader_xp int;
  v_current record;
  v_current_xp int;
  v_snapshot jsonb;
begin
  perform pg_advisory_xact_lock(918273645);

  select user_id, beer_xp into v_leader_id, v_leader_xp
  from public.user_xp_totals
  order by beer_xp desc, user_id
  limit 1;

  select * into v_current from public.abt_reigns where ended_at is null limit 1;

  if v_current is not null and v_leader_xp is not null and v_leader_xp > 0
     and v_current.user_id <> v_leader_id then
    select coalesce(beer_xp, 0) into v_current_xp from public.user_xp_totals where user_id = v_current.user_id;

    if v_leader_xp > v_current_xp then
      select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = v_current.user_id;

      update public.abt_reigns
        set ended_at = now(), ending_beer_xp = v_current_xp, dethroned_by_user_id = v_leader_id,
            ending_loadout_snapshot = v_snapshot
        where id = v_current.id;

      insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
      values (v_leader_id, now(), v_leader_xp);
    end if;
  end if;

  perform public._sync_absolute_abt();
end $$;

-- =========== 0038_best_of_three_throne_trials.sql ===========
-- =================================================================
-- OFFICE LORE — CHALLENGE FOR THE THRONE: BEST OF 3 TRIALS
-- =================================================================
-- Replaces the passive 7-day Beer XP duel from 0037 with a real
-- best-of-3 series of Trials. First to 2 Trial wins takes the throne.
--
--   Trial 1  challenger picks a Trial School
--   Trial 2  the Abt Lord picks a Trial School (the Lord's advantage)
--   Trial 3  only at 1-1: the FINAL TRIAL -- the throne chooses (a
--            random Trial from a random allowed school). 2-0 ends it.
--
-- A school choice draws a random Trial inside that school. Trials are
-- pure DATA (throne_trial_catalog) resolved by a small number of
-- resolution types (roll / answer / judge) -- adding a Trial = adding a
-- catalog row; adding a brand-new minigame type = one new resolution
-- value + one client renderer. The Throne Challenge itself never needs
-- rewriting.
--
-- State machine (throne_challenges.status):
--   pending         challenger created it, hasn't picked Trial 1's school yet
--   active          a Trial is being played / a school pick is due
--   awaiting_judge  the current Trial needs an independent judge
--   completed       someone reached 2 points (winner_user_id)
--   cancelled       challenger withdrew before Trial 1 / pending timed out
--
-- Asynchronous play: every step has a 48h deadline (step_deadline).
-- Lazy resolution, same as everything else here (no pg_cron): deadlines
-- are enforced from check_abt_throne(), resolve_throne_challenges() and
-- at the start of every challenge RPC. On expiry: unpicked school =
-- random school, unplayed Trial = lost by the non-responder (nobody
-- played = coin flip), unjudged Trial = coin flip, a never-started
-- pending challenge = cancelled.
--
-- Secrecy: the catalog (with answer keys) and the per-player
-- submissions have RLS enabled and NO client policy at all -- clients
-- can never read answers or the opponent's guess/roll early. The trial
-- row exposes only *_submitted booleans until the Trial resolves, plus
-- a snapshot of title/description/config.
--
-- Additive: nothing dropped. The 0037 XP-duel columns (ends_at,
-- *_xp_gained, resolved_at) stay but are retired. Same app-scoping
-- pattern as every table since 0015.
--
-- Run this once in the Supabase SQL Editor, after 0037.
-- =================================================================

-- =================================================================
-- SECTION 1 — throne_challenges: new state-machine columns
-- =================================================================
do $$
declare
  v_constraint_name text;
begin
  select conname into v_constraint_name
  from pg_constraint
  where conrelid = 'public.throne_challenges'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%status%';
  if v_constraint_name is not null then
    execute format('alter table public.throne_challenges drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.throne_challenges
  add column if not exists allow_real_life boolean not null default false,
  add column if not exists challenger_score int not null default 0,
  add column if not exists defender_score int not null default 0,
  add column if not exists winner_user_id uuid references public.profiles(id),
  add column if not exists started_at timestamptz,
  add column if not exists completed_at timestamptz,
  add column if not exists awaiting_pick_by uuid references public.profiles(id),
  add column if not exists step_deadline timestamptz;

alter table public.throne_challenges alter column ends_at drop not null;

-- any pre-existing XP-duel rows: keep them, in the new vocabulary
update public.throne_challenges
  set winner_user_id = case status
        when 'challenger_won' then challenger_user_id
        when 'defender_won' then defender_user_id
      end,
      completed_at = coalesce(resolved_at, now())
  where status in ('challenger_won', 'defender_won');
update public.throne_challenges set status = 'completed' where status in ('challenger_won', 'defender_won');

alter table public.throne_challenges add constraint throne_challenges_status_check
  check (status in ('pending', 'active', 'awaiting_judge', 'completed', 'cancelled'));

drop index if exists public.one_active_throne_challenge;
create unique index one_open_throne_challenge on public.throne_challenges ((1))
  where status in ('pending', 'active', 'awaiting_judge');

-- =================================================================
-- SECTION 2 — Trial catalog (private) + trials + submissions
-- =================================================================
create table public.throne_trial_catalog (
  id text primary key,
  school text not null check (school in ('pint', 'wisdom', 'lore', 'chaos', 'reflex', 'real_life')),
  title text not null,
  description text not null,
  resolution text not null check (resolution in ('roll', 'answer', 'judge')),
  public_config jsonb not null default '{}',
  answer_key jsonb, -- {"value": n} or {"source": "beers_count"|...}; never sent to clients
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.throne_trial_catalog enable row level security; -- deliberately NO policy

create table public.throne_challenge_trials (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references public.throne_challenges(id) on delete cascade,
  trial_no int not null check (trial_no between 1 and 3),
  picker_user_id uuid references public.profiles(id), -- null = the Final Trial (the throne chose)
  school text not null,
  catalog_id text not null references public.throne_trial_catalog(id),
  title text not null,
  description text not null,
  resolution text not null,
  public_config jsonb not null default '{}',
  status text not null default 'active' check (status in ('active', 'awaiting_judge', 'completed')),
  challenger_submitted boolean not null default false,
  defender_submitted boolean not null default false,
  challenger_result jsonb,
  defender_result jsonb,
  reveal jsonb,
  judge_user_id uuid references public.profiles(id),
  winner_user_id uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (challenge_id, trial_no)
);
alter table public.throne_challenge_trials enable row level security;
create policy "Throne challenge trials: read" on public.throne_challenge_trials for select to authenticated
  using (public.is_app_member('officelore'));

create table public.throne_trial_submissions (
  id uuid primary key default gen_random_uuid(),
  trial_id uuid not null references public.throne_challenge_trials(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  payload jsonb not null,
  created_at timestamptz not null default now(),
  unique (trial_id, user_id)
);
alter table public.throne_trial_submissions enable row level security; -- deliberately NO policy

alter publication supabase_realtime add table public.throne_challenge_trials;

-- placeholder Trials (real minigames come in later phases). REFLEX ones
-- are plain rolls until real-time minigames exist.
insert into public.throne_trial_catalog (id, school, title, description, resolution, public_config, answer_key) values
  ('pint_foam_fortune', 'pint', 'Foam Fortune', 'Roll the dice of the brewery gods. The highest roll takes the Trial.', 'roll', '{}', null),
  ('pint_beer_count', 'pint', 'The Great Beer Census', 'How many different beers has the Office registered in total? The closest guess wins.', 'answer', '{"unit":"beers"}', '{"source":"beers_count"}'),
  ('wisdom_eiffel', 'wisdom', 'Iron Lady', 'In which year was the Eiffel Tower completed? The closest guess wins.', 'answer', '{"unit":"year"}', '{"value":1889}'),
  ('wisdom_bones', 'wisdom', 'Skeleton Crew', 'How many bones does an adult human have? The closest guess wins.', 'answer', '{"unit":"bones"}', '{"value":206}'),
  ('lore_nickname_count', 'lore', 'Keepers of Names', 'How many nicknames exist on the Nickname Wall right now? The closest guess wins.', 'answer', '{"unit":"nicknames"}', '{"source":"nicknames_count"}'),
  ('lore_poem_count', 'lore', 'Verses of the Wall', 'How many poems are on the Poetry Wall right now? The closest guess wins.', 'answer', '{"unit":"poems"}', '{"source":"poems_count"}'),
  ('chaos_nickname_sprint', 'chaos', 'Nickname Sprint', 'Both players invent the best nickname for the judge, in 30 seconds. The judge decides.', 'judge', '{}', null),
  ('chaos_fake_holiday', 'chaos', 'Holiday Pitch', 'Both players pitch a brand-new fake Office Lore holiday. The judge decides.', 'judge', '{}', null),
  ('reflex_quick_draw', 'reflex', 'Quick Draw (placeholder)', 'The gunslingers of the taproom draw. For now the draw is a roll: highest wins.', 'roll', '{}', null),
  ('reflex_cap_flip', 'reflex', 'Bottle Cap Flip (placeholder)', 'A flick of the wrist, a roll of fate. Highest wins.', 'roll', '{}', null),
  ('real_bottle_flip', 'real_life', 'Bottle Flip Showdown', 'In real life: three bottle-flip attempts each. Most clean landings wins. The judge decides.', 'judge', '{}', null),
  ('real_arm_wrestle', 'real_life', 'Arm Wrestle', 'In real life: an arm-wrestling match at the nearest table. The judge decides.', 'judge', '{}', null);

-- =================================================================
-- SECTION 3 — internal helpers (revoked from client roles below)
-- =================================================================
create or replace function public._throne_answer_value(p_key jsonb)
returns numeric as $$
begin
  if p_key ? 'value' then
    return (p_key->>'value')::numeric;
  end if;
  return case p_key->>'source'
    when 'beers_count' then (select count(*) from public.beers)
    when 'nicknames_count' then (select count(*) from public.nicknames)
    when 'poems_count' then (select count(*) from public.poems)
    else 0
  end;
end;
$$ language plpgsql security definer set search_path = public;

-- draws a random unused, allowed catalog Trial. p_school null = random
-- school (the Final Trial / auto-pick). Falls back to any allowed Trial
-- when the chosen school has nothing usable left.
create or replace function public._pick_catalog_trial(p_challenge_id uuid, p_school text)
returns public.throne_trial_catalog as $$
declare
  c public.throne_challenges;
  v_judge_exists boolean;
  v_school text := p_school;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id;

  select exists (
    select 1 from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active = true
      and m.user_id not in (c.challenger_user_id, c.defender_user_id)
  ) into v_judge_exists;

  if v_school is not null then
    select t.* into v_cat from public.throne_trial_catalog t
      where t.is_active and t.school = v_school
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution <> 'judge' or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
      order by random() limit 1;
    if v_cat.id is not null then
      return v_cat;
    end if;
  end if;

  -- random school (or fallback): pick a school first so every school is
  -- equally likely regardless of how many Trials it has
  select s.school into v_school from (
    select distinct t.school from public.throne_trial_catalog t
      where t.is_active
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution <> 'judge' or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
  ) s order by random() limit 1;

  if v_school is null then
    raise exception 'No Trials available for this Throne Challenge';
  end if;

  select t.* into v_cat from public.throne_trial_catalog t
    where t.is_active and t.school = v_school
      and (c.allow_real_life or t.school <> 'real_life')
      and (t.resolution <> 'judge' or v_judge_exists)
      and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
    order by random() limit 1;
  return v_cat;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._start_throne_trial(p_challenge_id uuid, p_cat public.throne_trial_catalog, p_picker uuid)
returns uuid as $$
declare
  v_no int;
  v_id uuid;
  v_status text;
begin
  select count(*) + 1 into v_no from public.throne_challenge_trials where challenge_id = p_challenge_id;
  v_status := case when p_cat.resolution = 'judge' then 'awaiting_judge' else 'active' end;

  insert into public.throne_challenge_trials
    (challenge_id, trial_no, picker_user_id, school, catalog_id, title, description, resolution, public_config, status)
  values
    (p_challenge_id, v_no, p_picker, p_cat.school, p_cat.id, p_cat.title, p_cat.description, p_cat.resolution, p_cat.public_config, v_status)
  returning id into v_id;

  update public.throne_challenges
    set status = v_status,
        awaiting_pick_by = null,
        started_at = coalesce(started_at, now()),
        step_deadline = now() + interval '48 hours'
    where id = p_challenge_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- the throne changes hands (or not). Same reign swap as 0037.
create or replace function public._complete_throne_challenge(p_challenge_id uuid, p_winner uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_reign record;
  v_def_total int;
  v_chal_total int;
  v_snapshot jsonb;
begin
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.status in ('completed', 'cancelled') then
    return;
  end if;

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;

  if p_winner = c.challenger_user_id then
    if v_reign is null or v_reign.id <> c.reign_id then
      -- the challenged reign is no longer the open one: nothing to take
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;
      return;
    end if;

    select coalesce(beer_xp, 0) into v_def_total from public.user_xp_totals where user_id = c.defender_user_id;
    select coalesce(beer_xp, 0) into v_chal_total from public.user_xp_totals where user_id = c.challenger_user_id;
    select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = c.defender_user_id;

    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_def_total, dethroned_by_user_id = c.challenger_user_id,
          ending_loadout_snapshot = v_snapshot
      where id = v_reign.id;

    insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
    values (c.challenger_user_id, now(), v_chal_total);
  end if;

  update public.throne_challenges
    set status = 'completed', winner_user_id = p_winner, completed_at = now(), resolved_at = now(),
        awaiting_pick_by = null, step_deadline = null
    where id = c.id;

  perform public._sync_absolute_abt();
end;
$$ language plpgsql security definer set search_path = public;

-- scores a finished Trial and moves the series forward
create or replace function public._finish_throne_trial(p_trial_id uuid, p_winner uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
  v_chal int;
  v_def int;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.status = 'completed' then
    return;
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id for update;
  if p_winner not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Trial winner must be a participant';
  end if;

  update public.throne_challenge_trials
    set status = 'completed', winner_user_id = p_winner, completed_at = now()
    where id = t.id;

  v_chal := c.challenger_score + case when p_winner = c.challenger_user_id then 1 else 0 end;
  v_def := c.defender_score + case when p_winner = c.defender_user_id then 1 else 0 end;
  update public.throne_challenges set challenger_score = v_chal, defender_score = v_def where id = c.id;

  if v_chal >= 2 or v_def >= 2 then
    perform public._complete_throne_challenge(c.id, p_winner);
  elsif t.trial_no = 1 then
    -- Trial 2: the Abt Lord picks the school
    update public.throne_challenges
      set status = 'active', awaiting_pick_by = c.defender_user_id, step_deadline = now() + interval '48 hours'
      where id = c.id;
  else
    -- 1-1 after Trial 2: THE FINAL TRIAL, the throne chooses
    v_cat := public._pick_catalog_trial(c.id, null);
    perform public._start_throne_trial(c.id, v_cat, null);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- resolves a roll/answer Trial once both players have submitted
create or replace function public._resolve_submission_trial(p_trial_id uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  cat public.throne_trial_catalog;
  v_chal jsonb;
  v_def jsonb;
  v_target numeric;
  v_chal_score numeric;
  v_def_score numeric;
  v_winner uuid;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  select * into c from public.throne_challenges where id = t.challenge_id;
  select payload into v_chal from public.throne_trial_submissions where trial_id = t.id and user_id = c.challenger_user_id;
  select payload into v_def from public.throne_trial_submissions where trial_id = t.id and user_id = c.defender_user_id;

  if t.resolution = 'roll' then
    v_chal_score := (v_chal->>'roll')::numeric;
    v_def_score := (v_def->>'roll')::numeric;
    update public.throne_challenge_trials set challenger_result = v_chal, defender_result = v_def where id = t.id;
  else
    select * into cat from public.throne_trial_catalog where id = t.catalog_id;
    v_target := public._throne_answer_value(cat.answer_key);
    -- lower distance is better: compare negated distances
    v_chal_score := -abs((v_chal->>'guess')::numeric - v_target);
    v_def_score := -abs((v_def->>'guess')::numeric - v_target);
    update public.throne_challenge_trials
      set challenger_result = v_chal || jsonb_build_object('distance', abs((v_chal->>'guess')::numeric - v_target)),
          defender_result = v_def || jsonb_build_object('distance', abs((v_def->>'guess')::numeric - v_target)),
          reveal = jsonb_build_object('answer', v_target)
      where id = t.id;
  end if;

  if v_chal_score > v_def_score then
    v_winner := c.challenger_user_id;
  elsif v_def_score > v_chal_score then
    v_winner := c.defender_user_id;
  else
    v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
  end if;

  perform public._finish_throne_trial(t.id, v_winner);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — deadline enforcement (name kept: check_abt_throne() and
-- resolve_throne_challenges() already call it)
-- =================================================================
create or replace function public._resolve_expired_throne_challenge()
returns boolean as $$
declare
  c public.throne_challenges;
  t public.throne_challenge_trials;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_changed boolean := false;
  v_guard int := 0;
begin
  perform pg_advisory_xact_lock(918273645);

  loop
    v_guard := v_guard + 1;
    exit when v_guard > 10;

    select * into c from public.throne_challenges
      where status in ('pending', 'active', 'awaiting_judge')
        and step_deadline is not null and step_deadline <= now()
      limit 1;
    exit when c.id is null;
    v_changed := true;

    if c.status = 'pending' then
      -- the challenger never picked Trial 1's school: nothing was played, nobody lost
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;

    elsif c.awaiting_pick_by is not null then
      -- the picker didn't choose a school in time: a random school is drawn
      v_cat := public._pick_catalog_trial(c.id, null);
      perform public._start_throne_trial(c.id, v_cat, c.awaiting_pick_by);

    else
      select * into t from public.throne_challenge_trials
        where challenge_id = c.id and status <> 'completed'
        order by trial_no desc limit 1;

      if t.id is null then
        -- inconsistent state: close it safely
        update public.throne_challenges
          set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
          where id = c.id;
      else
        if t.resolution = 'judge' then
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        elsif t.challenger_submitted and not t.defender_submitted then
          v_winner := c.challenger_user_id; -- the non-responder forfeits
        elsif t.defender_submitted and not t.challenger_submitted then
          v_winner := c.defender_user_id;
        else
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        end if;
        update public.throne_challenge_trials
          set reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('timeout', true)
          where id = t.id;
        perform public._finish_throne_trial(t.id, v_winner);
      end if;
    end if;
  end loop;

  return v_changed;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — public RPCs
-- =================================================================
drop function if exists public.get_throne_challenge_progress();
drop function if exists public.create_throne_challenge();

create or replace function public.create_throne_challenge(p_allow_real_life boolean default false)
returns uuid as $$
declare
  v_reign record;
  v_id uuid;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;
  if v_reign is null then
    raise exception 'There is no Abt Lord to challenge yet';
  end if;
  if v_reign.user_id = auth.uid() then
    raise exception 'The Abt Lord cannot challenge themselves';
  end if;
  if exists (select 1 from public.throne_challenges where status in ('pending', 'active', 'awaiting_judge')) then
    raise exception 'A Throne Challenge is already underway';
  end if;

  insert into public.throne_challenges
    (reign_id, defender_user_id, challenger_user_id, allow_real_life, awaiting_pick_by, step_deadline, starts_at)
  values
    (v_reign.id, v_reign.user_id, auth.uid(), coalesce(p_allow_real_life, false), auth.uid(), now() + interval '48 hours', now())
  returning id into v_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.pick_throne_trial_school(p_challenge_id uuid, p_school text)
returns void as $$
declare
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.id is null or c.status not in ('pending', 'active') then
    raise exception 'This Throne Challenge is not waiting for a Trial School';
  end if;
  if c.awaiting_pick_by is distinct from auth.uid() then
    raise exception 'It is not your turn to choose a Trial School';
  end if;
  if p_school not in ('pint', 'wisdom', 'lore', 'chaos', 'reflex', 'real_life') then
    raise exception 'Unknown Trial School';
  end if;
  if p_school = 'real_life' and not c.allow_real_life then
    raise exception 'Real Life Trials are not allowed in this challenge';
  end if;

  v_cat := public._pick_catalog_trial(c.id, p_school);
  perform public._start_throne_trial(c.id, v_cat, auth.uid());
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.submit_throne_trial(p_trial_id uuid, p_payload jsonb default '{}')
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_payload jsonb;
  v_guess numeric;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'active' or t.resolution not in ('roll', 'answer') then
    raise exception 'This Trial is not open for submissions';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can play this Trial';
  end if;
  if exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = auth.uid()) then
    raise exception 'You have already played this Trial';
  end if;

  if t.resolution = 'roll' then
    v_payload := jsonb_build_object('roll', 1 + floor(random() * 100)::int);
  else
    begin
      v_guess := (p_payload->>'guess')::numeric;
    exception when others then
      v_guess := null;
    end;
    if v_guess is null then
      raise exception 'Enter a number as your guess';
    end if;
    v_payload := jsonb_build_object('guess', v_guess);
  end if;

  insert into public.throne_trial_submissions (trial_id, user_id, payload) values (t.id, auth.uid(), v_payload);

  if auth.uid() = c.challenger_user_id then
    update public.throne_challenge_trials set challenger_submitted = true where id = t.id;
  else
    update public.throne_challenge_trials set defender_submitted = true where id = t.id;
  end if;

  if exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = c.challenger_user_id)
     and exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = c.defender_user_id) then
    perform public._resolve_submission_trial(t.id);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.judge_throne_trial(p_trial_id uuid, p_winner uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'awaiting_judge' then
    raise exception 'This Trial is not waiting for a judge';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'A duelist cannot judge their own Trial';
  end if;
  if p_winner not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'The winner must be one of the duelists';
  end if;

  update public.throne_challenge_trials
    set judge_user_id = auth.uid(), reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid())
    where id = t.id;
  perform public._finish_throne_trial(t.id, p_winner);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.cancel_throne_challenge(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.id is null or c.challenger_user_id <> auth.uid() then
    raise exception 'Only the challenger can withdraw a challenge';
  end if;
  if c.status <> 'pending' or exists (select 1 from public.throne_challenge_trials where challenge_id = c.id) then
    raise exception 'The challenge has already begun';
  end if;

  update public.throne_challenges
    set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
    where id = c.id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — grants
-- =================================================================
revoke all on function public._throne_answer_value(jsonb) from public, anon, authenticated;
revoke all on function public._pick_catalog_trial(uuid, text) from public, anon, authenticated;
revoke all on function public._start_throne_trial(uuid, public.throne_trial_catalog, uuid) from public, anon, authenticated;
revoke all on function public._complete_throne_challenge(uuid, uuid) from public, anon, authenticated;
revoke all on function public._finish_throne_trial(uuid, uuid) from public, anon, authenticated;
revoke all on function public._resolve_submission_trial(uuid) from public, anon, authenticated;
revoke all on function public._resolve_expired_throne_challenge() from public, anon, authenticated;

revoke all on function public.create_throne_challenge(boolean) from public, anon;
revoke all on function public.pick_throne_trial_school(uuid, text) from public, anon;
revoke all on function public.submit_throne_trial(uuid, jsonb) from public, anon;
revoke all on function public.judge_throne_trial(uuid, uuid) from public, anon;
revoke all on function public.cancel_throne_challenge(uuid) from public, anon;
grant execute on function public.create_throne_challenge(boolean) to authenticated;
grant execute on function public.pick_throne_trial_school(uuid, text) to authenticated;
grant execute on function public.submit_throne_trial(uuid, jsonb) to authenticated;
grant execute on function public.judge_throne_trial(uuid, uuid) to authenticated;
grant execute on function public.cancel_throne_challenge(uuid) to authenticated;

-- =========== 0039_throne_challenge_pending_fix.sql ===========
-- =================================================================
-- OFFICE LORE — THRONE CHALLENGE: new challenges start as 'pending'
-- =================================================================
-- Fix for 0038: throne_challenges.status still defaulted to 'active'
-- (from 0037), and create_throne_challenge() didn't set a status, so a
-- freshly created challenge skipped 'pending' -- which broke "withdraw
-- before Trial 1" and the pending-timeout (both key off 'pending').
--
--  1. column default becomes 'pending'
--  2. create_throne_challenge() sets status explicitly
--  3. any challenge created by the bug (status 'active', no Trial yet,
--     waiting for the first school pick) is moved back to 'pending'
--
-- Idempotent. Run once in the Supabase SQL Editor, after 0038.
-- =================================================================

alter table public.throne_challenges alter column status set default 'pending';

update public.throne_challenges c
  set status = 'pending'
  where c.status = 'active'
    and c.awaiting_pick_by is not null
    and c.started_at is null
    and not exists (select 1 from public.throne_challenge_trials t where t.challenge_id = c.id);

create or replace function public.create_throne_challenge(p_allow_real_life boolean default false)
returns uuid as $$
declare
  v_reign record;
  v_id uuid;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;
  if v_reign is null then
    raise exception 'There is no Abt Lord to challenge yet';
  end if;
  if v_reign.user_id = auth.uid() then
    raise exception 'The Abt Lord cannot challenge themselves';
  end if;
  if exists (select 1 from public.throne_challenges where status in ('pending', 'active', 'awaiting_judge')) then
    raise exception 'A Throne Challenge is already underway';
  end if;

  insert into public.throne_challenges
    (reign_id, defender_user_id, challenger_user_id, status, allow_real_life, awaiting_pick_by, step_deadline, starts_at)
  values
    (v_reign.id, v_reign.user_id, auth.uid(), 'pending', coalesce(p_allow_real_life, false), auth.uid(), now() + interval '48 hours', now())
  returning id into v_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.create_throne_challenge(boolean) from public, anon;
grant execute on function public.create_throne_challenge(boolean) to authenticated;

-- =========== 0040_royal_gauntlets.sql ===========
-- =================================================================
-- OFFICE LORE — THE ROYAL GAUNTLET (access + cooldown + anti-spam)
-- =================================================================
-- Starting a Throne Challenge now costs 1 Royal Gauntlet. Gauntlets are
-- NOT a currency: they can't be bought, traded or sent. For now an admin
-- grants them from the SQL editor (see admin_grant_royal_gauntlets at the
-- bottom); later they are earned via Daily / Weekly Challenges.
--
--  1. royal_gauntlet_balances  one row per user, balance >= 0 (CHECK)
--  2. royal_gauntlet_ledger    append-only history. A UNIQUE index on
--                              challenge_id (per reason) makes it
--                              impossible to spend -- or refund -- the same
--                              Gauntlet for the same challenge twice.
--  3. create_throne_challenge  replaced: checks Gauntlet, cooldown, the
--                              expected Abt Lord, and the single open
--                              challenge rule, all inside one transaction
--                              under the throne advisory lock.
--  4. cooldown                 after a LOST challenge (defender won, incl.
--                              forfeits) the same challenger waits
--                              _throne_cooldown() before challenging again.
--                              Derived from throne_challenges, nothing stored.
--  5. refund trigger           a challenge that is cancelled (withdrawn or
--                              never started) gives its Gauntlet back, once.
--  6. get_throne_rules()       single source of truth for the cooldown and
--                              cost; the client reads it instead of
--                              hardcoding.
--
-- Additive, idempotent. Run once in the Supabase SQL Editor, after 0039.
-- =================================================================

-- -----------------------------------------------------------------
-- 1. Config (change here, the client follows via get_throne_rules())
-- -----------------------------------------------------------------
create or replace function public._throne_cooldown() returns interval as $$
  select interval '5 days';
$$ language sql immutable;

create or replace function public._throne_gauntlet_cost() returns int as $$
  select 1;
$$ language sql immutable;

-- -----------------------------------------------------------------
-- 2. Tables
-- -----------------------------------------------------------------
create table if not exists public.royal_gauntlet_balances (
  user_id uuid primary key references public.profiles(id),
  balance int not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.royal_gauntlet_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  delta int not null check (delta <> 0),
  reason text not null check (reason in ('admin_grant', 'throne_challenge', 'throne_refund')),
  challenge_id uuid references public.throne_challenges(id),
  note text,
  created_at timestamptz not null default now()
);

-- one spend and at most one refund per challenge: the same Gauntlet can
-- never be consumed (or given back) twice, whatever the client does
create unique index if not exists royal_gauntlet_one_spend_per_challenge
  on public.royal_gauntlet_ledger (challenge_id) where reason = 'throne_challenge';
create unique index if not exists royal_gauntlet_one_refund_per_challenge
  on public.royal_gauntlet_ledger (challenge_id) where reason = 'throne_refund';
create index if not exists royal_gauntlet_ledger_user on public.royal_gauntlet_ledger (user_id, created_at desc);

alter table public.royal_gauntlet_balances enable row level security;
alter table public.royal_gauntlet_ledger enable row level security;

-- members only ever see their OWN balance / history; no client write policy
-- exists, so every change goes through the SECURITY DEFINER functions below
drop policy if exists "Gauntlet balances: read own" on public.royal_gauntlet_balances;
create policy "Gauntlet balances: read own" on public.royal_gauntlet_balances for select to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

drop policy if exists "Gauntlet ledger: read own" on public.royal_gauntlet_ledger;
create policy "Gauntlet ledger: read own" on public.royal_gauntlet_ledger for select to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

do $$
begin
  begin
    alter publication supabase_realtime add table public.royal_gauntlet_balances;
  exception when duplicate_object then null;
  end;
end $$;

-- -----------------------------------------------------------------
-- 3. Cooldown after a lost challenge (derived, nothing stored)
-- -----------------------------------------------------------------
create or replace function public._throne_cooldown_until(p_user uuid)
returns timestamptz as $$
  select max(completed_at) + public._throne_cooldown()
  from public.throne_challenges
  where challenger_user_id = p_user
    and status = 'completed'
    and winner_user_id is not null
    and winner_user_id <> challenger_user_id;
$$ language sql stable security definer set search_path = public;

create or replace function public.get_throne_rules()
returns jsonb as $$
  select jsonb_build_object(
    'cooldown_hours', extract(epoch from public._throne_cooldown()) / 3600,
    'gauntlet_cost', public._throne_gauntlet_cost()
  );
$$ language sql stable security definer set search_path = public;

-- -----------------------------------------------------------------
-- 4. create_throne_challenge: replaced (the old 1-arg version would be a
--    bypass of every rule below, so it is dropped, not overloaded)
-- -----------------------------------------------------------------
drop function if exists public.create_throne_challenge(boolean);

create or replace function public.create_throne_challenge(
  p_allow_real_life boolean default false,
  p_expected_defender uuid default null
)
returns uuid as $$
declare
  v_reign record;
  v_id uuid;
  v_until timestamptz;
  v_cost int := public._throne_gauntlet_cost();
  v_left int;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;
  if v_reign is null then
    raise exception 'There is no Abt Lord to challenge yet';
  end if;
  if v_reign.user_id = auth.uid() then
    raise exception 'The Abt Lord cannot challenge themselves';
  end if;
  -- the UI showed a specific Lord; if the throne changed hands since, refuse
  if p_expected_defender is not null and v_reign.user_id <> p_expected_defender then
    raise exception 'The throne has changed hands. Refresh and look again.';
  end if;
  -- one open challenge at a time (also covers "no parallel challenges per user")
  if exists (select 1 from public.throne_challenges where status in ('pending', 'active', 'awaiting_judge')) then
    raise exception 'A Throne Challenge is already underway';
  end if;

  v_until := public._throne_cooldown_until(auth.uid());
  if v_until is not null and v_until > now() then
    raise exception 'COOLDOWN: you may challenge the throne again at %', v_until;
  end if;

  -- consume the Gauntlet atomically: the CHECK (balance >= 0) plus the
  -- conditional update means two parallel calls can never spend one twice
  update public.royal_gauntlet_balances
    set balance = balance - v_cost, updated_at = now()
    where user_id = auth.uid() and balance >= v_cost
    returning balance into v_left;
  if not found then
    raise exception 'You need a Royal Gauntlet to challenge the throne';
  end if;

  insert into public.throne_challenges
    (reign_id, defender_user_id, challenger_user_id, status, allow_real_life, awaiting_pick_by, step_deadline, starts_at)
  values
    (v_reign.id, v_reign.user_id, auth.uid(), 'pending', coalesce(p_allow_real_life, false), auth.uid(), now() + interval '48 hours', now())
  returning id into v_id;

  insert into public.royal_gauntlet_ledger (user_id, delta, reason, challenge_id)
    values (auth.uid(), -v_cost, 'throne_challenge', v_id);

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- -----------------------------------------------------------------
-- 5. A cancelled challenge (withdrawn, or never started in time) gives its
--    Gauntlet back -- once. Covers every cancel path, present and future.
-- -----------------------------------------------------------------
create or replace function public._refund_gauntlet_on_cancel()
returns trigger as $$
declare
  v_spent int;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    select -delta into v_spent from public.royal_gauntlet_ledger
      where challenge_id = new.id and reason = 'throne_challenge';
    if v_spent is not null then
      insert into public.royal_gauntlet_ledger (user_id, delta, reason, challenge_id)
        values (new.challenger_user_id, v_spent, 'throne_refund', new.id)
        on conflict do nothing;
      if found then
        insert into public.royal_gauntlet_balances (user_id, balance)
          values (new.challenger_user_id, v_spent)
          on conflict (user_id) do update
            set balance = public.royal_gauntlet_balances.balance + excluded.balance, updated_at = now();
      end if;
    end if;
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_refund_gauntlet_on_cancel on public.throne_challenges;
create trigger trg_refund_gauntlet_on_cancel
  after update of status on public.throne_challenges
  for each row execute procedure public._refund_gauntlet_on_cancel();

-- -----------------------------------------------------------------
-- 6. Admin / development grants -- SQL editor only (postgres role).
--    Not callable from the app by anyone.
--
--    select public.admin_grant_royal_gauntlets('Elien', 3);
--    select public.admin_grant_royal_gauntlets('Elien', -1);   -- take one back
-- -----------------------------------------------------------------
create or replace function public.admin_grant_royal_gauntlets(p_user_name text, p_amount int, p_note text default 'admin grant')
returns int as $$
declare
  v_user uuid;
  v_new int;
begin
  select id into v_user from public.profiles
    where lower(display_name) = lower(p_user_name) or lower(first_name) = lower(p_user_name)
    limit 1;
  if v_user is null then raise exception 'No user called %', p_user_name; end if;
  if p_amount = 0 then raise exception 'Amount must not be 0'; end if;

  insert into public.royal_gauntlet_balances (user_id, balance)
    values (v_user, p_amount)
    on conflict (user_id) do update
      set balance = public.royal_gauntlet_balances.balance + p_amount, updated_at = now()
    returning balance into v_new;

  insert into public.royal_gauntlet_ledger (user_id, delta, reason, note)
    values (v_user, p_amount, 'admin_grant', p_note);
  return v_new;
end;
$$ language plpgsql security definer set search_path = public;

-- -----------------------------------------------------------------
-- 7. grants
-- -----------------------------------------------------------------
revoke all on function public._throne_cooldown() from public, anon, authenticated;
revoke all on function public._throne_gauntlet_cost() from public, anon, authenticated;
revoke all on function public._throne_cooldown_until(uuid) from public, anon, authenticated;
revoke all on function public._refund_gauntlet_on_cancel() from public, anon, authenticated;
revoke all on function public.admin_grant_royal_gauntlets(text, int, text) from public, anon, authenticated;

revoke all on function public.get_throne_rules() from public, anon;
grant execute on function public.get_throne_rules() to authenticated;

revoke all on function public.create_throne_challenge(boolean, uuid) from public, anon;
grant execute on function public.create_throne_challenge(boolean, uuid) to authenticated;

-- =========== 0041_throne_trial_games.sql ===========
-- =================================================================
-- OFFICE LORE — THRONE TRIALS: THE FIRST REAL, AUTO-JUDGED GAMES
-- =================================================================
-- 0038 shipped placeholder Trials (roll / one numeric guess / judge). This
-- adds a generic QUIZ ENGINE and ten real games on top of it:
--
--   🍺 PINT     Beer Trivia · Higher or Lower · Guess the Beer
--   📜 LORE     Who Said It? · Nickname Knowledge · Office Lore Quiz
--   🧠 WISDOM   Office Lore Quiz (wisdom edition) · Closest Wins · Know Thy Enemy
--   ⚡ REFLEX   Rapid Fire (60s timer) · Sudden Death
--
-- HOW IT STAYS GENERIC
--   A game is ONE ROW in throne_trial_catalog. Its public_config says:
--     engine/resolution : quiz | timed | streak
--     templates         : which question templates feed it  (_tq_<name>)
--     count, options, duration_s, scoring, fallback, short, final_boost
--   A question template is one SQL function  _tq_<name>(chal, def, n_options)
--   returning rows of throne_question_t. New game from existing templates =
--   one INSERT. New kind of question = one new _tq_ function + its name in
--   a catalog row. New kind of mechanic = a new resolution + one client
--   renderer. The Throne Challenge itself never changes.
--
-- RESOLUTIONS (all auto-judged, nothing needs a human)
--   quiz    fixed list of questions, untimed. scoring:
--             'correct' more right answers wins            (tie: faster)
--             'error'   smaller total relative error wins   (Closest Wins)
--   timed   Rapid Fire. Server clock: the run is open duration_s seconds
--           from the first call to start_throne_run(). score = right - wrong.
--   streak  Sudden Death. A run ends at the first wrong answer; the longer
--           streak wins (tie: faster). Equivalent to "play until one is
--           wrong while the other is right", but works asynchronously.
--
-- FAIRNESS
--   * Questions are generated ONCE, when the Trial starts, and stored per
--     player (throne_trial_questions). Both players get the SAME questions in
--     the SAME order with the SAME option order -- except Know Thy Enemy,
--     where each player gets the MIRROR question about their opponent from
--     the same template (same difficulty, same position).
--   * Refresh / realtime / reconnect never generate anything new: the client
--     asks get_throne_run() and gets the stored questions back.
--   * The answer key never leaves the database: throne_trial_questions has
--     RLS and NO client policy; the RPCs return prompt/facts/options only.
--     Correctness is decided server-side per answer; the right answer is
--     revealed only AFTER that player answered that question.
--   * Own data first (beers, ratings, sessions, nicknames, quotes,
--     anecdotes, poems, battles -- all Office Lore tables, workspace-scoped
--     like the rest). When there is too little, the game is topped up from
--     throne_builtin_trivia (general beer / general knowledge).
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0040.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
do $$
declare
  v_constraint_name text;
begin
  select conname into v_constraint_name
  from pg_constraint
  where conrelid = 'public.throne_trial_catalog'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%resolution%';
  if v_constraint_name is not null then
    execute format('alter table public.throne_trial_catalog drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.throne_trial_catalog add constraint throne_trial_catalog_resolution_check
  check (resolution in ('roll', 'answer', 'judge', 'quiz', 'timed', 'streak'));

do $$
begin
  if not exists (select 1 from pg_type where typname = 'throne_question_t' and typnamespace = 'public'::regnamespace) then
    create type public.throne_question_t as (
      grp text,            -- question identity; a mirrored (per-player) pair shares one grp
      for_user_id uuid,    -- null = both players get this exact question
      kind text,           -- 'mc' (multiple choice) | 'numeric'
      tag text,            -- template tag, used for variety when picking
      prompt text,
      facts jsonb,         -- display extras (layout hints, quote text ...) -- never the answer
      options jsonb,       -- [{id,label}] for mc
      answer jsonb         -- {"id":"b"} or {"value":12}  -- PRIVATE
    );
  end if;
end $$;

-- built-in fallback trivia (used only to top up when own data is too thin)
create table if not exists public.throne_builtin_trivia (
  id serial primary key,
  category text not null check (category in ('beer', 'general')),
  prompt text not null unique,
  correct text not null,
  wrongs text[] not null,
  short boolean not null default true
);
alter table public.throne_builtin_trivia enable row level security; -- deliberately NO policy

-- the questions of a Trial, one copy per player (PRIVATE: holds the answers)
create table if not exists public.throne_trial_questions (
  trial_id uuid not null references public.throne_challenge_trials(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  seq int not null,
  kind text not null,
  tag text,
  prompt text not null,
  facts jsonb,
  options jsonb,
  answer jsonb not null,
  primary key (trial_id, user_id, seq)
);
alter table public.throne_trial_questions enable row level security; -- deliberately NO policy

-- one run per player per Trial
create table if not exists public.throne_trial_runs (
  trial_id uuid not null references public.throne_challenge_trials(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  started_at timestamptz not null default clock_timestamp(),
  last_at timestamptz,
  finished_at timestamptz,
  ended_by text check (ended_by in ('complete', 'wrong', 'time', 'deadline')),
  answered int not null default 0,
  correct int not null default 0,
  wrong int not null default 0,
  total_ms bigint not null default 0,
  err_sum numeric not null default 0,
  primary key (trial_id, user_id)
);
alter table public.throne_trial_runs enable row level security; -- deliberately NO policy

-- every answer given (audit + idempotency: a question can be answered once)
create table if not exists public.throne_trial_answers (
  trial_id uuid not null references public.throne_challenge_trials(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  seq int not null,
  choice jsonb not null,
  correct boolean not null,
  err numeric not null default 0,
  ms int not null default 0,
  answered_at timestamptz not null default clock_timestamp(),
  primary key (trial_id, user_id, seq)
);
alter table public.throne_trial_answers enable row level security; -- deliberately NO policy

-- built-in trivia seed
insert into public.throne_builtin_trivia (category, prompt, correct, wrongs) values
  ('beer', 'Which grain is the main ingredient of a classic Weissbier?', 'Wheat', array['Barley', 'Rye', 'Rice']),
  ('beer', 'Which ingredient gives beer most of its bitterness?', 'Hops', array['Malt', 'Yeast', 'Water']),
  ('beer', 'Which microorganism turns the sugars in wort into alcohol?', 'Yeast', array['Hops', 'Barley', 'Water']),
  ('beer', 'The Pilsner style was born in which Czech city?', 'Plzeň', array['Prague', 'Brno', 'Ostrava']),
  ('beer', 'In which city is Guinness brewed?', 'Dublin', array['Cork', 'Belfast', 'Galway']),
  ('beer', 'What does IPA stand for?', 'India Pale Ale', array['Imperial Pale Ale', 'International Pale Ale', 'Irish Pale Ale']),
  ('beer', 'Which Belgian beer style is fermented spontaneously with wild yeast?', 'Lambic', array['Dubbel', 'Tripel', 'Pils']),
  ('beer', 'Which Belgian style is typically strong and golden?', 'Tripel', array['Stout', 'Witbier', 'Porter']),
  ('beer', 'Which German city is the home of Kölsch?', 'Cologne', array['Munich', 'Berlin', 'Hamburg']),
  ('beer', 'In which city is the Oktoberfest held?', 'Munich', array['Berlin', 'Cologne', 'Vienna']),
  ('beer', 'What gives stout its dark colour?', 'Roasted malt', array['Dark hops', 'Food colouring', 'Smoked water']),
  ('beer', 'The sugary liquid before fermentation is called…', 'Wort', array['Krausen', 'Lees', 'Sparge']),
  ('beer', 'What does the Flemish word “Duvel” mean in English?', 'Devil', array['Duke', 'Dragon', 'Dwarf']),
  ('beer', 'Which animal features in the legend of Orval?', 'A trout', array['A swan', 'An eagle', 'A lion']),
  ('beer', 'Which glass shape is traditional for Belgian Trappist beers?', 'A chalice', array['A shot glass', 'A flat saucer', 'A test tube']),
  ('beer', 'In which country is the Trappist beer Westmalle brewed?', 'Belgium', array['The Netherlands', 'Germany', 'France']),
  ('beer', 'Which of these was NOT part of the original 1516 Reinheitsgebot?', 'Sugar', array['Water', 'Barley', 'Hops']),
  ('beer', 'Heineken comes from which country?', 'The Netherlands', array['Belgium', 'Germany', 'Denmark']),
  ('beer', 'Carlsberg comes from which country?', 'Denmark', array['Sweden', 'Norway', 'Germany']),
  ('beer', 'Corona comes from which country?', 'Mexico', array['Spain', 'Brazil', 'Colombia']),
  ('beer', 'Paulaner comes from which country?', 'Germany', array['Austria', 'Belgium', 'Switzerland']),
  ('beer', 'Peroni comes from which country?', 'Italy', array['Spain', 'France', 'Greece']),
  ('beer', 'What is the foam on top of a beer called?', 'The head', array['The cap', 'The lid', 'The veil']),
  ('beer', 'Which has the higher alcohol content: Duvel or Jupiler?', 'Duvel', array['Jupiler']),
  ('beer', 'Which has the higher alcohol content: Westmalle Tripel or Leffe Blonde?', 'Westmalle Tripel', array['Leffe Blonde']),
  ('beer', 'Which has the higher alcohol content: Chimay Blue or Orval?', 'Chimay Blue', array['Orval']),
  ('beer', 'Which has the higher alcohol content: Westvleteren 12 or Guinness Draught?', 'Westvleteren 12', array['Guinness Draught']),
  ('beer', 'Which has the higher alcohol content: Kwak or Hoegaarden?', 'Kwak', array['Hoegaarden']),
  ('beer', 'Which of these is a Trappist beer?', 'Chimay', array['Duvel', 'Leffe', 'Jupiler']),
  ('beer', 'Which of these is NOT a Trappist beer?', 'Leffe', array['Orval', 'Rochefort', 'Westmalle']),
  ('general', 'In which year was the Eiffel Tower completed?', '1889', array['1869', '1901', '1925']),
  ('general', 'How many bones does an adult human have?', '206', array['186', '226', '256']),
  ('general', 'What is the capital of Australia?', 'Canberra', array['Sydney', 'Melbourne', 'Perth']),
  ('general', 'Which planet is the largest in our solar system?', 'Jupiter', array['Saturn', 'Neptune', 'Earth']),
  ('general', 'What is the chemical symbol for gold?', 'Au', array['Ag', 'Gd', 'Go']),
  ('general', 'How many strings does a standard violin have?', '4', array['5', '6', '3']),
  ('general', 'Which ocean is the largest?', 'Pacific', array['Atlantic', 'Indian', 'Arctic']),
  ('general', 'What is the capital of Belgium?', 'Brussels', array['Antwerp', 'Ghent', 'Bruges']),
  ('general', 'Which Belgian city is famous for its diamond trade?', 'Antwerp', array['Ghent', 'Leuven', 'Liège']),
  ('general', 'How many players of one team are on the pitch in football?', '11', array['10', '12', '9']),
  ('general', 'What colour do you get by mixing blue and yellow?', 'Green', array['Purple', 'Orange', 'Brown']),
  ('general', 'Who painted the Mona Lisa?', 'Leonardo da Vinci', array['Michelangelo', 'Raphael', 'Rembrandt'])
on conflict (prompt) do nothing;

-- =================================================================
-- SECTION 2 — small helpers
-- =================================================================
-- builds {options:[{id,label}], answer:{id}} with the options shuffled (or
-- numerically sorted). null when there is no usable wrong answer.
create or replace function public._throne_mc(p_correct text, p_wrongs text[], p_n int default 4, p_sort boolean default false)
returns jsonb as $$
declare
  v_w text[];
  v_all text[];
  v_ids text[] := array['a', 'b', 'c', 'd', 'e'];
  v_opts jsonb := '[]'::jsonb;
  v_ans text;
  i int;
begin
  select coalesce(array_agg(w), '{}') into v_w from (
    select w from (
      select distinct w from unnest(p_wrongs) w
      where w is not null and btrim(w) <> '' and lower(w) <> lower(p_correct)
    ) d order by random() limit greatest(least(p_n, 5) - 1, 1)
  ) s;
  if cardinality(v_w) = 0 then
    return null;
  end if;
  if p_sort then
    select array_agg(l order by l::numeric) into v_all from unnest(array[p_correct] || v_w) l;
  else
    select array_agg(l order by random()) into v_all from unnest(array[p_correct] || v_w) l;
  end if;
  for i in 1..cardinality(v_all) loop
    v_opts := v_opts || jsonb_build_object('id', v_ids[i], 'label', v_all[i]);
    if v_all[i] = p_correct then v_ans := v_ids[i]; end if;
  end loop;
  return jsonb_build_object('options', v_opts, 'answer', jsonb_build_object('id', v_ans));
end;
$$ language plpgsql volatile;

-- multiple-choice around a count: nearby plausible numbers, sorted
create or replace function public._throne_num_mc(p_correct numeric, p_n int default 4)
returns jsonb as $$
declare
  v_c bigint := round(p_correct);
  v_step bigint := greatest(1, round(abs(round(p_correct)) * 0.2));
  v_w text[] := '{}';
  k int;
  cand bigint;
begin
  for k in 1..4 loop
    foreach cand in array array[v_c + k * v_step, v_c - k * v_step] loop
      if cand >= 0 then v_w := v_w || cand::text; end if;
    end loop;
  end loop;
  return public._throne_mc(v_c::text, v_w[1:(greatest(p_n, 2) - 1) * 2], p_n, true);
end;
$$ language plpgsql volatile;

create or replace function public._tq_row(p_grp text, p_user uuid, p_kind text, p_tag text, p_prompt text, p_facts jsonb, p_m jsonb)
returns public.throne_question_t as $$
  select row(coalesce(p_grp, md5(random()::text || clock_timestamp()::text || p_tag)), p_user, p_kind, p_tag, p_prompt, p_facts, p_m->'options', p_m->'answer')::public.throne_question_t;
$$ language sql volatile;

create or replace function public._tq_num_row(p_tag text, p_prompt text, p_value numeric, p_unit text)
returns public.throne_question_t as $$
  select row(md5(random()::text || clock_timestamp()::text || p_tag), null, 'numeric', p_tag, p_prompt,
             jsonb_build_object('unit', p_unit), null, jsonb_build_object('value', p_value))::public.throne_question_t;
$$ language sql volatile;

create or replace function public._throne_clip(p_text text, p_len int)
returns text as $$
  select case when length(btrim(p_text)) > p_len then left(btrim(p_text), p_len - 1) || '…' else btrim(p_text) end;
$$ language sql immutable;

-- every distinct person the Lore tables talk about
create or replace function public._throne_person_pool()
returns text[] as $$
  select coalesce(array_agg(distinct p), '{}') from (
    select btrim(person_real_name) as p from public.nicknames
    union select btrim(person_real_name) from public.quotes
    union select btrim(person_real_name) from public.anecdotes
  ) s where p <> '';
$$ language sql stable security definer set search_path = public;

-- other people, excluding anyone sharing the correct person's first name
-- ("Matthias" vs "Matthias Gils" must never both appear as options)
create or replace function public._throne_other_people(p_correct text)
returns text[] as $$
  select coalesce(array_agg(x), '{}') from unnest(public._throne_person_pool()) x
  where lower(split_part(btrim(x), ' ', 1)) <> lower(split_part(btrim(p_correct), ' ', 1));
$$ language sql stable security definer set search_path = public;

create or replace function public._throne_mentions(p_text text, p_name text)
returns boolean as $$
  select length(split_part(btrim(p_name), ' ', 1)) >= 3
     and position(lower(split_part(btrim(p_name), ' ', 1)) in lower(coalesce(p_text, ''))) > 0;
$$ language sql immutable;

create or replace function public._throne_member_names()
returns text[] as $$
  select coalesce(array_agg(p.display_name order by p.display_name), '{}')
  from public.profiles p
  join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active = true;
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 3 — question templates  (_tq_<name>(chal, def, n_options))
-- =================================================================

-- ---------- 🍺 beer templates ----------
create or replace function public._tq_beer_style(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_styles text[];
begin
  select array_agg(distinct initcap(lower(btrim(beer_style)))) into v_styles
    from public.beers where nullif(btrim(beer_style), '') is not null;
  if coalesce(cardinality(v_styles), 0) < 2 then return; end if;
  for r in
    select name, brewery, initcap(lower(btrim(beer_style))) as style from public.beers
    where nullif(btrim(beer_style), '') is not null order by random() limit 4
  loop
    v_m := public._throne_mc(r.style, v_styles, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_style',
        format('Which beer style is %s%s?', r.name, coalesce(' (' || nullif(btrim(r.brewery), '') || ')', '')), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_beer_brewery(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_b text[];
begin
  select array_agg(distinct btrim(brewery)) into v_b from public.beers where nullif(btrim(brewery), '') is not null;
  if coalesce(cardinality(v_b), 0) < 2 then return; end if;
  for r in select name, btrim(brewery) as brewery from public.beers where nullif(btrim(brewery), '') is not null order by random() limit 3 loop
    v_m := public._throne_mc(r.brewery, v_b, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_brewery', format('Which brewery makes %s?', r.name), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_beer_best_rated(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  i int;
  v_names text[];
  v_m jsonb;
begin
  for i in 1..3 loop
    select array_agg(name order by avg_r desc) into v_names from (
      select name, avg_r from (
        select distinct on (avg_r) name, avg_r from (
          select b.name, round(avg(r.rating), 1) as avg_r
          from public.beers b join public.beer_ratings r on r.beer_id = b.id
          where r.rating is not null group by b.id, b.name
        ) ba order by avg_r, random()
      ) d order by random() limit greatest(p_opts, 3)
    ) pick;
    if coalesce(cardinality(v_names), 0) < 3 then return; end if;
    v_m := public._throne_mc(v_names[1], v_names[2:cardinality(v_names)], p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_best_rated',
        'Which of these beers has the highest average rating in our app?', null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_beer_best_rater(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_names text[] := public._throne_member_names();
begin
  if cardinality(v_names) < 2 then return; end if;
  for r in
    select name, top_user from (
      select b.name,
             (array_agg(pr.display_name order by u.a desc))[1] as top_user,
             (array_agg(u.a order by u.a desc))[1] as top_a,
             (array_agg(u.a order by u.a desc))[2] as second_a
      from public.beers b
      join (select beer_id, user_id, avg(rating) a from public.beer_ratings where rating is not null group by beer_id, user_id) u on u.beer_id = b.id
      join public.profiles pr on pr.id = u.user_id
      group by b.id, b.name
      having count(*) >= 2
    ) x where top_a > second_a order by random() limit 3
  loop
    v_m := public._throne_mc(r.top_user, v_names, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_best_rater', format('Who gave %s the highest rating?', r.name), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_beer_session(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_labels text[];
begin
  -- a session is only usable when its label ("12 Mar 2026 · Pub") is unique
  select array_agg(label) into v_labels from (
    select to_char(s.session_date, 'DD Mon YYYY') || coalesce(' · ' || nullif(btrim(s.location), ''), '') as label
    from public.beer_sessions s
  ) l where label in (
    select to_char(s2.session_date, 'DD Mon YYYY') || coalesce(' · ' || nullif(btrim(s2.location), ''), '')
    from public.beer_sessions s2
    group by 1 having count(*) = 1
  );
  if coalesce(cardinality(v_labels), 0) < 2 then return; end if;

  for r in
    with sl as (
      select s.id, to_char(s.session_date, 'DD Mon YYYY') || coalesce(' · ' || nullif(btrim(s.location), ''), '') as label
      from public.beer_sessions s
    ), bs as (
      select beer_id, session_id from public.beer_ratings where session_id is not null
      union select beer_id, session_id from public.beer_consumption where session_id is not null
    )
    select b.name, sl.label
    from public.beers b
    join bs on bs.beer_id = b.id
    join sl on sl.id = bs.session_id
    where b.id in (select beer_id from bs group by beer_id having count(*) = 1)
      and sl.label = any (v_labels)
    order by random() limit 3
  loop
    v_m := public._throne_mc(r.label, v_labels, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_session', format('In which Beer Session was %s drunk?', r.name), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- Higher or Lower: show beer A (with its average), then beer B (without)
create or replace function public._tq_higher_lower(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_higher boolean;
begin
  for r in
    with ba as (
      select b.id, b.name, b.brewery, b.beer_style, round(avg(rt.rating), 1) as avg_r
      from public.beers b join public.beer_ratings rt on rt.beer_id = b.id
      where rt.rating is not null group by b.id, b.name, b.brewery, b.beer_style
    )
    select a.name an, a.brewery abr, a.beer_style ast, a.avg_r aavg, b.name bn, b.brewery bbr, b.beer_style bst, b.avg_r bavg
    from ba a join ba b on a.id <> b.id and abs(a.avg_r - b.avg_r) >= 0.5
    order by random() limit 8
  loop
    v_higher := r.bavg > r.aavg;
    return next row(md5(random()::text || r.an || r.bn), null, 'mc', 'higher_lower',
      'Does Beer B have a higher or lower average rating in our app than Beer A?',
      jsonb_build_object('layout', 'higher_lower',
        'a', jsonb_build_object('name', r.an, 'brewery', r.abr, 'style', r.ast, 'avg', r.aavg),
        'b', jsonb_build_object('name', r.bn, 'brewery', r.bbr, 'style', r.bst)),
      jsonb_build_array(jsonb_build_object('id', 'a', 'label', 'Higher'), jsonb_build_object('id', 'b', 'label', 'Lower')),
      jsonb_build_object('id', case when v_higher then 'a' else 'b' end))::public.throne_question_t;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- Guess the Beer: hints with the name hidden, choose from real beers
create or replace function public._tq_guess_beer(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_hints jsonb;
  v_wrongs text[];
  v_m jsonb;
begin
  for r in
    select b.id, b.name, b.brewery, initcap(lower(btrim(b.beer_style))) as style, b.alcohol_percentage as abv,
           (select round(avg(rating), 1) from public.beer_ratings where beer_id = b.id and rating is not null) as avg_r
    from public.beers b where nullif(btrim(b.beer_style), '') is not null
    order by random() limit 5
  loop
    v_hints := jsonb_build_array(jsonb_build_object('label', 'Style', 'value', r.style));
    if nullif(btrim(r.brewery), '') is not null
       and position(lower(r.name) in lower(r.brewery)) = 0
       and not ((r.abv is not null or r.avg_r is not null) and random() < 0.3) then
      v_hints := v_hints || jsonb_build_object('label', 'Brewery', 'value', btrim(r.brewery));
    end if;
    if r.abv is not null then
      v_hints := v_hints || jsonb_build_object('label', 'ABV', 'value', trim(trailing '.' from trim(trailing '0' from r.abv::text)) || '%');
    end if;
    if r.avg_r is not null then
      v_hints := v_hints || jsonb_build_object('label', 'Average rating', 'value', r.avg_r::text || ' / 10');
    end if;
    continue when jsonb_array_length(v_hints) < 2;

    select array_agg(name) into v_wrongs from (
      select name from public.beers where id <> r.id
      order by (lower(btrim(coalesce(beer_style, ''))) = lower(r.style)) desc, random()
      limit greatest(p_opts, 3) - 1
    ) w;
    v_m := public._throne_mc(r.name, v_wrongs, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'guess_beer', 'Which beer is this?',
        jsonb_build_object('layout', 'guess', 'hints', v_hints), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- ---------- 📜 lore templates ----------
create or replace function public._tq_nick_who(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select btrim(n.nickname) as nick, btrim(n.person_real_name) as person from public.nicknames n
    where n.status <> 'Gearchiveerd'
      and (select count(*) from public.nicknames x where lower(btrim(x.nickname)) = lower(btrim(n.nickname))) = 1
    order by random() limit 4
  loop
    v_m := public._throne_mc(r.person, public._throne_other_people(r.person), p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nick_who', format('Who has the nickname “%s”?', r.nick), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_nick_of_person(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_wrongs text[];
begin
  for r in
    select btrim(max(nickname)) as nick, btrim(person_real_name) as person from public.nicknames
    where status <> 'Gearchiveerd' group by btrim(person_real_name) having count(*) = 1 order by random() limit 4
  loop
    select array_agg(btrim(nickname)) into v_wrongs from public.nicknames
      where lower(split_part(btrim(person_real_name), ' ', 1)) <> lower(split_part(r.person, ' ', 1));
    v_m := public._throne_mc(r.nick, v_wrongs, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nick_of_person', format('Which nickname belongs to %s?', r.person), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- "Which nickname belongs to this story?"
create or replace function public._tq_nick_anecdote(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_wrongs text[];
begin
  for r in
    select btrim(nickname) as nick, btrim(anecdote) as story, btrim(person_real_name) as person from public.nicknames
    where length(btrim(coalesce(anecdote, ''))) >= 20
      and position(lower(btrim(nickname)) in lower(anecdote)) = 0
      and not public._throne_mentions(anecdote, person_real_name)
    order by random() limit 3
  loop
    select array_agg(btrim(nickname)) into v_wrongs from public.nicknames where lower(btrim(nickname)) <> lower(r.nick);
    v_m := public._throne_mc(r.nick, v_wrongs, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nick_anecdote', 'Which nickname belongs to this story?',
        jsonb_build_object('layout', 'quote', 'text', public._throne_clip(r.story, 260)), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- "Which colleague does this story belong to?"
create or replace function public._tq_nickstory_who(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select btrim(anecdote) as story, btrim(person_real_name) as person from public.nicknames
    where length(btrim(coalesce(anecdote, ''))) >= 20
      and not public._throne_mentions(anecdote, person_real_name)
    order by random() limit 3
  loop
    v_m := public._throne_mc(r.person, public._throne_other_people(r.person), p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nickstory_who', 'Which colleague does this story belong to?',
        jsonb_build_object('layout', 'quote', 'text', public._throne_clip(r.story, 260)), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- "Which of these nicknames is really on the Nickname Wall?"
create or replace function public._tq_nick_real(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_fakes text[] := array['Captain Foam', 'The Stapler Whisperer', 'Sir Reply-All', 'Coffee Goblin', 'Meeting Ghost',
                          'Duke of Excel', 'Printer Whisperer', 'The Last Biscuit', 'Lord of the Lanyards', 'Baron von Agenda'];
begin
  for r in select btrim(nickname) as nick from public.nicknames where status <> 'Gearchiveerd' order by random() limit 3 loop
    v_m := public._throne_mc(r.nick, v_fakes, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nick_real', 'Which of these nicknames is really on our Nickname Wall?', null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_quote_who(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select btrim(quote) as q, btrim(person_real_name) as person, nullif(btrim(context), '') as ctx from public.quotes
    where length(btrim(quote)) >= 8 and not public._throne_mentions(quote, person_real_name)
    order by random() limit 4
  loop
    v_m := public._throne_mc(r.person, public._throne_other_people(r.person), p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'quote_who', 'Who said this?',
        jsonb_build_object('layout', 'quote', 'text', '“' || public._throne_clip(r.q, 240) || '”'), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_anecdote_who(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select btrim(title) as title, btrim(description) as descr, btrim(person_real_name) as person from public.anecdotes
    where length(btrim(description)) >= 15
      and not public._throne_mentions(title || ' ' || description, person_real_name)
    order by random() limit 3
  loop
    v_m := public._throne_mc(r.person, public._throne_other_people(r.person), p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'anecdote_who', 'Whose anecdote is this?',
        jsonb_build_object('layout', 'quote', 'title', r.title, 'text', public._throne_clip(r.descr, 240)), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_poem_author(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_names text[] := public._throne_member_names();
begin
  if cardinality(v_names) < 2 then return; end if;
  for r in
    select btrim(p.title) as title, btrim(p.content) as content, pr.display_name as author
    from public.poems p join public.profiles pr on pr.id = p.author_user_id
    where length(btrim(p.content)) >= 30
      and not public._throne_mentions(p.title || ' ' || p.content, pr.display_name)
    order by random() limit 4
  loop
    v_m := public._throne_mc(r.author, v_names, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'poem_author', 'Who wrote this poem?',
        jsonb_build_object('layout', 'quote', 'title', r.title, 'text', public._throne_clip(r.content, 200)), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_battle_winner(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select nickname_a_text as a, nickname_b_text as b, winner_nickname_text as w from public.nickname_battles
    where status = 'finished' and winner_nickname_text is not null and nickname_a_text <> nickname_b_text
      and winner_nickname_text in (nickname_a_text, nickname_b_text)
    order by random() limit 3
  loop
    v_m := public._throne_mc(r.w, array[case when r.w = r.a then r.b else r.a end], 2);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'battle_winner',
        format('Nickname Battle: “%s” vs “%s”. Which one won?', r.a, r.b), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- ---------- 🧠 count questions (multiple choice) ----------
create or replace function public._tq_count_sessions(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare v_n bigint := (select count(*) from public.beer_sessions);
begin
  if v_n >= 1 then
    return next public._tq_row(null, null, 'mc', 'count_sessions', 'How many Beer Sessions have we had?', null, public._throne_num_mc(v_n, p_opts));
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_count_beers(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare v_n bigint := (select count(*) from public.beers);
begin
  if v_n >= 1 then
    return next public._tq_row(null, null, 'mc', 'count_beers', 'How many different beers are registered in the app?', null, public._throne_num_mc(v_n, p_opts));
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_count_nicknames(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare v_n bigint := (select count(*) from public.nicknames);
begin
  if v_n >= 1 then
    return next public._tq_row(null, null, 'mc', 'count_nicknames', 'How many nicknames are on the Nickname Wall?', null, public._throne_num_mc(v_n, p_opts));
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_count_poems(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare v_n bigint := (select count(*) from public.poems);
begin
  if v_n >= 1 then
    return next public._tq_row(null, null, 'mc', 'count_poems', 'How many poems are on the Poetry Wall?', null, public._throne_num_mc(v_n, p_opts));
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- ---------- 🧠 Closest Wins: numeric questions ----------
create or replace function public._tq_num_counts(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  v_n bigint;
  r record;
begin
  select count(*) into v_n from public.beers;
  if v_n > 0 then return next public._tq_num_row('num_beers', 'How many different beers are registered in the app?', v_n, 'beers'); end if;
  select count(*) into v_n from public.beer_ratings where rating is not null;
  if v_n > 0 then return next public._tq_num_row('num_ratings', 'How many beer ratings have we given in total?', v_n, 'ratings'); end if;
  select count(*) into v_n from public.nicknames;
  if v_n > 0 then return next public._tq_num_row('num_nicknames', 'How many nicknames are on the Nickname Wall?', v_n, 'nicknames'); end if;
  select count(*) into v_n from public.beer_sessions;
  if v_n > 0 then return next public._tq_num_row('num_sessions', 'How many Beer Sessions have we had?', v_n, 'sessions'); end if;
  select count(*) into v_n from public.poems;
  if v_n > 0 then return next public._tq_num_row('num_poems', 'How many poems are on the Poetry Wall?', v_n, 'poems'); end if;
  select count(*) into v_n from public.nickname_battles;
  if v_n > 0 then return next public._tq_num_row('num_battles', 'How many Nickname Battles have been fought?', v_n, 'battles'); end if;

  -- about a random member
  select p.id, p.display_name into r from public.profiles p
    join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active = true
    order by random() limit 1;
  if r.id is not null then
    if (select count(*) from public.perfect_pours) > 0 then
      select count(*) into v_n from public.perfect_pours where received_by_user_id = r.id;
      return next public._tq_num_row('num_pp_user', format('How many Perfect Pours has %s received?', r.display_name), v_n, 'Perfect Pours');
    end if;
    select count(distinct beer_id) into v_n from public.beer_ratings where user_id = r.id and rating is not null;
    if v_n > 0 then return next public._tq_num_row('num_ratings_user', format('How many different beers has %s rated?', r.display_name), v_n, 'beers'); end if;
    select count(*) into v_n from public.poems where author_user_id = r.id;
    if v_n > 0 then return next public._tq_num_row('num_poems_user', format('How many poems has %s written?', r.display_name), v_n, 'poems'); end if;
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- ---------- 🧠 Know Thy Enemy: mirrored questions about the opponent ----------
-- _enemy_q builds ONE question about p_subject, to be asked to p_asker
create or replace function public._enemy_q(p_kind text, p_subject uuid, p_asker uuid, p_opts int)
returns public.throne_question_t as $$
declare
  v_name text;
  v_top text; v_a1 numeric; v_a2 numeric;
  v_n bigint;
  v_wrongs text[];
  v_m jsonb;
  v_possessive text;
begin
  select display_name into v_name from public.profiles where id = p_subject;
  if v_name is null then return null; end if;
  v_possessive := v_name || '''s';

  if p_kind = 'best_beer' then
    with s as (
      select b.name, round(avg(r.rating), 2) as a from public.beer_ratings r join public.beers b on b.id = r.beer_id
      where r.user_id = p_subject and r.rating is not null group by b.id, b.name)
    select (array_agg(name order by a desc))[1], (array_agg(a order by a desc))[1], (array_agg(a order by a desc))[2]
      into v_top, v_a1, v_a2 from s;
    if v_top is null or (v_a2 is not null and v_a1 = v_a2) then return null; end if;
    select array_agg(name) into v_wrongs from public.beers where name <> v_top;
    v_m := public._throne_mc(v_top, v_wrongs, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_best_beer', format('What is %s highest rated beer?', v_possessive), null, v_m);

  elsif p_kind = 'fav_style' then
    with s as (
      select initcap(lower(btrim(b.beer_style))) as st, round(avg(r.rating), 2) as a
      from public.beer_ratings r join public.beers b on b.id = r.beer_id
      where r.user_id = p_subject and r.rating is not null and nullif(btrim(b.beer_style), '') is not null group by 1)
    select (array_agg(st order by a desc))[1], (array_agg(a order by a desc))[1], (array_agg(a order by a desc))[2]
      into v_top, v_a1, v_a2 from s;
    if v_top is null or v_a2 is null or v_a1 = v_a2 then return null; end if;
    select array_agg(distinct initcap(lower(btrim(beer_style)))) into v_wrongs from public.beers where nullif(btrim(beer_style), '') is not null;
    v_m := public._throne_mc(v_top, v_wrongs, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_fav_style', format('Which beer style does %s rate highest on average?', v_name), null, v_m);

  elsif p_kind = 'rating_count' then
    select count(distinct beer_id) into v_n from public.beer_ratings where user_id = p_subject and rating is not null;
    if v_n < 1 then return null; end if;
    v_m := public._throne_num_mc(v_n, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_rating_count', format('How many different beers has %s rated?', v_name), null, v_m);

  elsif p_kind = 'perfect_pours' then
    if (select count(*) from public.perfect_pours) < 1 then return null; end if;
    select count(*) into v_n from public.perfect_pours where received_by_user_id = p_subject;
    v_m := public._throne_num_mc(v_n, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_perfect_pours', format('How many Perfect Pours has %s received?', v_name), null, v_m);

  elsif p_kind = 'nickname' then
    select count(*), max(btrim(n.nickname)) into v_n, v_top
      from public.nicknames n join public.profiles pr on pr.id = p_subject
      where lower(btrim(n.person_real_name)) in (lower(btrim(coalesce(pr.first_name, ''))), lower(btrim(pr.display_name)), lower(btrim(coalesce(pr.profile_nickname, ''))))
        and btrim(n.person_real_name) <> '';
    if v_n <> 1 then return null; end if;
    select array_agg(btrim(nickname)) into v_wrongs from public.nicknames where lower(btrim(nickname)) <> lower(v_top);
    v_m := public._throne_mc(v_top, v_wrongs, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_nickname', format('Which nickname is on the Wall for %s?', v_name), null, v_m);

  elsif p_kind = 'poems' then
    select count(*) into v_n from public.poems where author_user_id = p_subject;
    if v_n < 1 then return null; end if;
    v_m := public._throne_num_mc(v_n, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_poems', format('How many poems has %s written?', v_name), null, v_m);

  elsif p_kind = 'sessions' then
    select count(*) into v_n from public.beer_session_participants where user_id = p_subject;
    if v_n < 1 then return null; end if;
    v_m := public._throne_num_mc(v_n, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_sessions', format('At how many Beer Sessions was %s present?', v_name), null, v_m);
  end if;
  return null;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- one pair: the same template asked about the opponent, to both players
create or replace function public._tq_enemy_pair(p_kind text, p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  qa public.throne_question_t;
  qb public.throne_question_t;
  v_grp text := md5(random()::text || clock_timestamp()::text || p_kind);
begin
  qa := public._enemy_q(p_kind, p_def, p_chal, p_opts); -- the challenger is asked about the defender
  qb := public._enemy_q(p_kind, p_chal, p_def, p_opts); -- the defender is asked about the challenger
  if qa.prompt is null or qb.prompt is null then return; end if;
  qa.grp := v_grp; qb.grp := v_grp;
  return next qa;
  return next qb;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_enemy_best_beer(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('best_beer', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_fav_style(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('fav_style', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_rating_count(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('rating_count', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_perfect_pours(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('perfect_pours', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_nickname(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('nickname', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_poems(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('poems', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_sessions(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('sessions', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;

-- =================================================================
-- SECTION 4 — question generation: the generic part
-- =================================================================
create or replace function public._prepare_throne_trial(p_trial_id uuid, p_cat public.throne_trial_catalog)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  cfg jsonb := coalesce(p_cat.public_config, '{}'::jsonb);
  v_count int := coalesce((cfg->>'count')::int, 5);
  v_opts int := coalesce((cfg->>'options')::int, 4);
  v_fb text := coalesce(cfg->>'fallback', 'beer');
  v_short boolean := coalesce((cfg->>'short')::boolean, false);
  v_pool jsonb := '[]'::jsonb;
  v_rows jsonb;
  v_tpl text;
  v_m jsonb;
  b record;
  v_n int;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  select * into c from public.throne_challenges where id = t.challenge_id;

  -- 1. own data: every template named in the catalog row (a failing template
  --    is skipped, never fatal)
  for v_tpl in select jsonb_array_elements_text(coalesce(cfg->'templates', '[]'::jsonb)) loop
    continue when v_tpl !~ '^[a-z_]+$';
    begin
      execute format('select coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) from public.%I($1, $2, $3) q', '_tq_' || v_tpl)
        into v_rows using c.challenger_user_id, c.defender_user_id, v_opts;
      v_pool := v_pool || v_rows;
    exception when others then
      raise warning 'throne template % failed: %', v_tpl, sqlerrm;
    end;
  end loop;

  -- 2. built-in trivia: always offered, but only used last (top-up)
  for b in
    select * from public.throne_builtin_trivia
    where (v_fb = 'any' or category = v_fb) and (not v_short or short)
    order by random() limit v_count
  loop
    v_m := public._throne_mc(b.correct, b.wrongs, v_opts);
    if v_m is not null then
      v_pool := v_pool || to_jsonb(public._tq_row(null, null, 'mc', 'builtin', b.prompt, null, v_m));
    end if;
  end loop;

  -- 3. pick `count` groups, round-robin over tags for variety (built-in last),
  --    and store one copy of the questions per player, same order for both
  with pool as (
    select * from jsonb_populate_recordset(null::public.throne_question_t, v_pool)
  ), grps as (
    select grp, min(tag) as tag, row_number() over (partition by min(tag) order by random()) as r_tag
    from pool group by grp
  ), chosen as (
    select grp, ord from (
      select grp, row_number() over (order by (tag = 'builtin'), r_tag, random()) as ord from grps
    ) x where ord <= v_count
  )
  insert into public.throne_trial_questions (trial_id, user_id, seq, kind, tag, prompt, facts, options, answer)
  select p_trial_id, u.uid,
         row_number() over (partition by u.uid order by ch.ord),
         q.kind, q.tag, q.prompt, q.facts, q.options, q.answer
  from chosen ch
  join pool q on q.grp = ch.grp
  cross join (values (c.challenger_user_id), (c.defender_user_id)) as u(uid)
  where q.for_user_id is null or q.for_user_id = u.uid;

  select count(*) into v_n from public.throne_trial_questions where trial_id = p_trial_id and user_id = c.challenger_user_id;
  if v_n < 1 then
    raise exception 'Could not build any questions for this Trial';
  end if;
  update public.throne_challenge_trials
    set public_config = public_config || jsonb_build_object('question_count', v_n)
    where id = p_trial_id;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- hook: every Trial of a quiz-type resolution gets its questions at start
create or replace function public._start_throne_trial(p_challenge_id uuid, p_cat public.throne_trial_catalog, p_picker uuid)
returns uuid as $$
declare
  v_no int;
  v_id uuid;
  v_status text;
begin
  select count(*) + 1 into v_no from public.throne_challenge_trials where challenge_id = p_challenge_id;
  v_status := case when p_cat.resolution = 'judge' then 'awaiting_judge' else 'active' end;

  insert into public.throne_challenge_trials
    (challenge_id, trial_no, picker_user_id, school, catalog_id, title, description, resolution, public_config, status)
  values
    (p_challenge_id, v_no, p_picker, p_cat.school, p_cat.id, p_cat.title, p_cat.description, p_cat.resolution, p_cat.public_config, v_status)
  returning id into v_id;

  if p_cat.resolution in ('quiz', 'timed', 'streak') then
    perform public._prepare_throne_trial(v_id, p_cat);
  end if;

  update public.throne_challenges
    set status = v_status,
        awaiting_pick_by = null,
        started_at = coalesce(started_at, now()),
        step_deadline = now() + interval '48 hours'
    where id = p_challenge_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — runs: start / answer / finish / resolve
-- =================================================================
create or replace function public._throne_run_state(p_trial_id uuid, p_user uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  r public.throne_trial_runs;
  v_state text;
  v_q jsonb := '[]'::jsonb;
  v_dur int;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  select * into r from public.throne_trial_runs where trial_id = p_trial_id and user_id = p_user;
  v_dur := case when t.resolution = 'timed' then coalesce((t.public_config->>'duration_s')::int, 60) else 0 end;
  v_state := case when r.trial_id is null then 'not_started' when r.finished_at is not null then 'finished' else 'running' end;

  if v_state = 'running' then
    select coalesce(jsonb_agg(jsonb_build_object('seq', seq, 'kind', kind, 'prompt', prompt, 'facts', facts, 'options', options) order by seq), '[]'::jsonb)
      into v_q from public.throne_trial_questions where trial_id = p_trial_id and user_id = p_user;
  end if;

  return jsonb_build_object(
    'state', v_state,
    'mode', t.resolution,
    'scoring', t.public_config->>'scoring',
    'duration_s', v_dur,
    'started_at', r.started_at,
    'ends_at', case when v_dur > 0 and r.started_at is not null then r.started_at + make_interval(secs => v_dur) end,
    'server_now', clock_timestamp(),
    'total', (select count(*) from public.throne_trial_questions where trial_id = p_trial_id and user_id = p_user),
    'answered', coalesce(r.answered, 0),
    'correct', coalesce(r.correct, 0),
    'wrong', coalesce(r.wrong, 0),
    'ended_by', r.ended_by,
    'questions', v_q
  );
end;
$$ language plpgsql stable security definer set search_path = public;

-- ends a run; when both players are done the Trial resolves by itself
create or replace function public._finalize_throne_run(p_trial_id uuid, p_user uuid, p_ended_by text)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
begin
  perform pg_advisory_xact_lock(918273645);
  update public.throne_trial_runs
    set finished_at = clock_timestamp(), ended_by = p_ended_by
    where trial_id = p_trial_id and user_id = p_user and finished_at is null;
  if not found then
    return;
  end if;

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if p_user = c.challenger_user_id then
    update public.throne_challenge_trials set challenger_submitted = true where id = t.id;
  else
    update public.throne_challenge_trials set defender_submitted = true where id = t.id;
  end if;

  if t.status = 'active'
     and exists (select 1 from public.throne_trial_runs where trial_id = t.id and user_id = c.challenger_user_id and finished_at is not null)
     and exists (select 1 from public.throne_trial_runs where trial_id = t.id and user_id = c.defender_user_id and finished_at is not null) then
    perform public._resolve_quiz_trial(t.id);
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- the automatic judge
create or replace function public._resolve_quiz_trial(p_trial_id uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  r1 public.throne_trial_runs;
  r2 public.throne_trial_runs;
  v_scoring text;
  v_a numeric[];
  v_b numeric[];
  v_winner uuid;
  v_decided text;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.status = 'completed' then return; end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  select * into r1 from public.throne_trial_runs where trial_id = t.id and user_id = c.challenger_user_id;
  select * into r2 from public.throne_trial_runs where trial_id = t.id and user_id = c.defender_user_id;
  v_scoring := coalesce(t.public_config->>'scoring', case t.resolution when 'timed' then 'timed' when 'streak' then 'streak' else 'correct' end);

  -- lexicographic keys, higher is better; the 2nd element is the tie-break
  if v_scoring = 'error' then
    v_a := array[-r1.err_sum, -r1.total_ms]; v_b := array[-r2.err_sum, -r2.total_ms];
  elsif v_scoring = 'timed' then
    v_a := array[r1.correct - r1.wrong, -r1.wrong]; v_b := array[r2.correct - r2.wrong, -r2.wrong];
  else
    v_a := array[r1.correct, -r1.total_ms]; v_b := array[r2.correct, -r2.total_ms];
  end if;

  if v_a > v_b then v_winner := c.challenger_user_id;
  elsif v_b > v_a then v_winner := c.defender_user_id;
  else v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
  end if;
  v_decided := case when v_a[1] <> v_b[1] then 'score' when v_a[2] <> v_b[2] then 'tiebreak' else 'coin' end;

  update public.throne_challenge_trials
    set challenger_result = jsonb_build_object('correct', r1.correct, 'wrong', r1.wrong, 'answered', r1.answered,
          'total_ms', r1.total_ms, 'err_sum', round(r1.err_sum, 4), 'ended_by', r1.ended_by),
        defender_result = jsonb_build_object('correct', r2.correct, 'wrong', r2.wrong, 'answered', r2.answered,
          'total_ms', r2.total_ms, 'err_sum', round(r2.err_sum, 4), 'ended_by', r2.ended_by),
        reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('scoring', v_scoring, 'decided_by', v_decided,
          'total', (select count(*) from public.throne_trial_questions where trial_id = t.id and user_id = c.challenger_user_id))
    where id = t.id;
  perform public._finish_throne_trial(t.id, v_winner);
end;
$$ language plpgsql volatile security definer set search_path = public;

-- timed runs whose hourglass ran out (the player closed the app): close them
create or replace function public._finalize_expired_runs()
returns boolean as $$
declare
  r record;
  v_changed boolean := false;
begin
  for r in
    select ru.trial_id, ru.user_id
    from public.throne_trial_runs ru
    join public.throne_challenge_trials t on t.id = ru.trial_id
    where ru.finished_at is null and t.status = 'active' and t.resolution = 'timed'
      and clock_timestamp() > ru.started_at + make_interval(secs => coalesce((t.public_config->>'duration_s')::int, 60) + 2)
  loop
    perform public._finalize_throne_run(r.trial_id, r.user_id, 'time');
    v_changed := true;
  end loop;
  return v_changed;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public.get_throne_run(p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id;
  if t.id is null or t.resolution not in ('quiz', 'timed', 'streak') then raise exception 'Not a question Trial'; end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then raise exception 'Only the two duelists can play this Trial'; end if;
  if t.status = 'completed' then
    return public._throne_run_state(t.id, auth.uid()) || jsonb_build_object('state', 'finished');
  end if;
  return public._throne_run_state(t.id, auth.uid());
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.start_throne_run(p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'active' or t.resolution not in ('quiz', 'timed', 'streak') then
    raise exception 'This Trial is not open for play';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can play this Trial';
  end if;

  -- idempotent: a second call (refresh, double tap) returns the SAME run
  insert into public.throne_trial_runs (trial_id, user_id, started_at, last_at)
    values (t.id, auth.uid(), clock_timestamp(), clock_timestamp())
    on conflict (trial_id, user_id) do nothing;
  return public._throne_run_state(t.id, auth.uid());
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.answer_throne_question(p_trial_id uuid, p_seq int, p_choice jsonb)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  r public.throne_trial_runs;
  q public.throne_trial_questions;
  v_total int;
  v_correct boolean;
  v_err numeric := 0;
  v_guess numeric;
  v_ans numeric;
  v_ms int;
  v_id text;
  v_reveal jsonb;
  v_dur int;
  v_ended text;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'active' or t.resolution not in ('quiz', 'timed', 'streak') then
    raise exception 'This Trial is not open for answers';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can play this Trial';
  end if;

  select * into r from public.throne_trial_runs where trial_id = t.id and user_id = auth.uid() for update;
  if r.trial_id is null then raise exception 'You have not started this Trial'; end if;
  if r.finished_at is not null then raise exception 'You have already finished this Trial'; end if;

  if t.resolution = 'timed' then
    v_dur := coalesce((t.public_config->>'duration_s')::int, 60);
    if clock_timestamp() > r.started_at + make_interval(secs => v_dur + 2) then
      perform public._finalize_throne_run(t.id, auth.uid(), 'time');
      return jsonb_build_object('finished', true, 'expired', true);
    end if;
  end if;

  if p_seq is distinct from r.answered + 1 then raise exception 'Answer the questions in order'; end if;
  select * into q from public.throne_trial_questions where trial_id = t.id and user_id = auth.uid() and seq = p_seq;
  if q.trial_id is null then raise exception 'Unknown question'; end if;
  select count(*) into v_total from public.throne_trial_questions where trial_id = t.id and user_id = auth.uid();

  if q.kind = 'numeric' then
    begin
      v_guess := (p_choice->>'value')::numeric;
    exception when others then
      v_guess := null;
    end;
    if v_guess is null then raise exception 'Enter a number'; end if;
    v_ans := (q.answer->>'value')::numeric;
    v_err := abs(v_guess - v_ans) / greatest(abs(v_ans), 1);
    v_correct := (v_guess = v_ans);
    v_reveal := jsonb_build_object('value', v_ans);
  else
    v_id := p_choice->>'id';
    if v_id is null or not (q.options @> jsonb_build_array(jsonb_build_object('id', v_id))) then
      raise exception 'Unknown option';
    end if;
    v_correct := (v_id = q.answer->>'id');
    v_reveal := q.answer;
  end if;

  v_ms := least(2000000000, greatest(0, round(extract(epoch from (clock_timestamp() - coalesce(r.last_at, r.started_at))) * 1000)))::int;
  insert into public.throne_trial_answers (trial_id, user_id, seq, choice, correct, err, ms)
    values (t.id, auth.uid(), p_seq, p_choice, v_correct, v_err, v_ms);
  update public.throne_trial_runs
    set answered = answered + 1,
        correct = correct + case when v_correct then 1 else 0 end,
        wrong = wrong + case when v_correct then 0 else 1 end,
        total_ms = total_ms + v_ms,
        err_sum = err_sum + v_err,
        last_at = clock_timestamp()
    where trial_id = t.id and user_id = auth.uid()
    returning * into r;

  if t.resolution = 'streak' and not v_correct then
    v_ended := 'wrong';
  elsif r.answered >= v_total then
    v_ended := 'complete';
  end if;
  if v_ended is not null then
    perform public._finalize_throne_run(t.id, auth.uid(), v_ended);
  end if;

  return jsonb_build_object('correct', v_correct, 'reveal', v_reveal, 'finished', v_ended is not null,
    'ended_by', v_ended, 'answered', r.answered, 'correct_count', r.correct, 'wrong_count', r.wrong);
end;
$$ language plpgsql security definer set search_path = public;

-- the hourglass ran out (Rapid Fire): the client says so, the server checks
create or replace function public.finish_throne_run(p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  r public.throne_trial_runs;
  v_dur int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.resolution <> 'timed' then raise exception 'This Trial has no hourglass'; end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can play this Trial';
  end if;
  select * into r from public.throne_trial_runs where trial_id = t.id and user_id = auth.uid() for update;
  if r.trial_id is null then raise exception 'You have not started this Trial'; end if;
  v_dur := coalesce((t.public_config->>'duration_s')::int, 60);
  if r.finished_at is null then
    if clock_timestamp() < r.started_at + make_interval(secs => v_dur - 1) then
      raise exception 'The hourglass is still running';
    end if;
    perform public._finalize_throne_run(t.id, auth.uid(), 'time');
  end if;
  return public._throne_run_state(t.id, auth.uid()) || jsonb_build_object('state', 'finished');
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — deadline resolver (replaces 0038's; adds quiz-type handling)
-- =================================================================
create or replace function public._resolve_expired_throne_challenge()
returns boolean as $$
declare
  c public.throne_challenges;
  t public.throne_challenge_trials;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_changed boolean := false;
  v_guard int := 0;
begin
  perform pg_advisory_xact_lock(918273645);

  -- Rapid Fire runs whose time is up resolve first (may finish a Trial)
  if public._finalize_expired_runs() then
    v_changed := true;
  end if;

  loop
    v_guard := v_guard + 1;
    exit when v_guard > 10;

    select * into c from public.throne_challenges
      where status in ('pending', 'active', 'awaiting_judge')
        and step_deadline is not null and step_deadline <= now()
      limit 1;
    exit when c.id is null;
    v_changed := true;

    if c.status = 'pending' then
      -- the challenger never picked Trial 1's school: nothing was played, nobody lost
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;

    elsif c.awaiting_pick_by is not null then
      -- the picker didn't choose a school in time: a random school is drawn
      v_cat := public._pick_catalog_trial(c.id, null);
      perform public._start_throne_trial(c.id, v_cat, c.awaiting_pick_by);

    else
      select * into t from public.throne_challenge_trials
        where challenge_id = c.id and status <> 'completed'
        order by trial_no desc limit 1;

      if t.id is null then
        -- inconsistent state: close it safely
        update public.throne_challenges
          set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
          where id = c.id;
      else
        if t.resolution in ('quiz', 'timed', 'streak') then
          -- close any run still in progress with what it has; if that leaves
          -- both runs finished the Trial resolves on its own
          perform public._finalize_throne_run(t.id, c.challenger_user_id, 'deadline');
          perform public._finalize_throne_run(t.id, c.defender_user_id, 'deadline');
          select * into t from public.throne_challenge_trials where id = t.id;
          continue when t.status = 'completed';
        end if;

        if t.resolution = 'judge' then
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        elsif t.challenger_submitted and not t.defender_submitted then
          v_winner := c.challenger_user_id; -- the non-responder forfeits
        elsif t.defender_submitted and not t.challenger_submitted then
          v_winner := c.defender_user_id;
        else
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        end if;
        update public.throne_challenge_trials
          set reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('timeout', true)
          where id = t.id;
        perform public._finish_throne_trial(t.id, v_winner);
      end if;
    end if;
  end loop;

  return v_changed;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 7 — the Final Trial likes Sudden Death
-- =================================================================
-- Catalog rows with public_config.final_boost = true get a 40% chance of
-- being THE FINAL TRIAL (when unused and allowed); otherwise the throne
-- chooses at random as before.
create or replace function public._pick_final_throne_trial(p_challenge_id uuid)
returns public.throne_trial_catalog as $$
declare
  v_cat public.throne_trial_catalog;
begin
  if random() < 0.4 then
    select * into v_cat from public.throne_trial_catalog t
      where t.is_active and coalesce((t.public_config->>'final_boost')::boolean, false)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
      order by random() limit 1;
    if v_cat.id is not null then
      return v_cat;
    end if;
  end if;
  return public._pick_catalog_trial(p_challenge_id, null);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._finish_throne_trial(p_trial_id uuid, p_winner uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
  v_chal int;
  v_def int;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.status = 'completed' then
    return;
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id for update;
  if p_winner not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Trial winner must be a participant';
  end if;

  update public.throne_challenge_trials
    set status = 'completed', winner_user_id = p_winner, completed_at = now()
    where id = t.id;

  v_chal := c.challenger_score + case when p_winner = c.challenger_user_id then 1 else 0 end;
  v_def := c.defender_score + case when p_winner = c.defender_user_id then 1 else 0 end;
  update public.throne_challenges set challenger_score = v_chal, defender_score = v_def where id = c.id;

  if v_chal >= 2 or v_def >= 2 then
    perform public._complete_throne_challenge(c.id, p_winner);
  elsif t.trial_no = 1 then
    update public.throne_challenges
      set status = 'active', awaiting_pick_by = c.defender_user_id, step_deadline = now() + interval '48 hours'
      where id = c.id;
  else
    v_cat := public._pick_final_throne_trial(c.id);
    perform public._start_throne_trial(c.id, v_cat, null);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 8 — the game catalog (the registry)
-- =================================================================
-- the roll-the-dice REFLEX placeholders are retired now that REFLEX is real
update public.throne_trial_catalog set is_active = false where id in ('reflex_quick_draw', 'reflex_cap_flip');

insert into public.throne_trial_catalog (id, school, title, description, resolution, public_config) values
  ('pint_beer_trivia', 'pint', 'Beer Trivia',
   'Five multiple-choice questions about OUR beers: styles, ratings, who rated what, which Session. Most right answers wins.',
   'quiz', '{"count":5,"options":4,"scoring":"correct","fallback":"beer","templates":["beer_style","beer_best_rated","beer_best_rater","beer_session","beer_brewery"]}'),
  ('pint_higher_lower', 'pint', 'Higher or Lower',
   'Beer A is shown with its average rating in our app. Is Beer B rated higher or lower? Six rounds, most right wins.',
   'quiz', '{"count":6,"options":2,"scoring":"correct","fallback":"beer","templates":["higher_lower"]}'),
  ('pint_guess_beer', 'pint', 'Guess the Beer',
   'The name is hidden. Style, brewery, ABV and average rating are your clues. Four beers to identify.',
   'quiz', '{"count":4,"options":4,"scoring":"correct","fallback":"beer","templates":["guess_beer"]}'),
  ('lore_who_said_it', 'lore', 'Who Said It?',
   'Quotes, anecdotes and poems from the Office Lore. Who is behind each one? Most right answers wins.',
   'quiz', '{"count":5,"options":4,"scoring":"correct","fallback":"general","templates":["quote_who","anecdote_who","nickstory_who","poem_author"]}'),
  ('lore_nickname_knowledge', 'lore', 'Nickname Knowledge',
   'Who has this nickname? Which nickname is real? Which one belongs to this story? Five questions from the Nickname Wall.',
   'quiz', '{"count":5,"options":4,"scoring":"correct","fallback":"general","templates":["nick_who","nick_of_person","nick_anecdote","nick_real"]}'),
  ('lore_office_quiz', 'lore', 'Office Lore Quiz',
   'Six questions drawn from the nicknames, anecdotes, poems and battles of the Office. Most right answers wins.',
   'quiz', '{"count":6,"options":4,"scoring":"correct","fallback":"general","templates":["nick_who","nickstory_who","poem_author","battle_winner","count_poems","count_nicknames"]}'),
  ('wisdom_office_quiz', 'wisdom', 'Office Lore Quiz: Wisdom Edition',
   'Numbers and facts from the Office: Beer Sessions, beers, battles, nicknames. Six questions, most right wins.',
   'quiz', '{"count":6,"options":4,"scoring":"correct","fallback":"general","templates":["count_sessions","count_beers","count_nicknames","count_poems","battle_winner","beer_session","beer_best_rated"]}'),
  ('wisdom_closest_wins', 'wisdom', 'Closest Wins',
   'Three numeric questions about the Office. Type your best guess: the smallest total miss wins.',
   'quiz', '{"count":3,"scoring":"error","fallback":"general","templates":["num_counts"]}'),
  ('wisdom_know_thy_enemy', 'wisdom', 'Know Thy Enemy',
   'Five questions about your OPPONENT, from their ratings and nicknames to their poems. Your rival gets the mirror questions about you.',
   'quiz', '{"count":5,"options":4,"scoring":"correct","fallback":"general","templates":["enemy_best_beer","enemy_fav_style","enemy_rating_count","enemy_nickname","enemy_poems","enemy_sessions","enemy_perfect_pours"]}'),
  ('reflex_rapid_fire', 'reflex', 'Rapid Fire',
   '60 seconds on the clock. Answer as many quick questions as you can. Right answers count +1, wrong ones -1.',
   'timed', '{"count":40,"options":3,"duration_s":60,"scoring":"timed","short":true,"fallback":"beer","templates":["beer_style","higher_lower","nick_who","nick_real","beer_brewery"]}'),
  ('reflex_sudden_death', 'reflex', 'Sudden Death',
   'Questions keep coming until your first mistake. The longer streak takes the Trial. Made for the Final Trial.',
   'streak', '{"count":20,"options":4,"scoring":"streak","final_boost":true,"fallback":"beer","templates":["beer_style","beer_best_rated","nick_who","nick_of_person","poem_author","beer_brewery"]}')
on conflict (id) do update set
  school = excluded.school, title = excluded.title, description = excluded.description,
  resolution = excluded.resolution, public_config = excluded.public_config, is_active = true;

-- =================================================================
-- SECTION 9 — grants
-- =================================================================
do $$
declare
  f record;
begin
  -- every internal helper / template: no client role may call it
  for f in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proname like '\_tq\_%' or p.proname like '\_throne\_%' or p.proname in
           ('_enemy_q', '_prepare_throne_trial', '_start_throne_trial', '_finalize_throne_run', '_resolve_quiz_trial',
            '_finalize_expired_runs', '_pick_final_throne_trial', '_finish_throne_trial', '_resolve_expired_throne_challenge'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

revoke all on function public.get_throne_run(uuid) from public, anon;
revoke all on function public.start_throne_run(uuid) from public, anon;
revoke all on function public.answer_throne_question(uuid, int, jsonb) from public, anon;
revoke all on function public.finish_throne_run(uuid) from public, anon;
grant execute on function public.get_throne_run(uuid) to authenticated;
grant execute on function public.start_throne_run(uuid) to authenticated;
grant execute on function public.answer_throne_question(uuid, int, jsonb) to authenticated;
grant execute on function public.finish_throne_run(uuid) to authenticated;

-- =========== 0042_royal_judge_creative_trials.sql ===========
-- =================================================================
-- OFFICE LORE — THE ROYAL JUDGE + CREATIVE (HUMAN-JUDGED) TRIALS
-- =================================================================
-- Trials a computer cannot score. Both duelists write something, a human
-- Royal Judge decides.
--
--   ✍️ POETRY DUEL     same absurd prompt (from the Poetry Wall prompts), a short poem
--   🏷️ NICKNAME DUEL   the app picks a person from the Office Lore, both invent a nickname
--   🎭 CAPTION BATTLE  same absurd situation, one caption each
--   😂 MAKE ME LAUGH   same subject, one sentence to make the Judge laugh
--   👑 ROYAL SPEECH    "explain in 30 seconds why you are the rightful ruler of The Taproom"
--
-- ROYAL JUDGE
--   Chosen automatically when a human-judged Trial starts: a random active
--   Office Lore member who is neither the challenger nor the defender (with
--   three users: simply the third one). Stored on the Trial
--   (throne_challenge_trials.judge_user_id) so it is stable and visible. Only
--   THAT member can judge. Verdicts:
--     the defender wins / the challenger wins / BOTH WERE TERRIBLE
--   "Both were terrible" scores NO point: the Trial is voided and a
--   replacement Trial (same Trial number, same school when possible, a
--   different Trial) takes its place.
--
-- ANONYMOUS VOTING
--   Creative entries are shown to the Judge as "Submission A" / "Submission B"
--   (random order, fixed when the second entry arrives). The Judge never
--   sees names. Only after the verdict does the Trial record who wrote what.
--   Entries live in throne_trial_submissions (no client policy): a duelist
--   only ever reads their OWN entry (via get_throne_creative), the Judge
--   reads the anonymous pair only while judging, and everybody reads the
--   revealed entries once the Trial is over (trial.reveal).
--
-- STATE (per Trial)
--   active          duelists are writing        (flags: *_submitted)
--   awaiting_judge  both entries in, Judge decides   (fresh 48h for the Judge)
--   completed       a winner was named
--   voided          "both were terrible": no point, replaced
--   Deadlines (48h per step, lazy like everything else): a duelist who never
--   writes forfeits (nobody wrote = coin flip); a Judge who never decides =
--   coin flip.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0041.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.throne_trial_catalog'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%resolution%';
  if v_name is not null then execute format('alter table public.throne_trial_catalog drop constraint %I', v_name); end if;

  select conname into v_name from pg_constraint
    where conrelid = 'public.throne_challenge_trials'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%status%';
  if v_name is not null then execute format('alter table public.throne_challenge_trials drop constraint %I', v_name); end if;
end $$;

alter table public.throne_trial_catalog add constraint throne_trial_catalog_resolution_check
  check (resolution in ('roll', 'answer', 'judge', 'quiz', 'timed', 'streak', 'creative'));
alter table public.throne_challenge_trials add constraint throne_challenge_trials_status_check
  check (status in ('active', 'awaiting_judge', 'completed', 'voided'));

-- a voided Trial is replaced by another attempt at the SAME Trial number
alter table public.throne_challenge_trials add column if not exists attempt int not null default 1;
alter table public.throne_challenge_trials drop constraint if exists throne_challenge_trials_challenge_id_trial_no_key;
create unique index if not exists throne_challenge_trials_no_attempt
  on public.throne_challenge_trials (challenge_id, trial_no, attempt);

alter table public.throne_trial_submissions add column if not exists slot text check (slot in ('A', 'B'));

-- prompts for the creative Trials (private: the chosen prompt is copied onto the Trial)
create table if not exists public.throne_creative_prompts (
  id serial primary key,
  kind text not null check (kind in ('caption', 'laugh', 'speech', 'poem')),
  prompt text not null unique
);
alter table public.throne_creative_prompts enable row level security; -- deliberately NO policy

insert into public.throne_creative_prompts (kind, prompt) values
  ('caption', 'The office printer has just been elected team leader. Caption the moment.'),
  ('caption', 'A lone banana sits in the CEO''s chair. Caption the photo.'),
  ('caption', 'Someone just replied-all to 400 people. Caption the second after.'),
  ('caption', 'The coffee machine, seconds after being told it is "out of order". Caption it.'),
  ('caption', 'A tiny dragon is guarding the last biscuit. Caption the scene.'),
  ('caption', 'The Abt Lord arrives at the Monday stand-up. Caption the entrance.'),
  ('caption', 'Two colleagues stare at the same spreadsheet in complete silence. Caption it.'),
  ('caption', 'A single sock was found on the printer. Caption the evidence.'),
  ('laugh', 'Mondays'),
  ('laugh', 'The office fridge'),
  ('laugh', 'Meetings that could have been an email'),
  ('laugh', 'Parking spots'),
  ('laugh', 'The last beer'),
  ('laugh', 'A reply-all chain that will not die'),
  ('laugh', 'Open-plan offices'),
  ('laugh', 'The company outing'),
  ('speech', 'Explain in 30 seconds why you are the rightful ruler of The Taproom.'),
  ('speech', 'Defend, in 30 seconds, why your taste in beer should be law.'),
  ('speech', 'Give a 30-second victory speech for the throne you have not won yet.'),
  ('speech', 'In 30 seconds: why does the Abt Lord''s crown fit YOUR head?'),
  ('speech', 'Convince the Royal Judge in 30 seconds that you are the true heir of the Taproom.'),
  ('poem', 'Write a short poem about a flying beer mat.'),
  ('poem', 'Write a short ode to the last biscuit in the tin.'),
  ('poem', 'Write a short poem about a stapler that dreams of the sea.')
on conflict (prompt) do nothing;

-- =================================================================
-- SECTION 2 — helpers
-- =================================================================
-- the Royal Judge: a random active Office Lore member, not a duelist
create or replace function public._pick_judge(p_challenge_id uuid)
returns uuid as $$
  select m.user_id
  from public.app_memberships m, public.throne_challenges c
  where c.id = p_challenge_id
    and m.app_id = 'officelore' and m.is_active = true
    and m.user_id not in (c.challenger_user_id, c.defender_user_id)
  order by random() limit 1;
$$ language sql volatile security definer set search_path = public;

-- both entries, with who wrote what (only ever written into trial.reveal AFTER judging)
create or replace function public._throne_creative_reveal(p_trial_id uuid)
returns jsonb as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'slot', slot, 'text', payload->>'text') order by slot), '[]'::jsonb)
  from public.throne_trial_submissions where trial_id = p_trial_id;
$$ language sql stable security definer set search_path = public;

-- draws the shared prompt of a creative Trial and stores it on the Trial
create or replace function public._prepare_creative_trial(p_trial_id uuid, p_cat public.throne_trial_catalog)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_kind text := p_cat.public_config->>'kind';
  v_prompt text;
  v_facts jsonb := '{}'::jsonb;
  r record;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  select * into c from public.throne_challenges where id = t.challenge_id;

  if v_kind = 'poem' then
    -- the Poetry Wall's own absurd prompts
    select prompt_text into v_prompt from public.poetry_prompts
      where is_active and category in ('absolute_nonsense', 'office_nonsense', 'beer_inspired', 'tragic', 'dramatic')
      order by random() limit 1;
    if v_prompt is null then
      select prompt into v_prompt from public.throne_creative_prompts where kind = 'poem' order by random() limit 1;
    end if;

  elsif v_kind = 'nickname' then
    -- a person already in the Office Lore, never one of the people in this duel
    select btrim(n.person_real_name) as person, max(nullif(btrim(n.business_unit), '')) as bu into r
    from public.nicknames n
    where btrim(n.person_real_name) <> ''
      and not exists (
        select 1 from public.profiles pr
        where pr.id in (c.challenger_user_id, c.defender_user_id, t.judge_user_id)
          and lower(split_part(btrim(pr.display_name), ' ', 1)) = lower(split_part(btrim(n.person_real_name), ' ', 1)))
    group by btrim(n.person_real_name)
    order by random() limit 1;
    if r.person is not null then
      v_prompt := format('Invent the best nickname for %s.', r.person);
      v_facts := jsonb_build_object('person', r.person, 'business_unit', r.bu);
    else
      v_prompt := 'Invent the best nickname for the colleague who always takes the last biscuit.';
    end if;

  else
    select prompt into v_prompt from public.throne_creative_prompts where kind = v_kind order by random() limit 1;
  end if;

  update public.throne_challenge_trials
    set public_config = public_config || jsonb_build_object('prompt', coalesce(v_prompt, p_cat.description), 'facts', v_facts)
    where id = p_trial_id;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- eligibility: human-judged Trials need a member who is not a duelist
create or replace function public._pick_catalog_trial(p_challenge_id uuid, p_school text)
returns public.throne_trial_catalog as $$
declare
  c public.throne_challenges;
  v_judge_exists boolean;
  v_school text := p_school;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id;

  select exists (
    select 1 from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active = true
      and m.user_id not in (c.challenger_user_id, c.defender_user_id)
  ) into v_judge_exists;

  if v_school is not null then
    select t.* into v_cat from public.throne_trial_catalog t
      where t.is_active and t.school = v_school
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution not in ('judge', 'creative') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
      order by random() limit 1;
    if v_cat.id is not null then
      return v_cat;
    end if;
  end if;

  select s.school into v_school from (
    select distinct t.school from public.throne_trial_catalog t
      where t.is_active
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution not in ('judge', 'creative') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
  ) s order by random() limit 1;

  if v_school is null then
    raise exception 'No Trials available for this Throne Challenge';
  end if;

  select t.* into v_cat from public.throne_trial_catalog t
    where t.is_active and t.school = v_school
      and (c.allow_real_life or t.school <> 'real_life')
      and (t.resolution not in ('judge', 'creative') or v_judge_exists)
      and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
    order by random() limit 1;
  return v_cat;
end;
$$ language plpgsql security definer set search_path = public;

-- starting a Trial: a replacement for a voided one reuses its number
create or replace function public._start_throne_trial(p_challenge_id uuid, p_cat public.throne_trial_catalog, p_picker uuid)
returns uuid as $$
declare
  v_no int;
  v_attempt int;
  v_id uuid;
  v_status text;
  v_judge uuid;
begin
  select count(*) + 1 into v_no from public.throne_challenge_trials where challenge_id = p_challenge_id and status <> 'voided';
  select count(*) + 1 into v_attempt from public.throne_challenge_trials where challenge_id = p_challenge_id and trial_no = v_no;
  v_status := case when p_cat.resolution = 'judge' then 'awaiting_judge' else 'active' end;
  v_judge := case when p_cat.resolution in ('judge', 'creative') then public._pick_judge(p_challenge_id) end;

  insert into public.throne_challenge_trials
    (challenge_id, trial_no, attempt, picker_user_id, school, catalog_id, title, description, resolution, public_config, status, judge_user_id)
  values
    (p_challenge_id, v_no, v_attempt, p_picker, p_cat.school, p_cat.id, p_cat.title, p_cat.description, p_cat.resolution, p_cat.public_config, v_status, v_judge)
  returning id into v_id;

  if p_cat.resolution in ('quiz', 'timed', 'streak') then
    perform public._prepare_throne_trial(v_id, p_cat);
  elsif p_cat.resolution = 'creative' then
    perform public._prepare_creative_trial(v_id, p_cat);
  end if;

  update public.throne_challenges
    set status = v_status,
        awaiting_pick_by = null,
        started_at = coalesce(started_at, now()),
        step_deadline = now() + interval '48 hours'
    where id = p_challenge_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — creative entries
-- =================================================================
create or replace function public.submit_throne_creative(p_trial_id uuid, p_text text)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_text text := btrim(coalesce(p_text, ''));
  v_max int;
  v_a_first boolean;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.resolution <> 'creative' or t.status <> 'active' then
    raise exception 'This Trial is not open for entries';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can enter this Trial';
  end if;
  if exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = auth.uid()) then
    raise exception 'You have already sealed your entry';
  end if;

  v_max := coalesce((t.public_config->>'max_chars')::int, 600);
  if length(v_text) < 1 then raise exception 'Write something first'; end if;
  if length(v_text) > v_max then raise exception 'Too long: at most % characters', v_max; end if;

  insert into public.throne_trial_submissions (trial_id, user_id, payload) values (t.id, auth.uid(), jsonb_build_object('text', v_text));
  if auth.uid() = c.challenger_user_id then
    update public.throne_challenge_trials set challenger_submitted = true where id = t.id;
  else
    update public.throne_challenge_trials set defender_submitted = true where id = t.id;
  end if;

  -- both entries in: fix the anonymous order and hand over to the Royal Judge
  if exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = c.challenger_user_id)
     and exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = c.defender_user_id) then
    v_a_first := random() < 0.5;
    update public.throne_trial_submissions set slot = case when (user_id = c.challenger_user_id) = v_a_first then 'A' else 'B' end
      where trial_id = t.id;
    update public.throne_challenge_trials set status = 'awaiting_judge' where id = t.id;
    update public.throne_challenges set status = 'awaiting_judge', step_deadline = now() + interval '48 hours' where id = c.id;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- what the caller may see of a creative Trial: their own entry, or (the Judge) the anonymous pair
create or replace function public.get_throne_creative(p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_role text;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  if t.id is null or t.resolution <> 'creative' then raise exception 'Not a creative Trial'; end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  v_role := case when auth.uid() = t.judge_user_id then 'judge'
                 when auth.uid() in (c.challenger_user_id, c.defender_user_id) then 'duelist' else 'spectator' end;
  return jsonb_build_object(
    'role', v_role,
    'mine', case when v_role = 'duelist' then
              (select payload->>'text' from public.throne_trial_submissions where trial_id = t.id and user_id = auth.uid()) end,
    'submissions', case when v_role = 'judge' and t.status = 'awaiting_judge' then
              (select coalesce(jsonb_agg(jsonb_build_object('slot', slot, 'text', payload->>'text') order by slot), '[]'::jsonb)
               from public.throne_trial_submissions where trial_id = t.id and slot is not null) end
  );
end;
$$ language plpgsql stable security definer set search_path = public;

-- =================================================================
-- SECTION 4 — the Royal Judge's verdict
-- =================================================================
--   creative Trials (anonymous):  'A' | 'B' | 'both_terrible'
--   other human-judged Trials:    'challenger' | 'defender' | 'both_terrible'
create or replace function public.judge_throne_verdict(p_trial_id uuid, p_verdict text)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_entries jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'awaiting_judge' or t.resolution not in ('judge', 'creative') then
    raise exception 'This Trial is not waiting for the Royal Judge';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'A duelist cannot judge their own Trial';
  end if;
  if t.judge_user_id is not null and t.judge_user_id <> auth.uid() then
    raise exception 'You are not the Royal Judge of this Trial';
  end if;

  if p_verdict = 'both_terrible' then
    v_winner := null;
  elsif t.resolution = 'creative' and p_verdict in ('A', 'B') then
    select user_id into v_winner from public.throne_trial_submissions where trial_id = t.id and slot = p_verdict;
  elsif t.resolution = 'judge' and p_verdict = 'challenger' then
    v_winner := c.challenger_user_id;
  elsif t.resolution = 'judge' and p_verdict = 'defender' then
    v_winner := c.defender_user_id;
  else
    raise exception 'Unknown verdict';
  end if;
  if p_verdict <> 'both_terrible' and v_winner is null then
    raise exception 'Unknown verdict';
  end if;

  v_entries := case when t.resolution = 'creative' then public._throne_creative_reveal(t.id) else null end;

  if v_winner is not null then
    update public.throne_challenge_trials
      set judge_user_id = auth.uid(),
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', p_verdict)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    perform public._finish_throne_trial(t.id, v_winner);
    return;
  end if;

  -- BOTH WERE TERRIBLE: no point. Void it and play a replacement Trial.
  begin
    update public.throne_challenge_trials
      set status = 'voided', completed_at = now(), judge_user_id = auth.uid(),
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', 'both_terrible', 'voided', true)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    v_cat := public._pick_catalog_trial(c.id, t.school);
    perform public._start_throne_trial(c.id, v_cat, t.picker_user_id);
  exception when raise_exception then
    -- no replacement Trial left: the throne decides by coin flip, openly
    v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
    update public.throne_challenge_trials
      set status = 'awaiting_judge', completed_at = null,
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', 'both_terrible', 'coin_flip', true)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    perform public._finish_throne_trial(t.id, v_winner);
  end;
end;
$$ language plpgsql security definer set search_path = public;

-- the 0038 entry point now goes through the same checks (and Judge identity)
create or replace function public.judge_throne_trial(p_trial_id uuid, p_winner uuid)
returns void as $$
declare
  c public.throne_challenges;
begin
  select ch.* into c from public.throne_challenges ch
    join public.throne_challenge_trials t on t.challenge_id = ch.id where t.id = p_trial_id;
  if c.id is null then raise exception 'This Trial is not waiting for the Royal Judge'; end if;
  perform public.judge_throne_verdict(p_trial_id,
    case when p_winner = c.challenger_user_id then 'challenger' when p_winner = c.defender_user_id then 'defender' else 'invalid' end);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — deadline resolver (replaces 0041's)
-- =================================================================
create or replace function public._resolve_expired_throne_challenge()
returns boolean as $$
declare
  c public.throne_challenges;
  t public.throne_challenge_trials;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_changed boolean := false;
  v_guard int := 0;
begin
  perform pg_advisory_xact_lock(918273645);

  if public._finalize_expired_runs() then
    v_changed := true;
  end if;

  loop
    v_guard := v_guard + 1;
    exit when v_guard > 10;

    select * into c from public.throne_challenges
      where status in ('pending', 'active', 'awaiting_judge')
        and step_deadline is not null and step_deadline <= now()
      limit 1;
    exit when c.id is null;
    v_changed := true;

    if c.status = 'pending' then
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;

    elsif c.awaiting_pick_by is not null then
      v_cat := public._pick_catalog_trial(c.id, null);
      perform public._start_throne_trial(c.id, v_cat, c.awaiting_pick_by);

    else
      select * into t from public.throne_challenge_trials
        where challenge_id = c.id and status in ('active', 'awaiting_judge')
        order by trial_no desc, attempt desc limit 1;

      if t.id is null then
        update public.throne_challenges
          set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
          where id = c.id;
      else
        if t.resolution in ('quiz', 'timed', 'streak') then
          perform public._finalize_throne_run(t.id, c.challenger_user_id, 'deadline');
          perform public._finalize_throne_run(t.id, c.defender_user_id, 'deadline');
          select * into t from public.throne_challenge_trials where id = t.id;
          continue when t.status = 'completed';
        end if;

        if t.status = 'awaiting_judge' then
          -- the Royal Judge never decided: the throne flips a coin
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        elsif t.challenger_submitted and not t.defender_submitted then
          v_winner := c.challenger_user_id; -- the non-responder forfeits
        elsif t.defender_submitted and not t.challenger_submitted then
          v_winner := c.defender_user_id;
        else
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        end if;
        update public.throne_challenge_trials
          set reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('timeout', true)
                       || case when t.resolution = 'creative' then jsonb_build_object('entries', public._throne_creative_reveal(t.id)) else '{}'::jsonb end
          where id = t.id;
        perform public._finish_throne_trial(t.id, v_winner);
      end if;
    end if;
  end loop;

  return v_changed;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — the creative Trials
-- =================================================================
-- the placeholder CHAOS judge Trials are replaced by the real ones
update public.throne_trial_catalog set is_active = false where id in ('chaos_nickname_sprint', 'chaos_fake_holiday');

insert into public.throne_trial_catalog (id, school, title, description, resolution, public_config) values
  ('lore_poetry_duel', 'lore', 'Poetry Duel',
   'Both duelists get the same absurd prompt and write a short poem. The Royal Judge reads them anonymously and chooses.',
   'creative', '{"kind":"poem","max_chars":700,"anonymous":true,"input":"Write your poem…"}'),
  ('lore_nickname_duel', 'lore', 'Nickname Duel',
   'The app picks a person from the Office Lore. Both duelists invent a nickname. The Royal Judge picks the better one, blind.',
   'creative', '{"kind":"nickname","max_chars":40,"anonymous":true,"single_line":true,"input":"Their new nickname…"}'),
  ('chaos_caption_battle', 'chaos', 'Caption Battle',
   'The same absurd situation, one caption each. The Royal Judge chooses the funniest, blind.',
   'creative', '{"kind":"caption","max_chars":160,"anonymous":true,"input":"Your caption…"}'),
  ('chaos_make_me_laugh', 'chaos', 'Make Me Laugh',
   'The same subject, ONE sentence each. Make the Royal Judge laugh.',
   'creative', '{"kind":"laugh","max_chars":200,"anonymous":true,"input":"One sentence…"}'),
  ('chaos_royal_speech', 'chaos', 'Royal Speech',
   'A short royal speech: convince the Royal Judge you are the rightful ruler. Keep it to what fits in 30 seconds.',
   'creative', '{"kind":"speech","max_chars":600,"anonymous":true,"input":"Your royal speech…"}')
on conflict (id) do update set
  school = excluded.school, title = excluded.title, description = excluded.description,
  resolution = excluded.resolution, public_config = excluded.public_config, is_active = true;

-- =================================================================
-- SECTION 7 — grants
-- =================================================================
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('_pick_judge', '_throne_creative_reveal', '_prepare_creative_trial', '_pick_catalog_trial',
                        '_start_throne_trial', '_resolve_expired_throne_challenge')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

revoke all on function public.submit_throne_creative(uuid, text) from public, anon;
revoke all on function public.get_throne_creative(uuid) from public, anon;
revoke all on function public.judge_throne_verdict(uuid, text) from public, anon;
revoke all on function public.judge_throne_trial(uuid, uuid) from public, anon;
grant execute on function public.submit_throne_creative(uuid, text) to authenticated;
grant execute on function public.get_throne_creative(uuid) to authenticated;
grant execute on function public.judge_throne_verdict(uuid, text) to authenticated;
grant execute on function public.judge_throne_trial(uuid, uuid) to authenticated;

-- =========== 0043_real_life_trials.sql ===========
-- =================================================================
-- OFFICE LORE — 🌍 REAL LIFE TRIALS
-- =================================================================
-- Physical, in-the-room challenges. The app GUIDES them (task, props, rules,
-- a big phone-on-the-table timer) but does not judge them: the Royal Judge
-- (0042) is the referee and names the winner.
--
-- A FIXED, CURATED POOL. Every Trial below is written by hand and reviewed
-- for safety. Nothing is generated freely and nothing is AI-written at
-- runtime; the only randomness is picking WHICH curated Trial, and which
-- curated option inside it (dance style, voice, quest ...).
--   SAFETY RULES BAKED INTO THE POOL
--   * nothing dangerous, nothing that can break or stain things
--   * nothing that involves driving, leaving the venue or running
--   * no alcohol task of any kind. The one drinking race, THE FASTEST PINT,
--     says in its title, description, rules and a red banner that it is for
--     WATER OR ALCOHOL-FREE BEER ONLY, in a small glass, with no chugging
--   * nothing humiliating or sexual, nothing illegal, no touching the
--     other player, no photos of people without their OK
--   * Real Life Trials only ever appear when "Allow Real Life Trials" was
--     switched on for the challenge (the school itself is gated, 0038)
--   * the Royal Judge can SKIP any Trial that is not possible or not
--     comfortable: no point is scored and a replacement Trial follows
--
-- FLOW (resolution 'reallife')
--   active           the task is shown (so the duelists can prepare). Each
--                    duelist presses READY on their own phone.
--   awaiting_judge   both are READY: GO! The timer helper runs on the phone.
--                    The Royal Judge watches and names the winner
--                    (defender / challenger / both were terrible / skip).
--   🎲 MYSTERY TRIAL the task is chosen by the server at the start and kept
--                    in a private table. It stays hidden until BOTH duelists
--                    press READY; only then is it revealed (and written to the
--                    Trial), and the client plays the reveal animation.
--   Deadlines (48h per step, lazy like everything else): a duelist who never
--   presses READY forfeits (nobody = coin flip); a Judge who never decides =
--   coin flip.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0042.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.throne_trial_catalog'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%resolution%';
  if v_name is not null then execute format('alter table public.throne_trial_catalog drop constraint %I', v_name); end if;
end $$;

alter table public.throne_trial_catalog add constraint throne_trial_catalog_resolution_check
  check (resolution in ('roll', 'answer', 'judge', 'quiz', 'timed', 'streak', 'creative', 'reallife'));

-- the secret task of a Mystery Trial until both duelists are READY (PRIVATE)
create table if not exists public.throne_mystery_tasks (
  trial_id uuid primary key references public.throne_challenge_trials(id) on delete cascade,
  catalog_id text not null references public.throne_trial_catalog(id)
);
alter table public.throne_mystery_tasks enable row level security; -- deliberately NO policy

-- =================================================================
-- SECTION 2 — helpers
-- =================================================================
-- the random bits of a Real Life Trial (dance style, voice, quest, person ...),
-- drawn from the CURATED lists in the catalog row's public_config
create or replace function public._reallife_picks(p_cfg jsonb, p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_picks jsonb := '[]'::jsonb;
  v_label text;
  v_pool jsonb;
  v_person text;
  v_lord text;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  select * into c from public.throne_challenges where id = t.challenge_id;

  if p_cfg ? 'pools' then
    for v_label, v_pool in select key, value from jsonb_each(p_cfg->'pools') loop
      v_picks := v_picks || jsonb_build_object('label', v_label, 'value', v_pool->>(floor(random() * jsonb_array_length(v_pool))::int));
    end loop;
  end if;

  if p_cfg ? 'person_label' then
    -- a person from the Office Lore, never one of the people in this challenge
    select btrim(n.person_real_name) into v_person
    from public.nicknames n
    where btrim(n.person_real_name) <> ''
      and not exists (
        select 1 from public.profiles pr
        where pr.id in (c.challenger_user_id, c.defender_user_id, t.judge_user_id)
          and lower(split_part(btrim(pr.display_name), ' ', 1)) = lower(split_part(btrim(n.person_real_name), ' ', 1)))
    group by btrim(n.person_real_name)
    order by random() limit 1;
    if v_person is not null then
      v_picks := v_picks || jsonb_build_object('label', p_cfg->>'person_label', 'value', v_person);
    end if;
  end if;

  if coalesce((p_cfg->>'abt_lord')::boolean, false) then
    select pr.display_name into v_lord from public.abt_reigns r join public.profiles pr on pr.id = r.user_id where r.ended_at is null limit 1;
    if v_lord is not null then
      v_picks := v_picks || jsonb_build_object('label', 'Draw', 'value', v_lord || ', the Abt Lord');
    end if;
  end if;

  return v_picks;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._prepare_reallife_trial(p_trial_id uuid, p_cat public.throne_trial_catalog)
returns void as $$
declare
  t public.throne_challenge_trials;
  v_inner public.throne_trial_catalog;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;

  if coalesce((p_cat.public_config->>'mystery')::boolean, false) then
    -- pick the hidden task now, keep it private until both are READY
    select c.* into v_inner from public.throne_trial_catalog c
      where c.is_active and c.school = 'real_life' and c.resolution = 'reallife'
        and not coalesce((c.public_config->>'mystery')::boolean, false)
        and c.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = t.challenge_id)
        and c.id not in (select m.catalog_id from public.throne_mystery_tasks m
                         join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = t.challenge_id)
      order by random() limit 1;
    if v_inner.id is null then
      raise exception 'No Real Life Trial left for the Mystery Trial';
    end if;
    insert into public.throne_mystery_tasks (trial_id, catalog_id) values (p_trial_id, v_inner.id);
    update public.throne_challenge_trials
      set public_config = public_config || jsonb_build_object('revealed', false)
      where id = p_trial_id;
  else
    update public.throne_challenge_trials
      set public_config = public_config || jsonb_build_object('picks', public._reallife_picks(p_cat.public_config, p_trial_id))
      where id = p_trial_id;
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- eligibility: human-judged Trials need a member who is not a duelist; a
-- Mystery Trial's hidden task counts as used
create or replace function public._pick_catalog_trial(p_challenge_id uuid, p_school text)
returns public.throne_trial_catalog as $$
declare
  c public.throne_challenges;
  v_judge_exists boolean;
  v_school text := p_school;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id;

  select exists (
    select 1 from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active = true
      and m.user_id not in (c.challenger_user_id, c.defender_user_id)
  ) into v_judge_exists;

  if v_school is not null then
    select t.* into v_cat from public.throne_trial_catalog t
      where t.is_active and t.school = v_school
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution not in ('judge', 'creative', 'reallife') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
        and t.id not in (select m.catalog_id from public.throne_mystery_tasks m
                         join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = p_challenge_id)
      order by random() limit 1;
    if v_cat.id is not null then
      return v_cat;
    end if;
  end if;

  select s.school into v_school from (
    select distinct t.school from public.throne_trial_catalog t
      where t.is_active
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution not in ('judge', 'creative', 'reallife') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
        and t.id not in (select m.catalog_id from public.throne_mystery_tasks m
                         join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = p_challenge_id)
  ) s order by random() limit 1;

  if v_school is null then
    raise exception 'No Trials available for this Throne Challenge';
  end if;

  select t.* into v_cat from public.throne_trial_catalog t
    where t.is_active and t.school = v_school
      and (c.allow_real_life or t.school <> 'real_life')
      and (t.resolution not in ('judge', 'creative', 'reallife') or v_judge_exists)
      and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
      and t.id not in (select m.catalog_id from public.throne_mystery_tasks m
                       join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = p_challenge_id)
    order by random() limit 1;
  return v_cat;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._start_throne_trial(p_challenge_id uuid, p_cat public.throne_trial_catalog, p_picker uuid)
returns uuid as $$
declare
  v_no int;
  v_attempt int;
  v_id uuid;
  v_status text;
  v_judge uuid;
begin
  select count(*) + 1 into v_no from public.throne_challenge_trials where challenge_id = p_challenge_id and status <> 'voided';
  select count(*) + 1 into v_attempt from public.throne_challenge_trials where challenge_id = p_challenge_id and trial_no = v_no;
  v_status := case when p_cat.resolution = 'judge' then 'awaiting_judge' else 'active' end;
  v_judge := case when p_cat.resolution in ('judge', 'creative', 'reallife') then public._pick_judge(p_challenge_id) end;

  insert into public.throne_challenge_trials
    (challenge_id, trial_no, attempt, picker_user_id, school, catalog_id, title, description, resolution, public_config, status, judge_user_id)
  values
    (p_challenge_id, v_no, v_attempt, p_picker, p_cat.school, p_cat.id, p_cat.title, p_cat.description, p_cat.resolution, p_cat.public_config, v_status, v_judge)
  returning id into v_id;

  if p_cat.resolution in ('quiz', 'timed', 'streak') then
    perform public._prepare_throne_trial(v_id, p_cat);
  elsif p_cat.resolution = 'creative' then
    perform public._prepare_creative_trial(v_id, p_cat);
  elsif p_cat.resolution = 'reallife' then
    perform public._prepare_reallife_trial(v_id, p_cat);
  end if;

  update public.throne_challenges
    set status = v_status,
        awaiting_pick_by = null,
        started_at = coalesce(started_at, now()),
        step_deadline = now() + interval '48 hours'
    where id = p_challenge_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — READY
-- =================================================================
create or replace function public.ready_throne_trial(p_trial_id uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_inner public.throne_trial_catalog;
  v_cfg jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.resolution <> 'reallife' or t.status <> 'active' then
    raise exception 'This Trial is not waiting for READY';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can be READY';
  end if;

  if auth.uid() = c.challenger_user_id then
    update public.throne_challenge_trials set challenger_submitted = true where id = t.id;
  else
    update public.throne_challenge_trials set defender_submitted = true where id = t.id;
  end if;
  select * into t from public.throne_challenge_trials where id = t.id;

  if t.challenger_submitted and t.defender_submitted then
    v_cfg := t.public_config;
    if coalesce((v_cfg->>'mystery')::boolean, false) and not coalesce((v_cfg->>'revealed')::boolean, false) then
      -- REVEAL: the hidden task becomes the Trial
      select ct.* into v_inner from public.throne_mystery_tasks m join public.throne_trial_catalog ct on ct.id = m.catalog_id where m.trial_id = t.id;
      update public.throne_challenge_trials
        set title = v_inner.title, description = v_inner.description,
            public_config = v_inner.public_config
              || jsonb_build_object('mystery', true, 'revealed', true, 'picks', public._reallife_picks(v_inner.public_config, t.id), 'go_at', now())
        where id = t.id;
    else
      update public.throne_challenge_trials
        set public_config = public_config || jsonb_build_object('go_at', now())
        where id = t.id;
    end if;
    update public.throne_challenge_trials set status = 'awaiting_judge' where id = t.id;
    update public.throne_challenges set status = 'awaiting_judge', step_deadline = now() + interval '48 hours' where id = c.id;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — the Royal Judge's verdict (0042's, now also for Real Life)
-- =================================================================
--   creative Trials (anonymous):          'A' | 'B' | 'both_terrible'
--   judge / Real Life Trials (named):     'challenger' | 'defender' | 'both_terrible'
--   Real Life / judge Trials only:        'skip'  (not possible or not comfortable here)
-- 'both_terrible' and 'skip' score no point; the Trial is voided and replaced.
create or replace function public.judge_throne_verdict(p_trial_id uuid, p_verdict text)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_entries jsonb;
  v_void boolean := p_verdict in ('both_terrible', 'skip');
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'awaiting_judge' or t.resolution not in ('judge', 'creative', 'reallife') then
    raise exception 'This Trial is not waiting for the Royal Judge';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'A duelist cannot judge their own Trial';
  end if;
  if t.judge_user_id is not null and t.judge_user_id <> auth.uid() then
    raise exception 'You are not the Royal Judge of this Trial';
  end if;

  if v_void then
    if p_verdict = 'skip' and t.resolution = 'creative' then raise exception 'Unknown verdict'; end if;
  elsif t.resolution = 'creative' and p_verdict in ('A', 'B') then
    select user_id into v_winner from public.throne_trial_submissions where trial_id = t.id and slot = p_verdict;
  elsif t.resolution in ('judge', 'reallife') and p_verdict = 'challenger' then
    v_winner := c.challenger_user_id;
  elsif t.resolution in ('judge', 'reallife') and p_verdict = 'defender' then
    v_winner := c.defender_user_id;
  else
    raise exception 'Unknown verdict';
  end if;
  if not v_void and v_winner is null then
    raise exception 'Unknown verdict';
  end if;

  v_entries := case when t.resolution = 'creative' then public._throne_creative_reveal(t.id) else null end;

  if not v_void then
    update public.throne_challenge_trials
      set judge_user_id = auth.uid(),
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', p_verdict)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    perform public._finish_throne_trial(t.id, v_winner);
    return;
  end if;

  -- no point scored: void it and play a replacement Trial
  begin
    update public.throne_challenge_trials
      set status = 'voided', completed_at = now(), judge_user_id = auth.uid(),
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', p_verdict, 'voided', true, 'skipped', p_verdict = 'skip')
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    v_cat := public._pick_catalog_trial(c.id, t.school);
    perform public._start_throne_trial(c.id, v_cat, t.picker_user_id);
  exception when raise_exception then
    -- no replacement Trial left: the throne decides by coin flip, openly
    v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
    update public.throne_challenge_trials
      set status = 'awaiting_judge', completed_at = null,
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', p_verdict, 'coin_flip', true)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    perform public._finish_throne_trial(t.id, v_winner);
  end;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — the curated Real Life pool
-- =================================================================
-- the 0038 placeholders are retired (arm wrestling is not a safe default)
update public.throne_trial_catalog set is_active = false where id in ('real_bottle_flip', 'real_arm_wrestle');

-- public_config keys the client understands:
--   icon, props, rules[], decide, format, timer_s, timer_mode (turns | shared | stopwatch),
--   timer_label, pools{label:[...]}, person_label, abt_lord, drink_safe, mystery
insert into public.throne_trial_catalog (id, school, title, description, resolution, public_config) values
  ('real_royal_waltz', 'real_life', 'The Royal Waltz',
   '30 seconds each to show your finest waltz. Grace beats speed.', 'reallife',
   $j${"icon":"💃","props":"A little clear floor space","timer_s":30,"timer_mode":"turns","timer_label":"Waltz",
       "rules":["One duelist at a time, 30 seconds each.","Waltz solo or with an imaginary partner. No touching the other duelist.","Mind the furniture, the glasses and your neighbours."],
       "decide":"Grace, rhythm and royal bearing."}$j$::jsonb),
  ('real_fastest_pint', 'real_life', 'The Fastest Pint (alcohol-free)',
   'A race to finish a small glass of WATER or ALCOHOL-FREE beer. Never alcohol. This is not a drinking contest.', 'reallife',
   $j${"icon":"🥤","drink_safe":true,"props":"Two small glasses (25 cl at most) of WATER or ALCOHOL-FREE beer","timer_mode":"stopwatch","timer_label":"Race",
       "rules":["WATER OR ALCOHOL-FREE BEER ONLY. No alcohol, ever, in this Trial.","Small glass, 25 cl at most. Drink steadily: no gulping contest.","Stop at once if anyone coughs, chokes or feels unwell.","Ready, set, drink! The Royal Judge calls who finished first."],
       "decide":"First to put down an empty glass."}$j$::jsonb),
  ('real_coin_to_glass', 'real_life', 'Coin to Glass',
   'Best of 5: drop a coin into an EMPTY glass or cup.', 'reallife',
   $j${"icon":"🎯","format":"Best of 5","props":"A coin each and an empty plastic cup or sturdy glass","timer_mode":"none",
       "rules":["Empty cup on a stable table. No drinks involved.","Five attempts each, taking turns, from a fixed distance you agree on.","Most coins in the cup wins; a tie is settled by one sudden-death attempt each."],
       "decide":"Most coins in the cup after five attempts."}$j$::jsonb),
  ('real_flip_cup', 'real_life', 'Royal Flip Cup',
   'Flip an EMPTY plastic cup so it lands upside down. Best of 3, or first clean flip.', 'reallife',
   $j${"icon":"🥤","format":"Best of 3 or first clean flip","props":"An empty plastic cup each","timer_mode":"none",
       "rules":["Empty plastic cups only. There are NO drinks in this game.","Set the cup over the table edge and flick the base to flip it.","Agree before you start: best of 3, or first clean flip wins."],
       "decide":"Most clean flips, or the first one."}$j$::jsonb),
  ('real_kings_toss', 'real_life', 'The King''s Toss',
   'Bounce a coin off the table into a cup.', 'reallife',
   $j${"icon":"🪙","props":"A coin each, an empty cup, a sturdy table","timer_mode":"none","format":"3 tosses each",
       "rules":["Empty cup, no drinks.","Bounce the coin once off the table so that it lands in the cup.","Three tosses each, taking turns. Most successful tosses wins.","Toss along the table, never towards people."],
       "decide":"Most coins in the cup."}$j$::jsonb),
  ('real_tower', 'real_life', 'The Tower',
   '60 seconds to build the tallest free-standing tower of coasters.', 'reallife',
   $j${"icon":"🧻","props":"A pile of coasters (or other flat, light objects) each","timer_s":60,"timer_mode":"shared","timer_label":"Build",
       "rules":["Coasters or other flat, light objects only.","Free-standing: no leaning on anything, and hands off when time is up.","The tower must still stand when the Royal Judge looks."],
       "decide":"The tallest tower still standing."}$j$::jsonb),
  ('real_coaster_flip', 'real_life', 'Coaster Flip',
   'Flip and catch coasters. One more every round. The first failure loses.', 'reallife',
   $j${"icon":"🍻","props":"A stack of coasters each","timer_mode":"none",
       "rules":["Round 1: flick one coaster off the table edge and catch it.","Each round add one more coaster to the stack you flip.","The first to drop the coaster, or the stack, loses the Trial.","Keep the flips low and over the table."],
       "decide":"Last one still catching."}$j$::jsonb),
  ('real_draw_enemy', 'real_life', 'Draw Thy Enemy',
   '60 seconds. Draw your opponent.', 'reallife',
   $j${"icon":"🎨","props":"Pen and paper (or a drawing app)","timer_s":60,"timer_mode":"shared","timer_label":"Draw",
       "rules":["Draw your opponent in 60 seconds.","Funny is good, cruel is not. Be kind to the face and to the ego.","Show both drawings to the Royal Judge at the same time."],
       "decide":"The best (funniest) portrait."}$j$::jsonb),
  ('real_draw_abt', 'real_life', 'Draw the Abt',
   'Draw the current Abt Lord with your eyes closed.', 'reallife',
   $j${"icon":"👑","abt_lord":true,"props":"Pen and paper","timer_s":45,"timer_mode":"shared","timer_label":"Draw",
       "rules":["Close your eyes (or cover them with your free hand) and draw the subject in 45 seconds.","Stay seated and put nothing over your eyes that you cannot take off at once.","No peeking! The Royal Judge watches."],
       "decide":"The most majestic (or most hilarious) likeness."}$j$::jsonb),
  ('real_royal_statue', 'real_life', 'Royal Statue',
   'Stay as still as a statue for as long as you can. The Royal Judge tries to make you laugh.', 'reallife',
   $j${"icon":"🗿","props":"Nothing","timer_mode":"stopwatch","timer_label":"Statue",
       "rules":["Freeze like a statue. First to move or laugh is out.","The Royal Judge may pull faces, make sounds and tell clean jokes.","No touching, tickling or props near faces."],
       "decide":"The statue that lasts the longest."}$j$::jsonb),
  ('real_dont_laugh', 'real_life', 'Don''t Laugh',
   'The first one to laugh loses.', 'reallife',
   $j${"icon":"😐","props":"Nothing","timer_mode":"stopwatch","timer_label":"Straight faces",
       "rules":["Face each other with a straight face. The first to laugh or smile loses.","The Royal Judge or the other duelist may make faces, but no touching or tickling.","Clean jokes only."],
       "decide":"The last straight face."}$j$::jsonb),
  ('real_staring_contest', 'real_life', 'Staring Contest',
   'The classic. First to blink or look away loses.', 'reallife',
   $j${"icon":"👁️","props":"Nothing","timer_mode":"stopwatch","timer_label":"Stare",
       "rules":["Look each other in the eyes. First to blink or look away loses.","Stop if your eyes hurt; the Royal Judge will call it."],
       "decide":"The last one staring."}$j$::jsonb),
  ('real_dance_abt', 'real_life', 'Dance of the Abt',
   'A random dance style. 30 seconds each. Commit.', 'reallife',
   $j${"icon":"🕺","props":"A little clear floor space","timer_s":30,"timer_mode":"turns","timer_label":"Dance",
       "pools":{"Style":["Waltz","Disco","Robot","Slow Motion","Irish Dance","Interpretive Dance"]},
       "rules":["The app picks the dance style for both duelists.","One at a time, 30 seconds each.","Keep it safe: no jumps, no lifts, no touching the other duelist.","Mind the furniture and the glasses."],
       "decide":"The best dance in this style."}$j$::jsonb),
  ('real_karaoke', 'real_life', 'Royal Karaoke',
   '30 seconds of song each.', 'reallife',
   $j${"icon":"🎤","props":"A song you know (a hairbrush microphone is welcome)","timer_s":30,"timer_mode":"turns","timer_label":"Sing",
       "rules":["Any song, friendly lyrics only. 30 seconds each, one at a time.","Everyone, including the Royal Judge, must listen with respect."],
       "decide":"The most royal performance."}$j$::jsonb),
  ('real_impersonation', 'real_life', 'Impersonation Trial',
   'Impersonate a person from the Office Lore. Kind, not cruel.', 'reallife',
   $j${"icon":"🎭","props":"Nothing","timer_s":30,"timer_mode":"turns","timer_label":"Act","person_label":"Impersonate",
       "rules":["Impersonate the person shown: how they talk, move or laugh. 30 seconds each.","Keep it kind: a mannerism or a catchphrase, never a flaw, their looks or anything private.","Only people from the Office Lore are used."],
       "decide":"The best performance."}$j$::jsonb),
  ('real_accent_battle', 'real_life', 'Accent Battle',
   'The same absurd line, in the same funny voice.', 'reallife',
   $j${"icon":"🗣️","props":"Nothing","timer_s":30,"timer_mode":"turns","timer_label":"Perform",
       "pools":{"Voice":["a pirate captain","a very posh butler","a robot running out of battery","a medieval king","a dramatic news anchor","a nature documentary narrator","an opera singer","a cowboy"],
                "Line":["The biscuit tin has been empty since Tuesday and nobody will speak of it.","I would like to speak to whoever moved my stapler.","The printer and I have an understanding.","Today we gather to mourn the last beer in the fridge."]},
       "rules":["Both perform the same line in the same voice, one at a time, 30 seconds.","The voice is always a character, never a real nationality or group of people."],
       "decide":"The best performance of the line."}$j$::jsonb),
  ('real_royal_speech_live', 'real_life', 'Royal Speech: Live',
   '30 seconds of royal improvisation on a topic you get on the spot.', 'reallife',
   $j${"icon":"📢","props":"Nothing","timer_s":30,"timer_mode":"turns","timer_label":"Speak",
       "pools":{"Topic":["Why the Taproom needs a moat.","Why Mondays are abolished by royal decree.","Why the last biscuit belongs to the crown.","Why my chair is the true throne.","Why every meeting should end with a toast."]},
       "rules":["Improvise a speech on the topic, 30 seconds each, one at a time.","No preparation, no notes."],
       "decide":"The most convincing (or most entertaining) speech."}$j$::jsonb),
  ('real_five_seconds', 'real_life', 'Five Seconds',
   'Name three valid answers within 5 seconds.', 'reallife',
   $j${"icon":"🧠","props":"Nothing","timer_s":5,"timer_mode":"turns","timer_label":"5 seconds",
       "pools":{"Round 1":["Three beer brands","Three things in a kitchen","Three Belgian cities"],
                "Round 2":["Three things you find in a pub","Three animals with four legs","Three colours of the rainbow"],
                "Round 3":["Three board games","Three types of cheese","Three things that are round"]},
       "rules":["Three rounds. In each round the category is shown; the duelist whose turn it is has 5 seconds to name three valid answers.","Alternate who starts each round.","The Royal Judge decides what counts as valid."],
       "decide":"Most successful rounds."}$j$::jsonb),
  ('real_hum_tune', 'real_life', 'Hum That Tune',
   'One hums, the other guesses. Then swap.', 'reallife',
   $j${"icon":"🎵","props":"Songs in your head","timer_s":30,"timer_mode":"turns","timer_label":"Hum",
       "pools":{"Category":["a famous movie theme","a children's song","a pop classic","a Christmas song","a cartoon theme","a Disney song"]},
       "rules":["The hummer picks a song from the category and hums it for 30 seconds. No words!","The other duelist guesses. Then swap roles.","The Royal Judge keeps score of the correct guesses."],
       "decide":"Most songs guessed."}$j$::jsonb),
  ('real_fashion', 'real_life', 'The Fashion Trial',
   '2 minutes to create the most majestic Abt outfit from what is around you.', 'reallife',
   $j${"icon":"🧦","props":"Whatever is around you","timer_s":120,"timer_mode":"shared","timer_label":"Dress",
       "rules":["Create the most majestic Abt outfit in 2 minutes with your own belongings or things you have permission to use.","Nothing that can stain, tear or hurt. Keep it dignified.","Model it for the Royal Judge when the time is up."],
       "decide":"The most majestic outfit."}$j$::jsonb),
  ('real_paper_toss', 'real_life', 'Paper Toss',
   'Scrunch up a sheet of paper and sink it. Best of 5.', 'reallife',
   $j${"icon":"🏹","format":"Best of 5","props":"Scrap paper and a bin or cup as target","timer_mode":"none",
       "rules":["Aim at the bin or cup, never at people.","Five throws each from the same spot, taking turns.","Most hits wins; a tie is settled by one sudden-death throw each."],
       "decide":"Most hits in five throws."}$j$::jsonb),
  ('real_air_force', 'real_life', 'Royal Air Force',
   'Build a paper plane. The furthest valid flight wins.', 'reallife',
   $j${"icon":"✈️","props":"One sheet of paper each","timer_s":60,"timer_mode":"shared","timer_label":"Build",
       "rules":["60 seconds to build a paper plane.","Throw along a clear path, away from people.","Each duelist gets one flight; the Royal Judge measures."],
       "decide":"The furthest valid flight."}$j$::jsonb),
  ('real_balance_power', 'real_life', 'Balance of Power',
   'Balance a safe little object. The longest time wins.', 'reallife',
   $j${"icon":"⚖️","props":"A coaster, spoon or pen each","timer_mode":"stopwatch","timer_label":"Balance",
       "rules":["Balance the object on a finger, the back of your hand or your chin while seated or standing still.","Nothing sharp, hot or fragile.","The clock stops when the object falls."],
       "decide":"The longest balance."}$j$::jsonb),
  ('real_quest', 'real_life', 'The Quest',
   'A simple, safe fetch quest. First back wins.', 'reallife',
   $j${"icon":"🏃","props":"The venue around you","timer_mode":"stopwatch","timer_label":"Quest",
       "pools":{"Quest":["Bring something yellow.","Bring something that smells nice.","Bring the roundest object you can find.","Bring the most boring object in the room.","Bring something that starts with the letter B.","Bring the smallest useful thing you can find."]},
       "rules":["Stay inside the venue. WALK, don't run.","Take only what is yours or what you have permission to take.","First back with a valid item wins; the Royal Judge decides what is valid."],
       "decide":"First back with a valid item."}$j$::jsonb),
  ('real_photo_quest', 'real_life', 'Photo Quest',
   'The most majestic photo wins.', 'reallife',
   $j${"icon":"📸","props":"Your phone's camera","timer_s":120,"timer_mode":"shared","timer_label":"Shoot",
       "pools":{"Quest":["Take the most majestic photo with a plant.","Take a heroic portrait of a chair.","Take the most dramatic photo of a coaster.","Take a royal portrait of a glass.","Take a photo that looks like a movie poster, using only objects."]},
       "rules":["2 minutes. Photograph objects, plants or yourself only: no photos of other people without their OK.","Stay inside the venue.","The photos stay on your phone; show them to the Royal Judge."],
       "decide":"The most majestic photo."}$j$::jsonb),
  ('real_mystery', 'real_life', 'Mystery Trial',
   'The task is hidden until BOTH duelists press READY.', 'reallife',
   $j${"icon":"🎲","mystery":true,"props":"???","rules":["Nobody knows the task.","Both duelists press READY to reveal it.","Then the Royal Judge watches and decides."],"decide":"???"}$j$::jsonb)
on conflict (id) do update set
  school = excluded.school, title = excluded.title, description = excluded.description,
  resolution = excluded.resolution, public_config = excluded.public_config, is_active = true;

-- =================================================================
-- SECTION 6 — grants
-- =================================================================
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('_reallife_picks', '_prepare_reallife_trial', '_pick_catalog_trial', '_start_throne_trial')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

revoke all on function public.ready_throne_trial(uuid) from public, anon;
revoke all on function public.judge_throne_verdict(uuid, text) from public, anon;
grant execute on function public.ready_throne_trial(uuid) to authenticated;
grant execute on function public.judge_throne_verdict(uuid, text) to authenticated;

-- =========== 0044_dynasty_outcomes.sql ===========
-- =================================================================
-- OFFICE LORE — THE OUTCOME OF A THRONE CHALLENGE (Dynasty history)
-- =================================================================
-- Makes the end of a Throne Challenge fully recorded in the Dynasty:
--
--   CHALLENGER WINS  the old reign is closed (ended_at, ending_beer_xp,
--                    dethroned_by, loadout snapshot, and now also WHICH
--                    challenge ended it), a new reign is opened for the
--                    challenger (linked to its predecessor and to the winning
--                    challenge). The challenger's "throne captures" go up
--                    because a capture IS a reign. Beer XP is never touched:
--                    starting_beer_xp / ending_beer_xp are only snapshots.
--   DEFENDER WINS    abt_reigns.successful_defenses +1 on the reign that was
--                    defended (a stored counter, so it can become an
--                    achievement / statistic later without recomputing).
--
-- New abt_reigns columns (all additive, history is preserved):
--   predecessor_reign_id   the reign this one followed
--   won_challenge_id       the Throne Challenge that started this reign
--   ended_by_challenge_id  the Throne Challenge that ended this reign
--   successful_defenses    challenges successfully defended during this reign
--
-- Challenge wins / losses are derived from throne_challenges (completed rows),
-- not stored twice.
--
-- THE FALLEN ABT is derived (the lord whose reign ended most recently, for a
-- limited window, see the client). Nothing is deleted: cosmetics, loadouts and
-- Beer XP stay exactly as they were.
--
-- HIGH BREWMASTER is independent of the throne: whoever has the most Beer XP
-- (user_xp_totals) is High Brewmaster whether or not they sit on the throne,
-- so a dethroned lord with the most Beer XP simply stays High Brewmaster.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0043.
-- =================================================================

-- =================================================================
-- SECTION 1 — columns + backfill
-- =================================================================
alter table public.abt_reigns
  add column if not exists predecessor_reign_id uuid references public.abt_reigns(id),
  add column if not exists won_challenge_id uuid references public.throne_challenges(id),
  add column if not exists ended_by_challenge_id uuid references public.throne_challenges(id),
  add column if not exists successful_defenses int not null default 0;

-- predecessor of every existing reign = the reign before it
update public.abt_reigns r
  set predecessor_reign_id = p.prev_id
  from (select id, lag(id) over (order by started_at) as prev_id from public.abt_reigns) p
  where p.id = r.id and r.predecessor_reign_id is null and p.prev_id is not null;

-- successful defenses so far = completed challenges the sitting lord won
update public.abt_reigns r
  set successful_defenses = d.n
  from (select reign_id, count(*) as n from public.throne_challenges
        where status = 'completed' and winner_user_id = defender_user_id group by reign_id) d
  where d.reign_id = r.id;

-- link reigns to the challenge that ended / started them
update public.abt_reigns r
  set ended_by_challenge_id = c.id
  from public.throne_challenges c
  where c.reign_id = r.id and c.status = 'completed' and c.winner_user_id = c.challenger_user_id
    and r.ended_at is not null and r.dethroned_by_user_id = c.challenger_user_id and r.ended_by_challenge_id is null;
update public.abt_reigns r
  set won_challenge_id = x.ended_by_challenge_id
  from public.abt_reigns x
  where r.predecessor_reign_id = x.id and x.ended_by_challenge_id is not null and r.won_challenge_id is null;

-- =================================================================
-- SECTION 2 — the outcome (replaces 0038's)
-- =================================================================
create or replace function public._complete_throne_challenge(p_challenge_id uuid, p_winner uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_reign record;
  v_def_total int;
  v_chal_total int;
  v_snapshot jsonb;
  v_new_reign uuid;
begin
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.status in ('completed', 'cancelled') then
    return; -- idempotent: an outcome is registered exactly once
  end if;

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;

  if p_winner = c.challenger_user_id then
    if v_reign is null or v_reign.id <> c.reign_id then
      -- the challenged reign is no longer the open one: nothing to take
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;
      return;
    end if;

    -- Beer XP is only READ here, as a snapshot for the history. It is never changed.
    select coalesce(beer_xp, 0) into v_def_total from public.user_xp_totals where user_id = c.defender_user_id;
    select coalesce(beer_xp, 0) into v_chal_total from public.user_xp_totals where user_id = c.challenger_user_id;
    select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = c.defender_user_id;

    -- close the old reign
    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_def_total, dethroned_by_user_id = c.challenger_user_id,
          ending_loadout_snapshot = v_snapshot, ended_by_challenge_id = c.id
      where id = v_reign.id;

    -- open the new one: the challenger is the Abt Lord (this is a throne capture)
    insert into public.abt_reigns (user_id, started_at, starting_beer_xp, predecessor_reign_id, won_challenge_id)
    values (c.challenger_user_id, now(), v_chal_total, v_reign.id, c.id)
    returning id into v_new_reign;

  elsif p_winner = c.defender_user_id then
    -- the throne stands: register the successful defense on the defended reign
    update public.abt_reigns set successful_defenses = successful_defenses + 1
      where id = c.reign_id and ended_at is null;
  end if;

  update public.throne_challenges
    set status = 'completed', winner_user_id = p_winner, completed_at = now(), resolved_at = now(),
        awaiting_pick_by = null, step_deadline = null
    where id = c.id;

  perform public._sync_absolute_abt();
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public._complete_throne_challenge(uuid, uuid) from public, anon, authenticated;

-- =========== 0045_beer_xp_milestones.sql ===========
-- =================================================================
-- OFFICE LORE — 🍺 BEER XP MILESTONES (a progression apart from the throne)
-- =================================================================
-- Beer XP stays valuable whoever sits on the Abt throne. Reaching Beer XP
-- milestones permanently unlocks cosmetics, exactly like the Abt Lord's
-- day milestones do, but based on the user's total Beer XP:
--
--    250  Brewer's Tankard            1500  St. Bernard Companion
--    500  Hop Crown                   2000  High Brewmaster Armor
--    750  Brewmaster Apron            3000  Legendary Brewery Set (3 pieces)
--   1000  Brewer's Shield
--
-- CONFIGURABLE: the thresholds live in the table beer_xp_milestones (one row
-- per milestone: xp_required, title, flavor_text). Rewards are
-- abt_cosmetic_items rows with unlock_type = 'beer_xp' and milestone_xp = the
-- threshold, so a milestone can grant one item or several (the Legendary
-- Brewery Set grants three). Change or add milestones with plain SQL; no code
-- change. Every reward below is a PLACEHOLDER (flat art drawn by the client)
-- until real illustrations exist; swap the art by changing the asset_key.
--
-- PERMANENT: a reward is a row in user_abt_cosmetics. Nothing ever deletes or
-- re-evaluates it, so losing the #1 Beer XP spot (or the throne) never takes a
-- milestone cosmetic away.
--
-- LAZY (no pg_cron): sync_beer_xp_milestones() grants everything the caller's
-- current Beer XP has reached and returns only what is NEW, so the client can
-- celebrate it exactly once. Beer XP is read from user_xp_totals, the same
-- number the whole app shows.
--
-- The temporary 🍺 HIGH BREWMASTER title for the current #1 is derived live in
-- the client (it needs no storage); this migration only adds the permanent part.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0044.
-- =================================================================

-- =================================================================
-- SECTION 1 — config table
-- =================================================================
create table if not exists public.beer_xp_milestones (
  xp_required int primary key check (xp_required > 0),
  title text not null,
  flavor_text text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.beer_xp_milestones enable row level security;
drop policy if exists "Beer XP milestones: read" on public.beer_xp_milestones;
create policy "Beer XP milestones: read" on public.beer_xp_milestones for select to authenticated
  using (public.is_app_member('officelore'));

-- =================================================================
-- SECTION 2 — cosmetics: a new unlock type
-- =================================================================
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.abt_cosmetic_items'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%unlock_type%';
  if v_name is not null then execute format('alter table public.abt_cosmetic_items drop constraint %I', v_name); end if;

  select conname into v_name from pg_constraint
    where conrelid = 'public.user_abt_cosmetics'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%unlock_source%';
  if v_name is not null then execute format('alter table public.user_abt_cosmetics drop constraint %I', v_name); end if;
end $$;

alter table public.abt_cosmetic_items add constraint abt_cosmetic_items_unlock_type_check
  check (unlock_type in ('standard', 'daily_pick', 'milestone', 'beer_xp'));
alter table public.user_abt_cosmetics add constraint user_abt_cosmetics_unlock_source_check
  check (unlock_source in ('daily_pick', 'milestone', 'beer_xp'));
alter table public.abt_cosmetic_items add column if not exists milestone_xp int references public.beer_xp_milestones(xp_required);

-- =================================================================
-- SECTION 3 — the milestones and their (placeholder) rewards
-- =================================================================
insert into public.beer_xp_milestones (xp_required, title, flavor_text) values
  (250, 'Brewer''s Tankard', 'A sturdy tankard, dented by honest work.'),
  (500, 'Hop Crown', 'Green cones, golden pride.'),
  (750, 'Brewmaster Apron', 'Splashes of three hundred batches. Wear them proudly.'),
  (1000, 'Brewer''s Shield', 'Guards against warm beer and bad opinions.'),
  (1500, 'St. Bernard Companion', 'Always carries a small barrel. Never lost, never thirsty.'),
  (2000, 'High Brewmaster Armor', 'Forged in the tuns of a legendary brewery.'),
  (3000, 'Legendary Brewery Set', 'A crown, a scepter and a banner. The brewery bows to you.')
on conflict (xp_required) do update set title = excluded.title, flavor_text = excluded.flavor_text;

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_xp, asset_key, render_tint)
select v.name, v.flavor_text, v.category, v.rarity, 'beer_xp', v.xp, v.asset_key, v.tint
from (values
  ('Brewer''s Tankard', 'A sturdy tankard, dented by honest work. (placeholder art)', 'accessory', 'common', 250, 'accessory.tankard', '#d9a441'),
  ('Hop Crown', 'Green cones, golden pride. (placeholder art)', 'headwear', 'rare', 500, 'headwear.hop_crown', null),
  ('Brewmaster Apron', 'Splashes of three hundred batches. (placeholder art)', 'armor', 'rare', 750, 'armor.brewmaster_apron', null),
  ('Brewer''s Shield', 'Guards against warm beer and bad opinions. (placeholder art)', 'accessory', 'epic', 1000, 'accessory.shield', '#c98a1f'),
  ('St. Bernard', 'Always carries a small barrel. (placeholder art)', 'companion', 'epic', 1500, 'companion.st_bernard', null),
  ('High Brewmaster Armor', 'Forged in the tuns of a legendary brewery. (placeholder art)', 'armor', 'legendary', 2000, 'armor.high_brewmaster_armor', null),
  ('Legendary Brewery Crown', 'Part of the Legendary Brewery Set. (placeholder art)', 'headwear', 'legendary', 3000, 'headwear.brewery_set_crown', null),
  ('Legendary Brewery Scepter', 'Part of the Legendary Brewery Set. (placeholder art)', 'weapon', 'legendary', 3000, 'weapon.brewery_set_scepter', null),
  ('Legendary Brewery Banner', 'Part of the Legendary Brewery Set. (placeholder art)', 'accessory', 'legendary', 3000, 'accessory.brewery_set_banner', null)
) as v(name, flavor_text, category, rarity, xp, asset_key, tint)
where not exists (
  select 1 from public.abt_cosmetic_items i where i.unlock_type = 'beer_xp' and i.asset_key = v.asset_key and i.milestone_xp = v.xp
);

-- =================================================================
-- SECTION 4 — grant (lazy, idempotent, permanent)
-- =================================================================
-- Returns the milestones that became NEW rewards during this call.
create or replace function public.sync_beer_xp_milestones()
returns table (xp_required int, title text, flavor_text text, item_ids uuid[]) as $$
declare
  v_xp int;
  m public.beer_xp_milestones;
  v_ids uuid[];
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  -- a quick double fire (token refresh, tab refocus) must not race itself
  perform pg_advisory_xact_lock(hashtext('sync_beer_xp_milestones:' || auth.uid()::text));

  select coalesce(beer_xp, 0) into v_xp from public.user_xp_totals where user_id = auth.uid();
  v_xp := coalesce(v_xp, 0);

  for m in
    select * from public.beer_xp_milestones b where b.is_active and b.xp_required <= v_xp order by b.xp_required
  loop
    with ins as (
      insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source)
      select auth.uid(), i.id, 'beer_xp'
      from public.abt_cosmetic_items i
      where i.unlock_type = 'beer_xp' and i.milestone_xp = m.xp_required and i.is_active
      on conflict (user_id, cosmetic_item_id) do nothing
      returning cosmetic_item_id
    )
    select array_agg(cosmetic_item_id) into v_ids from ins;

    if v_ids is not null then
      xp_required := m.xp_required; title := m.title; flavor_text := m.flavor_text; item_ids := v_ids;
      return next;
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.sync_beer_xp_milestones() from public, anon;
grant execute on function public.sync_beer_xp_milestones() to authenticated;
