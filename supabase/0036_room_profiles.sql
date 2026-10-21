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
