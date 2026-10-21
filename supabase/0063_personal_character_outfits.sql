-- =================================================================
-- OFFICE LORE — PERSONAL CHARACTER: base + standard outfit (separate from the Abt Lord)
-- =================================================================
-- Every member makes their own little character in My Room: a BASE (female or male,
-- character-images/character/base-*.png) and one of the standard OUTFITS
-- (character-images/outfit/: f1, f2, ... for female, m1, m2, ... for male). This is
-- completely separate from the Abt Lord's Royal Wardrobe; nobody needs to be the Lord.
--
--   set_room_character(base, outfit)   base 'female' | 'male'; outfit null (the plain
--                                      base) or 'f<n>' / 'm<n>' matching the base.
--   stored in room_profiles.body_type (the base) and room_profiles.loadout.outfit.
--
-- New outfits only need an image in the app plus a code in the client list: the server
-- accepts any f<n> / m<n> that matches the base. Mystery drops (headwear, weapon, ...)
-- are worn on top of the outfit and are not touched. Additive + idempotent.
-- Run once in the Supabase SQL Editor, after 0062.
-- =================================================================
create or replace function public.set_room_character(p_base text, p_outfit text default null)
returns jsonb as $$
declare
  v_loadout jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_base not in ('female', 'male') then raise exception 'Choose a female or male base'; end if;
  if p_outfit is not null then
    if p_outfit !~ '^[fm][0-9]{1,2}$' then raise exception 'Unknown outfit'; end if;
    if left(p_outfit, 1) <> left(p_base, 1) then raise exception 'That outfit does not belong to this base'; end if;
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
