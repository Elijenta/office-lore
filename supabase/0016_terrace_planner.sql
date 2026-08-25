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
