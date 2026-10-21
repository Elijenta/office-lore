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
