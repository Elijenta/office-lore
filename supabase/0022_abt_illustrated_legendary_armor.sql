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
