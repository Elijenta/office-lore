-- =================================================================
-- OFFICE LORE / TRIPEL TALES — SEASONAL OUTFITS (Halloween first)
-- =================================================================
-- A seasonal outfit can be worn by EVERYBODY while its season lasts, no quest needed. Each has a window (starts_on .. ends_on, Brussels
-- date). After the window nobody can newly choose it; whoever is wearing it keeps it until they change. The pictures are in the app
-- (supabase/tools/build_seasonal_images.py); this table says which codes exist, for which body, and when.
--   hw1  Pirate   (female + male)      hw2  Vampire (female)      hw3  Zombie (male)
-- Halloween runs until the 15th of November 2026. A next season = new rows (and pictures), no code change.
-- Additive + idempotent. Run after 0082.
-- =================================================================
create table if not exists public.character_seasonal_outfits (
  id text primary key check (id ~ '^[a-z]{2}[0-9]{1,2}$'),
  name text not null,
  season text not null,
  genders text[] not null default '{f,m}',
  starts_on date not null,
  ends_on date not null,
  sort_order int not null default 0,
  is_active boolean not null default true
);
alter table public.character_seasonal_outfits enable row level security;
drop policy if exists "Seasonal outfits: read" on public.character_seasonal_outfits;
create policy "Seasonal outfits: read" on public.character_seasonal_outfits for select to authenticated using (public.is_app_member('officelore'));
insert into public.character_seasonal_outfits (id, name, season, genders, starts_on, ends_on, sort_order) values
  ('hw1', 'Pirate',  'halloween', '{f,m}', date '2026-10-01', date '2026-11-15', 10),
  ('hw2', 'Vampire', 'halloween', '{f}',   date '2026-10-01', date '2026-11-15', 20),
  ('hw3', 'Zombie',  'halloween', '{m}',   date '2026-10-01', date '2026-11-15', 30)
on conflict (id) do update set name = excluded.name, season = excluded.season, genders = excluded.genders, starts_on = excluded.starts_on,
  ends_on = excluded.ends_on, sort_order = excluded.sort_order;

-- wearing: seasonal outfits are allowed inside their window (otherwise unchanged from 0066)
create or replace function public.set_room_character(p_base text, p_outfit text default null)
returns jsonb as $$
declare
  v_loadout jsonb;
  v_set text;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_base not in ('female', 'male') then raise exception 'Choose a female or male base'; end if;
  if p_outfit is not null then
    if p_outfit !~ '^[fm]([0-9]{1,2}|[a-z]{2}[0-9]{1,2})$' then raise exception 'Unknown outfit'; end if;
    if left(p_outfit, 1) <> left(p_base, 1) then raise exception 'That outfit does not belong to this base'; end if;
    v_set := substr(p_outfit, 2);
    if v_set !~ '^[0-9]+$' then                                   -- a special set or a seasonal outfit
      if exists (select 1 from public.character_seasonal_outfits s where s.id = v_set and s.is_active) then
        -- seasonal: everybody may pick it while its season lasts (Brussels date); whoever already wears it may keep it afterwards
        if not exists (select 1 from public.character_seasonal_outfits s
                       where s.id = v_set and s.is_active and left(p_outfit, 1) = any (s.genders)
                         and (now() at time zone 'Europe/Brussels')::date between s.starts_on and s.ends_on)
           and (select loadout->>'outfit' from public.room_profiles where user_id = auth.uid()) is distinct from p_outfit then
          raise exception 'This seasonal outfit is not available right now';
        end if;
      else
        if not exists (select 1 from public.character_outfit_sets where id = v_set and is_active) then raise exception 'Unknown outfit'; end if;
        if not exists (select 1 from public.user_character_outfits u where u.user_id = auth.uid() and u.set_id = v_set) then
          raise exception 'You have not unlocked this outfit yet';
        end if;
      end if;
    end if;
  end if;
  insert into public.room_profiles (user_id, body_type) values (auth.uid(), p_base) on conflict (user_id) do nothing;
  select loadout into v_loadout from public.room_profiles where user_id = auth.uid() for update;
  v_loadout := coalesce(v_loadout, '{}'::jsonb) - 'outfit';
  if p_outfit is not null then v_loadout := v_loadout || jsonb_build_object('outfit', p_outfit); end if;
  update public.room_profiles set body_type = p_base, loadout = v_loadout where user_id = auth.uid();
  return jsonb_build_object('body_type', p_base, 'loadout', v_loadout);
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.set_room_character(text, text) from public, anon;
grant execute on function public.set_room_character(text, text) to authenticated;
