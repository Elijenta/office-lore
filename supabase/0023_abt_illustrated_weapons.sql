-- =================================================================
-- OFFICE LORE — ABT AVATAR: ILLUSTRATED STANDARD WEAPONS
-- =================================================================
-- Elien illustrated 12 held-item icons as the new standard weapon
-- set. 3 of them (sword/staff/mug) reuse the asset_key of an
-- existing standard item -- no DB change needed there, the client
-- picks up the illustrated art automatically over the old SVG shape.
-- The other 8 are genuinely new concepts, added here as new standard
-- weapon rows (fresh asset_keys, so they don't collide with the
-- existing daily-pick 'weapon.hammer'/'weapon.axe'/etc. rows).
--
-- Run this once in the Supabase SQL Editor, after 0022.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Warhammer', 'For a lord who has strong opinions about doors.', 'weapon', 'standard', 'standard', 'weapon.warhammer'),
  ('Dagger', 'Small, sharp, surprisingly good at opening bottles.', 'weapon', 'standard', 'standard', 'weapon.dagger'),
  ('Hunting Bow', 'Never actually fired at anything but the beer fridge.', 'weapon', 'standard', 'standard', 'weapon.hunting_bow'),
  ('St. Bernardus Bottle', 'A weapon in the loosest possible sense.', 'weapon', 'standard', 'standard', 'weapon.beer_bottle'),
  ('Round Shield', 'Defends against nothing but criticism, now in weapon-slot form.', 'weapon', 'standard', 'standard', 'weapon.round_shield'),
  ('Crossbow', 'Reload time: however long the current round takes.', 'weapon', 'standard', 'standard', 'weapon.crossbow'),
  ('Torch', 'For dramatically lighting the way to the fridge.', 'weapon', 'standard', 'standard', 'weapon.torch'),
  ('Spellbook', 'Contains zero spells. Looks very authoritative regardless.', 'weapon', 'standard', 'standard', 'weapon.spellbook');
