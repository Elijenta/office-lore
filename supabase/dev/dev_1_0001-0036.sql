-- DEV bundle part 1/5: migrations 0001 to 0036. Run the parts in order, each once, in a NEW empty Supabase project (never in production).

-- =========== 0001_schema.sql ===========
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

-- =========== 0003_xp_cleanup_triggers.sql ===========
-- =================================================================
-- OFFICE LORE — XP CLEANUP TRIGGERS (required, run after 0001)
-- =================================================================
-- xp_events.source_id is a plain uuid (it can point at rows in many
-- different tables, so it can't be a single foreign key), which means
-- it does NOT get cleaned up automatically when the source row is
-- deleted. Without this, deleting a nickname/quote/anecdote/counter/
-- beer, or moving a Perfect Pour vote, would leave stale XP behind.
-- These triggers remove the matching xp_events row(s) whenever their
-- source is deleted (including via cascade, e.g. deleting a nickname
-- cascades to its nickname_events, which fires the cleanup below too).
-- =================================================================

create or replace function public.xp_cleanup_by_source(p_source_type text, p_source_id uuid)
returns void as $$
begin
  delete from public.xp_events where source_type = p_source_type and source_id = p_source_id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.trg_fn_xp_cleanup_nickname()
returns trigger as $$ begin perform public.xp_cleanup_by_source('nickname', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_nickname_delete after delete on public.nicknames for each row execute procedure public.trg_fn_xp_cleanup_nickname();

create or replace function public.trg_fn_xp_cleanup_nickname_event()
returns trigger as $$ begin perform public.xp_cleanup_by_source('nickname_event', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_nickname_event_delete after delete on public.nickname_events for each row execute procedure public.trg_fn_xp_cleanup_nickname_event();

create or replace function public.trg_fn_xp_cleanup_quote()
returns trigger as $$ begin
  perform public.xp_cleanup_by_source('quote', old.id);
  perform public.xp_cleanup_by_source('quote_bonus', old.id);
  return old;
end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_quote_delete after delete on public.quotes for each row execute procedure public.trg_fn_xp_cleanup_quote();

create or replace function public.trg_fn_xp_cleanup_anecdote()
returns trigger as $$ begin
  perform public.xp_cleanup_by_source('anecdote', old.id);
  perform public.xp_cleanup_by_source('anecdote_bonus', old.id);
  return old;
end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_anecdote_delete after delete on public.anecdotes for each row execute procedure public.trg_fn_xp_cleanup_anecdote();

create or replace function public.trg_fn_xp_cleanup_counter_event()
returns trigger as $$ begin perform public.xp_cleanup_by_source('counter_event', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_counter_event_delete after delete on public.counter_events for each row execute procedure public.trg_fn_xp_cleanup_counter_event();

create or replace function public.trg_fn_xp_cleanup_beer_rating()
returns trigger as $$ begin perform public.xp_cleanup_by_source('rating_given', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_beer_rating_delete after delete on public.beer_ratings for each row execute procedure public.trg_fn_xp_cleanup_beer_rating();

create or replace function public.trg_fn_xp_cleanup_beer_consumption()
returns trigger as $$ begin
  perform public.xp_cleanup_by_source('per_drink', old.id);
  perform public.xp_cleanup_by_source('new_beer_tried', old.id);
  return old;
end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_beer_consumption_delete after delete on public.beer_consumption for each row execute procedure public.trg_fn_xp_cleanup_beer_consumption();

create or replace function public.trg_fn_xp_cleanup_beer()
returns trigger as $$ begin perform public.xp_cleanup_by_source('own_beer_adopted', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_beer_delete after delete on public.beers for each row execute procedure public.trg_fn_xp_cleanup_beer();

create or replace function public.trg_fn_xp_cleanup_perfect_pour()
returns trigger as $$ begin perform public.xp_cleanup_by_source('perfect_pour', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_perfect_pour_delete after delete on public.perfect_pours for each row execute procedure public.trg_fn_xp_cleanup_perfect_pour();

-- =========== 0004_abt_dynasty.sql ===========
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

-- =========== 0005_beer_session_editing.sql ===========
-- =================================================================
-- OFFICE LORE — BEER SESSION EDITING (required)
-- =================================================================
-- 1) Broadens Beer Club RLS so any of the 3 authenticated users can
--    edit an existing session (date/location, participants, beers,
--    ratings, consumption) on behalf of the group, not just the
--    original creator / row-owner.
--
--    This also fixes a latent bug in the ORIGINAL "create session"
--    flow: the score matrix already lets one person fill in every
--    OTHER participant's score/quantity too (that's the whole point
--    of a shared session log) — but the old owner-only policies
--    (`with check (user_id = auth.uid())`) would silently reject any
--    row in that batch insert that wasn't the creator's own,  which
--    (because Postgres RLS-checks a bulk insert atomically) likely
--    failed the ENTIRE beer_ratings/beer_consumption insert whenever
--    a session had more than one participant with data filled in.
--
-- 2) Adds a delta-XP trigger for beer_consumption UPDATEs, so editing
--    an existing quantity only awards/revokes XP for the DIFFERENCE,
--    never re-awards the full amount. Editing a rating (vs adding a
--    new one) already awards no extra XP by design — there's no
--    UPDATE trigger on beer_ratings, only the existing INSERT one.
-- =================================================================

-- ---- beer_sessions: date/location editable by any authenticated user ----
drop policy if exists "Beer sessions: only creator may update" on public.beer_sessions;
create policy "Beer sessions: authenticated may update"
  on public.beer_sessions for update to authenticated using (true) with check (true);

-- ---- beer_session_participants: add/remove by any authenticated user ----
drop policy if exists "Session participants: only session creator may add" on public.beer_session_participants;
drop policy if exists "Session participants: only session creator may remove" on public.beer_session_participants;
create policy "Session participants: authenticated may add"
  on public.beer_session_participants for insert to authenticated with check (true);
create policy "Session participants: authenticated may remove"
  on public.beer_session_participants for delete to authenticated using (true);

-- ---- beer_ratings: a session's scores are a shared group log, not
--      private per-user data -> any authenticated user may log/edit/
--      remove any row (row still always records the real user_id it
--      belongs to; this only changes who is ALLOWED to write it) ----
drop policy if exists "Beer ratings: only own rating may be added" on public.beer_ratings;
drop policy if exists "Beer ratings: only own rating may be updated" on public.beer_ratings;
drop policy if exists "Beer ratings: only own rating may be deleted" on public.beer_ratings;
create policy "Beer ratings: authenticated may add"
  on public.beer_ratings for insert to authenticated with check (true);
create policy "Beer ratings: authenticated may update"
  on public.beer_ratings for update to authenticated using (true) with check (true);
create policy "Beer ratings: authenticated may delete"
  on public.beer_ratings for delete to authenticated using (true);

-- ---- beer_consumption: same reasoning ----
drop policy if exists "Beer consumption: only own entry may be added" on public.beer_consumption;
drop policy if exists "Beer consumption: only own entry may be updated" on public.beer_consumption;
drop policy if exists "Beer consumption: only own entry may be deleted" on public.beer_consumption;
create policy "Beer consumption: authenticated may add"
  on public.beer_consumption for insert to authenticated with check (true);
create policy "Beer consumption: authenticated may update"
  on public.beer_consumption for update to authenticated using (true) with check (true);
create policy "Beer consumption: authenticated may delete"
  on public.beer_consumption for delete to authenticated using (true);


-- =================================================================
-- delta XP when an existing quantity is edited
-- =================================================================
create or replace function public.xp_on_beer_consumption_update()
returns trigger as $$
declare
  v_delta int;
begin
  v_delta := new.quantity - old.quantity;
  if v_delta <> 0 then
    insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
    values (new.user_id, 'beer', 'per_drink_adjustment', new.id, v_delta, 'Aanpassing aantal (' || old.quantity || ' -> ' || new.quantity || ')');
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_beer_consumption_update
  after update on public.beer_consumption
  for each row
  when (old.quantity is distinct from new.quantity)
  execute procedure public.xp_on_beer_consumption_update();

-- extend the existing cleanup (0003_xp_cleanup_triggers.sql) so
-- adjustment XP is also removed if the consumption row is later
-- deleted entirely
create or replace function public.trg_fn_xp_cleanup_beer_consumption()
returns trigger as $$ begin
  perform public.xp_cleanup_by_source('per_drink', old.id);
  perform public.xp_cleanup_by_source('new_beer_tried', old.id);
  perform public.xp_cleanup_by_source('per_drink_adjustment', old.id);
  return old;
end; $$ language plpgsql security definer set search_path = public;

-- =========== 0006_standalone_beer_ratings.sql ===========
-- =================================================================
-- OFFICE LORE — RATE A BEER WITHOUT A SESSION (required)
-- =================================================================
-- Lets a user log a personal rating for a beer directly from its
-- detail page, with no Beer Session required (session_id = null).
--
-- Reuses the exact same beer_ratings / beer_consumption tables and
-- the exact same existing XP triggers (xp_on_beer_rating_insert,
-- xp_on_beer_consumption_insert, xp_on_beer_consumption_adoption_check,
-- xp_on_beer_consumption_update, and the 0003 cleanup triggers)
-- completely unchanged — none of them reference session_id anywhere
-- in their logic, so a standalone row earns/loses XP through exactly
-- the same rules as a session-logged one, automatically.
--
-- Multiple standalone ratings for the same beer by the same user are
-- intentionally allowed (each is its own tasting occasion, matching
-- the rest of the app's event-log philosophy) — Postgres already
-- treats NULL as distinct in the existing unique(beer_id, session_id,
-- user_id) constraint, so no constraint changes are needed for this.
-- =================================================================

alter table public.beer_ratings alter column session_id drop not null;
alter table public.beer_consumption alter column session_id drop not null;

-- standalone-only fields (harmless/unused on session-linked rows,
-- which keep using the session's own date/location instead)
alter table public.beer_ratings add column rated_at date not null default current_date;
alter table public.beer_ratings add column context text;

-- =========== 0007_beer_consumption_updated_at.sql ===========
-- =================================================================
-- OFFICE LORE — beer_consumption.updated_at (required)
-- =================================================================
-- Additive-only: adds the one column named in the "per-participant
-- consumption" schema that was actually missing (updated_at), plus a
-- trigger to keep it current on quantity edits. No existing data is
-- touched, no constraints change — the unique(beer_id, session_id,
-- user_id) constraint this bugfix relies on already exists from
-- 0001_schema.sql.
-- =================================================================

alter table public.beer_consumption add column updated_at timestamptz not null default now();

create trigger trg_beer_consumption_updated_at
  before update on public.beer_consumption
  for each row execute procedure public.set_updated_at();

-- =========== 0008_safe_deletes.sql ===========
-- =================================================================
-- OFFICE LORE — SAFE DELETES for Beer Sessions + counter events
-- =================================================================
-- 1) RLS broadening (same "shared session log" reasoning already used
--    in 0005_beer_session_editing.sql): any authenticated user may
--    delete a beer_sessions/perfect_pours/counter_events row, not
--    just its creator/giver/logger. Required for the app's new
--    "Delete Session" feature to work via a single cascading delete
--    regardless of who's deleting — Postgres checks RLS per-row even
--    for cascaded deletes, so a narrower policy would make the whole
--    delete fail with a foreign-key violation whenever a cascaded
--    row (e.g. someone else's Perfect Pour vote) belongs to another
--    user.
-- 2) Smarter beer_consumption delete cleanup: deleting the specific
--    row that earned "new beer tried" XP no longer just deletes that
--    XP — if the user still has OTHER consumption of the same beer,
--    the XP is reassigned to one of those rows instead of being lost.
--    Also revokes "own beer adopted" XP if a delete drops a beer's
--    distinct-drinker count back under 2.
-- =================================================================

-- ---- 1. RLS broadening ----
drop policy if exists "Beer sessions: only creator may delete" on public.beer_sessions;
create policy "Beer sessions: authenticated may delete"
  on public.beer_sessions for delete to authenticated using (true);

drop policy if exists "Perfect pours: only own vote may be retracted" on public.perfect_pours;
create policy "Perfect pours: authenticated may delete"
  on public.perfect_pours for delete to authenticated using (true);

drop policy if exists "Counter events: only own entry may be deleted" on public.counter_events;
create policy "Counter events: authenticated may delete"
  on public.counter_events for delete to authenticated using (true);


-- ---- 2. smarter beer_consumption delete cleanup ----
-- replaces the version from 0003_xp_cleanup_triggers.sql
create or replace function public.trg_fn_xp_cleanup_beer_consumption()
returns trigger as $$
declare
  v_new_beer_tried_event_id uuid;
  v_replacement_row_id uuid;
  v_remaining_drinkers int;
begin
  -- per_drink and per_drink_adjustment are simple 1:1 cleanups, unchanged
  perform public.xp_cleanup_by_source('per_drink', old.id);
  perform public.xp_cleanup_by_source('per_drink_adjustment', old.id);

  -- new_beer_tried: reassign to another remaining row for the same
  -- beer+user if one exists, instead of just losing the XP
  select id into v_new_beer_tried_event_id
  from public.xp_events
  where source_type = 'new_beer_tried' and source_id = old.id
  limit 1;

  if v_new_beer_tried_event_id is not null then
    select id into v_replacement_row_id
    from public.beer_consumption
    where beer_id = old.beer_id and user_id = old.user_id and id <> old.id
    order by created_at asc
    limit 1;

    if v_replacement_row_id is not null then
      update public.xp_events set source_id = v_replacement_row_id where id = v_new_beer_tried_event_id;
    else
      delete from public.xp_events where id = v_new_beer_tried_event_id;
    end if;
  end if;

  -- own_beer_adopted: revoke if this beer no longer has >=2 distinct drinkers
  select count(distinct user_id) into v_remaining_drinkers
  from public.beer_consumption
  where beer_id = old.beer_id;

  if v_remaining_drinkers < 2 then
    delete from public.xp_events where source_type = 'own_beer_adopted' and source_id = old.beer_id;
  end if;

  return old;
end;
$$ language plpgsql security definer set search_path = public;

-- =========== 0009_poetry_wall.sql ===========
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

-- =========== 0010_nickname_reactions.sql ===========
-- =================================================================
-- OFFICE LORE — Nicknames: Legendary + Doubt reactions
-- =================================================================
-- Single additive change: widen nickname_votes.vote_type to allow
-- two new reaction types. RLS is already fully generic (own vote to
-- insert/delete, open read) so no policy changes are needed, and
-- votes have never granted XP (confirmed against
-- 0003_xp_cleanup_triggers.sql) so no trigger changes are needed
-- either. Existing funny/accurate/savage rows are untouched.
-- =================================================================

alter table public.nickname_votes drop constraint if exists nickname_votes_vote_type_check;
alter table public.nickname_votes add constraint nickname_votes_vote_type_check
  check (vote_type in ('funny', 'accurate', 'savage', 'legendary', 'doubt'));

-- =========== 0011_nickname_battles.sql ===========
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

-- =========== 0012_poetry_challenges.sql ===========
-- =================================================================
-- OFFICE LORE — POETRY CHALLENGES (extends Poetry Wall)
-- =================================================================
-- New table: poetry_prompts (seeded with ~41 prompts below). Extends
-- poems with prompt_id + denormalized snapshot fields (same "freeze
-- historical display data" pattern as nickname_battles) + a
-- is_challenge_poem flag. Challenge XP (+3) is added to the EXISTING
-- xp_on_poem_insert() trigger from 0009 rather than a new trigger --
-- since it only fires on INSERT (never UPDATE), editing a poem can
-- never re-grant it, with no extra idempotency bookkeeping needed.
-- =================================================================

-- ---- 1. poetry_prompts ----
create table public.poetry_prompts (
  id uuid primary key default gen_random_uuid(),
  prompt_text text not null,
  category text not null check (category in (
    'romantic', 'tragic', 'office_nonsense', 'beer_inspired', 'absolute_nonsense', 'dramatic', 'abt_dynasty'
  )),
  is_daily_eligible boolean not null default true,
  is_surprise_eligible boolean not null default false,
  is_active boolean not null default true,
  created_by_user_id uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

alter table public.poetry_prompts enable row level security;
create policy "Poetry prompts: read" on public.poetry_prompts for select to authenticated using (true);
create policy "Poetry prompts: insert own" on public.poetry_prompts for insert to authenticated
  with check (created_by_user_id = auth.uid());
create policy "Poetry prompts: update own" on public.poetry_prompts for update to authenticated
  using (created_by_user_id = auth.uid());
create policy "Poetry prompts: delete own" on public.poetry_prompts for delete to authenticated
  using (created_by_user_id = auth.uid());

-- ---- 2. seed prompts ----
insert into public.poetry_prompts (prompt_text, category) values
  ('Write a romantic poem about the office printer.', 'romantic'),
  ('Write a love letter to the coffee machine.', 'romantic'),
  ('Write a sonnet about someone finally replying to your Teams message.', 'romantic'),
  ('Write about Excel as if it were your forbidden lover.', 'romantic'),
  ('Write a passionate poem about Friday afternoon.', 'romantic'),

  ('Write a tragic poem about a meeting that could have been an email.', 'tragic'),
  ('Mourn the death of your weekend on Monday morning.', 'tragic'),
  ('Write about the coffee machine being empty.', 'tragic'),
  ('Write a funeral poem for a crashed spreadsheet.', 'tragic'),
  ('Describe the pain of seeing "Meeting extended by 30 minutes."', 'tragic'),

  ('Write an epic poem about someone stealing your chair.', 'office_nonsense'),
  ('Turn a printer jam into a heroic battle.', 'office_nonsense'),
  ('Write about a mysterious smell in the office kitchen.', 'office_nonsense'),
  ('Describe a Teams notification as a supernatural event.', 'office_nonsense'),
  ('Write about the person who never replaces the toilet roll as an ancient villain.', 'office_nonsense'),

  ('Write an ode to your favourite beer.', 'beer_inspired'),
  ('Describe The Abt Lord as an ancient ruler.', 'beer_inspired'),
  ('Write about opening the first beer after work.', 'beer_inspired'),
  ('Write a medieval prophecy about the next Abt Lord.', 'beer_inspired'),
  ('Write a tragic poem about the last beer being gone.', 'beer_inspired'),

  ('Write a poem from the perspective of a stapler.', 'absolute_nonsense'),
  ('Write about a PowerPoint presentation becoming self-aware.', 'absolute_nonsense'),
  ('Describe a keyboard plotting revenge.', 'absolute_nonsense'),
  ('Write a poem about a pigeon becoming CEO.', 'absolute_nonsense'),
  ('Write an emotional goodbye between two Post-it notes.', 'absolute_nonsense'),

  ('Turn a minor office inconvenience into a Shakespearean tragedy.', 'dramatic'),
  ('Write about someone taking the last cookie as an act of betrayal.', 'dramatic'),
  ('Describe losing Wi-Fi as the fall of civilization.', 'dramatic'),
  ('Write an epic battle between coffee and tea.', 'dramatic'),
  ('Write about a 4:59 PM Teams message as the beginning of the apocalypse.', 'dramatic'),

  ('Write a coronation poem for The Abt Lord.', 'abt_dynasty'),
  ('Write a lament from The Fallen Abt.', 'abt_dynasty'),
  ('Write a prophecy predicting who will next take the throne.', 'abt_dynasty'),
  ('Describe an Abt Lord dethronement as a medieval coup.', 'abt_dynasty'),
  ('Write an anthem for the Beer Kingdom.', 'abt_dynasty');

-- "Give Me Something Stupid" -- a distinct curated pool, not just
-- "whatever's tagged absolute_nonsense", so that category can grow
-- later without silently changing what Surprise Me serves.
insert into public.poetry_prompts (prompt_text, category, is_daily_eligible, is_surprise_eligible) values
  ('Write a breakup poem addressed to Microsoft Excel.', 'absolute_nonsense', false, true),
  ('Write a medieval ballad about someone microwaving fish at work.', 'absolute_nonsense', false, true),
  ('Write a seductive poem about a Power BI refresh.', 'absolute_nonsense', false, true),
  ('Write from the perspective of a forgotten yoghurt in the office fridge.', 'absolute_nonsense', false, true),
  ('Write a eulogy for a pen that has run out of ink.', 'absolute_nonsense', false, true),
  ('Write about The Abt Lord discovering that the fridge is empty.', 'absolute_nonsense', false, true);

-- ---- 3. extend poems ----
alter table public.poems add column prompt_id uuid references public.poetry_prompts(id) on delete set null;
alter table public.poems add column prompt_text_snapshot text;
alter table public.poems add column prompt_category_snapshot text;
alter table public.poems add column is_challenge_poem boolean not null default false;

-- ---- 4. challenge XP: extend the existing publish trigger ----
create or replace function public.xp_on_poem_insert()
returns trigger as $$
begin
  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (new.author_user_id, 'poetry', 'poem_published', new.id, 5, 'Gedicht gepubliceerd: "' || new.title || '"');

  if new.is_challenge_poem then
    insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
    values (new.author_user_id, 'poetry', 'challenge_completed', new.id, 3, 'Poetry Challenge voltooid: "' || new.title || '"');
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

-- extend the existing poem-delete cleanup with the new source_type
create or replace function public.trg_fn_xp_cleanup_poem()
returns trigger as $$
begin
  perform public.xp_cleanup_by_source('poem_published', old.id);
  perform public.xp_cleanup_by_source('actually_good_bonus', old.id);
  perform public.xp_cleanup_by_source('challenge_completed', old.id);
  return old;
end;
$$ language plpgsql security definer set search_path = public;

-- ---- 5. Realtime ----
alter publication supabase_realtime add table public.poetry_prompts;

-- =========== 0013_nickname_edit_permissions.sql ===========
-- =================================================================
-- OFFICE LORE — Nicknames: correct edit rights for creator vs. others
-- =================================================================
-- Bugfix: the UPDATE RLS policy on nicknames has always been
-- creator-only, but the frontend used one plain full-field update
-- for everyone -- a non-creator's update silently matched zero rows
-- (Supabase doesn't error on an RLS-filtered update with no matching
-- rows), so nothing ever saved for them, with no error surfaced.
--
-- Fix: keep the existing owner-only UPDATE policy exactly as-is (the
-- creator's full edit keeps working through it unchanged), and add a
-- narrow SECURITY DEFINER RPC that any authenticated user can call to
-- update ONLY description/anecdote -- its own SQL statement is
-- structurally incapable of touching any other column, so this is
-- safe against a manipulated API call, not just a UI convention.
-- =================================================================

-- ---- 1. updated_by_user_id: who last touched this row, via either path ----
alter table public.nicknames add column updated_by_user_id uuid references public.profiles(id);

create or replace function public.set_nickname_updated_by()
returns trigger as $$
begin
  new.updated_by_user_id = auth.uid();
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_nicknames_updated_by
  before update on public.nicknames
  for each row execute procedure public.set_nickname_updated_by();

-- ---- 2. collaborative-fields RPC (description + anecdote only) ----
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

  update public.nicknames
    set description = p_description, anecdote = p_anecdote
    where id = p_nickname_id;
end;
$$ language plpgsql security definer set search_path = public;

-- Note: no XP trigger changes needed -- trg_xp_nickname_insert (0001)
-- is `after insert` only, so editing (by anyone, any number of
-- times, through either path) has never been able to re-grant the
-- +10 creation XP.

-- =========== 0014_daily_poetry_challenges.sql ===========
-- =================================================================
-- OFFICE LORE — DAILY POETRY CHALLENGE (subject = nickname or user)
-- =================================================================
-- New table: daily_poetry_challenges, one row per calendar date,
-- written exactly once by get_or_create_daily_challenge() (the only
-- thing that ever writes here -- same read-only-for-clients pattern
-- as abt_reigns/poet_laureate_reigns). Extends poems with a link +
-- flag; no new XP trigger needed since a daily-challenge poem is
-- submitted with is_challenge_poem = true, so the EXISTING publish
-- trigger (0009/0012) already grants the normal +5/+3.
-- =================================================================

-- ---- 1. daily_poetry_challenges ----
create table public.daily_poetry_challenges (
  id uuid primary key default gen_random_uuid(),
  challenge_date date not null unique,
  subject_type text not null check (subject_type in ('nickname', 'user')),
  nickname_id uuid references public.nicknames(id) on delete set null,
  user_id uuid references public.profiles(id) on delete set null,
  subject_text text not null,
  category text not null check (category in (
    'romantic', 'tragic', 'office_nonsense', 'beer_inspired', 'absolute_nonsense',
    'dramatic', 'abt_dynasty', 'deep_thoughts', 'wholesome'
  )),
  prompt_text text not null,
  created_at timestamptz not null default now()
);

alter table public.daily_poetry_challenges enable row level security;
create policy "Daily poetry challenges: read" on public.daily_poetry_challenges for select to authenticated using (true);
-- no insert/update/delete policy: only get_or_create_daily_challenge() (security definer) writes here

-- ---- 2. get-or-create, race-safe via a per-date advisory lock ----
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
  -- "user" subjects komen uitsluitend uit de 3 OUDSTE profiles (Elien/
  -- Nick/Atti, de originele 3 vaste accounts) -- niet zomaar "alle
  -- profiles", want self-service signup betekent dat er in de praktijk
  -- ook losse test-/QA-accounts kunnen bestaan, en die horen nooit als
  -- subject van een Daily Challenge te verschijnen.
  select count(*) into v_user_count from (select id from public.profiles order by created_at asc limit 3) t;

  -- flat 50/50 tussen nickname en user als subject (niet naar pool-
  -- grootte gewogen, anders komt "user" met maar 3 kandidaten tegen
  -- ~22 nicknames zelden aan bod)
  if v_nickname_count > 0 and (v_user_count = 0 or v_subject_seed % 2 = 0) then
    v_subject_type := 'nickname';
    select id, nickname into v_nickname_id, v_subject_text
      from public.nicknames order by id offset (v_subject_seed % v_nickname_count) limit 1;
  else
    v_subject_type := 'user';
    select id, display_name into v_user_id, v_subject_text
      from (select id, display_name from public.profiles order by created_at asc limit 3) t
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
    -- een gelijktijdige transactie won de race (defensief, de
    -- advisory lock hierboven maakt dit in de praktijk onmogelijk) --
    -- gewoon de bestaande rij ophalen
    select * into v_row from public.daily_poetry_challenges where challenge_date = v_today;
  end if;

  return v_row;
end;
$$ language plpgsql security definer set search_path = public;

-- ---- 3. extend poems ----
alter table public.poems add column daily_challenge_id uuid references public.daily_poetry_challenges(id) on delete set null;
alter table public.poems add column is_daily_challenge boolean not null default false;

-- max 1 daily-challenge gedicht per user per daily challenge
create unique index one_daily_challenge_poem_per_user
  on public.poems (daily_challenge_id, author_user_id) where is_daily_challenge = true;

-- ---- 4. Realtime ----
alter publication supabase_realtime add table public.daily_poetry_challenges;

-- =========== 0015_app_memberships.sql ===========
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
insert into public.app_memberships (app_id, user_id) select 'officelore', u.id from auth.users u where u.id in ('b064ee54-08c8-4d80-863a-b75d6a46b523', '3a5ad158-62db-4852-90b4-e1034adf894d', '809714bc-e4c4-4628-b624-94a2803d16de') on conflict (app_id, user_id) do nothing;

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

-- =========== 0016_terrace_planner.sql ===========
-- =================================================================
-- OFFICE LORE — TERRACE PLANNER
-- =================================================================
-- Propose a drink, gauge availability, pick a spot, confirm it, then
-- turn it into a real Beer Club session. One "option" row is a full
-- (date, time, location) candidate slot -- the simple flow creates
-- exactly one; "multiple locations" adds options sharing the same
-- date/time but varying location (voted via terrace_location_votes,
-- one pick per user); "multiple date/time alternatives" adds options
-- sharing the same location but varying date/time (voted via
-- per-option terrace_availability rows). The simple, single-option
-- case always uses terrace_availability.option_id = null -- a plain
-- whole-event RSVP.
--
-- Same app-scoping pattern as every other table since 0015: RLS gates
-- on public.is_app_member('officelore'), no new membership logic.
-- =================================================================

-- ---- 1. terrace_locations ("Favourite Spots") ----
create table public.terrace_locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  city text,
  note text,
  website_url text,
  has_terrace boolean not null default true,
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
-- no visit-count/rating columns -- both derived live (visits = count
-- of terrace_events/beer_sessions at this location; ratings =
-- averaged from terrace_location_ratings), same "derive don't store"
-- convention as computeBeerXp()/computeLoreScore() etc.

create table public.terrace_location_favorites (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.terrace_locations(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (location_id, user_id)
);

-- ---- 2. terrace_events ----
create table public.terrace_events (
  id uuid primary key default gen_random_uuid(),
  title text,
  created_by_user_id uuid not null references public.profiles(id),
  status text not null default 'proposed' check (status in ('proposed', 'confirmed', 'cancelled')),
  note text,
  confirmed_option_id uuid, -- FK added below, after terrace_event_options exists (circular reference)
  linked_beer_session_id uuid references public.beer_sessions(id) on delete set null,
  invited_user_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- "Waiting for answers" vs "Looks good" are never stored -- computed
-- client-side from live availability counts while status='proposed'.
-- Only confirmed/cancelled are real, explicit stored states.

create trigger trg_terrace_events_updated_at
  before update on public.terrace_events
  for each row execute procedure public.set_updated_at();

-- ---- 3. terrace_event_options ----
create table public.terrace_event_options (
  id uuid primary key default gen_random_uuid(),
  terrace_event_id uuid not null references public.terrace_events(id) on delete cascade,
  event_date date not null,
  event_time time,
  location_id uuid references public.terrace_locations(id),
  manual_location text,
  created_at timestamptz not null default now()
);

alter table public.terrace_events
  add constraint terrace_events_confirmed_option_fkey
  foreign key (confirmed_option_id) references public.terrace_event_options(id) on delete set null;

-- ---- 4. terrace_availability ----
create table public.terrace_availability (
  id uuid primary key default gen_random_uuid(),
  terrace_event_id uuid not null references public.terrace_events(id) on delete cascade,
  option_id uuid references public.terrace_event_options(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  status text not null check (status in ('yes', 'maybe', 'no')),
  needs_reconfirmation boolean not null default false,
  updated_at timestamptz not null default now()
);
-- two partial unique indexes instead of one plain unique constraint:
-- Postgres treats NULL as distinct in a normal unique constraint, so
-- a plain unique(terrace_event_id, option_id, user_id) would silently
-- allow duplicate whole-event RSVPs when option_id is null.
create unique index terrace_availability_whole_event_unique
  on public.terrace_availability (terrace_event_id, user_id) where option_id is null;
create unique index terrace_availability_per_option_unique
  on public.terrace_availability (terrace_event_id, option_id, user_id) where option_id is not null;

create trigger trg_terrace_availability_updated_at
  before update on public.terrace_availability
  for each row execute procedure public.set_updated_at();

-- ---- 5. terrace_location_votes (one preference per user per event) ----
create table public.terrace_location_votes (
  id uuid primary key default gen_random_uuid(),
  terrace_event_id uuid not null references public.terrace_events(id) on delete cascade,
  option_id uuid not null references public.terrace_event_options(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (terrace_event_id, user_id)
);

-- ---- 6. terrace_attendance (separate from availability, on purpose) ----
create table public.terrace_attendance (
  id uuid primary key default gen_random_uuid(),
  terrace_event_id uuid not null references public.terrace_events(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  attended boolean not null,
  recorded_at timestamptz not null default now(),
  unique (terrace_event_id, user_id)
);

-- ---- 7. terrace_location_ratings ----
create table public.terrace_location_ratings (
  id uuid primary key default gen_random_uuid(),
  terrace_event_id uuid not null references public.terrace_events(id) on delete cascade,
  location_id uuid not null references public.terrace_locations(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  terrace_rating int check (terrace_rating between 1 and 10),
  beer_selection_rating int check (beer_selection_rating between 1 and 10),
  vibe_rating int check (vibe_rating between 1 and 10),
  created_at timestamptz not null default now(),
  unique (terrace_event_id, location_id, user_id)
);

-- ---- 8. quotes/nicknames linkage (purely additive, nullable) ----
alter table public.quotes add column terrace_event_id uuid references public.terrace_events(id) on delete set null;
alter table public.nicknames add column terrace_event_id uuid references public.terrace_events(id) on delete set null;

-- ---- 9. reconfirmation flag: an edit to a CONFIRMED event's chosen
-- option flags existing yes/maybe votes instead of silently resetting
-- them. Data-integrity concern, so it's a trigger rather than
-- client-side bookkeeping -- holds regardless of which UI path edits
-- the option.
create or replace function public.flag_terrace_reconfirmation()
returns trigger as $$
declare
  v_event public.terrace_events;
begin
  select * into v_event from public.terrace_events where id = new.terrace_event_id;
  if v_event.status = 'confirmed' and v_event.confirmed_option_id = new.id then
    if new.event_date is distinct from old.event_date
       or new.event_time is distinct from old.event_time
       or new.location_id is distinct from old.location_id
       or new.manual_location is distinct from old.manual_location then
      update public.terrace_availability
        set needs_reconfirmation = true
        where terrace_event_id = new.terrace_event_id
          and status in ('yes', 'maybe');
    end if;
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_terrace_option_reconfirmation
  after update on public.terrace_event_options
  for each row execute procedure public.flag_terrace_reconfirmation();

-- =================================================================
-- SECTION 10 — RLS. Every table: select gated on is_app_member
-- ('officelore') (reusing the 0015 helper, no new membership logic).
-- Writes follow the same "shared group log" model already
-- established for beer_sessions/beer_session_participants (0005) --
-- any app member may create/edit shared Terrace content -- except
-- availability/location-votes/ratings, which are personal and
-- restricted to auth.uid() = user_id per the spec's explicit
-- "Users mogen alleen hun eigen availability vote rechtstreeks
-- wijzigen."
-- =================================================================

alter table public.terrace_locations enable row level security;
create policy "Terrace locations: read" on public.terrace_locations for select to authenticated
  using (public.is_app_member('officelore'));
create policy "Terrace locations: any member may add" on public.terrace_locations for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
create policy "Terrace locations: any member may edit" on public.terrace_locations for update to authenticated
  using (public.is_app_member('officelore')) with check (public.is_app_member('officelore'));

alter table public.terrace_location_favorites enable row level security;
create policy "Terrace location favorites: read" on public.terrace_location_favorites for select to authenticated
  using (public.is_app_member('officelore'));
create policy "Terrace location favorites: own toggle" on public.terrace_location_favorites for insert to authenticated
  with check (user_id = auth.uid() and public.is_app_member('officelore'));
create policy "Terrace location favorites: own toggle may be removed" on public.terrace_location_favorites for delete to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

alter table public.terrace_events enable row level security;
create policy "Terrace events: read" on public.terrace_events for select to authenticated
  using (public.is_app_member('officelore'));
create policy "Terrace events: any member may propose" on public.terrace_events for insert to authenticated
  with check (created_by_user_id = auth.uid() and public.is_app_member('officelore'));
create policy "Terrace events: any member may update" on public.terrace_events for update to authenticated
  using (public.is_app_member('officelore')) with check (public.is_app_member('officelore'));
create policy "Terrace events: any member may delete" on public.terrace_events for delete to authenticated
  using (public.is_app_member('officelore'));

alter table public.terrace_event_options enable row level security;
create policy "Terrace event options: read" on public.terrace_event_options for select to authenticated
  using (public.is_app_member('officelore'));
create policy "Terrace event options: any member may add" on public.terrace_event_options for insert to authenticated
  with check (public.is_app_member('officelore'));
create policy "Terrace event options: any member may edit" on public.terrace_event_options for update to authenticated
  using (public.is_app_member('officelore')) with check (public.is_app_member('officelore'));
create policy "Terrace event options: any member may remove" on public.terrace_event_options for delete to authenticated
  using (public.is_app_member('officelore'));

alter table public.terrace_availability enable row level security;
create policy "Terrace availability: read" on public.terrace_availability for select to authenticated
  using (public.is_app_member('officelore'));
create policy "Terrace availability: only own vote may be added" on public.terrace_availability for insert to authenticated
  with check (user_id = auth.uid() and public.is_app_member('officelore'));
create policy "Terrace availability: only own vote may be changed" on public.terrace_availability for update to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'))
  with check (user_id = auth.uid() and public.is_app_member('officelore'));

alter table public.terrace_location_votes enable row level security;
create policy "Terrace location votes: read" on public.terrace_location_votes for select to authenticated
  using (public.is_app_member('officelore'));
create policy "Terrace location votes: only own vote, while proposed" on public.terrace_location_votes for insert to authenticated
  with check (
    user_id = auth.uid() and public.is_app_member('officelore')
    and exists (select 1 from public.terrace_events e where e.id = terrace_event_id and e.status = 'proposed')
  );
create policy "Terrace location votes: only own vote may be changed, while proposed" on public.terrace_location_votes for update to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'))
  with check (
    user_id = auth.uid() and public.is_app_member('officelore')
    and exists (select 1 from public.terrace_events e where e.id = terrace_event_id and e.status = 'proposed')
  );
create policy "Terrace location votes: only own vote may be retracted" on public.terrace_location_votes for delete to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

alter table public.terrace_attendance enable row level security;
create policy "Terrace attendance: read" on public.terrace_attendance for select to authenticated
  using (public.is_app_member('officelore'));
create policy "Terrace attendance: any member may record" on public.terrace_attendance for insert to authenticated
  with check (public.is_app_member('officelore'));
create policy "Terrace attendance: any member may correct" on public.terrace_attendance for update to authenticated
  using (public.is_app_member('officelore')) with check (public.is_app_member('officelore'));

alter table public.terrace_location_ratings enable row level security;
create policy "Terrace location ratings: read" on public.terrace_location_ratings for select to authenticated
  using (public.is_app_member('officelore'));
create policy "Terrace location ratings: only own rating may be added" on public.terrace_location_ratings for insert to authenticated
  with check (user_id = auth.uid() and public.is_app_member('officelore'));
create policy "Terrace location ratings: only own rating may be changed" on public.terrace_location_ratings for update to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'))
  with check (user_id = auth.uid() and public.is_app_member('officelore'));

-- =================================================================
-- SECTION 11 — Realtime
-- =================================================================
alter publication supabase_realtime add table public.terrace_locations;
alter publication supabase_realtime add table public.terrace_location_favorites;
alter publication supabase_realtime add table public.terrace_events;
alter publication supabase_realtime add table public.terrace_event_options;
alter publication supabase_realtime add table public.terrace_availability;
alter publication supabase_realtime add table public.terrace_location_votes;
alter publication supabase_realtime add table public.terrace_attendance;
alter publication supabase_realtime add table public.terrace_location_ratings;

-- =========== 0017_poem_comments.sql ===========
-- =================================================================
-- OFFICE LORE — POETRY WALL: WRITTEN COMMENTS
-- =================================================================
-- Adds real written comments on poems, alongside (not replacing) the
-- existing emoji reactions in poem_reactions. Deliberately no XP
-- trigger -- comments are for conversation, not a new XP source (the
-- spec explicitly wants to avoid cheap XP-farming via short comments).
-- Same app-scoping pattern as every table since 0015: RLS gates on
-- public.is_app_member('officelore'), reusing the existing helper.
-- =================================================================

create table public.poem_comments (
  id uuid primary key default gen_random_uuid(),
  poem_id uuid not null references public.poems(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  content text not null check (char_length(content) <= 1000 and char_length(trim(content)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_poem_comments_updated_at
  before update on public.poem_comments
  for each row execute procedure public.set_updated_at();
-- "edited" is derived client-side (updated_at !== created_at), same
-- philosophy as every other derived-not-stored flag in this app --
-- no separate is_edited column needed.

create index poem_comments_poem_id_idx on public.poem_comments (poem_id);

alter table public.poem_comments enable row level security;

create policy "Poem comments: read" on public.poem_comments for select to authenticated
  using (public.is_app_member('officelore'));

-- anyone (including the poem's own author -- unlike reactions, there's
-- no self-comment restriction in the spec) may comment
create policy "Poem comments: authenticated may add own" on public.poem_comments for insert to authenticated
  with check (user_id = auth.uid() and public.is_app_member('officelore'));

create policy "Poem comments: only own comment may be edited" on public.poem_comments for update to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'))
  with check (user_id = auth.uid() and public.is_app_member('officelore'));

create policy "Poem comments: only own comment may be deleted" on public.poem_comments for delete to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

alter publication supabase_realtime add table public.poem_comments;

-- =========== 0018_abt_avatar_wardrobe.sql ===========
-- =================================================================
-- OFFICE LORE — THE ABT AVATAR & ROYAL WARDROBE
-- =================================================================
-- A visual customization layer on top of the existing Abt Dynasty
-- system (0004_abt_dynasty.sql). Does NOT change how the throne is
-- decided (trg_check_abt_throne / abt_reigns stay untouched except
-- one additive nullable column) — this only reads abt_reigns to
-- figure out (a) who may currently equip/claim, and (b) how many
-- cosmetic rewards a user has earned.
--
-- Only the current Abt Lord may equip an item or claim a Daily Royal
-- Pick — enforced server-side in the two RPCs below, not just in the
-- client. Standard items are available to every current lord from
-- day one and are never stored as "unlocked" rows (see catalog seed
-- below) — only earned daily-pick/milestone items get a
-- user_abt_cosmetics row. Milestones are permanent once earned,
-- independent of current lord status.
--
-- Same app-scoping pattern as every table since 0015: RLS gates on
-- public.is_app_member('officelore'), reusing the existing helper.
-- Run this once in the Supabase SQL Editor, after 0001-0017.
-- =================================================================

-- =================================================================
-- SECTION 1 — abt_cosmetic_items (the static catalog)
-- =================================================================
create table public.abt_cosmetic_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  flavor_text text,
  category text not null check (category in ('hair','headwear','armor','cape','weapon','accessory')),
  rarity text not null check (rarity in ('standard','common','rare','epic','legendary','dynasty')),
  unlock_type text not null check (unlock_type in ('standard','daily_pick','milestone')),
  milestone_days int, -- only set for unlock_type='milestone' (1/7/14/30/50/75/100)
  asset_key text not null, -- maps to the JS SVG shape registry, e.g. 'headwear.silver_crown'
  render_tint text, -- optional hex/CSS color recoloring a shared base silhouette (how variants are built)
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index abt_cosmetic_items_category_idx on public.abt_cosmetic_items (category);

-- =================================================================
-- SECTION 2 — user_abt_cosmetics (permanent per-user unlocks)
-- =================================================================
-- Standard items are NOT rows here — they're implicitly available to
-- every current lord (see catalog seed). Only earned daily-pick /
-- milestone items get a row, and it's permanent (never deleted).
create table public.user_abt_cosmetics (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  cosmetic_item_id uuid not null references public.abt_cosmetic_items(id),
  unlocked_at timestamptz not null default now(),
  unlock_source text not null check (unlock_source in ('daily_pick','milestone')),
  reign_id uuid references public.abt_reigns(id),
  unique (user_id, cosmetic_item_id)
);

create index user_abt_cosmetics_user_id_idx on public.user_abt_cosmetics (user_id);

-- =================================================================
-- SECTION 3 — abt_daily_rewards (the claim ledger)
-- =================================================================
create table public.abt_daily_rewards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  reign_id uuid not null references public.abt_reigns(id),
  reign_day int not null, -- which eligible day of that reign this claim used up
  cosmetic_item_id uuid not null references public.abt_cosmetic_items(id),
  claimed_at timestamptz not null default now(),
  unique (reign_id, reign_day) -- at most one Daily Royal Pick per reign-day, ever
);

create index abt_daily_rewards_user_id_idx on public.abt_daily_rewards (user_id);

-- =================================================================
-- SECTION 4 — abt_avatar_loadouts (current equipped state, one row/user)
-- =================================================================
create table public.abt_avatar_loadouts (
  user_id uuid primary key references public.profiles(id),
  hair_item_id uuid references public.abt_cosmetic_items(id),
  headwear_item_id uuid references public.abt_cosmetic_items(id),
  armor_item_id uuid references public.abt_cosmetic_items(id),
  cape_item_id uuid references public.abt_cosmetic_items(id),
  weapon_item_id uuid references public.abt_cosmetic_items(id),
  accessory_item_id uuid references public.abt_cosmetic_items(id),
  updated_at timestamptz not null default now()
);

create trigger trg_abt_avatar_loadouts_updated_at
  before update on public.abt_avatar_loadouts
  for each row execute procedure public.set_updated_at();

-- =================================================================
-- SECTION 5 — abt_reigns: one additive snapshot column
-- =================================================================
-- Populated automatically inside check_abt_throne() the moment a
-- reign closes (captures the outgoing lord's exact loadout as JSON
-- before closing the row). Purely an extra write in the same trigger
-- transaction — does not touch throne-decision logic at all. Not yet
-- rendered anywhere in the UI (first pass captures the data only, so
-- a future round can visualize historical avatars without a schema
-- change).
alter table public.abt_reigns add column ending_loadout_snapshot jsonb;

create or replace function public.check_abt_throne()
returns trigger as $$
declare
  v_leader_id uuid;
  v_leader_xp int;
  v_current record;
  v_current_lord_xp int;
  v_snapshot jsonb;
begin
  perform pg_advisory_xact_lock(918273645);

  select user_id, beer_xp into v_leader_id, v_leader_xp
  from public.user_xp_totals
  order by beer_xp desc, user_id
  limit 1;

  if v_leader_xp is null or v_leader_xp <= 0 then
    return new;
  end if;

  select * into v_current from public.abt_reigns where ended_at is null limit 1;

  if v_current is null then
    insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
    values (v_leader_id, now(), v_leader_xp);
    return new;
  end if;

  if v_current.user_id = v_leader_id then
    return new;
  end if;

  select beer_xp into v_current_lord_xp
  from public.user_xp_totals where user_id = v_current.user_id;

  if v_leader_xp > coalesce(v_current_lord_xp, 0) then
    select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = v_current.user_id;

    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_current_lord_xp, dethroned_by_user_id = v_leader_id,
          ending_loadout_snapshot = v_snapshot
      where id = v_current.id;

    insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
    values (v_leader_id, now(), v_leader_xp);
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;
-- trg_check_abt_throne (0004) already points at this function by name --
-- no change needed to the trigger itself.

-- =================================================================
-- SECTION 6 — equip_abt_item(): the only write path for loadouts
-- =================================================================
create or replace function public.equip_abt_item(p_category text, p_item_id uuid)
returns void as $$
declare
  v_item public.abt_cosmetic_items;
  v_is_lord boolean;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  select exists (
    select 1 from public.abt_reigns where user_id = auth.uid() and ended_at is null
  ) into v_is_lord;
  if not v_is_lord then
    raise exception 'Only the current Abt Lord may dress the Abt Avatar';
  end if;

  select * into v_item from public.abt_cosmetic_items where id = p_item_id and is_active = true;
  if v_item is null or v_item.category <> p_category then
    raise exception 'Unknown or mismatched cosmetic item';
  end if;

  if v_item.unlock_type <> 'standard' and not exists (
    select 1 from public.user_abt_cosmetics where user_id = auth.uid() and cosmetic_item_id = p_item_id
  ) then
    raise exception 'Item not yet unlocked';
  end if;

  insert into public.abt_avatar_loadouts (user_id) values (auth.uid())
  on conflict (user_id) do nothing;

  execute format('update public.abt_avatar_loadouts set %I = $1, updated_at = now() where user_id = $2', p_category || '_item_id')
    using p_item_id, auth.uid();
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.equip_abt_item(text, uuid) to authenticated;

-- =================================================================
-- SECTION 7 — claim_abt_daily_pick(): the only way to earn a
-- daily_pick item (milestones are granted separately, see section 8)
-- =================================================================
create or replace function public.claim_abt_daily_pick(p_cosmetic_item_id uuid)
returns void as $$
declare
  v_reign record;
  v_item public.abt_cosmetic_items;
  v_eligible_days int;
  v_claimed_days int;
  v_next_day int;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  -- serialize per user -- a fast double-click (or the same
  -- onAuthStateChange double-fire risk noted on sync_abt_milestones)
  -- could otherwise let two concurrent claims compute the same
  -- v_next_day and race into the (reign_id, reign_day) unique
  -- constraint as a raw, unhandled exception instead of being cleanly
  -- serialized. Same technique as check_abt_throne's advisory lock.
  perform pg_advisory_xact_lock(hashtext('claim_abt_daily_pick:' || auth.uid()::text));

  select * into v_reign from public.abt_reigns where user_id = auth.uid() and ended_at is null;
  if v_reign is null then
    raise exception 'Only the current Abt Lord may claim a Royal Pick';
  end if;

  -- eligible days across ALL of this user's reigns (past + current) --
  -- banked picks survive dethronement, matching getReignDays'/
  -- getTotalDaysInPower's exact day-math client-side
  select coalesce(sum(greatest(0, floor(extract(epoch from (coalesce(r.ended_at, now()) - r.started_at)) / 86400))), 0)
    into v_eligible_days
    from public.abt_reigns r where r.user_id = auth.uid();

  select count(*) into v_claimed_days from public.abt_daily_rewards where user_id = auth.uid();

  if v_eligible_days - v_claimed_days <= 0 then
    raise exception 'No Royal Pick available';
  end if;

  select * into v_item from public.abt_cosmetic_items where id = p_cosmetic_item_id and is_active = true;
  if v_item is null or v_item.unlock_type <> 'daily_pick' then
    raise exception 'Item is not a valid Daily Royal Pick choice';
  end if;
  if exists (select 1 from public.user_abt_cosmetics where user_id = auth.uid() and cosmetic_item_id = p_cosmetic_item_id) then
    raise exception 'Item already unlocked';
  end if;

  -- next unclaimed reign-day number, scoped to the CURRENT reign (the
  -- (reign_id, reign_day) unique constraint is the final backstop
  -- against a double-claim race)
  select coalesce(max(reign_day), 0) + 1 into v_next_day
    from public.abt_daily_rewards where reign_id = v_reign.id;

  insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source, reign_id)
    values (auth.uid(), p_cosmetic_item_id, 'daily_pick', v_reign.id);
  insert into public.abt_daily_rewards (user_id, reign_id, reign_day, cosmetic_item_id)
    values (auth.uid(), v_reign.id, v_next_day, p_cosmetic_item_id);
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.claim_abt_daily_pick(uuid) to authenticated;

-- =================================================================
-- SECTION 8 — sync_abt_milestones(): lazy-granted, permanent relics
-- =================================================================
-- No pg_cron in this project, so milestones are evaluated lazily —
-- called once per app load (see index.html) for whichever user is
-- logged in. A milestone "arrives" the next time the app loads after
-- the threshold is crossed, not at the exact millisecond, which is
-- fine since the app re-renders on every realtime change anyway.
-- Based on the LONGEST SINGLE reign (current or historical), per the
-- spec's "Reign 1 = 20 days, Reign 2 = 15 days -> Day 30 NOT unlocked"
-- example — deliberately different from the daily-pick pool, which
-- sums across all reigns.
create or replace function public.sync_abt_milestones()
returns setof public.abt_cosmetic_items as $$
declare
  v_longest_reign record;
  v_item public.abt_cosmetic_items;
  v_inserted uuid;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  -- this app's known onAuthStateChange behavior can call this function
  -- more than once for the same user in quick succession (token
  -- refresh / tab refocus, not just genuine login) -- serialize per
  -- user so two overlapping calls can never both pass the "not
  -- already owned" check and then race each other into the unique
  -- constraint below. Same technique as check_abt_throne's advisory
  -- lock (0004_abt_dynasty.sql).
  perform pg_advisory_xact_lock(hashtext('sync_abt_milestones:' || auth.uid()::text));

  for v_item in
    select * from public.abt_cosmetic_items
    where unlock_type = 'milestone' and is_active = true
    order by milestone_days asc
  loop
    if exists (select 1 from public.user_abt_cosmetics where user_id = auth.uid() and cosmetic_item_id = v_item.id) then
      continue; -- already owned, permanent, never re-evaluated
    end if;

    select r.id, greatest(0, floor(extract(epoch from (coalesce(r.ended_at, now()) - r.started_at)) / 86400)) as days
      into v_longest_reign
      from public.abt_reigns r
      where r.user_id = auth.uid()
      order by days desc
      limit 1;

    if v_longest_reign.days >= v_item.milestone_days then
      -- on conflict do nothing is a defense-in-depth backstop -- the
      -- advisory lock above already makes this practically impossible
      v_inserted := null;
      insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source, reign_id)
        values (auth.uid(), v_item.id, 'milestone', v_longest_reign.id)
        on conflict (user_id, cosmetic_item_id) do nothing
        returning cosmetic_item_id into v_inserted;
      if v_inserted is not null then
        return next v_item;
      end if;
    end if;
  end loop;

  return;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.sync_abt_milestones() to authenticated;

-- =================================================================
-- SECTION 9 — RLS. All 4 new tables: select gated on
-- is_app_member('officelore'); writes are RPC-only (no client
-- insert/update/delete policy anywhere), same "server decides" model
-- as abt_reigns itself.
-- =================================================================
alter table public.abt_cosmetic_items enable row level security;
create policy "Abt cosmetic items: read" on public.abt_cosmetic_items for select to authenticated
  using (public.is_app_member('officelore'));

alter table public.user_abt_cosmetics enable row level security;
create policy "User abt cosmetics: read" on public.user_abt_cosmetics for select to authenticated
  using (public.is_app_member('officelore'));

alter table public.abt_daily_rewards enable row level security;
create policy "Abt daily rewards: read" on public.abt_daily_rewards for select to authenticated
  using (public.is_app_member('officelore'));

alter table public.abt_avatar_loadouts enable row level security;
create policy "Abt avatar loadouts: read" on public.abt_avatar_loadouts for select to authenticated
  using (public.is_app_member('officelore'));

-- =================================================================
-- SECTION 10 — REALTIME
-- =================================================================
alter publication supabase_realtime add table public.user_abt_cosmetics;
alter publication supabase_realtime add table public.abt_daily_rewards;
alter publication supabase_realtime add table public.abt_avatar_loadouts;

-- =================================================================
-- SECTION 11 — catalog seed ("solid starter set")
-- =================================================================
-- Standard items: exactly the categories/examples from the spec,
-- always available to any current lord from day one, no
-- user_abt_cosmetics row needed. asset_key maps 1:1 to the JS
-- AVATAR_*_SHAPES registries in index.html.

-- hair (standard, 5)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Short Hair', 'Low maintenance, high authority.', 'hair', 'standard', 'standard', 'hair.short'),
  ('Long Hair', 'Flowing, dramatic, unnecessary.', 'hair', 'standard', 'standard', 'hair.long'),
  ('Slick Back', 'Combed with the confidence of a man who has never lost a round.', 'hair', 'standard', 'standard', 'hair.slick_back'),
  ('Messy Hair', 'The reigning look of someone who was up late defending the throne.', 'hair', 'standard', 'standard', 'hair.messy'),
  ('Bald', 'Nothing to hide, nothing to lose.', 'hair', 'standard', 'standard', 'hair.bald');

-- headwear (standard, 5)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('No Hat', 'The wind in your hair, the XP in your ledger.', 'headwear', 'standard', 'standard', 'headwear.none'),
  ('Simple Crown', 'A crown of questionable authority.', 'headwear', 'standard', 'standard', 'headwear.simple_crown'),
  ('Monk Hood', 'For the contemplative reign.', 'headwear', 'standard', 'standard', 'headwear.monk_hood'),
  ('Beer Cap', 'A bottle cap, worn with pride.', 'headwear', 'standard', 'standard', 'headwear.beer_cap'),
  ('Basic Knight Helmet', 'Standard-issue tavern-guard steel.', 'headwear', 'standard', 'standard', 'headwear.knight_helmet');

-- armor (standard, 5)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  ('Monk Robes', 'A vow of moderation, rarely kept.', 'armor', 'standard', 'standard', 'armor.robes', '#8a5a35'),
  ('Leather Armor', 'Tavern Guard Armor — smells faintly of hops.', 'armor', 'standard', 'standard', 'armor.leather', '#7a4a2c'),
  ('Basic Knight Armor', 'Knight of the Tap.', 'armor', 'standard', 'standard', 'armor.plate', '#9aa3ad'),
  ('Tavern Outfit', 'Practical. Stain-resistant. Mostly.', 'armor', 'standard', 'standard', 'armor.tunic', '#5a6b7a'),
  ('Royal Tunic', 'Fit for someone who definitely earned it.', 'armor', 'standard', 'standard', 'armor.tunic', '#8a2f3d');

-- cape (standard, 5, one silhouette + render_tint)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  ('No Cape', 'A capeless reign is still a reign.', 'cape', 'standard', 'standard', 'cape.none', null),
  ('Red Cape', 'Crimson, bold, slightly dry-clean-only.', 'cape', 'standard', 'standard', 'cape.base', '#b53a3a'),
  ('Green Cape', 'The color of hops and ambition.', 'cape', 'standard', 'standard', 'cape.base', '#3f7a4a'),
  ('Black Cape', 'Mysterious. Dramatic. Slightly too warm indoors.', 'cape', 'standard', 'standard', 'cape.base', '#2b2320'),
  ('Brown Traveller Cape', 'For the Abt Lord who journeys to the terrace and back.', 'cape', 'standard', 'standard', 'cape.base', '#6b4226');

-- weapon (standard, 6 incl. none, mixed silhouettes)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  ('No Weapon', 'Diplomacy first.', 'weapon', 'standard', 'standard', 'weapon.none', null),
  ('The Bottle Opener', 'Sharper than any sword, in the ways that matter.', 'weapon', 'standard', 'standard', 'weapon.bottle_opener', null),
  ('Sword', 'A blade for a lord with something to prove.', 'weapon', 'standard', 'standard', 'weapon.sword', '#c7ccd1'),
  ('Axe', 'Blunt authority.', 'weapon', 'standard', 'standard', 'weapon.axe', '#c7ccd1'),
  ('Wooden Staff', 'Staff of Fermentation, junior edition.', 'weapon', 'standard', 'standard', 'weapon.staff', '#8a5a35'),
  ('Beer Mug', 'The only weapon that has ever truly won a round.', 'weapon', 'standard', 'standard', 'weapon.mug', '#c98a1f');

-- accessory (standard, 6 incl. none)
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  ('None', 'Unaccessorized, undefeated.', 'accessory', 'standard', 'standard', 'accessory.none', null),
  ('Beer Mug', 'Always within reach.', 'accessory', 'standard', 'standard', 'accessory.mug', '#c98a1f'),
  ('Hop Necklace', 'Sacred Beer Token, entry-level.', 'accessory', 'standard', 'standard', 'accessory.necklace', '#6f8a3d'),
  ('Belt', 'Holds absolutely nothing, looks great.', 'accessory', 'standard', 'standard', 'accessory.belt', '#6b4226'),
  ('Small Shield', 'Defends against nothing but criticism.', 'accessory', 'standard', 'standard', 'accessory.shield', '#9aa3ad'),
  ('Tankard', 'Ceremonial, mostly empty.', 'accessory', 'standard', 'standard', 'accessory.tankard', '#cfa53d');

-- Daily-pick pool (common/rare/epic) — color/material variants of a
-- handful of shared base silhouettes, matching the spec's own
-- "items may have variants" guidance. ~19 items, comfortably covers
-- weeks of daily reign; more can be added later via a new seed
-- migration with zero code changes.
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key, render_tint) values
  -- headwear
  ('Silver Crown', 'Another completely necessary symbol of authority.', 'headwear', 'common', 'daily_pick', 'headwear.simple_crown', '#c7ccd1'),
  ('Hop Crown', 'Woven from the finest hops in the fridge.', 'headwear', 'common', 'daily_pick', 'headwear.hop_crown', '#6f8a3d'),
  ('Golden Winged Helmet', 'For a lord with somewhere important to fly.', 'headwear', 'rare', 'daily_pick', 'headwear.winged_helmet', '#cfa53d'),
  ('Crown of Questionable Authority', 'Fits surprisingly well.', 'headwear', 'rare', 'daily_pick', 'headwear.simple_crown', '#c98a1f'),
  -- armor tints
  ('Bronze Armor', 'Knight of the Tap, bronze division.', 'armor', 'common', 'daily_pick', 'armor.plate', '#b08d57'),
  ('Steel Armor', 'A cleaner shine than the standard-issue set.', 'armor', 'common', 'daily_pick', 'armor.plate', '#c7ccd1'),
  ('Dark Iron Armor', 'Armor of the Eternal Tap, junior edition.', 'armor', 'rare', 'daily_pick', 'armor.plate', '#3d3f45'),
  ('Blackened Steel Armor', 'Forged in a beer fridge, allegedly.', 'armor', 'rare', 'daily_pick', 'armor.plate', '#1f2126'),
  ('Golden Abt Plate', 'Reserved for a lord with taste.', 'armor', 'epic', 'daily_pick', 'armor.plate', '#e0b84e'),
  -- cape colors
  ('Burgundy Cape', 'Cape of Questionable Decisions, formal edition.', 'cape', 'common', 'daily_pick', 'cape.base', '#6e2c3a'),
  ('Forest Green Cape', 'Blends in at the terrace, stands out at the bar.', 'cape', 'common', 'daily_pick', 'cape.base', '#2f5233'),
  ('Midnight Cape', 'For late-round decision-making.', 'cape', 'common', 'daily_pick', 'cape.base', '#1b1f2e'),
  ('Navy Cape', 'Last Call Cloak, everyday edition.', 'cape', 'rare', 'daily_pick', 'cape.base', '#1f3a5f'),
  ('Cream Cape', 'Surprisingly hard to keep clean.', 'cape', 'rare', 'daily_pick', 'cape.base', '#f0e6d2'),
  ('Purple Cape', 'Mantle of the High Abt, casual Friday version.', 'cape', 'epic', 'daily_pick', 'cape.base', '#5a3f7a'),
  -- weapon materials
  ('Battle Axe', 'Hammer of Last Call''s cousin.', 'weapon', 'common', 'daily_pick', 'weapon.axe', '#e0b84e'),
  ('Hammer of Last Call', 'When the tap runs dry, this settles it.', 'weapon', 'rare', 'daily_pick', 'weapon.hammer', '#8a5a35'),
  ('Mace', 'The Pintbreaker.', 'weapon', 'rare', 'daily_pick', 'weapon.mace', '#9aa3ad'),
  ('Giant Bottle Opener', 'Same tool, considerably more legendary.', 'weapon', 'epic', 'daily_pick', 'weapon.bottle_opener', '#cfa53d'),
  -- accessories
  ('Golden Tankard', 'Perfect Pour Medal, drinkable edition.', 'accessory', 'common', 'daily_pick', 'accessory.tankard', '#e0b84e'),
  ('Sacred Beer Token', 'Grants no powers. Looks important.', 'accessory', 'rare', 'daily_pick', 'accessory.necklace', '#cfa53d'),
  ('Perfect Pour Medal', 'For services rendered to foam management.', 'accessory', 'epic', 'daily_pick', 'accessory.medal', '#e0b84e');

-- Milestone relics — fully bespoke, gold/gem accents, permanent once
-- earned regardless of current lord status. render_tint carries the
-- signature gold/prestige color; the JS renderer applies extra
-- glow/shimmer purely from rarity ('legendary'/'dynasty'), not from
-- unlock_type, so future non-milestone prestige items could reuse it.
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key, render_tint) values
  ('The First Crown', 'Every dynasty starts somewhere.', 'headwear', 'legendary', 'milestone', 1, 'headwear.first_crown', '#e0b84e'),
  ('Crimson Cape of the Seven Pints', 'A luxury far beyond the standard cape rack.', 'cape', 'legendary', 'milestone', 7, 'cape.seven_pints', '#8a1f2b'),
  ('The Sacred Abt Blade', 'Uniquely shaped. Subtly glowing. Deeply unnecessary.', 'weapon', 'legendary', 'milestone', 14, 'weapon.sacred_blade', '#e0b84e'),
  ('Armor of the Eternal Tap', 'Full plate, brass and gold detailing throughout.', 'armor', 'epic', 'milestone', 30, 'armor.eternal_tap', '#cfa53d'),
  ('Crown of Eternal Foam', 'Grand, gilded, faintly foam-flecked.', 'headwear', 'legendary', 'milestone', 50, 'headwear.eternal_foam', '#f0d98c'),
  ('Mantle of the High Abt', 'A cape and outfit combination reserved for legends.', 'cape', 'legendary', 'milestone', 75, 'cape.high_abt_mantle', '#3d1f5a'),
  ('The Eternal Abt Crown', 'Unmistakable proof: 100 days on the throne.', 'headwear', 'dynasty', 'milestone', 100, 'headwear.eternal_abt', '#f5d76e');

-- =========== 0019_abt_milestone_expansion.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: MILESTONE RELIC EXPANSION
-- =================================================================
-- Purely additive: new rows in abt_cosmetic_items only. Does not
-- touch, rename, or renumber any existing catalog row (Elien's
-- already-earned "The First Crown" keeps its exact id/reference) and
-- does not touch abt_reigns/throne logic at all. New milestone_days
-- thresholds slot into the existing sync_abt_milestones() loop
-- unchanged -- that function already evaluates every unlock_type=
-- 'milestone' row independently, so multiple relics sharing the same
-- milestone_days (see the Day 100 "full set") already just work.
--
-- Run this once in the Supabase SQL Editor, after 0018.
-- =================================================================

-- ---- headwear: one more escalation step between Day 1 and Day 50 ----
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key, render_tint) values
  ('Crown of Growing Ambition', 'It was smaller yesterday. It will be bigger tomorrow.', 'headwear', 'legendary', 'milestone', 25, 'headwear.growing_crown', '#e0b84e');

-- ---- armor: animal-themed milestone track, as requested ----
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key, render_tint) values
  ('Lionheart Armor', 'Mane of the Pride Alpha. Roars optional.', 'armor', 'epic', 'milestone', 5, 'armor.lion', '#c98a1f'),
  ('Grizzled Bear Armor', 'Hide of the Grizzled Abt. Smells vaguely of the forest.', 'armor', 'epic', 'milestone', 15, 'armor.bear', '#6b4a35'),
  ('Tiger-Stripe Armor', 'Stripes of the Silent Hunter. Not silent at all.', 'armor', 'epic', 'milestone', 25, 'armor.tiger', '#e0801f'),
  ('Armor of the Eternal Abt', 'Full gold-and-diamond plate. Unmistakably 100 days.', 'armor', 'dynasty', 'milestone', 100, 'armor.eternal_abt', '#f5d76e');

-- ---- cape: bigger, fur-trimmed, escalating bling ----
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key, render_tint) values
  ('Cloak of a Thousand Golden Threads', 'Fur-trimmed. Slightly too warm indoors, extremely worth it.', 'cape', 'epic', 'milestone', 35, 'cape.golden_threads', '#8a5a1f'),
  ('Cape of the Eternal Abt', 'Fur, gold, and 100 days of undeniable authority.', 'cape', 'dynasty', 'milestone', 100, 'cape.eternal_abt', '#3d1f5a');

-- ---- weapon: giant and dramatic ----
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key, render_tint) values
  ('Winged Warbow', 'An arrow that has never once been fired at another beer.', 'weapon', 'epic', 'milestone', 45, 'weapon.winged_bow', '#e0e6ea'),
  ('The Colossal Abt Blade', 'Comically, gloriously oversized.', 'weapon', 'epic', 'milestone', 60, 'weapon.colossal_blade', '#c7ccd1'),
  ('Blade of the Eternal Abt', 'The Sacred Abt Blade''s older, gaudier sibling.', 'weapon', 'dynasty', 'milestone', 100, 'weapon.eternal_blade', '#f5d76e');

-- ---- accessory: fun and absurd escalation, incl. a companion ----
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key, render_tint) values
  ('The Farmhorse Companion', 'A completely unnecessary but deeply loyal draft horse.', 'accessory', 'epic', 'milestone', 10, 'accessory.farmhorse', '#8a5a35'),
  ('Platter of Ten Tankards', 'Nobody asked for this many mugs. Everybody needed it.', 'accessory', 'rare', 'milestone', 20, 'accessory.mug_platter', '#c98a1f'),
  ('Diadem of a Thousand Feasts', 'Understated, until you notice the gemstones.', 'accessory', 'legendary', 'milestone', 90, 'accessory.diadem', '#f5d76e');

-- =========== 0020_abt_dragon_set.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: DRAGON MILESTONE SET
-- =================================================================
-- Purely additive: 2 new catalog rows, same Day-40 threshold, granted
-- together the same way the Day-100 "full set" already is (multiple
-- unlock_type='milestone' rows sharing one milestone_days value --
-- sync_abt_milestones() already evaluates each row independently, no
-- code/function change needed). Does not touch any existing row.
--
-- Run this once in the Supabase SQL Editor, after 0019.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key, render_tint) values
  ('Dragon Armor', 'Scaled plate with real wings. Roaring not included.', 'armor', 'legendary', 'milestone', 40, 'armor.dragon', '#2f7a4a'),
  ('Dragon-Head Helm', 'A dragon''s skull, worn as a hat. Deeply reasonable.', 'headwear', 'legendary', 'milestone', 40, 'headwear.dragon_helm', '#2f7a4a');

-- =========== 0021_abt_body_types_and_armor_art.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: BODY TYPES + ILLUSTRATED ARMOR ART
-- =================================================================
-- Two additive changes, run together:
--
-- 1. Adds "body" as a 7th cosmetic category (female / male / male
--    muscle / male thin), all Standard (available from day one, same
--    as every other Standard item). Widens the category check
--    constraint, adds one nullable column to abt_avatar_loadouts.
--    No RLS/RPC changes needed -- equip_abt_item() already resolves
--    the target column generically via `p_category || '_item_id'`.
--
-- 2. Elien illustrated a full matching outfit set for all 4 body
--    types (abtlord-images/base-armors.png) plus a Tiger-Stripe
--    milestone variant (tiger-armor.png). This UPDATEs the 5
--    existing standard armor rows' asset_key (and names, to match
--    her labels) to point at the new art instead of the old flat SVG
--    shapes -- no new rows needed, no existing unlocks/ownership
--    touched (standard items were never tracked per-user anyway).
--    'Tiger-Stripe Armor' already used asset_key='armor.tiger', so it
--    needs no change here. Every other armor item (the 5 daily-pick
--    'armor.plate' tints, and the lion/bear/eternal_tap/eternal_abt
--    milestones) has no illustrated art yet -- the client filters
--    those out of the Wardrobe grid rather than rendering a
--    mismatched/missing image, exactly as it already does for 'cape'.
--
-- Run this once in the Supabase SQL Editor, after 0020.
-- =================================================================

do $$
declare
  v_constraint_name text;
begin
  select conname into v_constraint_name
  from pg_constraint
  where conrelid = 'public.abt_cosmetic_items'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%category%';
  if v_constraint_name is not null then
    execute format('alter table public.abt_cosmetic_items drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.abt_cosmetic_items add constraint abt_cosmetic_items_category_check
  check (category in ('hair','headwear','armor','cape','weapon','accessory','body'));

alter table public.abt_avatar_loadouts add column if not exists body_item_id uuid references public.abt_cosmetic_items(id);

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key)
select v.name, v.flavor_text, 'body', 'standard', 'standard', v.asset_key
from (values
  ('Female', 'The default look for a lord who has earned it.', 'body.female'),
  ('Male', 'Standard issue. Perfectly respectable.', 'body.male'),
  ('Male (Muscle)', 'Definitely earned through beer alone.', 'body.male_muscle'),
  ('Male (Thin)', 'Lean, mean, questionable-decision-making machine.', 'body.male_thin')
) as v(name, flavor_text, asset_key)
where not exists (
  select 1 from public.abt_cosmetic_items existing where existing.asset_key = v.asset_key
);

-- ---- illustrated armor: repoint the 5 existing standard rows ----
update public.abt_cosmetic_items set asset_key = 'armor.monk_robes'
  where category = 'armor' and unlock_type = 'standard' and name = 'Monk Robes';

update public.abt_cosmetic_items set name = 'Leather Ranger', asset_key = 'armor.leather_ranger'
  where category = 'armor' and unlock_type = 'standard' and name = 'Leather Armor';

update public.abt_cosmetic_items set name = 'Knight Armor', asset_key = 'armor.knight_armor'
  where category = 'armor' and unlock_type = 'standard' and name = 'Basic Knight Armor';

update public.abt_cosmetic_items set asset_key = 'armor.tavern_outfit'
  where category = 'armor' and unlock_type = 'standard' and name = 'Tavern Outfit';

update public.abt_cosmetic_items set name = 'Royal Guard', asset_key = 'armor.royal_guard'
  where category = 'armor' and unlock_type = 'standard' and name = 'Royal Tunic';

-- =========== 0022_abt_illustrated_legendary_armor.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: ILLUSTRATED LEGENDARY ARMOR
-- =================================================================
-- Elien illustrated full-character art (head+body+outfit, one image
-- per body type) for several existing milestone armors, replacing
-- the flat SVG placeholders with proper artwork. Repoints existing
-- rows' asset_key only -- no new day thresholds, no ownership touched
-- (already-earned items keep their id, just look better now). Adds
-- 2 new milestone relics for the extra Ice Bear / Ice Dragon sets.
--
-- The 5 standard armor styles (Monk Robes/Leather Ranger/Knight
-- Armor/Royal Guard/Tavern Outfit) and Tiger-Stripe Armor already use
-- the correct asset_key from 0021 -- their illustrated art existing
-- now is a client-side-only change, no DB update needed here.
--
-- Run this once in the Supabase SQL Editor, after 0021.
-- =================================================================

update public.abt_cosmetic_items set asset_key = 'armor.brown_bear'
  where category = 'armor' and unlock_type = 'milestone' and name = 'Grizzled Bear Armor';

update public.abt_cosmetic_items set name = 'Fire Dragon Armor', asset_key = 'armor.fire_dragon'
  where category = 'armor' and unlock_type = 'milestone' and name = 'Dragon Armor';

update public.abt_cosmetic_items set name = 'Armor of the Eternal Abt Dynasty', asset_key = 'armor.eternal_abt_dynasty'
  where category = 'armor' and unlock_type = 'milestone' and name = 'Armor of the Eternal Abt';

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key) values
  ('Frostbite Bear Armor', 'Hide of the Grizzled Abt, now with 30% more frostbite.', 'armor', 'legendary', 'milestone', 20, 'armor.ice_bear'),
  ('Glacial Dragon Armor', 'The Fire Dragon''s colder, more judgmental sibling.', 'armor', 'legendary', 'milestone', 65, 'armor.ice_dragon');

-- =========== 0023_abt_illustrated_weapons.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: ILLUSTRATED STANDARD WEAPONS
-- =================================================================
-- Elien illustrated 12 held-item icons as the new standard weapon
-- set. 3 of them (sword/staff/mug) reuse the asset_key of an
-- existing standard item -- no DB change needed there, the client
-- picks up the illustrated art automatically over the old SVG shape.
-- The other 8 are genuinely new concepts, added here as new standard
-- weapon rows (fresh asset_keys, so they don't collide with the
-- existing daily-pick 'weapon.hammer'/'weapon.axe'/etc. rows).
--
-- Run this once in the Supabase SQL Editor, after 0022.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Warhammer', 'For a lord who has strong opinions about doors.', 'weapon', 'standard', 'standard', 'weapon.warhammer'),
  ('Dagger', 'Small, sharp, surprisingly good at opening bottles.', 'weapon', 'standard', 'standard', 'weapon.dagger'),
  ('Hunting Bow', 'Never actually fired at anything but the beer fridge.', 'weapon', 'standard', 'standard', 'weapon.hunting_bow'),
  ('St. Bernardus Bottle', 'A weapon in the loosest possible sense.', 'weapon', 'standard', 'standard', 'weapon.beer_bottle'),
  ('Round Shield', 'Defends against nothing but criticism, now in weapon-slot form.', 'weapon', 'standard', 'standard', 'weapon.round_shield'),
  ('Crossbow', 'Reload time: however long the current round takes.', 'weapon', 'standard', 'standard', 'weapon.crossbow'),
  ('Torch', 'For dramatically lighting the way to the fridge.', 'weapon', 'standard', 'standard', 'weapon.torch'),
  ('Spellbook', 'Contains zero spells. Looks very authoritative regardless.', 'weapon', 'standard', 'standard', 'weapon.spellbook');

-- =========== 0024_abt_illustrated_standard_headwear.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: ILLUSTRATED STANDARD HEADWEAR
-- =================================================================
-- Elien illustrated 31 headwear icons (crowns, hats, animal hoods,
-- accessories) as a new standard headwear set, available to everyone
-- from day one -- same idea as 0023's standard weapons. Purely
-- additive: fresh asset_keys, no existing row touched (the existing
-- 'headwear.simple_crown' asset_key stays flat-SVG, since it's shared
-- by tinted daily-pick variants that would lose their tint if
-- repointed to a single illustrated image).
--
-- Run this once in the Supabase SQL Editor, after 0023.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Gilded Crown', 'Classic. Effective. Slightly too big.', 'headwear', 'standard', 'standard', 'headwear.gold_crown_simple'),
  ('Jeweled Crown', 'More jewels than the last one. That''s the whole pitch.', 'headwear', 'standard', 'standard', 'headwear.gold_crown_jeweled'),
  ('Royal Velvet Crown', 'Fur trim included. Dry-clean only.', 'headwear', 'standard', 'standard', 'headwear.royal_crown_red'),
  ('Sapphire Tiara', 'Delicate, gleaming, and completely unearned.', 'headwear', 'standard', 'standard', 'headwear.tiara_laurel_gem'),
  ('Laurel Wreath', 'For lords who peaked in ancient Rome.', 'headwear', 'standard', 'standard', 'headwear.laurel_wreath'),
  ('Daisy Crown', 'Soft power. Very soft.', 'headwear', 'standard', 'standard', 'headwear.flower_crown'),
  ('Sun Hat', 'For the lord who reigns from a beach chair.', 'headwear', 'standard', 'standard', 'headwear.straw_hat_flower'),
  ('Ranch Hat', 'Yee. And also haw.', 'headwear', 'standard', 'standard', 'headwear.cowboy_hat_badge'),
  ('Sheriff''s Hat', 'Protecting the fridge, one star at a time.', 'headwear', 'standard', 'standard', 'headwear.cowboy_hat_star'),
  ('Pawprint Cap', 'Blue, white, and unreasonably loyal.', 'headwear', 'standard', 'standard', 'headwear.cap_paw_blue'),
  ('Sly Fox Cap', 'For lords who see everything and admit nothing.', 'headwear', 'standard', 'standard', 'headwear.cap_fox_black'),
  ('Cozy Beanie', 'Pompom included. Dignity optional.', 'headwear', 'standard', 'standard', 'headwear.beanie_paw_green'),
  ('Formal Top Hat', 'Extremely serious. Extremely a paw badge.', 'headwear', 'standard', 'standard', 'headwear.top_hat_paw'),
  ('Musketeer Hat', 'One for all, and mostly for the Abt Lord.', 'headwear', 'standard', 'standard', 'headwear.musketeer_hat'),
  ('Wizard''s Hat', 'Grants no spells. Grants excellent posture.', 'headwear', 'standard', 'standard', 'headwear.wizard_hat'),
  ('Party Hat', 'It is always someone''s reign-iversary somewhere.', 'headwear', 'standard', 'standard', 'headwear.party_hat'),
  ('Aviator Cap', 'For lords about to make a very questionable landing.', 'headwear', 'standard', 'standard', 'headwear.aviator_cap'),
  ('Viking Helm', 'Horns purely decorative. Please don''t headbutt anything.', 'headwear', 'standard', 'standard', 'headwear.viking_helmet'),
  ('Brown Bear Hood', 'Warm, fuzzy, mildly threatening.', 'headwear', 'standard', 'standard', 'headwear.bear_hood_brown'),
  ('Polar Bear Hood', 'Now with a decorative ice gem.', 'headwear', 'standard', 'standard', 'headwear.bear_hood_white'),
  ('Wolf Hood', 'Runs with a pack of exactly one.', 'headwear', 'standard', 'standard', 'headwear.wolf_hood'),
  ('Fox Hood', 'Cunning not included, unfortunately.', 'headwear', 'standard', 'standard', 'headwear.fox_hood'),
  ('Frog Hood', 'Ribbiting fashion choice.', 'headwear', 'standard', 'standard', 'headwear.frog_hood'),
  ('Chicken Hood', 'Bold. Fearless. Slightly egg-shaped.', 'headwear', 'standard', 'standard', 'headwear.chicken_hood'),
  ('Studio Headphones', 'For carefully curating the throne-room playlist.', 'headwear', 'standard', 'standard', 'headwear.headphones_paw'),
  ('Steampunk Goggles', 'Purpose unclear. Vibe immaculate.', 'headwear', 'standard', 'standard', 'headwear.steampunk_goggles'),
  ('Red Bandana', 'Simple. Practical. Slightly outlaw-coded.', 'headwear', 'standard', 'standard', 'headwear.bandana_red'),
  ('Blue Pawprint Bandana', 'The loyal cousin of the red one.', 'headwear', 'standard', 'standard', 'headwear.bandana_blue_paw'),
  ('White Lily', 'Tucked in, no questions asked.', 'headwear', 'standard', 'standard', 'headwear.flower_white'),
  ('Red Rose', 'A single rose. Extremely dramatic energy.', 'headwear', 'standard', 'standard', 'headwear.flower_rose'),
  ('Jack-o''-Lantern Hat', 'A pumpkin, a ghost, and questionable judgment.', 'headwear', 'standard', 'standard', 'headwear.witch_pumpkin');

-- =========== 0025_abt_illustrated_legendary_headwear.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: ILLUSTRATED LEGENDARY HEADWEAR
-- =================================================================
-- Elien illustrated 12 legendary headwear pieces. 5 of them are a
-- direct thematic match for an existing milestone crown and simply
-- repoint that row's asset_key to the new illustrated art (same
-- pattern as 0022 for armor) -- no day/name/ownership change, already-
-- earned items just look better now. The other 7 are new concepts,
-- added as brand new milestone headwear rows at previously-unused
-- reign-day thresholds.
--
-- Run this once in the Supabase SQL Editor, after 0024.
-- =================================================================

-- Repoint 5 existing milestone crowns to illustrated art
update public.abt_cosmetic_items set asset_key = 'headwear.red_gold_lion_crown'
  where category = 'headwear' and unlock_type = 'milestone' and name = 'The First Crown';

update public.abt_cosmetic_items set asset_key = 'headwear.dark_spiked_crown'
  where category = 'headwear' and unlock_type = 'milestone' and name = 'Crown of Growing Ambition';

update public.abt_cosmetic_items set asset_key = 'headwear.dragon_horn_helm'
  where category = 'headwear' and unlock_type = 'milestone' and name = 'Dragon-Head Helm';

update public.abt_cosmetic_items set asset_key = 'headwear.abtlord_beer_crown'
  where category = 'headwear' and unlock_type = 'milestone' and name = 'Crown of Eternal Foam';

update public.abt_cosmetic_items set asset_key = 'headwear.angel_halo_wings'
  where category = 'headwear' and unlock_type = 'milestone' and name = 'The Eternal Abt Crown';

-- 7 new milestone headwear relics at previously-unused day thresholds
insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key) values
  ('Frostglass Tiara', 'Delicate, glittering, and somehow still standing after all these days.', 'headwear', 'legendary', 'milestone', 3, 'headwear.ice_crystal_tiara'),
  ('Winterfang Hood', 'The pack respects seniority. You have seniority.', 'headwear', 'legendary', 'milestone', 12, 'headwear.white_wolf_hood'),
  ('Amethyst Shower Tiara', 'It rains gemstones when you''ve reigned this long.', 'headwear', 'legendary', 'milestone', 18, 'headwear.purple_crystal_tiara'),
  ('Chieftain''s Bear Crown', 'A small crown on a large, unbothered bear.', 'headwear', 'legendary', 'milestone', 33, 'headwear.crowned_bear_hood'),
  ('Circlet of the Wild Antlers', 'Grown, not forged. Deeply unauthorized by HR.', 'headwear', 'legendary', 'milestone', 55, 'headwear.antler_circlet'),
  ('Corsair''s Plumed Hat', 'Yer a long-reigning scoundrel, and there be no code of conduct violation here.', 'headwear', 'legendary', 'milestone', 70, 'headwear.pirate_tricorn'),
  ('Oni Warlord Mask', 'Face of a demon. Spreadsheet of a bureaucrat.', 'headwear', 'legendary', 'milestone', 85, 'headwear.oni_demon_helm');

-- =========== 0026_abt_illustrated_daily_pick_headwear.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: ILLUSTRATED DAILY-PICK HEADWEAR
-- =================================================================
-- Elien illustrated 20 fun/meme-themed headwear pieces for the Daily
-- Royal Pick pool. Purely additive: fresh asset_keys, no existing row
-- touched. Rarity spread mirrors the existing daily_pick set (mostly
-- common/rare, a few epic for the more elaborate pieces) so the
-- deterministic 3-choice offer stays varied.
--
-- Run this once in the Supabase SQL Editor, after 0025.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Deal With It Crown', 'Pixelated shades. Undeniable authority.', 'headwear', 'rare', 'daily_pick', 'headwear.swag_crown_shades'),
  ('Beer Mode Backpack', 'A hands-free hydration system. For beer.', 'headwear', 'epic', 'daily_pick', 'headwear.beer_mode_cap'),
  ('Jester''s Cap', 'The wisest fool ever to hold the throne.', 'headwear', 'rare', 'daily_pick', 'headwear.jester_hat'),
  ('Disco Helmet', 'Saturday night at the office, apparently.', 'headwear', 'epic', 'daily_pick', 'headwear.disco_ball_shades'),
  ('Inflatable Flamingo', 'Worn as a hat. No further questions.', 'headwear', 'epic', 'daily_pick', 'headwear.flamingo_float'),
  ('Six-Pack Crown', 'Fully loaded. Somehow still standing upright.', 'headwear', 'common', 'daily_pick', 'headwear.beer_bottle_crown'),
  ('Frothy Top Hat', 'Formalwear, reimagined by a brewery.', 'headwear', 'common', 'daily_pick', 'headwear.beer_mug_hat'),
  ('Majestic Unicorn Hood', 'Rare, magical, deeply extra.', 'headwear', 'epic', 'daily_pick', 'headwear.unicorn_horn'),
  ('Bottled Royalty', 'Every bottle a tiny throne of its own.', 'headwear', 'common', 'daily_pick', 'headwear.royal_beer_crown'),
  ('Brewmaster''s Peak', 'For a lord of unusually specific expertise.', 'headwear', 'rare', 'daily_pick', 'headwear.wizard_beer_hat'),
  ('Braided Raider Helm', 'Pillages nothing but the fridge.', 'headwear', 'common', 'daily_pick', 'headwear.viking_braids'),
  ('Rainbow Goggle Panda', 'Sees the world in full color. Mostly beer-colored.', 'headwear', 'rare', 'daily_pick', 'headwear.panda_goggles'),
  ('Captain''s Bearing', 'Commands a fleet of exactly zero ships.', 'headwear', 'common', 'daily_pick', 'headwear.captain_hat'),
  ('Outlaw Bandana Hat', 'Wanted: for excessive reign length.', 'headwear', 'common', 'daily_pick', 'headwear.cowboy_bandana'),
  ('Taco Sombrero ''Stache', 'A full meal and a mustache in one hat.', 'headwear', 'epic', 'daily_pick', 'headwear.taco_mustache'),
  ('Blockhead Shades', 'Ssss. Deeply unbothered.', 'headwear', 'rare', 'daily_pick', 'headwear.creeper_shades'),
  ('Gamer Ears Headset', 'Callouts optional. Paw print mandatory.', 'headwear', 'rare', 'daily_pick', 'headwear.cat_ear_headphones'),
  ('Beach Day Hat', 'On break from ruling, technically.', 'headwear', 'common', 'daily_pick', 'headwear.sun_hat_tropical'),
  ('Living Hedge Wig', 'Fully landscaped. Butterflies included, free of charge.', 'headwear', 'epic', 'daily_pick', 'headwear.garden_bush'),
  ('Rainbow Clown Wig', 'Honk if you''ve reigned longer than expected.', 'headwear', 'rare', 'daily_pick', 'headwear.clown_wig');

-- =========== 0027_cleanup_duplicate_daily_pick_headwear.sql ===========
-- =================================================================
-- OFFICE LORE — CLEANUP: DUPLICATE DAILY-PICK HEADWEAR FROM 0026
-- =================================================================
-- 0026 was accidentally run twice, inserting each of the 20 new
-- daily-pick headwear rows twice. Nothing had claimed/equipped any
-- of them yet (verified against user_abt_cosmetics/abt_daily_rewards
-- before writing this), so it's safe to just delete the newer
-- duplicate of each pair, keeping the earliest-created row.
--
-- Run this once in the Supabase SQL Editor, after 0026.
-- =================================================================

delete from public.abt_cosmetic_items a
  using public.abt_cosmetic_items b
  where a.category = 'headwear'
    and a.unlock_type = 'daily_pick'
    and a.asset_key = b.asset_key
    and a.created_at > b.created_at;

-- =========== 0028_abt_illustrated_standard_accessories.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: ILLUSTRATED STANDARD ACCESSORIES
-- =================================================================
-- Elien illustrated 22 accessory pieces (drinks, a whip, magic wands,
-- shields, a serving tray, a lantern) as a new standard accessory
-- set, available to everyone from day one -- same idea as 0024's
-- standard headwear. Purely additive: fresh asset_keys, no existing
-- row touched.
--
-- Run this once in the Supabase SQL Editor, after 0027.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Chimay Mug', 'A classic. No further introduction needed.', 'accessory', 'standard', 'standard', 'accessory.chimay_mug'),
  ('Dark Ale Glass', 'St. Bernardus, properly poured.', 'accessory', 'standard', 'standard', 'accessory.dark_ale_glass'),
  ('St. Bernardus Bottle', 'The label does the talking.', 'accessory', 'standard', 'standard', 'accessory.st_bernardus_bottle'),
  ('Bottle of Champagne', 'For celebrating absolutely anything.', 'accessory', 'standard', 'standard', 'accessory.champagne_bottle'),
  ('Champagne Flute', 'Bubbles included. Achievements not required.', 'accessory', 'standard', 'standard', 'accessory.champagne_flute'),
  ('Glass of Red Wine', 'Sophisticated. Mostly for the aesthetic.', 'accessory', 'standard', 'standard', 'accessory.red_wine_glass'),
  ('Aperol Spritz', 'Orange, bubbly, deeply on-brand for a terrace.', 'accessory', 'standard', 'standard', 'accessory.aperol_spritz'),
  ('Leather Whip', 'For cracking down on slow rounds.', 'accessory', 'standard', 'standard', 'accessory.leather_whip'),
  ('Blue Crystal Wand', 'Channels pure, unearned confidence.', 'accessory', 'standard', 'standard', 'accessory.blue_crystal_wand'),
  ('Gold Star Wand', 'Grants wishes. Mostly for more beer.', 'accessory', 'standard', 'standard', 'accessory.gold_star_wand'),
  ('Paw Scepter', 'Ceremonial. Extremely pettable.', 'accessory', 'standard', 'standard', 'accessory.paw_scepter'),
  ('Purple Crystal Wand', 'The blue one''s moodier cousin.', 'accessory', 'standard', 'standard', 'accessory.purple_crystal_wand'),
  ('Paw Round Shield', 'Defends the honor of the office dog.', 'accessory', 'standard', 'standard', 'accessory.paw_round_shield'),
  ('Lion Crest Shield', 'Borrowed heraldry. Nobody''s checking.', 'accessory', 'standard', 'standard', 'accessory.lion_crest_shield'),
  ('Viking Round Shield', 'Raided nothing but the snack drawer.', 'accessory', 'standard', 'standard', 'accessory.viking_round_shield'),
  ('Abt Lord Barrel Shield', 'A literal barrel. Extremely on theme.', 'accessory', 'standard', 'standard', 'accessory.abtlord_barrel_shield'),
  ('Lion Sun Shield', 'Radiates authority and also just sunlight.', 'accessory', 'standard', 'standard', 'accessory.lion_sun_shield'),
  ('Wooden Paw Shield', 'Hand-carved. Paw-approved.', 'accessory', 'standard', 'standard', 'accessory.wooden_paw_shield'),
  ('Beer Serving Tray', 'White-glove treatment for brown bottles.', 'accessory', 'standard', 'standard', 'accessory.beer_serving_tray'),
  ('Beer Bottle Belt', 'Ammunition, technically.', 'accessory', 'standard', 'standard', 'accessory.beer_bottle_belt'),
  ('Wine Holster', 'Quick-draw, for emergencies.', 'accessory', 'standard', 'standard', 'accessory.wine_holster'),
  ('Brass Lantern', 'Lights the way to the fridge, mostly.', 'accessory', 'standard', 'standard', 'accessory.brass_lantern');

-- =========== 0029_abt_companion_category.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: THE ABT COMPANION CATEGORY
-- =================================================================
-- Adds "companion" as a new cosmetic category -- an illustrated pet
-- standing beside the Abt Lord. Takes the Wardrobe slot that 'cape'
-- used to occupy (cape stays in the data model, still excluded from
-- the UI/render composition, untouched by this migration). No RLS/
-- RPC changes needed -- equip_abt_item() already resolves the target
-- column generically via `p_category || '_item_id'`.
--
-- Elien illustrated 8 standard companions (a royal cat, a black cat,
-- a golden retriever, a german shepherd, a baby goat, a lamb, a
-- donkey, and a pony), all available from day one, plus a "No
-- Companion" default matching every other category's none option.
--
-- Run this once in the Supabase SQL Editor, after 0028.
-- =================================================================

do $$
declare
  v_constraint_name text;
begin
  select conname into v_constraint_name
  from pg_constraint
  where conrelid = 'public.abt_cosmetic_items'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%category%';
  if v_constraint_name is not null then
    execute format('alter table public.abt_cosmetic_items drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.abt_cosmetic_items add constraint abt_cosmetic_items_category_check
  check (category in ('hair','headwear','armor','cape','companion','weapon','accessory','body'));

alter table public.abt_avatar_loadouts add column if not exists companion_item_id uuid references public.abt_cosmetic_items(id);

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('No Companion', 'Reigning alone. Bold choice.', 'companion', 'standard', 'standard', 'companion.none'),
  ('Royal Cat', 'Crowned, unbothered, technically outranks you.', 'companion', 'standard', 'standard', 'companion.royal_cat'),
  ('Black Cat', 'Bad luck for everyone except the Abt Lord.', 'companion', 'standard', 'standard', 'companion.black_cat'),
  ('Golden Retriever', 'Guards the throne. Mostly guards the fridge.', 'companion', 'standard', 'standard', 'companion.golden_retriever'),
  ('German Shepherd', 'Official Captain of the Royal Guard.', 'companion', 'standard', 'standard', 'companion.german_shepherd'),
  ('Baby Goat', 'Snacks on the hedge accessory when nobody''s looking.', 'companion', 'standard', 'standard', 'companion.baby_goat'),
  ('Lamb', 'Soft, loyal, occasionally mistaken for foam.', 'companion', 'standard', 'standard', 'companion.lamb'),
  ('Royal Donkey', 'Carries the good beer. Never complains.', 'companion', 'standard', 'standard', 'companion.donkey'),
  ('Royal Pony', 'Saddled up for absolutely no reason.', 'companion', 'standard', 'standard', 'companion.pony');

-- =========== 0030_abt_companion_daily_pick.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: COMPANION DAILY-PICK SET
-- =================================================================
-- Elien illustrated 6 armored/regal companions (a black horse, a
-- leopard, a buffalo, a penguin, a kitten, and an eagle) for the
-- Daily Royal Pick pool -- same idea as 0026's daily-pick headwear.
-- Purely additive: fresh asset_keys, no existing row touched.
--
-- Run this once in the Supabase SQL Editor, after 0029.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Royal Warhorse', 'Feathered hooves, unshakeable poise, one banner.', 'companion', 'epic', 'daily_pick', 'companion.royal_black_horse'),
  ('Royal Leopard', 'Prowls the office in a very small cape.', 'companion', 'epic', 'daily_pick', 'companion.royal_leopard'),
  ('Royal Buffalo', 'Nose ring, chain, banner. Fully committed.', 'companion', 'epic', 'daily_pick', 'companion.royal_buffalo'),
  ('Royal Penguin', 'Scarf, cape, and a mug of St. Bernardus. Living the dream.', 'companion', 'rare', 'daily_pick', 'companion.royal_penguin'),
  ('Royal Kitten', 'Tiny crown, enormous authority.', 'companion', 'common', 'daily_pick', 'companion.royal_kitten'),
  ('Royal Eagle', 'Flies the banner. Files the paperwork never.', 'companion', 'epic', 'daily_pick', 'companion.royal_eagle');

-- =========== 0031_abt_companion_legendary.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: LEGENDARY COMPANIONS
-- =================================================================
-- Elien illustrated 4 legendary companions (a royal lion, an ice
-- tiger, a St. Bernardus hound, and a Royal T-Rex) as new milestone
-- rewards -- same idea as 0025's legendary headwear. Purely
-- additive: fresh asset_keys and milestone_days, no existing row
-- touched. Days chosen to not collide with any existing milestone
-- threshold across any category.
--
-- Run this once in the Supabase SQL Editor, after 0030.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key) values
  ('Royal Lion', 'Mane, crown, three separate "Abt Lord" medallions. No notes.', 'companion', 'legendary', 'milestone', 8, 'companion.royal_lion'),
  ('Frost Tiger', 'Radiates cold. Radiates authority. Mostly cold.', 'companion', 'legendary', 'milestone', 22, 'companion.ice_tiger'),
  ('St. Bernardus Hound', 'Carries the good barrel. Never spills a drop.', 'companion', 'legendary', 'milestone', 48, 'companion.st_bernard'),
  ('Royal T-Rex', 'Tiny arms, enormous banner, undisputed apex predator of the office.', 'companion', 'legendary', 'milestone', 95, 'companion.royal_trex');

-- =========== 0032_abt_remove_superseded_placeholders.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: REMOVE SUPERSEDED PLACEHOLDER ITEMS
-- =================================================================
-- Cleans up the flat-SVG placeholder content built before Elien's
-- illustrated art arrived, now that it's fully superseded:
--
--  - 'hair' (5 standard items): the category was disabled from the
--    Wardrobe the moment illustrated bodies arrived (hair is baked
--    into the body art) and has never been selectable since.
--  - 'cape' STANDARD tier only (5 items, incl. "No Cape"): the
--    category is disabled (superseded by the new 'companion' slot),
--    but its daily_pick (6) and milestone (4) rows are LEFT IN PLACE
--    -- they're still real earned/earnable rewards (one, "Purple
--    Cape", is already owned by a user) with no illustrated
--    replacement yet, so removing them would be a functional loss,
--    not a cleanup.
--  - 4 old standard headwear rows (Simple Crown/Monk Hood/Beer
--    Cap/Basic Knight Helmet) -- fully superseded by the 31
--    illustrated standard headwear items from 0024. "No Hat" is kept
--    (still the default). The 'headwear.simple_crown' flat SVG shape
--    stays in the client -- still used by 2 daily-pick items with
--    tints (Silver Crown, Crown of Questionable Authority).
--  - 5 old standard accessory rows (Beer Mug/Hop Necklace/Belt/Small
--    Shield/Tankard) -- fully superseded by the 22 illustrated
--    standard accessories from 0028. "None" is kept (still the
--    default). The flat shapes for necklace/tankard stay in the
--    client -- still used by 2 tinted daily-pick items.
--
-- Verified before writing this: none of these 19 rows are referenced
-- by any user_abt_cosmetics row (standard items never are). One user
-- currently has "Long Hair" set as their (invisible, unrendered)
-- hair_item_id -- cleared first so the delete doesn't hit the FK.
--
-- Run this once in the Supabase SQL Editor, after 0031.
-- =================================================================

update public.abt_avatar_loadouts set hair_item_id = null
where hair_item_id in (
  select id from public.abt_cosmetic_items where category = 'hair'
);

delete from public.abt_cosmetic_items
where (category = 'hair' and unlock_type = 'standard')
   or (category = 'cape' and unlock_type = 'standard')
   or (category = 'headwear' and unlock_type = 'standard' and name in ('Simple Crown', 'Monk Hood', 'Beer Cap', 'Basic Knight Helmet'))
   or (category = 'accessory' and unlock_type = 'standard' and name in ('Beer Mug', 'Hop Necklace', 'Belt', 'Small Shield', 'Tankard'));

-- =========== 0033_abt_remove_old_flat_armor.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: REMOVE OLD FLAT-SVG ARMOR ITEMS
-- =================================================================
-- Elien asked to remove 7 flat-SVG armor items that never got
-- illustrated art: the 5 tinted 'armor.plate' daily-pick variants
-- (Bronze/Steel/Dark Iron/Blackened Steel/Golden Abt Plate) and 2
-- milestone relics (Armor of the Eternal Tap, Lionheart Armor).
--
-- 3 of these were already earned/equipped (Lionheart Armor by two
-- users, Dark Iron Armor by one -- currently equipped by them too),
-- so this clears those references first: unequips the item from
-- abt_avatar_loadouts (their avatar just falls back to the default
-- illustrated body/armor), then removes the earned-unlock rows from
-- user_abt_cosmetics, before deleting the catalog rows themselves
-- (required either way -- the FK would otherwise block the delete).
--
-- The underlying flat SVG shapes (AVATAR_ARMOR_SHAPES.knight_armor
-- via the 'plate' alias, .lion) stay in the client -- 'knight_armor'
-- is still the illustrated 'Knight Armor' standard item's own shape
-- key coincidentally, and removing shared code isn't needed for a
-- catalog-only cleanup.
--
-- Run this once in the Supabase SQL Editor, after 0032.
-- =================================================================

update public.abt_avatar_loadouts set armor_item_id = null
where armor_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'armor'
    and name in ('Bronze Armor', 'Steel Armor', 'Dark Iron Armor', 'Blackened Steel Armor', 'Golden Abt Plate', 'Armor of the Eternal Tap', 'Lionheart Armor')
);

-- Dark Iron Armor was claimed via a Daily Royal Pick, which also left a row
-- in the claim ledger (abt_daily_rewards, unique per reign-day) -- deleting
-- it "returns" that reign-day's pick, same net effect as never having spent
-- it on this item, consistent with also losing the item itself below.
delete from public.abt_daily_rewards
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'armor'
    and name in ('Bronze Armor', 'Steel Armor', 'Dark Iron Armor', 'Blackened Steel Armor', 'Golden Abt Plate', 'Armor of the Eternal Tap', 'Lionheart Armor')
);

delete from public.user_abt_cosmetics
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'armor'
    and name in ('Bronze Armor', 'Steel Armor', 'Dark Iron Armor', 'Blackened Steel Armor', 'Golden Abt Plate', 'Armor of the Eternal Tap', 'Lionheart Armor')
);

delete from public.abt_cosmetic_items
where category = 'armor'
  and name in ('Bronze Armor', 'Steel Armor', 'Dark Iron Armor', 'Blackened Steel Armor', 'Golden Abt Plate', 'Armor of the Eternal Tap', 'Lionheart Armor');

-- =========== 0034_abt_remove_old_flat_headwear.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: REMOVE OLD FLAT-SVG HEADWEAR ITEMS
-- =================================================================
-- Elien asked to remove the remaining flat-SVG headwear items that
-- never got illustrated art -- the last 4 daily-pick ones (all 5
-- milestone headwear rows were already repointed to her illustrated
-- art back in 0025, and the old standard placeholders were removed
-- in 0032).
--
-- "Silver Crown" was already earned/claimed by one user (a Daily
-- Royal Pick, not currently equipped) -- same treatment as 0033:
-- clear the claim ledger row and the earned-unlock row first (that
-- reign-day's pick is returned, same net effect as never spending it
-- here), then delete the catalog row itself.
--
-- Run this once in the Supabase SQL Editor, after 0033.
-- =================================================================

delete from public.abt_daily_rewards
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'headwear'
    and name in ('Golden Winged Helmet', 'Silver Crown', 'Hop Crown', 'Crown of Questionable Authority')
);

delete from public.user_abt_cosmetics
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'headwear'
    and name in ('Golden Winged Helmet', 'Silver Crown', 'Hop Crown', 'Crown of Questionable Authority')
);

delete from public.abt_cosmetic_items
where category = 'headwear'
  and name in ('Golden Winged Helmet', 'Silver Crown', 'Hop Crown', 'Crown of Questionable Authority');

-- =========== 0035_abt_remove_old_flat_weapons.sql ===========
-- =================================================================
-- OFFICE LORE — ABT AVATAR: REMOVE OLD FLAT-SVG WEAPON ITEMS
-- =================================================================
-- Elien asked to remove the flat-SVG weapon items that never got
-- illustrated art -- same treatment as 0033 (armor) and 0034
-- (headwear): 2 standard (Axe, The Bottle Opener), 4 daily-pick
-- (Battle Axe, Hammer of Last Call, Mace, Giant Bottle Opener), and
-- 4 milestone (The Sacred Abt Blade, Winged Warbow, The Colossal Abt
-- Blade, Blade of the Eternal Abt).
--
-- "Giant Bottle Opener" was already earned/claimed (a Daily Royal
-- Pick, not currently equipped) and "Axe" is currently equipped as a
-- standard weapon -- both cleared first (claim ledger, earned-unlock
-- row, and the live loadout reference), same pattern as before.
--
-- Run this once in the Supabase SQL Editor, after 0034.
-- =================================================================

update public.abt_avatar_loadouts set weapon_item_id = null
where weapon_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'weapon'
    and name in ('Battle Axe', 'Hammer of Last Call', 'Mace', 'Giant Bottle Opener', 'The Sacred Abt Blade', 'Winged Warbow', 'The Colossal Abt Blade', 'Blade of the Eternal Abt', 'The Bottle Opener', 'Axe')
);

delete from public.abt_daily_rewards
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'weapon'
    and name in ('Battle Axe', 'Hammer of Last Call', 'Mace', 'Giant Bottle Opener', 'The Sacred Abt Blade', 'Winged Warbow', 'The Colossal Abt Blade', 'Blade of the Eternal Abt', 'The Bottle Opener', 'Axe')
);

delete from public.user_abt_cosmetics
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'weapon'
    and name in ('Battle Axe', 'Hammer of Last Call', 'Mace', 'Giant Bottle Opener', 'The Sacred Abt Blade', 'Winged Warbow', 'The Colossal Abt Blade', 'Blade of the Eternal Abt', 'The Bottle Opener', 'Axe')
);

delete from public.abt_cosmetic_items
where category = 'weapon'
  and name in ('Battle Axe', 'Hammer of Last Call', 'Mace', 'Giant Bottle Opener', 'The Sacred Abt Blade', 'Winged Warbow', 'The Colossal Abt Blade', 'Blade of the Eternal Abt', 'The Bottle Opener', 'Axe');

-- =========== 0036_room_profiles.sql ===========
-- =================================================================
-- OFFICE LORE — MY ROOM: room_profiles
-- =================================================================
-- One row per user, storing their Personal Character's body type and
-- a reserved-but-unused jsonb loadout slot for the future room/wardrobe
-- system. Personal Character is a fully separate concept from the Abt
-- Lord dynasty/Royal Wardrobe (abt_avatar_loadouts) -- this table does
-- not touch, extend, or reuse anything from that system.
--
-- Same app-scoping pattern as every table since 0015: read gated by
-- is_app_member('officelore') alone (any member may view any member's
-- room), write gated by user_id = auth.uid() AND is_app_member(...)
-- (only your own row). No unlock/ownership gating exists for body
-- type, so writes go straight from the client -- no RPC needed, same
-- as profiles' own direct-update pattern.
--
-- loadout stays an empty '{}' for this migration -- nothing writes to
-- it yet (no Personal Character cosmetic catalog exists). Kept now so
-- the client's default-row shape never has to change later, only its
-- contents.
--
-- Run this once in the Supabase SQL Editor, after 0035.
-- =================================================================

create table public.room_profiles (
  user_id uuid primary key references public.profiles(id),
  body_type text not null default 'male'
    check (body_type in ('female', 'male', 'muscular', 'skinny')),
  loadout jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_room_profiles_updated_at
  before update on public.room_profiles
  for each row execute procedure public.set_updated_at();

alter table public.room_profiles enable row level security;

create policy "Room profiles: read" on public.room_profiles for select to authenticated
  using (public.is_app_member('officelore'));

create policy "Room profiles: insert own" on public.room_profiles for insert to authenticated
  with check (user_id = auth.uid() and public.is_app_member('officelore'));

create policy "Room profiles: update own" on public.room_profiles for update to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'))
  with check (user_id = auth.uid() and public.is_app_member('officelore'));

alter publication supabase_realtime add table public.room_profiles;
