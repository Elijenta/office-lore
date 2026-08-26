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
