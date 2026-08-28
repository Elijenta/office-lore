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
