-- =================================================================
-- OFFICE LORE — POETRY WALL (new module)
-- =================================================================
-- New tables: poems, poem_reactions, poet_laureate_reigns.
-- One existing-table change, additive only: xp_events.xp_type gains
-- a third allowed value ('poetry') and user_xp_totals gains a
-- poetry_xp column — nothing that already reads 'lore'/'beer' XP is
-- affected.
-- =================================================================

-- ---- 1. poems ----
create table public.poems (
  id uuid primary key default gen_random_uuid(),
  author_user_id uuid not null references public.profiles(id),
  title text not null,
  content text not null,
  mood text not null check (mood in (
    'romantic','melancholic','comedy','deep_thoughts','beer_inspired',
    'office_tragedy','wholesome','nonsense','dramatic','other'
  )),
  context text,
  actually_good_bonus_awarded boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_poems_updated_at
  before update on public.poems
  for each row execute procedure public.set_updated_at();

-- ---- 2. poem_reactions ----
create table public.poem_reactions (
  id uuid primary key default gen_random_uuid(),
  poem_id uuid not null references public.poems(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  reaction_type text not null check (reaction_type in (
    'charming','creative','tragic','comedy_gold','deep',
    'beer_inspired','what_did_i_just_read','actually_good','emotional_damage'
  )),
  created_at timestamptz not null default now(),
  unique (poem_id, user_id, reaction_type)
);

-- max 3 distinct reactions per user per poem (uniqueness alone can't express this)
create or replace function public.enforce_max_poem_reactions()
returns trigger as $$
declare
  v_count int;
begin
  select count(*) into v_count from public.poem_reactions
  where poem_id = new.poem_id and user_id = new.user_id;
  if v_count >= 3 then
    raise exception 'Maximum of 3 different reactions per poem per user';
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_enforce_max_poem_reactions
  before insert on public.poem_reactions
  for each row execute procedure public.enforce_max_poem_reactions();

-- ---- 3. poet_laureate_reigns (mirrors abt_reigns from 0004) ----
create table public.poet_laureate_reigns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  starting_poetry_xp int not null,
  ending_poetry_xp int,
  dethroned_by_user_id uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create unique index one_active_poet_laureate_reign
  on public.poet_laureate_reigns ((1)) where ended_at is null;

-- ---- 4. extend the shared xp_events ledger with xp_type = 'poetry' ----
alter table public.xp_events drop constraint if exists xp_events_xp_type_check;
alter table public.xp_events add constraint xp_events_xp_type_check
  check (xp_type in ('lore', 'beer', 'poetry'));

create or replace view public.user_xp_totals as
select
  p.id as user_id,
  coalesce(sum(x.points) filter (where x.xp_type = 'lore'), 0) as lore_xp,
  coalesce(sum(x.points) filter (where x.xp_type = 'beer'), 0) as beer_xp,
  coalesce(sum(x.points) filter (where x.xp_type = 'poetry'), 0) as poetry_xp
from public.profiles p
left join public.xp_events x on x.user_id = p.id
group by p.id;

-- ---- 5. Poetry XP triggers ----

-- publish a poem -> +5 to the author. after INSERT only, so editing a
-- poem (an UPDATE) never re-grants this.
create or replace function public.xp_on_poem_insert()
returns trigger as $$
begin
  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (new.author_user_id, 'poetry', 'poem_published', new.id, 5, 'Gedicht gepubliceerd: "' || new.title || '"');
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_on_poem_insert
  after insert on public.poems
  for each row execute procedure public.xp_on_poem_insert();

-- reaction received -> +1 to the author, every reaction row is its
-- own event. plus the one-time "both other users gave Actually Good"
-- +5 bonus, guarded by poems.actually_good_bonus_awarded so it can
-- never be double-granted.
create or replace function public.xp_on_poem_reaction_insert()
returns trigger as $$
declare
  v_author uuid;
  v_bonus_awarded boolean;
  v_actually_good_count int;
begin
  select author_user_id, actually_good_bonus_awarded into v_author, v_bonus_awarded
  from public.poems where id = new.poem_id;

  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (v_author, 'poetry', 'reaction_received', new.id, 1, 'Reaction ontvangen: ' || new.reaction_type);

  if new.reaction_type = 'actually_good' and not v_bonus_awarded then
    select count(distinct user_id) into v_actually_good_count
    from public.poem_reactions
    where poem_id = new.poem_id and reaction_type = 'actually_good' and user_id <> v_author;

    if v_actually_good_count >= 2 then
      update public.poems set actually_good_bonus_awarded = true where id = new.poem_id;
      insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
      values (v_author, 'poetry', 'actually_good_bonus', new.poem_id, 5, 'Beide lezers vonden dit gedicht "Actually Good"');
    end if;
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_on_poem_reaction_insert
  after insert on public.poem_reactions
  for each row execute procedure public.xp_on_poem_reaction_insert();

-- reaction removed (toggle-off, or cascaded from a poem delete) ->
-- reverse its own +1, and re-check/revoke the Actually Good bonus.
-- The "poem still exists?" guard is what makes this safe to run as
-- part of a poem-cascade-delete: by the time a cascaded child row's
-- own AFTER DELETE trigger fires, the parent poems row is already
-- gone, so the author lookup returns nothing and this just no-ops --
-- the poem-level cleanup trigger below already reverses the bonus in
-- that case.
create or replace function public.xp_cleanup_poem_reaction()
returns trigger as $$
declare
  v_author uuid;
  v_actually_good_count int;
begin
  perform public.xp_cleanup_by_source('reaction_received', old.id);

  if old.reaction_type = 'actually_good' then
    select author_user_id into v_author from public.poems where id = old.poem_id;
    if v_author is not null then
      select count(distinct user_id) into v_actually_good_count
      from public.poem_reactions
      where poem_id = old.poem_id and reaction_type = 'actually_good' and user_id <> v_author;

      if v_actually_good_count < 2 then
        delete from public.xp_events where source_type = 'actually_good_bonus' and source_id = old.poem_id;
        update public.poems set actually_good_bonus_awarded = false where id = old.poem_id;
      end if;
    end if;
  end if;

  return old;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_cleanup_poem_reaction
  after delete on public.poem_reactions
  for each row execute procedure public.xp_cleanup_poem_reaction();

-- poem deleted -> reverse the publish XP and the actually-good bonus.
-- per-reaction reaction_received XP is already handled individually
-- as poem_reactions rows cascade and fire their own cleanup trigger
-- above (same "cascade still fires child triggers" mechanism already
-- relied on for Beer Session deletes in 0008) -- zero orphans.
create or replace function public.trg_fn_xp_cleanup_poem()
returns trigger as $$
begin
  perform public.xp_cleanup_by_source('poem_published', old.id);
  perform public.xp_cleanup_by_source('actually_good_bonus', old.id);
  return old;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_cleanup_poem
  after delete on public.poems
  for each row execute procedure public.trg_fn_xp_cleanup_poem();

-- ---- 6. The Poet Laureate: automatic throne trigger (mirrors check_abt_throne in 0004) ----
create or replace function public.check_poet_laureate_throne()
returns trigger as $$
declare
  v_leader_id uuid;
  v_leader_xp int;
  v_active_reign record;
  v_incumbent_xp int;
begin
  -- distinct lock key from the Abt throne's 918273645, so poetry XP
  -- writes never serialize against beer XP writes
  perform pg_advisory_xact_lock(462981037);

  select user_id, poetry_xp into v_leader_id, v_leader_xp
  from public.user_xp_totals order by poetry_xp desc, user_id limit 1;

  if v_leader_xp <= 0 then
    return new;
  end if;

  select * into v_active_reign from public.poet_laureate_reigns where ended_at is null limit 1;

  if v_active_reign is null then
    insert into public.poet_laureate_reigns (user_id, starting_poetry_xp) values (v_leader_id, v_leader_xp);
    return new;
  end if;

  if v_active_reign.user_id = v_leader_id then
    return new;
  end if;

  select poetry_xp into v_incumbent_xp from public.user_xp_totals where user_id = v_active_reign.user_id;

  if v_leader_xp > coalesce(v_incumbent_xp, 0) then
    update public.poet_laureate_reigns
      set ended_at = now(), ending_poetry_xp = v_incumbent_xp, dethroned_by_user_id = v_leader_id
      where id = v_active_reign.id;
    insert into public.poet_laureate_reigns (user_id, starting_poetry_xp) values (v_leader_id, v_leader_xp);
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_check_poet_laureate_throne
  after insert on public.xp_events
  for each row when (new.xp_type = 'poetry')
  execute procedure public.check_poet_laureate_throne();

-- ---- 7. RLS ----
alter table public.poems enable row level security;
alter table public.poem_reactions enable row level security;
alter table public.poet_laureate_reigns enable row level security;

create policy "Poems: read" on public.poems for select to authenticated using (true);
create policy "Poems: insert own" on public.poems for insert to authenticated
  with check (author_user_id = auth.uid());
create policy "Poems: update own" on public.poems for update to authenticated
  using (author_user_id = auth.uid());
create policy "Poems: delete own" on public.poems for delete to authenticated
  using (author_user_id = auth.uid());

create policy "Poem reactions: read" on public.poem_reactions for select to authenticated using (true);
create policy "Poem reactions: insert own, not own poem" on public.poem_reactions for insert to authenticated
  with check (
    user_id = auth.uid()
    and not exists (select 1 from public.poems p where p.id = poem_id and p.author_user_id = auth.uid())
  );
create policy "Poem reactions: delete own" on public.poem_reactions for delete to authenticated
  using (user_id = auth.uid());

create policy "Poet laureate reigns: read" on public.poet_laureate_reigns for select to authenticated using (true);
-- no insert/update/delete policy: only the trigger (security definer) writes here

-- ---- 8. Realtime ----
alter publication supabase_realtime add table public.poems, public.poem_reactions, public.poet_laureate_reigns;
