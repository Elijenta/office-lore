-- =================================================================
-- OFFICE LORE — SUPABASE SCHEMA (Fase 1: Auth, Profiles, alle tabellen,
-- RLS, XP-ledger + triggers, seed data van de huidige demo-inhoud)
-- =================================================================
-- Voer dit VOLLEDIGE bestand in één keer uit in de Supabase SQL Editor
-- (Project → SQL Editor → New query → plak dit bestand → Run).
--
-- BELANGRIJK — lees dit eerst:
-- 1. Dit script gaat ervan uit dat je nog GEEN van deze tabellen hebt.
--    Voer het dus uit op een leeg/nieuw project.
-- 2. Het seed-gedeelte onderaan (SECTIE 10) verwijst naar 3 gebruikers
--    via e-mailadres: elien@officelore.app, nick@officelore.app,
--    atti@officelore.app. Je moet die 3 accounts EERST aanmaken via
--    Authentication → Users → Add user in het Supabase dashboard,
--    VOORDAT je dit script draait. Gebruik je liever andere/echte
--    e-mailadressen? Pas dan gewoon de 3 e-mails onderaan in SECTIE 10
--    aan naar wat je echt hebt gebruikt.
-- 3. Enkele kolommen/tabellen zijn toegevoegd bovenop wat je zelf had
--    opgesomd, telkens omdat bestaande functionaliteit dat vereist.
--    Elke toevoeging staat aangeduid met "[TOEGEVOEGD]" in een comment.
-- =================================================================

create extension if not exists pgcrypto;

-- generieke trigger-functie om updated_at automatisch bij te werken
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;


-- =================================================================
-- SECTIE 1 — PROFILES
-- =================================================================
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  first_name text,
  avatar_url text,
  bio text,
  business_unit text,
  accent_color text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute procedure public.set_updated_at();

-- automatisch een profiel-rij aanmaken zodra er een nieuwe auth-user
-- bijkomt (bv. wanneer je de 3 accounts aanmaakt via het dashboard)
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
-- SECTIE 2 — NICKNAMES + events + votes
-- =================================================================
create table public.nicknames (
  id uuid primary key default gen_random_uuid(),
  nickname text not null,
  person_real_name text not null,
  business_unit text,
  description text,
  anecdote text,
  status text not null default 'Actief'
    check (status in ('Actief', 'In overweging', 'Gearchiveerd')), -- [TOEGEVOEGD] bestaande status-functionaliteit
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
  unique (nickname_id, user_id, vote_type) -- voorkomt dubbele stem van dezelfde soort
);

-- gemak: totale nickname-XP (10 startbonus + som van alle events)
create view public.nickname_xp_totals as
select n.id as nickname_id,
       10 + coalesce(sum(ne.xp_value), 0) as total_xp,
       count(ne.id) as usage_count
from public.nicknames n
left join public.nickname_events ne on ne.nickname_id = n.id
group by n.id;


-- =================================================================
-- SECTIE 3 — QUOTES (+ reacties)
-- =================================================================
create table public.quotes (
  id uuid primary key default gen_random_uuid(),
  person_real_name text not null,
  business_unit text,
  quote text not null,
  context text,
  all_three_bonus_awarded boolean not null default false, -- [TOEGEVOEGD] bestaande bonus-logica
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_quotes_updated_at
  before update on public.quotes
  for each row execute procedure public.set_updated_at();

-- [TOEGEVOEGD] reacties (Funny/Savage/Facepalm) — bestaande functionaliteit
create table public.quote_reactions (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.quotes(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  reaction_type text not null check (reaction_type in ('funny', 'savage', 'facepalm')),
  created_at timestamptz not null default now(),
  unique (quote_id, user_id, reaction_type)
);


-- =================================================================
-- SECTIE 4 — ANECDOTES (+ reacties)
-- =================================================================
create table public.anecdotes (
  id uuid primary key default gen_random_uuid(),
  person_real_name text not null,
  business_unit text,
  title text not null,
  description text not null,
  all_three_bonus_awarded boolean not null default false, -- [TOEGEVOEGD]
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_anecdotes_updated_at
  before update on public.anecdotes
  for each row execute procedure public.set_updated_at();

create table public.anecdote_reactions ( -- [TOEGEVOEGD]
  id uuid primary key default gen_random_uuid(),
  anecdote_id uuid not null references public.anecdotes(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  reaction_type text not null check (reaction_type in ('funny', 'savage', 'facepalm')),
  created_at timestamptz not null default now(),
  unique (anecdote_id, user_id, reaction_type)
);


-- =================================================================
-- SECTIE 5 — COUNTERS + events
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
  delta int not null default 1, -- [TOEGEVOEGD] noodzakelijk voor +1/-1, ontbrak in de oorspronkelijke lijst
  note text,
  created_at timestamptz not null default now()
);

-- gemak: huidige stand = som van alle events (niet apart opgeslagen)
create view public.counter_totals as
select c.id as counter_id,
       coalesce(sum(ce.delta), 0) as total,
       count(ce.id) as event_count
from public.counters c
left join public.counter_events ce on ce.counter_id = c.id
group by c.id;


-- =================================================================
-- SECTIE 6 — BEER CLUB
-- =================================================================
create table public.beers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  brewery text,
  beer_style text,
  alcohol_percentage numeric(4,1),
  country text,
  image_url text,
  created_by_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (name, brewery) -- zelfde dedup-regel als de huidige app (isDuplicateBeer)
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
  check (given_by_user_id <> received_by_user_id), -- geen zelf-stem
  unique (session_id, given_by_user_id) -- max 1 stem per user per sessie
);


-- =================================================================
-- SECTIE 7 — XP_EVENTS (centrale ledger, enkel schrijfbaar via triggers)
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

-- gemak: totale Lore XP / Beer XP per user, rechtstreeks uit de ledger
create view public.user_xp_totals as
select
  p.id as user_id,
  coalesce(sum(x.points) filter (where x.xp_type = 'lore'), 0) as lore_xp,
  coalesce(sum(x.points) filter (where x.xp_type = 'beer'), 0) as beer_xp
from public.profiles p
left join public.xp_events x on x.user_id = p.id
group by p.id;

-- "The Abt Lord" = user met hoogste beer_xp; wordt dus NIET apart
-- opgeslagen, gewoon: select * from user_xp_totals order by beer_xp desc limit 1;

-- ---- triggers die xp_events automatisch vullen ----

-- nieuwe nickname -> +10 lore XP voor de maker
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

-- nickname-gebruiksmoment -> XP gaat naar de MAKER van de nickname
-- (zelfde regel als de bestaande app: nickname-XP telt mee voor wie
-- de nickname toevoegde, niet voor wie het gebruiksmoment registreerde)
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

-- nieuwe quote -> +5 lore XP
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

-- nieuwe anekdote -> +5 lore XP
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

-- "alle 3 users reageerden" bonus op quotes (eenmalig, +5 lore XP)
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

-- zelfde bonus-regel voor anekdotes
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

-- counter-event -> lore XP voor de MAKER van de counter, punten = delta
-- (mag dus ook negatief zijn bij een -1 registratie, zelfde als vandaag)
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

-- perfect pour ontvangen -> +3 beer XP
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

-- NOTE over Beer XP (perDrink/newBeerTried/ratingGiven/ownBeerAdopted):
-- deze regels hangen af van "is dit de eerste keer dat deze user dit
-- bier proeft" en "wordt mijn eigen toegevoegde bier door >=2 mensen
-- geprobeerd" — allebei afhankelijk van de volledige historiek op het
-- moment van invoegen. Deze triggers bouwen we samen met de Beer Club-
-- fase (waar we toch de hele invoerflow herbouwen), zodat we ze meteen
-- end-to-end kunnen testen. Voorlopig kan Beer XP voor die drie regels
-- ook prima uit beer_ratings/beer_consumption berekend worden met een
-- gewone SELECT (zonder trigger) — functioneel identiek, alleen niet
-- in xp_events totdat we de trigger toevoegen.


-- =================================================================
-- SECTIE 8 — ROW LEVEL SECURITY
-- =================================================================

-- ---- profiles ----
alter table public.profiles enable row level security;

create policy "Profiles: iedereen die ingelogd is mag alle profielen lezen"
  on public.profiles for select
  to authenticated
  using (true);

create policy "Profiles: enkel jezelf mag je eigen profiel bewerken"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);
-- geen insert/delete-policy: profielen ontstaan enkel via de
-- handle_new_user()-trigger (SECURITY DEFINER, omzeilt RLS)

-- ---- nicknames ----
alter table public.nicknames enable row level security;

create policy "Nicknames: authenticated mag lezen"
  on public.nicknames for select to authenticated using (true);
create policy "Nicknames: authenticated mag toevoegen als zichzelf"
  on public.nicknames for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Nicknames: enkel maker mag bewerken"
  on public.nicknames for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Nicknames: enkel maker mag verwijderen"
  on public.nicknames for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- nickname_events ----
alter table public.nickname_events enable row level security;

create policy "Nickname events: authenticated mag lezen"
  on public.nickname_events for select to authenticated using (true);
create policy "Nickname events: iedereen mag een gebruiksmoment loggen als zichzelf"
  on public.nickname_events for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Nickname events: enkel eigen registratie verwijderen"
  on public.nickname_events for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- nickname_votes ----
alter table public.nickname_votes enable row level security;

create policy "Nickname votes: authenticated mag lezen"
  on public.nickname_votes for select to authenticated using (true);
create policy "Nickname votes: enkel eigen stem toevoegen"
  on public.nickname_votes for insert to authenticated with check (user_id = auth.uid());
create policy "Nickname votes: enkel eigen stem intrekken"
  on public.nickname_votes for delete to authenticated using (user_id = auth.uid());

-- ---- quotes ----
alter table public.quotes enable row level security;

create policy "Quotes: authenticated mag lezen"
  on public.quotes for select to authenticated using (true);
create policy "Quotes: authenticated mag toevoegen als zichzelf"
  on public.quotes for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Quotes: enkel maker mag bewerken"
  on public.quotes for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Quotes: enkel maker mag verwijderen"
  on public.quotes for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- quote_reactions ----
alter table public.quote_reactions enable row level security;

create policy "Quote reactions: authenticated mag lezen"
  on public.quote_reactions for select to authenticated using (true);
create policy "Quote reactions: enkel eigen reactie toevoegen"
  on public.quote_reactions for insert to authenticated with check (user_id = auth.uid());
create policy "Quote reactions: enkel eigen reactie intrekken"
  on public.quote_reactions for delete to authenticated using (user_id = auth.uid());

-- ---- anecdotes ----
alter table public.anecdotes enable row level security;

create policy "Anecdotes: authenticated mag lezen"
  on public.anecdotes for select to authenticated using (true);
create policy "Anecdotes: authenticated mag toevoegen als zichzelf"
  on public.anecdotes for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Anecdotes: enkel maker mag bewerken"
  on public.anecdotes for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Anecdotes: enkel maker mag verwijderen"
  on public.anecdotes for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- anecdote_reactions ----
alter table public.anecdote_reactions enable row level security;

create policy "Anecdote reactions: authenticated mag lezen"
  on public.anecdote_reactions for select to authenticated using (true);
create policy "Anecdote reactions: enkel eigen reactie toevoegen"
  on public.anecdote_reactions for insert to authenticated with check (user_id = auth.uid());
create policy "Anecdote reactions: enkel eigen reactie intrekken"
  on public.anecdote_reactions for delete to authenticated using (user_id = auth.uid());

-- ---- counters ----
alter table public.counters enable row level security;

create policy "Counters: authenticated mag lezen"
  on public.counters for select to authenticated using (true);
create policy "Counters: authenticated mag toevoegen als zichzelf"
  on public.counters for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Counters: enkel maker mag bewerken"
  on public.counters for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Counters: enkel maker mag verwijderen"
  on public.counters for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- counter_events ----
alter table public.counter_events enable row level security;

create policy "Counter events: authenticated mag lezen"
  on public.counter_events for select to authenticated using (true);
create policy "Counter events: iedereen mag +1/-1 registreren als zichzelf"
  on public.counter_events for insert to authenticated with check (registered_by_user_id = auth.uid());
create policy "Counter events: enkel eigen registratie verwijderen"
  on public.counter_events for delete to authenticated using (registered_by_user_id = auth.uid());

-- ---- beers ----
alter table public.beers enable row level security;

create policy "Beers: authenticated mag lezen"
  on public.beers for select to authenticated using (true);
create policy "Beers: authenticated mag toevoegen als zichzelf"
  on public.beers for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Beers: enkel maker mag bewerken"
  on public.beers for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Beers: enkel maker mag verwijderen"
  on public.beers for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- beer_sessions ----
alter table public.beer_sessions enable row level security;

create policy "Beer sessions: authenticated mag lezen"
  on public.beer_sessions for select to authenticated using (true);
create policy "Beer sessions: authenticated mag toevoegen als zichzelf"
  on public.beer_sessions for insert to authenticated with check (created_by_user_id = auth.uid());
create policy "Beer sessions: enkel maker mag bewerken"
  on public.beer_sessions for update to authenticated using (created_by_user_id = auth.uid()) with check (created_by_user_id = auth.uid());
create policy "Beer sessions: enkel maker mag verwijderen"
  on public.beer_sessions for delete to authenticated using (created_by_user_id = auth.uid());

-- ---- beer_session_participants ----
-- geen created_by_user_id op deze tabel (puur koppeltabel) — daarom
-- geldt hier: enkel de maker van de SESSIE mag deelnemers toevoegen/
-- verwijderen (functionele uitzondering op de standaardregel).
alter table public.beer_session_participants enable row level security;

create policy "Session participants: authenticated mag lezen"
  on public.beer_session_participants for select to authenticated using (true);
create policy "Session participants: enkel sessie-maker mag toevoegen"
  on public.beer_session_participants for insert to authenticated
  with check (exists (
    select 1 from public.beer_sessions s
    where s.id = session_id and s.created_by_user_id = auth.uid()
  ));
create policy "Session participants: enkel sessie-maker mag verwijderen"
  on public.beer_session_participants for delete to authenticated
  using (exists (
    select 1 from public.beer_sessions s
    where s.id = session_id and s.created_by_user_id = auth.uid()
  ));

-- ---- beer_ratings ----
alter table public.beer_ratings enable row level security;

create policy "Beer ratings: authenticated mag lezen"
  on public.beer_ratings for select to authenticated using (true);
create policy "Beer ratings: enkel eigen rating toevoegen"
  on public.beer_ratings for insert to authenticated with check (user_id = auth.uid());
create policy "Beer ratings: enkel eigen rating bewerken"
  on public.beer_ratings for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Beer ratings: enkel eigen rating verwijderen"
  on public.beer_ratings for delete to authenticated using (user_id = auth.uid());

-- ---- beer_consumption ----
alter table public.beer_consumption enable row level security;

create policy "Beer consumption: authenticated mag lezen"
  on public.beer_consumption for select to authenticated using (true);
create policy "Beer consumption: enkel eigen registratie toevoegen"
  on public.beer_consumption for insert to authenticated with check (user_id = auth.uid());
create policy "Beer consumption: enkel eigen registratie bewerken"
  on public.beer_consumption for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Beer consumption: enkel eigen registratie verwijderen"
  on public.beer_consumption for delete to authenticated using (user_id = auth.uid());

-- ---- perfect_pours ----
alter table public.perfect_pours enable row level security;

create policy "Perfect pours: authenticated mag lezen"
  on public.perfect_pours for select to authenticated using (true);
create policy "Perfect pours: enkel eigen stem uitdelen"
  on public.perfect_pours for insert to authenticated with check (given_by_user_id = auth.uid());
create policy "Perfect pours: enkel eigen stem intrekken"
  on public.perfect_pours for delete to authenticated using (given_by_user_id = auth.uid());

-- ---- xp_events ----
-- enkel leesbaar voor authenticated. GEEN insert/update/delete-policy
-- voor de client: deze tabel wordt uitsluitend gevuld door de
-- SECURITY DEFINER-triggers hierboven, zodat niemand vanuit de app
-- zichzelf punten kan toekennen.
alter table public.xp_events enable row level security;

create policy "XP events: authenticated mag lezen"
  on public.xp_events for select to authenticated using (true);


-- =================================================================
-- SECTIE 9 — REALTIME
-- =================================================================
-- Zet de tabellen aan waarvoor we live-updates willen (nieuwe
-- nickname/quote/counter-event/rating/perfect pour meteen zichtbaar
-- bij andere gebruikers zonder refresh).
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


-- =================================================================
-- SECTIE 10 — SEED DATA (huidige demo-inhoud)
-- =================================================================
-- Vereist dat de 3 accounts al bestaan (Authentication → Users).
-- Pas de 3 e-mails hieronder aan als je andere adressen gebruikte.
do $$
declare
  elien_id uuid;
  nick_id uuid;
  atti_id uuid;

  n1 uuid; n2 uuid; n3 uuid; n4 uuid;
  q1 uuid; q2 uuid; q3 uuid;
  a1 uuid; a2 uuid; a3 uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid;

  b1 uuid; b2 uuid; b3 uuid; b4 uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid;
begin
  select id into elien_id from auth.users where email = 'elien@officelore.app';
  select id into nick_id   from auth.users where email = 'nick@officelore.app';
  select id into atti_id   from auth.users where email = 'atti@officelore.app';

  if elien_id is null or nick_id is null or atti_id is null then
    raise exception 'Kon niet alle 3 accounts vinden. Maak eerst elien@officelore.app, nick@officelore.app en atti@officelore.app aan via Authentication -> Users (of pas de e-mails in dit script aan), en voer SECTIE 10 dan opnieuw uit.';
  end if;

  -- profielen aanvullen (de trigger heeft ze al leeg aangemaakt)
  update public.profiles set display_name='Elien', first_name='Elien', bio='Houdt de Office Lore-app draaiende en verzamelt alle bewijs.', accent_color='var(--lilac)' where id = elien_id;
  update public.profiles set display_name='Nick', first_name='Nick', business_unit='Engineering', bio='Fixt bugs sneller dan je ze kan reproduceren.', accent_color='var(--sky)' where id = nick_id;
  update public.profiles set display_name='Atti', first_name='Atti', business_unit='Marketing', bio='Verzint altijd de gekste actiethema''s en kent iedereen bij naam binnen een week.', accent_color='var(--pink)' where id = atti_id;

  -- ---- nicknames ----
  insert into public.nicknames (nickname, person_real_name, business_unit, description, anecdote, status, created_by_user_id, created_at)
    values ('"De Meme Minister"', 'Atti', 'Marketing', 'Ontstaan na een epische meme-thread die Atti zelf startte in de team-chat.', 'Tijdens de laatste town hall gebruikte de CEO deze naam per ongeluk.', 'Actief', nick_id, '2026-07-22')
    returning id into n1;
  insert into public.nickname_events (nickname_id, event_type, xp_value, created_by_user_id, created_at) values
    (n1, 'reused', 1, elien_id, '2026-07-23'),
    (n1, 'used_present', 2, atti_id, '2026-07-26'),
    (n1, 'person_laughs', 3, nick_id, '2026-07-29');
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values
    (n1, elien_id, 'funny'), (n1, nick_id, 'funny'), (n1, atti_id, 'accurate');

  insert into public.nicknames (nickname, person_real_name, business_unit, description, status, created_by_user_id, created_at)
    values ('"Atti die op tafel klopt"', 'Atti', 'Marketing', 'Atti klopt op tafel wanneer die het ergens roerend mee eens is tijdens meetings - inmiddels een herkenningsteken.', 'Actief', elien_id, '2026-08-01')
    returning id into n2;

  insert into public.nicknames (nickname, person_real_name, business_unit, description, anecdote, status, created_by_user_id, created_at)
    values ('"Atti die zichzelf als groot licht gedraagt"', 'Atti', 'Marketing', 'Na een zelfverzekerde speech tijdens de kick-off waarin Atti zichzelf vergeleek met een lichtbaken.', 'Een klant vroeg achteraf of "het licht" ook aan de vergadering zou deelnemen.', 'Actief', atti_id, '2026-08-05')
    returning id into n3;
  insert into public.nickname_events (nickname_id, event_type, xp_value, created_by_user_id, created_at) values
    (n3, 'used_outsider', 5, nick_id, '2026-08-06');
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values
    (n3, elien_id, 'savage'), (n3, nick_id, 'savage');

  insert into public.nicknames (nickname, person_real_name, business_unit, description, anecdote, status, created_by_user_id, created_at)
    values ('"Ctrl+Z Koning"', 'Nick', 'Engineering', 'Nick drukt letterlijk Ctrl+Z als hij een verkeerde beslissing neemt, ook buiten de code.', 'Probeerde ooit een fysieke handdruk ongedaan te maken met Ctrl+Z.', 'Actief', atti_id, '2026-07-24')
    returning id into n4;
  insert into public.nickname_events (nickname_id, event_type, xp_value, created_by_user_id, created_at) values
    (n4, 'self_used', 15, atti_id, '2026-07-28');
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values
    (n4, atti_id, 'funny'), (n4, elien_id, 'accurate'), (n4, nick_id, 'accurate'), (n4, atti_id, 'accurate');

  -- ---- quotes ----
  insert into public.quotes (person_real_name, business_unit, quote, context, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Atti', 'Marketing', '"We doen gewoon iets en kijken wat er gebeurt."', 'Tijdens de sprint planning, toen niemand een duidelijk plan had.', true, elien_id, '2026-07-25')
    returning id into q1;
  insert into public.quote_reactions (quote_id, user_id, reaction_type) values
    (q1, elien_id, 'funny'), (q1, nick_id, 'funny'), (q1, atti_id, 'funny'), (q1, nick_id, 'savage');

  insert into public.quotes (person_real_name, business_unit, quote, context, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Atti', 'Marketing', '"Als het niet werkt, noemen we het een feature."', '', false, nick_id, '2026-08-03')
    returning id into q2;
  insert into public.quote_reactions (quote_id, user_id, reaction_type) values (q2, elien_id, 'funny');

  insert into public.quotes (person_real_name, business_unit, quote, context, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Nick', 'Engineering', '"Works on my machine."', 'Antwoord op een bugreport, vlak voor de deploy.', true, nick_id, '2026-08-01')
    returning id into q3;
  insert into public.quote_reactions (quote_id, user_id, reaction_type) values
    (q3, elien_id, 'funny'), (q3, atti_id, 'funny'), (q3, nick_id, 'savage'), (q3, elien_id, 'facepalm');

  -- ---- anecdotes ----
  insert into public.anecdotes (person_real_name, business_unit, title, description, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'Presentatie in de verkeerde taal', 'Vijf slides ver voor iemand het durfde te zeggen.', true, elien_id, '2026-07-30')
    returning id into a1;
  insert into public.anecdote_reactions (anecdote_id, user_id, reaction_type) values
    (a1, nick_id, 'funny'), (a1, atti_id, 'funny'), (a1, elien_id, 'facepalm');

  insert into public.anecdotes (person_real_name, business_unit, title, description, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'De actiethema-brainstorm die uit de hand liep', 'Begon met confetti-ideeën en eindigde met een discussie of duiven een geldig kantoordier zijn.', false, atti_id, '2026-08-04')
    returning id into a2;
  insert into public.anecdote_reactions (anecdote_id, user_id, reaction_type) values (a2, elien_id, 'funny');

  insert into public.anecdotes (person_real_name, business_unit, title, description, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Nick', 'Engineering', 'Deploy op vrijdagnamiddag', 'Wat kan er nu fout gaan, dacht hij nog.', true, nick_id, '2026-08-07')
    returning id into a3;
  insert into public.anecdote_reactions (anecdote_id, user_id, reaction_type) values
    (a3, nick_id, 'funny'), (a3, elien_id, 'savage'), (a3, atti_id, 'facepalm');

  -- ---- counters ----
  insert into public.counters (person_real_name, business_unit, title, description, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'Atti die op tafel klopt', 'Atti klopt op tafel wanneer die het ergens roerend mee eens is tijdens meetings.', elien_id, '2026-07-20')
    returning id into c1;
  insert into public.counter_events (counter_id, registered_by_user_id, delta, note, created_at) values
    (c1, elien_id, 1, '', '2026-07-21T09:14:00'),
    (c1, nick_id, 1, 'Tijdens de stand-up', '2026-07-21T09:20:00'),
    (c1, atti_id, 1, '', '2026-07-28T11:02:00'),
    (c1, elien_id, 1, '', '2026-08-04T14:45:00'),
    (c1, elien_id, 1, 'Twee keer in dezelfde meeting', '2026-08-11T10:00:00'),
    (c1, elien_id, 1, '', '2026-08-11T10:03:00'),
    (c1, nick_id, 1, '', '2026-08-12T08:30:00');

  insert into public.counters (person_real_name, business_unit, title, description, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'Atti die zichzelf als groot licht gedraagt', 'Wanneer Atti zichzelf weer eens vergelijkt met een lichtbaken tijdens een speech of pitch.', atti_id, '2026-08-01')
    returning id into c2;
  insert into public.counter_events (counter_id, registered_by_user_id, delta, note, created_at) values
    (c2, nick_id, 1, '', '2026-08-02T16:00:00'),
    (c2, atti_id, 1, 'Kick-off speech', '2026-08-06T13:30:00'),
    (c2, nick_id, 1, '', '2026-08-10T09:00:00');

  insert into public.counters (person_real_name, business_unit, title, description, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'Keer "we pivoten" gezegd', 'Elke keer dat Atti een nieuw plan verkoopt als "geen koerswijziging, gewoon een pivot".', elien_id, '2026-07-15')
    returning id into c3;
  insert into public.counter_events (counter_id, registered_by_user_id, delta, note, created_at) values
    (c3, nick_id, 1, '', '2026-07-16T10:00:00'),
    (c3, elien_id, 1, '', '2026-07-18T15:20:00'),
    (c3, atti_id, 1, 'Tijdens de OKR-review', '2026-07-22T09:45:00'),
    (c3, elien_id, 1, '', '2026-07-25T11:00:00'),
    (c3, nick_id, 1, '', '2026-07-30T14:10:00'),
    (c3, elien_id, 1, '', '2026-08-03T16:40:00'),
    (c3, atti_id, 1, '', '2026-08-06T10:30:00'),
    (c3, elien_id, 1, '', '2026-08-09T13:00:00');

  insert into public.counters (person_real_name, business_unit, title, description, created_by_user_id, created_at) values
    ('Nick', 'Engineering', 'Keer prod gecrasht', 'Elke keer dat een deploy van Nick production platlegt.', nick_id, '2026-07-22')
    returning id into c4;
  insert into public.counter_events (counter_id, registered_by_user_id, delta, note, created_at) values
    (c4, nick_id, 1, 'Vrijdagmiddag deploy', '2026-07-28T17:05:00'),
    (c4, atti_id, 1, '', '2026-08-07T18:20:00');

  -- ---- beers ----
  insert into public.beers (name, brewery, beer_style, alcohol_percentage, country, created_by_user_id, created_at) values
    ('Tripel Karmeliet', 'Bosteels', 'Tripel', 8.4, 'België', elien_id, '2026-07-10') returning id into b1;
  insert into public.beers (name, brewery, beer_style, alcohol_percentage, country, created_by_user_id, created_at) values
    ('Duvel', 'Duvel Moortgat', 'Belgian Strong Golden Ale', 8.5, 'België', nick_id, '2026-07-10') returning id into b2;
  insert into public.beers (name, brewery, beer_style, alcohol_percentage, country, created_by_user_id, created_at) values
    ('La Chouffe', 'Brasserie d''Achouffe', 'Blond', 8.0, 'België', atti_id, '2026-07-15') returning id into b3;
  insert into public.beers (name, brewery, beer_style, alcohol_percentage, country, created_by_user_id, created_at) values
    ('Westmalle Tripel', 'Brouwerij der Trappisten van Westmalle', 'Trappist Tripel', 9.5, 'België', elien_id, '2026-08-01') returning id into b4;

  -- ---- sessie 1 ----
  insert into public.beer_sessions (session_date, location, created_by_user_id, created_at) values
    ('2026-07-12', 'Kantoor terras', elien_id, '2026-07-12') returning id into s1;
  insert into public.beer_session_participants (session_id, user_id) values (s1, elien_id), (s1, nick_id), (s1, atti_id);
  insert into public.beer_ratings (beer_id, session_id, user_id, rating, review) values
    (b1, s1, elien_id, 8, 'Fruitig en romig'), (b1, s1, nick_id, 7, ''), (b1, s1, atti_id, 9, 'Favoriet!'),
    (b2, s1, elien_id, 6, 'Sterk'), (b2, s1, nick_id, 8, ''), (b2, s1, atti_id, 7, '');
  insert into public.beer_consumption (beer_id, session_id, user_id, quantity) values
    (b1, s1, elien_id, 1), (b1, s1, nick_id, 1), (b1, s1, atti_id, 2),
    (b2, s1, elien_id, 1), (b2, s1, nick_id, 1), (b2, s1, atti_id, 1);
  insert into public.perfect_pours (session_id, given_by_user_id, received_by_user_id) values
    (s1, elien_id, atti_id), (s1, nick_id, atti_id), (s1, atti_id, elien_id);

  -- ---- sessie 2 ----
  insert into public.beer_sessions (session_date, location, created_by_user_id, created_at) values
    ('2026-07-26', 'Vrijdagborrel', nick_id, '2026-07-26') returning id into s2;
  insert into public.beer_session_participants (session_id, user_id) values (s2, elien_id), (s2, nick_id);
  insert into public.beer_ratings (beer_id, session_id, user_id, rating, review) values
    (b2, s2, elien_id, 7, 'Nog steeds goed'), (b2, s2, nick_id, 8, ''),
    (b3, s2, elien_id, 9, 'Beste van de avond'), (b3, s2, nick_id, 8, '');
  insert into public.beer_consumption (beer_id, session_id, user_id, quantity) values
    (b2, s2, elien_id, 2), (b2, s2, nick_id, 1),
    (b3, s2, elien_id, 1), (b3, s2, nick_id, 1);
  insert into public.perfect_pours (session_id, given_by_user_id, received_by_user_id) values
    (s2, elien_id, nick_id), (s2, nick_id, elien_id);

  -- ---- sessie 3 ----
  insert into public.beer_sessions (session_date, location, created_by_user_id, created_at) values
    ('2026-08-09', 'Kantoor terras', atti_id, '2026-08-09') returning id into s3;
  insert into public.beer_session_participants (session_id, user_id) values (s3, elien_id), (s3, nick_id), (s3, atti_id);
  insert into public.beer_ratings (beer_id, session_id, user_id, rating, review) values
    (b1, s3, elien_id, 8, ''), (b1, s3, atti_id, 9, ''),
    (b4, s3, elien_id, 7, 'Pittig'), (b4, s3, nick_id, 9, 'Topbier'), (b4, s3, atti_id, 8, '');
  insert into public.beer_consumption (beer_id, session_id, user_id, quantity) values
    (b1, s3, elien_id, 1), (b1, s3, atti_id, 1),
    (b4, s3, elien_id, 1), (b4, s3, nick_id, 1), (b4, s3, atti_id, 2);
  insert into public.perfect_pours (session_id, given_by_user_id, received_by_user_id) values
    (s3, elien_id, nick_id), (s3, atti_id, nick_id);

  -- ---- sessie 4 ----
  insert into public.beer_sessions (session_date, location, created_by_user_id, created_at) values
    ('2026-08-11', 'Weekend BBQ', elien_id, '2026-08-11') returning id into s4;
  insert into public.beer_session_participants (session_id, user_id) values (s4, elien_id), (s4, nick_id), (s4, atti_id);
  insert into public.beer_ratings (beer_id, session_id, user_id, rating, review) values
    (b2, s4, elien_id, 6, 'Ik heb er nog een paar staan liggen'), (b2, s4, nick_id, 8, ''), (b2, s4, atti_id, 7, '');
  insert into public.beer_consumption (beer_id, session_id, user_id, quantity) values
    (b2, s4, elien_id, 11), (b2, s4, nick_id, 1), (b2, s4, atti_id, 2);
  insert into public.perfect_pours (session_id, given_by_user_id, received_by_user_id) values
    (s4, nick_id, atti_id);

  raise notice 'Seed data succesvol toegevoegd.';
end $$;
