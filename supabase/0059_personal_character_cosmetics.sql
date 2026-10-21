-- =================================================================
-- OFFICE LORE — Mystery drops for the PERSONAL CHARACTER (My Room)
-- =================================================================
-- Until now a Mystery cosmetic could only be worn by the Abt Lord (the Royal
-- Wardrobe is Lord-only). Everybody has a Personal Character in My Room
-- (room_profiles, a separate system with a reserved, empty `loadout`), and its
-- Wardrobe already has tabs for armor / headwear / weapon / accessory /
-- companion that said "No items yet". Mystery cosmetics now fill them:
--
--   * equip_room_item(category, item): wears an item you OWN from the Mystery pool
--     on your Personal Character (null = take it off). Ownership, category and pool
--     membership are checked on the server; the result is stored in
--     room_profiles.loadout {"headwear": "<item id>", ...}.
--   * the same unlock still works in the Royal Wardrobe when you are the Abt Lord.
--   * the legendary HEADGEAR set (abtlord-images/headgear-legendary-cropped) joins the
--     legendary tier of the Mystery pool. They remain Abt Lord reign milestones too;
--     the one 'dynasty' crown (The Eternal Abt Crown) stays reign-only.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0058.
-- =================================================================

update public.abt_cosmetic_items set mystery_eligible = true
  where is_active and category = 'headwear' and rarity = 'legendary' and unlock_type = 'milestone';

-- the placeholder 'Phantom Crown of Foam' only duplicated Frostglass Tiara's art: the real legendary headgear replaces it
update public.abt_cosmetic_items set is_active = false, mystery_eligible = false where unlock_type = 'mystery' and name = 'Phantom Crown of Foam';

create or replace function public.equip_room_item(p_category text, p_item_id uuid)
returns jsonb as $$
declare
  it public.abt_cosmetic_items;
  v_loadout jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_category not in ('armor', 'headwear', 'weapon', 'accessory', 'companion') then raise exception 'Unknown slot'; end if;
  insert into public.room_profiles (user_id) values (auth.uid()) on conflict do nothing;
  select loadout into v_loadout from public.room_profiles where user_id = auth.uid() for update;
  v_loadout := coalesce(v_loadout, '{}'::jsonb);

  if p_item_id is null then
    v_loadout := v_loadout - p_category;                       -- take it off
  else
    select * into it from public.abt_cosmetic_items where id = p_item_id and is_active;
    if it.id is null or it.category <> p_category then raise exception 'That item does not fit this slot'; end if;
    if not it.mystery_eligible then raise exception 'This item can only be worn by the Abt Lord'; end if;
    if not exists (select 1 from public.user_abt_cosmetics u where u.user_id = auth.uid() and u.cosmetic_item_id = it.id) then
      raise exception 'You have not unlocked this item yet';
    end if;
    v_loadout := jsonb_set(v_loadout, array[p_category], to_jsonb(p_item_id::text), true);
  end if;
  update public.room_profiles set loadout = v_loadout where user_id = auth.uid();
  return v_loadout;
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.equip_room_item(text, uuid) from public, anon;
grant execute on function public.equip_room_item(text, uuid) to authenticated;
