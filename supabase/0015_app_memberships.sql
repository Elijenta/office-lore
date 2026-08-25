-- =================================================================
-- OFFICE LORE — APP MEMBERSHIPS (strict per-app user isolation)
-- =================================================================
-- Office Lore shares one Supabase project (and therefore one
-- auth.users table) with an unrelated second app, QuestNest. Until
-- now, handle_new_user() fired on EVERY auth.users insert project-
-- wide, so anyone who signed up through QuestNest's own signup form
-- (or any test account, for any reason) automatically got an Office
-- Lore `profiles` row and, since RLS was a blanket `using (true)` on
-- nearly every table, full read access to all Office Lore data.
--
-- This migration introduces `app_memberships` as the single source of
-- truth for "is this auth user actually part of Office Lore," and
-- adds an `is_app_member('officelore')` gate to every table's RLS,
-- the two SECURITY DEFINER RPCs that bypass table RLS entirely, and
-- the two views queried directly by the client. `profiles` additionally
-- gets a row-level filter (it's the one general-purpose table another
-- app's signup could have a row in) on top of the caller-is-member gate.
--
-- No users are deleted. Existing non-member profile rows are simply
-- never returned to an officelore member anymore.
-- =================================================================

-- ---- 1. app_memberships ----
create table public.app_memberships (
  id uuid primary key default gen_random_uuid(),
  app_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (app_id, user_id)
);

-- security definer is required, not optional: without it, this
-- function can't be safely called from inside app_memberships' own
-- RLS policy below without infinite recursion.
create or replace function public.is_app_member(p_app_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.app_memberships
    where user_id = auth.uid() and app_id = p_app_id and is_active = true
  );
$$;

grant execute on function public.is_app_member(text) to authenticated;

alter table public.app_memberships enable row level security;

-- own row always readable (needed for the login-gate check even for a
-- non-member), PLUS any row for an app you yourself belong to (needed
-- so members can see each other -- without this, profiles' row filter
-- below would silently return zero rows for everyone but the caller).
create policy "App memberships: own row, or any row for an app you belong to"
  on public.app_memberships for select
  to authenticated
  using (
    user_id = auth.uid()
    or public.is_app_member(app_id)
  );
-- no insert/update/delete policy: memberships are granted by an admin
-- running SQL directly in the Supabase dashboard.

-- ---- 2. backfill the 3 real Office Lore users (ids confirmed live) ----
insert into public.app_memberships (app_id, user_id) values
  ('officelore', 'b064ee54-08c8-4d80-863a-b75d6a46b523'), -- Elien
  ('officelore', '3a5ad158-62db-4852-90b4-e1034adf894d'), -- Nicky
  ('officelore', '809714bc-e4c4-4628-b624-94a2803d16de')  -- Atti
on conflict (app_id, user_id) do nothing;

-- =================================================================
-- SECTION 3 — profiles: row-level filter, not just a caller-is-member gate
-- =================================================================
drop policy if exists "Profiles: any authenticated user can read all profiles" on public.profiles;
create policy "Profiles: officelore members may read officelore members' profiles"
  on public.profiles for select
  to authenticated
  using (
    public.is_app_member('officelore')
    and exists (
      select 1 from public.app_memberships m2
      where m2.user_id = profiles.id and m2.app_id = 'officelore' and m2.is_active = true
    )
  );

drop policy if exists "Profiles: only yourself may edit your own profile" on public.profiles;
create policy "Profiles: only yourself may edit your own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id and public.is_app_member('officelore'))
  with check (auth.uid() = id and public.is_app_member('officelore'));

-- =================================================================
-- SECTION 4 — every other Office Lore table: AND is_app_member('officelore')
-- into every existing using/with check clause, action-for-action,
-- using each table's CURRENT effective policy (several were replaced
-- by later migrations -- 0005/0008 -- not the 0001 originals)
-- =================================================================

-- ---- nicknames ----
drop policy if exists "Nicknames: authenticated may read" on public.nicknames;
create policy "Nicknames: authenticated may read" on public.nicknames for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Nicknames: authenticated may insert as themselves" on public.nicknames;
create policy "Nicknames: authenticated may insert as themselves" on public.nicknames for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Nicknames: only creator may update" on public.nicknames;
create policy "Nicknames: only creator may update" on public.nicknames for update to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'))
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Nicknames: only creator may delete" on public.nicknames;
create policy "Nicknames: only creator may delete" on public.nicknames for delete to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- nickname_events ----
drop policy if exists "Nickname events: authenticated may read" on public.nickname_events;
create policy "Nickname events: authenticated may read" on public.nickname_events for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Nickname events: anyone may log a usage moment as themselves" on public.nickname_events;
create policy "Nickname events: anyone may log a usage moment as themselves" on public.nickname_events for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Nickname events: only own entry may be deleted" on public.nickname_events;
create policy "Nickname events: only own entry may be deleted" on public.nickname_events for delete to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- nickname_votes ----
drop policy if exists "Nickname votes: authenticated may read" on public.nickname_votes;
create policy "Nickname votes: authenticated may read" on public.nickname_votes for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Nickname votes: only own vote may be added" on public.nickname_votes;
create policy "Nickname votes: only own vote may be added" on public.nickname_votes for insert to authenticated
  with check (user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Nickname votes: only own vote may be retracted" on public.nickname_votes;
create policy "Nickname votes: only own vote may be retracted" on public.nickname_votes for delete to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- quotes ----
drop policy if exists "Quotes: authenticated may read" on public.quotes;
create policy "Quotes: authenticated may read" on public.quotes for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Quotes: authenticated may insert as themselves" on public.quotes;
create policy "Quotes: authenticated may insert as themselves" on public.quotes for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Quotes: only creator may update" on public.quotes;
create policy "Quotes: only creator may update" on public.quotes for update to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'))
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Quotes: only creator may delete" on public.quotes;
create policy "Quotes: only creator may delete" on public.quotes for delete to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- quote_reactions ----
drop policy if exists "Quote reactions: authenticated may read" on public.quote_reactions;
create policy "Quote reactions: authenticated may read" on public.quote_reactions for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Quote reactions: only own reaction may be added" on public.quote_reactions;
create policy "Quote reactions: only own reaction may be added" on public.quote_reactions for insert to authenticated
  with check (user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Quote reactions: only own reaction may be retracted" on public.quote_reactions;
create policy "Quote reactions: only own reaction may be retracted" on public.quote_reactions for delete to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- anecdotes ----
drop policy if exists "Anecdotes: authenticated may read" on public.anecdotes;
create policy "Anecdotes: authenticated may read" on public.anecdotes for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Anecdotes: authenticated may insert as themselves" on public.anecdotes;
create policy "Anecdotes: authenticated may insert as themselves" on public.anecdotes for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Anecdotes: only creator may update" on public.anecdotes;
create policy "Anecdotes: only creator may update" on public.anecdotes for update to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'))
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Anecdotes: only creator may delete" on public.anecdotes;
create policy "Anecdotes: only creator may delete" on public.anecdotes for delete to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- anecdote_reactions ----
drop policy if exists "Anecdote reactions: authenticated may read" on public.anecdote_reactions;
create policy "Anecdote reactions: authenticated may read" on public.anecdote_reactions for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Anecdote reactions: only own reaction may be added" on public.anecdote_reactions;
create policy "Anecdote reactions: only own reaction may be added" on public.anecdote_reactions for insert to authenticated
  with check (user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Anecdote reactions: only own reaction may be retracted" on public.anecdote_reactions;
create policy "Anecdote reactions: only own reaction may be retracted" on public.anecdote_reactions for delete to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- counters ----
drop policy if exists "Counters: authenticated may read" on public.counters;
create policy "Counters: authenticated may read" on public.counters for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Counters: authenticated may insert as themselves" on public.counters;
create policy "Counters: authenticated may insert as themselves" on public.counters for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Counters: only creator may update" on public.counters;
create policy "Counters: only creator may update" on public.counters for update to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'))
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Counters: only creator may delete" on public.counters;
create policy "Counters: only creator may delete" on public.counters for delete to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- counter_events (delete is the 0008 version, not 0001) ----
drop policy if exists "Counter events: authenticated may read" on public.counter_events;
create policy "Counter events: authenticated may read" on public.counter_events for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Counter events: anyone may register +1/-1 as themselves" on public.counter_events;
create policy "Counter events: anyone may register +1/-1 as themselves" on public.counter_events for insert to authenticated
  with check (registered_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Counter events: authenticated may delete" on public.counter_events;
create policy "Counter events: authenticated may delete" on public.counter_events for delete to authenticated
  using (public.is_app_member('officelore'));

-- ---- beers ----
drop policy if exists "Beers: authenticated may read" on public.beers;
create policy "Beers: authenticated may read" on public.beers for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Beers: authenticated may insert as themselves" on public.beers;
create policy "Beers: authenticated may insert as themselves" on public.beers for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Beers: only creator may update" on public.beers;
create policy "Beers: only creator may update" on public.beers for update to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'))
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Beers: only creator may delete" on public.beers;
create policy "Beers: only creator may delete" on public.beers for delete to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- beer_sessions (update/delete are the 0005/0008 versions) ----
drop policy if exists "Beer sessions: authenticated may read" on public.beer_sessions;
create policy "Beer sessions: authenticated may read" on public.beer_sessions for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Beer sessions: authenticated may insert as themselves" on public.beer_sessions;
create policy "Beer sessions: authenticated may insert as themselves" on public.beer_sessions for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Beer sessions: authenticated may update" on public.beer_sessions;
create policy "Beer sessions: authenticated may update" on public.beer_sessions for update to authenticated
  using (public.is_app_member('officelore')) with check (public.is_app_member('officelore'));
drop policy if exists "Beer sessions: authenticated may delete" on public.beer_sessions;
create policy "Beer sessions: authenticated may delete" on public.beer_sessions for delete to authenticated
  using (public.is_app_member('officelore'));

-- ---- beer_session_participants (insert/delete are the 0005 versions) ----
drop policy if exists "Session participants: authenticated may read" on public.beer_session_participants;
create policy "Session participants: authenticated may read" on public.beer_session_participants for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Session participants: authenticated may add" on public.beer_session_participants;
create policy "Session participants: authenticated may add" on public.beer_session_participants for insert to authenticated
  with check (public.is_app_member('officelore'));
drop policy if exists "Session participants: authenticated may remove" on public.beer_session_participants;
create policy "Session participants: authenticated may remove" on public.beer_session_participants for delete to authenticated
  using (public.is_app_member('officelore'));

-- ---- beer_ratings (insert/update/delete are the 0005 versions) ----
drop policy if exists "Beer ratings: authenticated may read" on public.beer_ratings;
create policy "Beer ratings: authenticated may read" on public.beer_ratings for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Beer ratings: authenticated may add" on public.beer_ratings;
create policy "Beer ratings: authenticated may add" on public.beer_ratings for insert to authenticated
  with check (public.is_app_member('officelore'));
drop policy if exists "Beer ratings: authenticated may update" on public.beer_ratings;
create policy "Beer ratings: authenticated may update" on public.beer_ratings for update to authenticated
  using (public.is_app_member('officelore')) with check (public.is_app_member('officelore'));
drop policy if exists "Beer ratings: authenticated may delete" on public.beer_ratings;
create policy "Beer ratings: authenticated may delete" on public.beer_ratings for delete to authenticated
  using (public.is_app_member('officelore'));

-- ---- beer_consumption (insert/update/delete are the 0005 versions) ----
drop policy if exists "Beer consumption: authenticated may read" on public.beer_consumption;
create policy "Beer consumption: authenticated may read" on public.beer_consumption for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Beer consumption: authenticated may add" on public.beer_consumption;
create policy "Beer consumption: authenticated may add" on public.beer_consumption for insert to authenticated
  with check (public.is_app_member('officelore'));
drop policy if exists "Beer consumption: authenticated may update" on public.beer_consumption;
create policy "Beer consumption: authenticated may update" on public.beer_consumption for update to authenticated
  using (public.is_app_member('officelore')) with check (public.is_app_member('officelore'));
drop policy if exists "Beer consumption: authenticated may delete" on public.beer_consumption;
create policy "Beer consumption: authenticated may delete" on public.beer_consumption for delete to authenticated
  using (public.is_app_member('officelore'));

-- ---- perfect_pours (delete is the 0008 version) ----
drop policy if exists "Perfect pours: authenticated may read" on public.perfect_pours;
create policy "Perfect pours: authenticated may read" on public.perfect_pours for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Perfect pours: only own vote may be cast" on public.perfect_pours;
create policy "Perfect pours: only own vote may be cast" on public.perfect_pours for insert to authenticated
  with check (given_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Perfect pours: authenticated may delete" on public.perfect_pours;
create policy "Perfect pours: authenticated may delete" on public.perfect_pours for delete to authenticated
  using (public.is_app_member('officelore'));

-- ---- xp_events ----
drop policy if exists "XP events: authenticated may read" on public.xp_events;
create policy "XP events: authenticated may read" on public.xp_events for select to authenticated
  using (public.is_app_member('officelore'));

-- ---- abt_reigns ----
drop policy if exists "Abt reigns: authenticated may read" on public.abt_reigns;
create policy "Abt reigns: authenticated may read" on public.abt_reigns for select to authenticated
  using (public.is_app_member('officelore'));

-- ---- poems ----
drop policy if exists "Poems: read" on public.poems;
create policy "Poems: read" on public.poems for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Poems: insert own" on public.poems;
create policy "Poems: insert own" on public.poems for insert to authenticated
  with check (author_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Poems: update own" on public.poems;
create policy "Poems: update own" on public.poems for update to authenticated
  using (author_user_id = auth.uid() and public.is_app_member('officelore'))
  with check (author_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Poems: delete own" on public.poems;
create policy "Poems: delete own" on public.poems for delete to authenticated
  using (author_user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- poem_reactions ----
drop policy if exists "Poem reactions: read" on public.poem_reactions;
create policy "Poem reactions: read" on public.poem_reactions for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Poem reactions: insert own, not own poem" on public.poem_reactions;
create policy "Poem reactions: insert own, not own poem" on public.poem_reactions for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.is_app_member('officelore')
    and not exists (select 1 from public.poems p where p.id = poem_id and p.author_user_id = auth.uid())
  );
drop policy if exists "Poem reactions: delete own" on public.poem_reactions;
create policy "Poem reactions: delete own" on public.poem_reactions for delete to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- poet_laureate_reigns ----
drop policy if exists "Poet laureate reigns: read" on public.poet_laureate_reigns;
create policy "Poet laureate reigns: read" on public.poet_laureate_reigns for select to authenticated
  using (public.is_app_member('officelore'));

-- ---- poetry_prompts ----
drop policy if exists "Poetry prompts: read" on public.poetry_prompts;
create policy "Poetry prompts: read" on public.poetry_prompts for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Poetry prompts: insert own" on public.poetry_prompts;
create policy "Poetry prompts: insert own" on public.poetry_prompts for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Poetry prompts: update own" on public.poetry_prompts;
create policy "Poetry prompts: update own" on public.poetry_prompts for update to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Poetry prompts: delete own" on public.poetry_prompts;
create policy "Poetry prompts: delete own" on public.poetry_prompts for delete to authenticated
  using (created_by_user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- nickname_battles ----
drop policy if exists "Nickname battles: read" on public.nickname_battles;
create policy "Nickname battles: read" on public.nickname_battles for select to authenticated
  using (public.is_app_member('officelore'));
drop policy if exists "Nickname battles: authenticated may create" on public.nickname_battles;
create policy "Nickname battles: authenticated may create" on public.nickname_battles for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
drop policy if exists "Nickname battles: authenticated may update" on public.nickname_battles;
create policy "Nickname battles: authenticated may update" on public.nickname_battles for update to authenticated
  using (public.is_app_member('officelore')) with check (public.is_app_member('officelore'));
drop policy if exists "Nickname battles: authenticated may delete" on public.nickname_battles;
create policy "Nickname battles: authenticated may delete" on public.nickname_battles for delete to authenticated
  using (public.is_app_member('officelore'));

-- ---- nickname_battle_votes ----
drop policy if exists "Battle votes: read own always, all once revealed" on public.nickname_battle_votes;
create policy "Battle votes: read own always, all once revealed" on public.nickname_battle_votes for select to authenticated
  using (
    public.is_app_member('officelore')
    and (
      user_id = auth.uid()
      or exists (select 1 from public.nickname_battles b where b.id = battle_id and b.status <> 'open')
    )
  );
drop policy if exists "Battle votes: insert own" on public.nickname_battle_votes;
create policy "Battle votes: insert own" on public.nickname_battle_votes for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.is_app_member('officelore')
    and exists (select 1 from public.nickname_battles b where b.id = battle_id and b.status = 'open')
  );
drop policy if exists "Battle votes: update own while open" on public.nickname_battle_votes;
create policy "Battle votes: update own while open" on public.nickname_battle_votes for update to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'))
  with check (
    user_id = auth.uid()
    and public.is_app_member('officelore')
    and exists (select 1 from public.nickname_battles b where b.id = battle_id and b.status = 'open')
  );
drop policy if exists "Battle votes: delete own" on public.nickname_battle_votes;
create policy "Battle votes: delete own" on public.nickname_battle_votes for delete to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

-- ---- daily_poetry_challenges ----
drop policy if exists "Daily poetry challenges: read" on public.daily_poetry_challenges;
create policy "Daily poetry challenges: read" on public.daily_poetry_challenges for select to authenticated
  using (public.is_app_member('officelore'));

-- =================================================================
-- SECTION 5 — harden the two SECURITY DEFINER RPCs that bypass RLS
-- entirely (they run as the table owner regardless of policy changes)
-- =================================================================
create or replace function public.update_nickname_collaborative_fields(
  p_nickname_id uuid,
  p_description text,
  p_anecdote text
)
returns void as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  update public.nicknames
    set description = p_description, anecdote = p_anecdote
    where id = p_nickname_id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.close_nickname_battle_early(p_battle_id uuid)
returns void as $$
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;
  perform public.resolve_nickname_battle_outcome(p_battle_id, false);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — nickname_battle_vote_counts: this view is queried
-- directly by index.html and, being owner-run, bypasses RLS entirely --
-- add the gate explicitly in the view body (not security_invoker,
-- which would break the deliberate pre-reveal vote-count bypass the
-- view's own 0011 comment documents)
-- =================================================================
create or replace view public.nickname_battle_vote_counts as
select
  v.battle_id,
  count(*) as total_votes,
  count(*) filter (where b.status <> 'open' and v.voted_side = 'a') as votes_a,
  count(*) filter (where b.status <> 'open' and v.voted_side = 'b') as votes_b
from public.nickname_battle_votes v
join public.nickname_battles b on b.id = v.battle_id
where public.is_app_member('officelore')
group by v.battle_id;

-- =================================================================
-- SECTION 7 — user_xp_totals: scopes check_abt_throne() /
-- check_poet_laureate_throne() automatically (both SECURITY DEFINER,
-- both only ever query this view -- no changes needed to them)
-- =================================================================
create or replace view public.user_xp_totals as
select
  p.id as user_id,
  coalesce(sum(x.points) filter (where x.xp_type = 'lore'), 0) as lore_xp,
  coalesce(sum(x.points) filter (where x.xp_type = 'beer'), 0) as beer_xp,
  coalesce(sum(x.points) filter (where x.xp_type = 'poetry'), 0) as poetry_xp
from public.profiles p
join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active = true
left join public.xp_events x on x.user_id = p.id
group by p.id;

-- =================================================================
-- SECTION 8 — handle_new_user(): the actual source of the leak.
-- Becomes conditional on signup metadata: only a signup that
-- explicitly identifies itself as an Office Lore signup gets a
-- profiles row. QuestNest signups (or anything else in this shared
-- auth.users) never pass this metadata, so they're excluded at the
-- source instead of merely hidden downstream.
-- =================================================================
create or replace function public.handle_new_user()
returns trigger as $$
begin
  if new.raw_user_meta_data->>'app' = 'officelore' then
    insert into public.profiles (id, display_name, first_name)
    values (new.id, split_part(new.email, '@', 1), split_part(new.email, '@', 1));
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
-- trigger on_auth_user_created (0001) already points at this function
-- by name -- no change needed there.

-- =================================================================
-- SECTION 9 — get_or_create_daily_challenge(): replace the ad hoc
-- "3 oldest profiles" heuristic (a workaround from a prior round for
-- exactly this problem) with a real app_memberships join.
-- =================================================================
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
  -- "user" subjects komen uitsluitend uit officelore app_memberships,
  -- niet uit "oudste 3 profiles" -- die heuristiek liet QA-/QuestNest-
  -- accounts meedoen zodra ze toevallig oud genoeg waren.
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

  v_category := (array[
    'romantic', 'tragic', 'office_nonsense', 'beer_inspired', 'absolute_nonsense',
    'dramatic', 'abt_dynasty', 'deep_thoughts', 'wholesome'
  ])[1 + (v_category_seed % 9)];

  v_template := case v_category
    when 'romantic' then (array[
      'Write a romantic poem about %s as if they were the love of your life.',
      'Write a love poem describing an unexpected office encounter with %s.',
      'Write a sonnet about someone hopelessly falling for %s.'
    ])[1 + (v_template_seed % 3)]
    when 'tragic' then (array[
      'Write a tragic poem about the day %s lost everything.',
      'Write a tragic poem mourning %s''s greatest defeat.',
      'Write a eulogy-style poem for %s''s fallen dignity.'
    ])[1 + (v_template_seed % 3)]
    when 'office_nonsense' then (array[
      'Write an absurd office poem starring %s in an epic printer battle.',
      'Write about %s discovering a mysterious smell in the office kitchen.',
      'Write a poem about %s becoming an office legend for all the wrong reasons.'
    ])[1 + (v_template_seed % 3)]
    when 'beer_inspired' then (array[
      'Write an ode to %s discovering the perfect beer.',
      'Write a tragic poem about %s finding the beer fridge empty.',
      'Write a medieval poem about %s and the Abt Lord''s throne.'
    ])[1 + (v_template_seed % 3)]
    when 'absolute_nonsense' then (array[
      'Write a poem about %s being elected Supreme Leader by the office printer.',
      'Write about %s slowly turning into a sentient stapler.',
      'Write an absurd poem about %s versus a rogue PowerPoint presentation.'
    ])[1 + (v_template_seed % 3)]
    when 'dramatic' then (array[
      'Describe %s losing Wi-Fi as if civilization itself has collapsed.',
      'Turn %s''s minor office inconvenience into a Shakespearean tragedy.',
      'Write an epic battle poem starring %s against a broken coffee machine.'
    ])[1 + (v_template_seed % 3)]
    when 'abt_dynasty' then (array[
      'Write a medieval prophecy about %s attempting to seize the Abt throne.',
      'Turn %s into a legendary knight serving the Abt Lord.',
      'Write a coronation poem imagining %s as the next Abt Lord.'
    ])[1 + (v_template_seed % 3)]
    when 'deep_thoughts' then (array[
      'Write a philosophical poem about %s contemplating the meaning of a Monday.',
      'Write a deep, reflective poem about %s staring at a spreadsheet.',
      'Write an existential poem from %s''s perspective at 4:59 PM.'
    ])[1 + (v_template_seed % 3)]
    when 'wholesome' then (array[
      'Write a wholesome poem about %s making everyone''s day a little better.',
      'Write a heartwarming poem about %s sharing their lunch.',
      'Write a sweet poem about %s remembering everyone''s birthday.'
    ])[1 + (v_template_seed % 3)]
  end;

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
