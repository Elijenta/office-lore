-- =================================================================
-- OFFICE LORE — THE ABT DYNASTY (required)
-- =================================================================
-- Persisted reign history for "The Abt Lord" (highest total Beer XP).
-- Additive-only migration: adds one new table + one new trigger on the
-- existing xp_events table. Does not touch, recalculate, or reset any
-- existing data (profiles, nicknames, quotes, counters, beers,
-- xp_events, or any other table are all left exactly as they are).
--
-- Run this once in the Supabase SQL Editor, after 0001/0002/0003.
-- =================================================================

-- =================================================================
-- SECTION 1 — abt_reigns
-- =================================================================
create table public.abt_reigns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  starting_beer_xp int not null,
  ending_beer_xp int,
  dethroned_by_user_id uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

-- hard guarantee: at most one active (ended_at is null) reign can ever
-- exist, enforced by Postgres itself, not just application logic
create unique index one_active_abt_reign on public.abt_reigns ((1)) where ended_at is null;


-- =================================================================
-- SECTION 2 — automatic throne transition
-- =================================================================
-- Fires after every new BEER xp_events row (i.e. every time someone's
-- Beer XP goes up, via the existing perfect-pour/rating/consumption/
-- adoption triggers — none of those are modified). Never fires from
-- client code, and the client has no insert/update/delete access to
-- this table (see RLS below) — the throne can only ever change here.
create or replace function public.check_abt_throne()
returns trigger as $$
declare
  v_leader_id uuid;
  v_leader_xp int;
  v_current record;
  v_current_lord_xp int;
begin
  -- serialize concurrent evaluations (3-user app, negligible cost) so
  -- two near-simultaneous XP-earning actions can never both decide to
  -- crown someone at the same time and race each other
  perform pg_advisory_xact_lock(918273645);

  select user_id, beer_xp into v_leader_id, v_leader_xp
  from public.user_xp_totals
  order by beer_xp desc, user_id
  limit 1;

  if v_leader_xp is null or v_leader_xp <= 0 then
    return new; -- nobody has any Beer XP yet
  end if;

  select * into v_current from public.abt_reigns where ended_at is null limit 1;

  if v_current is null then
    -- first-ever coronation, nothing to dethrone
    insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
    values (v_leader_id, now(), v_leader_xp);
    return new;
  end if;

  if v_current.user_id = v_leader_id then
    return new; -- reigning lord is still in the lead, nothing to do
  end if;

  select beer_xp into v_current_lord_xp
  from public.user_xp_totals where user_id = v_current.user_id;

  -- strict greater-than: an equal score never dethrones (ties keep
  -- the current lord on the throne until someone truly overtakes them)
  if v_leader_xp > coalesce(v_current_lord_xp, 0) then
    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_current_lord_xp, dethroned_by_user_id = v_leader_id
      where id = v_current.id;

    insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
    values (v_leader_id, now(), v_leader_xp);
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_check_abt_throne
  after insert on public.xp_events
  for each row
  when (new.xp_type = 'beer')
  execute procedure public.check_abt_throne();


-- =================================================================
-- SECTION 3 — RLS
-- =================================================================
-- Same pattern as xp_events: readable by any authenticated user,
-- writable only by the SECURITY DEFINER trigger above — nobody can
-- crown themselves or rewrite history from the app.
alter table public.abt_reigns enable row level security;

create policy "Abt reigns: authenticated may read"
  on public.abt_reigns for select to authenticated using (true);


-- =================================================================
-- SECTION 4 — REALTIME
-- =================================================================
alter publication supabase_realtime add table public.abt_reigns;
