-- =================================================================
-- OFFICE LORE — NICKNAME BATTLES (Phase 1: 1v1 battles, no Championship yet)
-- =================================================================
-- New tables: nickname_battles, nickname_battle_votes, plus a
-- vote-count aggregate view. No XP wiring -- ordinary battle wins
-- grant no XP per spec (only a future Championship win would, out of
-- scope here). Nicknames themselves are untouched.
-- =================================================================

-- ---- 1. nickname_battles ----
-- Every display field is denormalized at creation time (in addition
-- to the FK) so a battle's history stays stable even if the source
-- nickname is later edited or deleted.
create table public.nickname_battles (
  id uuid primary key default gen_random_uuid(),
  nickname_a_id uuid references public.nicknames(id) on delete set null,
  nickname_a_text text not null,
  nickname_a_person_name text,
  nickname_a_business_unit text,
  nickname_b_id uuid references public.nicknames(id) on delete set null,
  nickname_b_text text not null,
  nickname_b_person_name text,
  nickname_b_business_unit text,
  status text not null default 'open' check (status in ('open', 'finished', 'draw')),
  winner_nickname_id uuid references public.nicknames(id) on delete set null,
  winner_nickname_text text,
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  check (nickname_a_id is distinct from nickname_b_id or nickname_a_id is null)
);

-- ---- 2. nickname_battle_votes ----
-- voted_side ('a'/'b') rather than a nickname_id FK: the battle row
-- already carries both nicknames' identities, so this avoids an
-- unnecessary FK-on-delete edge case entirely.
create table public.nickname_battle_votes (
  id uuid primary key default gen_random_uuid(),
  battle_id uuid not null references public.nickname_battles(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  voted_side text not null check (voted_side in ('a', 'b')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (battle_id, user_id)
);

create trigger trg_nickname_battle_votes_updated_at
  before update on public.nickname_battle_votes
  for each row execute procedure public.set_updated_at();

-- ---- 3. vote-count view: safe to read while a battle is still open ----
-- total_votes is always live (needed for "2/3 votes received"), but
-- votes_a/votes_b only ever become real numbers once status <> 'open'
-- -- the filter clause is false while voting is in progress, so this
-- view can never leak the live breakdown before reveal. Views run
-- with their owner's privileges, so this legitimately bypasses the
-- base table's row-level "hide other users' votes" policy below for
-- these three safe aggregate columns only.
create view public.nickname_battle_vote_counts as
select
  v.battle_id,
  count(*) as total_votes,
  count(*) filter (where b.status <> 'open' and v.voted_side = 'a') as votes_a,
  count(*) filter (where b.status <> 'open' and v.voted_side = 'b') as votes_b
from public.nickname_battle_votes v
join public.nickname_battles b on b.id = v.battle_id
group by v.battle_id;

-- ---- 4. finalization: a shared resolver, called from the vote
-- trigger (auto-finalize once all 3 have voted) and from a manual
-- "close early" RPC (force-resolve on demand, landing on 'draw' if
-- tied). Per-battle advisory lock (hashtext-derived) rather than one
-- global constant, so unrelated battles' votes never serialize
-- against each other.
create or replace function public.resolve_nickname_battle_outcome(p_battle_id uuid, p_require_all_votes boolean)
returns void as $$
declare
  v_battle record;
  v_vote_count int;
  v_a_votes int;
  v_b_votes int;
begin
  perform pg_advisory_xact_lock(hashtext('nickname_battle:' || p_battle_id::text));

  select * into v_battle from public.nickname_battles where id = p_battle_id;
  if v_battle is null or v_battle.status <> 'open' then
    return; -- al afgerond (of niet-bestaand) -- veilige no-op bij een gelijktijdige poging
  end if;

  select count(*) into v_vote_count from public.nickname_battle_votes where battle_id = p_battle_id;
  if v_vote_count = 0 or (p_require_all_votes and v_vote_count < 3) then
    return;
  end if;

  select count(*) filter (where voted_side = 'a'), count(*) filter (where voted_side = 'b')
    into v_a_votes, v_b_votes
    from public.nickname_battle_votes where battle_id = p_battle_id;

  if v_a_votes = v_b_votes then
    update public.nickname_battles set status = 'draw', finished_at = now() where id = p_battle_id;
  elsif v_a_votes > v_b_votes then
    update public.nickname_battles
      set status = 'finished', winner_nickname_id = v_battle.nickname_a_id, winner_nickname_text = v_battle.nickname_a_text, finished_at = now()
      where id = p_battle_id;
  else
    update public.nickname_battles
      set status = 'finished', winner_nickname_id = v_battle.nickname_b_id, winner_nickname_text = v_battle.nickname_b_text, finished_at = now()
      where id = p_battle_id;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.trg_finalize_nickname_battle()
returns trigger as $$
begin
  perform public.resolve_nickname_battle_outcome(new.battle_id, true);
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_finalize_nickname_battle
  after insert or update on public.nickname_battle_votes
  for each row execute procedure public.trg_finalize_nickname_battle();

-- manual "force close" -- called directly via sb.rpc(...) from the client
create or replace function public.close_nickname_battle_early(p_battle_id uuid)
returns void as $$
begin
  perform public.resolve_nickname_battle_outcome(p_battle_id, false);
end;
$$ language plpgsql security definer set search_path = public;

-- ---- 5. RLS ----
alter table public.nickname_battles enable row level security;
alter table public.nickname_battle_votes enable row level security;

create policy "Nickname battles: read" on public.nickname_battles for select to authenticated using (true);
create policy "Nickname battles: authenticated may create" on public.nickname_battles for insert to authenticated
  with check (created_by_user_id = auth.uid());
create policy "Nickname battles: authenticated may update" on public.nickname_battles for update to authenticated
  using (true) with check (true);
create policy "Nickname battles: authenticated may delete" on public.nickname_battles for delete to authenticated
  using (true);

-- votes: always see your own vote; see everyone's only once the
-- battle is no longer open -- the actual enforcement of "don't show
-- other users' choices before reveal", not just a UI convention.
create policy "Battle votes: read own always, all once revealed" on public.nickname_battle_votes for select to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from public.nickname_battles b where b.id = battle_id and b.status <> 'open')
  );
create policy "Battle votes: insert own" on public.nickname_battle_votes for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.nickname_battles b where b.id = battle_id and b.status = 'open')
  );
create policy "Battle votes: update own while open" on public.nickname_battle_votes for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.nickname_battles b where b.id = battle_id and b.status = 'open')
  );
create policy "Battle votes: delete own" on public.nickname_battle_votes for delete to authenticated
  using (user_id = auth.uid());

-- ---- 6. Realtime ----
alter publication supabase_realtime add table public.nickname_battles, public.nickname_battle_votes;
