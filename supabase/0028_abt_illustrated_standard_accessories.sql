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
