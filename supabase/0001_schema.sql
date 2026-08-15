-- =================================================================
-- OFFICE LORE — SUPABASE SCHEMA (required)
-- Tables, RLS policies, XP-ledger triggers, Realtime.
-- =================================================================
-- Run this ENTIRE file once in the Supabase SQL Editor
-- (Project -> SQL Editor -> New query -> paste this file -> Run).
--
-- BEFORE running this:
-- 1. Create the 3 accounts first via Authentication -> Users -> Add user
--    (use real email addresses you control — needed for password reset
--    to actually work). A `profiles` row is auto-created for each one
--    by the trigger at the bottom of section 1.
-- 2. This script assumes none of these tables exist yet — run it on an
--    empty/new Supabase project.
--
-- After this file, optionally run 0002_seed_demo_data.sql to load the
-- app's existing demo content (safe to skip entirely).
-- =================================================================

create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;


-- =================================================================
-- SECTION 1 — PROFILES
-- =================================================================
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  first_name text,
  profile_nickname text,
  job_title text,
  business_unit text,
  bio text,
  avatar_emoji text,
  avatar_photo text, -- base64 data URL, nullable (photo takes priority over emoji when set)
  accent_color text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute procedure public.set_updated_at();

-- auto-create a profile row the moment a new auth user appears
-- (i.e. as soon as you add the 3 accounts via the dashboard)
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, display_name, first_name)
  values (new.id, split_part(new.email, '@', 1), split_part(new.email, '@', 1));
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- =================================================================
-- SECTION 2 — NICKNAMES + events + votes
-- =================================================================
create table public.nicknames (
  id uuid primary key default gen_random_uuid(),
  nickname text not null,
  person_real_name text not null,
  business_unit text,
  description text,
  anecdote text,
  status text not null default 'Actief'
    check (status in ('Actief', 'In overweging', 'Gearchiveerd')),
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_nicknames_updated_at
  before update on public.nicknames
  for each row execute procedure public.set_updated_at();

create table public.nickname_events (
  id uuid primary key default gen_random_uuid(),
  nickname_id uuid not null references public.nicknames(id) on delete cascade,
  event_type text not null
    check (event_type in ('reused', 'used_present', 'person_laughs', 'used_outsider', 'self_used')),
  xp_value int not null,
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.nickname_votes (
  id uuid primary key default gen_random_uuid(),
  nickname_id uuid not null references public.nicknames(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  vote_type text not null check (vote_type in ('funny', 'accurate', 'savage')),
  created_at timestamptz not null default now(),
  unique (nickname_id, user_id, vote_type) -- toggle: insert if absent, delete if present
);

-- convenience: total nickname XP (10 base bonus on creation + sum of all events)
create view public.nickname_xp_totals as
select n.id as nickname_id,
       10 + coalesce(sum(ne.xp_value), 0) as total_xp,
       count(ne.id) as usage_count
from public.nicknames n
left join public.nickname_events ne on ne.nickname_id = n.id
group by n.id;


-- =================================================================
-- SECTION 3 — QUOTES (+ reactions)
-- =================================================================
create table public.quotes (
  id uuid primary key default gen_random_uuid(),
  person_real_name text not null,
  business_unit text,
  quote text not null,
  context text,
  all_three_bonus_awarded boolean not null default false,
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_quotes_updated_at
  before update on public.quotes
  for each row execute procedure public.set_updated_at();

create table public.quote_reactions (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.quotes(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  reaction_type text not null check (reaction_type in ('funny', 'savage', 'facepalm')),
  created_at timestamptz not null default now(),
  unique (quote_id, user_id, reaction_type)
);


-- =================================================================
-- SECTION 4 — ANECDOTES (+ reactions)
-- =================================================================
create table public.anecdotes (
  id uuid primary key default gen_random_uuid(),
  person_real_name text not null,
  business_unit text,
  title text not null,
  description text not null,
  all_three_bonus_awarded boolean not null default false,
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_anecdotes_updated_at
  before update on public.anecdotes
  for each row execute procedure public.set_updated_at();

create table public.anecdote_reactions (
  id uuid primary key default gen_random_uuid(),
  anecdote_id uuid not null references public.anecdotes(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  reaction_type text not null check (reaction_type in ('funny', 'savage', 'facepalm')),
  created_at timestamptz not null default now(),
  unique (anecdote_id, user_id, reaction_type)
);


-- =================================================================
-- SECTION 5 — COUNTERS + events
-- =================================================================
create table public.counters (
  id uuid primary key default gen_random_uuid(),
  person_real_name text not null,
  business_unit text,
  title text not null,
  description text,
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.counter_events (
  id uuid primary key default gen_random_uuid(),
  counter_id uuid not null references public.counters(id) on delete cascade,
  registered_by_user_id uuid not null references public.profiles(id),
  delta int not null default 1,
  note text,
  created_at timestamptz not null default now()
);

-- current total = sum of all deltas, clamped at 0 (matches app's Math.max(0, ...) behavior).
-- Events stay the single source of truth — no separate mutable total column.
create view public.counter_totals as
select c.id as counter_id,
       greatest(0, coalesce(sum(ce.delta), 0)) as total,
       count(ce.id) as event_count
from public.counters c
left join public.counter_events ce on ce.counter_id = c.id
group by c.id;


-- =================================================================
-- SECTION 6 — BEER CLUB
-- =================================================================
create table public.beers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  brewery text,
  beer_style text,
  alcohol_percentage numeric(4,1),
  country text,
  image_url text, -- base64 data URL
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (name, brewery)
);

create table public.beer_sessions (
  id uuid primary key default gen_random_uuid(),
  session_date date not null,
  location text,
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.beer_session_participants (
  session_id uuid not null references public.beer_sessions(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  primary key (session_id, user_id)
);

create table public.beer_ratings (
  id uuid primary key default gen_random_uuid(),
  beer_id uuid not null references public.beers(id) on delete cascade,
  session_id uuid not null references public.beer_sessions(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  rating int check (rating between 1 and 10),
  review text,
  created_at timestamptz not null default now(),
  unique (beer_id, session_id, user_id)
);

create table public.beer_consumption (
  id uuid primary key default gen_random_uuid(),
  beer_id uuid not null references public.beers(id) on delete cascade,
  session_id uuid not null references public.beer_sessions(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  quantity int not null default 1,
  created_at timestamptz not null default now(),
  unique (beer_id, session_id, user_id)
);

create table public.perfect_pours (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.beer_sessions(id) on delete cascade,
  given_by_user_id uuid not null references public.profiles(id),
  received_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check (given_by_user_id <> received_by_user_id),
  unique (session_id, given_by_user_id) -- max 1 vote per user per session
);


-- =================================================================
-- SECTION 7 — XP_EVENTS (central ledger, write-only via triggers)
-- =================================================================
create table public.xp_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  xp_type text not null check (xp_type in ('lore', 'beer')),
  source_type text not null,
  source_id uuid,
  points int not null,
  description text,
  created_at timestamptz not null default now()
);

-- convenience: total Lore XP / Beer XP per user, straight from the ledger
create view public.user_xp_totals as
select
  p.id as user_id,
  coalesce(sum(x.points) filter (where x.xp_type = 'lore'), 0) as lore_xp,
  coalesce(sum(x.points) filter (where x.xp_type = 'beer'), 0) as beer_xp
from public.profiles p
left join public.xp_events x on x.user_id = p.id
group by p.id;

-- "The Abt Lord" = user with the highest beer_xp; not stored anywhere,
-- just: select * from user_xp_totals order by beer_xp desc limit 1;

-- ---- triggers that fill xp_events automatically ----

-- new nickname -> +10 lore XP for the creator
create or replace function public.xp_on_nickname_insert()
returns trigger as $$
begin
  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (new.created_by_user_id, 'lore', 'nickname', new.id, 10, 'Nieuwe nickname: ' || new.nickname);
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_nickname_insert
  after insert on public.nicknames
  for each row execute procedure public.xp_on_nickname_insert();

-- nickname usage moment -> XP goes to the nickname's CREATOR
-- (same rule as the app: nickname XP counts for whoever added the
-- nickname, not whoever logged the usage moment)
create or replace function public.xp_on_nickname_event_insert()
returns trigger as $$
declare
  v_owner uuid;
  v_nickname text;
begin
  select created_by_user_id, nickname into v_owner, v_nickname
  from public.nicknames where id = new.nickname_id;

  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (v_owner, 'lore', 'nickname_event', new.id, new.xp_value, 'Gebruiksmoment "' || v_nickname || '": ' || new.event_type);
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_nickname_event_insert
  after insert on public.nickname_events
  for each row execute procedure public.xp_on_nickname_event_insert();

-- new quote -> +5 lore XP
create or replace function public.xp_on_quote_insert()
returns trigger as $$
begin
  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (new.created_by_user_id, 'lore', 'quote', new.id, 5, 'Nieuwe quote');
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_quote_insert
  after insert on public.quotes
  for each row execute procedure public.xp_on_quote_insert();

-- new anecdote -> +5 lore XP
create or replace function public.xp_on_anecdote_insert()
returns trigger as $$
begin
  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (new.created_by_user_id, 'lore', 'anecdote', new.id, 5, 'Nieuwe anekdote: ' || new.title);
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_anecdote_insert
  after insert on public.anecdotes
  for each row execute procedure public.xp_on_anecdote_insert();

-- "all 3 users reacted" bonus on quotes (one-time, +5 lore XP)
create or replace function public.xp_on_quote_reaction_insert()
returns trigger as $$
declare
  v_distinct_reactors int;
  v_already boolean;
  v_owner uuid;
begin
  select all_three_bonus_awarded, created_by_user_id into v_already, v_owner
  from public.quotes where id = new.quote_id;

  if not v_already then
    select count(distinct user_id) into v_distinct_reactors
    from public.quote_reactions where quote_id = new.quote_id;

    if v_distinct_reactors >= 3 then
      update public.quotes set all_three_bonus_awarded = true where id = new.quote_id;
      insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
      values (v_owner, 'lore', 'quote_bonus', new.quote_id, 5, 'Alle 3 gebruikers reageerden op deze quote');
    end if;
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_quote_reaction_insert
  after insert on public.quote_reactions
  for each row execute procedure public.xp_on_quote_reaction_insert();

-- same bonus rule for anecdotes
create or replace function public.xp_on_anecdote_reaction_insert()
returns trigger as $$
declare
  v_distinct_reactors int;
  v_already boolean;
  v_owner uuid;
begin
  select all_three_bonus_awarded, created_by_user_id into v_already, v_owner
  from public.anecdotes where id = new.anecdote_id;

  if not v_already then
    select count(distinct user_id) into v_distinct_reactors
    from public.anecdote_reactions where anecdote_id = new.anecdote_id;

    if v_distinct_reactors >= 3 then
      update public.anecdotes set all_three_bonus_awarded = true where id = new.anecdote_id;
      insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
      values (v_owner, 'lore', 'anecdote_bonus', new.anecdote_id, 5, 'Alle 3 gebruikers reageerden op deze anekdote');
    end if;
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_anecdote_reaction_insert
  after insert on public.anecdote_reactions
  for each row execute procedure public.xp_on_anecdote_reaction_insert();

-- counter event -> lore XP for the counter's CREATOR, points = delta
-- (can be negative on a -1 registration, same as today)
create or replace function public.xp_on_counter_event_insert()
returns trigger as $$
declare
  v_owner uuid;
  v_title text;
begin
  select created_by_user_id, title into v_owner, v_title
  from public.counters where id = new.counter_id;

  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (v_owner, 'lore', 'counter_event', new.id, new.delta, 'Counter "' || v_title || '"');
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_counter_event_insert
  after insert on public.counter_events
  for each row execute procedure public.xp_on_counter_event_insert();

-- perfect pour received -> +3 beer XP
create or replace function public.xp_on_perfect_pour_insert()
returns trigger as $$
begin
  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (new.received_by_user_id, 'beer', 'perfect_pour', new.id, 3, 'Perfect Pour ontvangen');
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_perfect_pour_insert
  after insert on public.perfect_pours
  for each row execute procedure public.xp_on_perfect_pour_insert();

-- beer rating given -> +2 beer XP (ratingGiven rule)
create or replace function public.xp_on_beer_rating_insert()
returns trigger as $$
begin
  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (new.user_id, 'beer', 'rating_given', new.id, 2, 'Rating gegeven');
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_beer_rating_insert
  after insert on public.beer_ratings
  for each row execute procedure public.xp_on_beer_rating_insert();

-- beer consumption logged -> +1 beer XP per unit (perDrink), plus +3 once
-- if this is the first time this user ever tried this beer (newBeerTried)
create or replace function public.xp_on_beer_consumption_insert()
returns trigger as $$
declare
  v_first_time boolean;
begin
  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (new.user_id, 'beer', 'per_drink', new.id, new.quantity, 'Bier gedronken (' || new.quantity || 'x)');

  select not exists (
    select 1 from public.beer_consumption
    where beer_id = new.beer_id and user_id = new.user_id and id <> new.id
  ) into v_first_time;

  if v_first_time then
    insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
    values (new.user_id, 'beer', 'new_beer_tried', new.id, 3, 'Nieuw bier geproefd');
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_beer_consumption_insert
  after insert on public.beer_consumption
  for each row execute procedure public.xp_on_beer_consumption_insert();

-- ownBeerAdopted -> +5 beer XP, once, to whoever added a beer once it
-- has been drunk by 2+ distinct people (idempotency guard: only fires
-- once per beer, checked against xp_events itself)
create or replace function public.xp_on_beer_consumption_adoption_check()
returns trigger as $$
declare
  v_distinct_drinkers int;
  v_beer_owner uuid;
  v_beer_name text;
  v_already_awarded boolean;
begin
  select count(distinct user_id) into v_distinct_drinkers
  from public.beer_consumption where beer_id = new.beer_id;

  if v_distinct_drinkers >= 2 then
    select created_by_user_id, name into v_beer_owner, v_beer_name
    from public.beers where id = new.beer_id;

    select exists (
      select 1 from public.xp_events
      where source_type = 'own_beer_adopted' and source_id = new.beer_id
    ) into v_already_awarded;

    if not v_already_awarded then
      insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
      values (v_beer_owner, 'beer', 'own_beer_adopted', new.beer_id, 5, 'Eigen bier "' || v_beer_name || '" werd overgenomen');
    end if;
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_beer_consumption_adoption
  after insert on public.beer_consumption
  for each row execute procedure public.xp_on_beer_consumption_adoption_check();


-- =================================================================
-- SECTION 8 — ROW LEVEL SECURITY
-- =================================================================

-- ---- profiles ----
alter table public.profiles enable row level security;

create policy "Profiles: any authenticated user can read all profiles"
  on public.profiles for select
  to authenticated
  using (true);

create policy "Profiles: only yourself may edit your own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);
-- no insert/delete policy: profiles only ever come from the
-- handle_new_user() trigger (SECURITY DEFINER, bypasses RLS)

-- ---- nicknames ----
alter table public.nicknames enable row level security;

create policy "Nicknames: authenticated may read"
  on public.nicknames for select to authenticated using (true);
create policy "Nicknames: authenticated may insert as themselves"
  on public.nicknames for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Nicknames: only creator may update"
  on public.nicknames for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Nicknames: only creator may delete"
  on public.nicknames for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- nickname_events ----
alter table public.nickname_events enable row level security;

create policy "Nickname events: authenticated may read"
  on public.nickname_events for select to authenticated using (true);
create policy "Nickname events: anyone may log a usage moment as themselves"
  on public.nickname_events for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Nickname events: only own entry may be deleted"
  on public.nickname_events for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- nickname_votes ----
alter table public.nickname_votes enable row level security;

create policy "Nickname votes: authenticated may read"
  on public.nickname_votes for select to authenticated using (true);
create policy "Nickname votes: only own vote may be added"
  on public.nickname_votes for insert to authenticated with check (user_id = auth.uid());
create policy "Nickname votes: only own vote may be retracted"
  on public.nickname_votes for delete to authenticated using (user_id = auth.uid());

-- ---- quotes ----
alter table public.quotes enable row level security;

create policy "Quotes: authenticated may read"
  on public.quotes for select to authenticated using (true);
create policy "Quotes: authenticated may insert as themselves"
  on public.quotes for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Quotes: only creator may update"
  on public.quotes for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Quotes: only creator may delete"
  on public.quotes for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- quote_reactions ----
alter table public.quote_reactions enable row level security;

create policy "Quote reactions: authenticated may read"
  on public.quote_reactions for select to authenticated using (true);
create policy "Quote reactions: only own reaction may be added"
  on public.quote_reactions for insert to authenticated with check (user_id = auth.uid());
create policy "Quote reactions: only own reaction may be retracted"
  on public.quote_reactions for delete to authenticated using (user_id = auth.uid());

-- ---- anecdotes ----
alter table public.anecdotes enable row level security;

create policy "Anecdotes: authenticated may read"
  on public.anecdotes for select to authenticated using (true);
create policy "Anecdotes: authenticated may insert as themselves"
  on public.anecdotes for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Anecdotes: only creator may update"
  on public.anecdotes for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Anecdotes: only creator may delete"
  on public.anecdotes for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- anecdote_reactions ----
alter table public.anecdote_reactions enable row level security;

create policy "Anecdote reactions: authenticated may read"
  on public.anecdote_reactions for select to authenticated using (true);
create policy "Anecdote reactions: only own reaction may be added"
  on public.anecdote_reactions for insert to authenticated with check (user_id = auth.uid());
create policy "Anecdote reactions: only own reaction may be retracted"
  on public.anecdote_reactions for delete to authenticated using (user_id = auth.uid());

-- ---- counters ----
alter table public.counters enable row level security;

create policy "Counters: authenticated may read"
  on public.counters for select to authenticated using (true);
create policy "Counters: authenticated may insert as themselves"
  on public.counters for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Counters: only creator may update"
  on public.counters for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Counters: only creator may delete"
  on public.counters for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- counter_events ----
alter table public.counter_events enable row level security;

create policy "Counter events: authenticated may read"
  on public.counter_events for select to authenticated using (true);
create policy "Counter events: anyone may register +1/-1 as themselves"
  on public.counter_events for insert to authenticated with check (registered_by_user_id = auth.uid());
create policy "Counter events: only own entry may be deleted"
  on public.counter_events for delete to authenticated using (registered_by_user_id = auth.uid());

-- ---- beers ----
alter table public.beers enable row level security;

create policy "Beers: authenticated may read"
  on public.beers for select to authenticated using (true);
create policy "Beers: authenticated may insert as themselves"
  on public.beers for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Beers: only creator may update"
  on public.beers for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Beers: only creator may delete"
  on public.beers for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- beer_sessions ----
alter table public.beer_sessions enable row level security;

create policy "Beer sessions: authenticated may read"
  on public.beer_sessions for select to authenticated using (true);
create policy "Beer sessions: authenticated may insert as themselves"
  on public.beer_sessions for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Beer sessions: only creator may update"
  on public.beer_sessions for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Beer sessions: only creator may delete"
  on public.beer_sessions for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- beer_session_participants ----
-- no created_by_user_id on this table (pure join table) — so functionally
-- the standard rule is replaced with: only the SESSION's creator may
-- add/remove participants.
alter table public.beer_session_participants enable row level security;

create policy "Session participants: authenticated may read"
  on public.beer_session_participants for select to authenticated using (true);
create policy "Session participants: only session creator may add"
  on public.beer_session_participants for insert to authenticated
  with check (exists (
    select 1 from public.beer_sessions s
    where s.id = session_id and s.created_by_user_id = auth.uid()
  ));
create policy "Session participants: only session creator may remove"
  on public.beer_session_participants for delete to authenticated
  using (exists (
    select 1 from public.beer_sessions s
    where s.id = session_id and s.created_by_user_id = auth.uid()
  ));

-- ---- beer_ratings ----
alter table public.beer_ratings enable row level security;

create policy "Beer ratings: authenticated may read"
  on public.beer_ratings for select to authenticated using (true);
create policy "Beer ratings: only own rating may be added"
  on public.beer_ratings for insert to authenticated with check (user_id = auth.uid());
create policy "Beer ratings: only own rating may be updated"
  on public.beer_ratings for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Beer ratings: only own rating may be deleted"
  on public.beer_ratings for delete to authenticated using (user_id = auth.uid());

-- ---- beer_consumption ----
alter table public.beer_consumption enable row level security;

create policy "Beer consumption: authenticated may read"
  on public.beer_consumption for select to authenticated using (true);
create policy "Beer consumption: only own entry may be added"
  on public.beer_consumption for insert to authenticated with check (user_id = auth.uid());
create policy "Beer consumption: only own entry may be updated"
  on public.beer_consumption for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Beer consumption: only own entry may be deleted"
  on public.beer_consumption for delete to authenticated using (user_id = auth.uid());

-- ---- perfect_pours ----
alter table public.perfect_pours enable row level security;

create policy "Perfect pours: authenticated may read"
  on public.perfect_pours for select to authenticated using (true);
create policy "Perfect pours: only own vote may be cast"
  on public.perfect_pours for insert to authenticated with check (given_by_user_id = auth.uid());
create policy "Perfect pours: only own vote may be retracted"
  on public.perfect_pours for delete to authenticated using (given_by_user_id = auth.uid());

-- ---- xp_events ----
-- read-only for the client. No insert/update/delete policy: this table
-- is populated exclusively by the SECURITY DEFINER triggers above, so
-- nobody can grant themselves points from the app.
alter table public.xp_events enable row level security;

create policy "XP events: authenticated may read"
  on public.xp_events for select to authenticated using (true);


-- =================================================================
-- SECTION 9 — REALTIME
-- =================================================================
alter publication supabase_realtime add table
  public.nicknames,
  public.nickname_events,
  public.nickname_votes,
  public.quotes,
  public.quote_reactions,
  public.anecdotes,
  public.anecdote_reactions,
  public.counters,
  public.counter_events,
  public.beers,
  public.beer_sessions,
  public.beer_session_participants,
  public.beer_ratings,
  public.beer_consumption,
  public.perfect_pours;
