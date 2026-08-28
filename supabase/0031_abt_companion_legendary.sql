-- =================================================================
-- OFFICE LORE — ABT AVATAR: LEGENDARY COMPANIONS
-- =================================================================
-- Elien illustrated 4 legendary companions (a royal lion, an ice
-- tiger, a St. Bernardus hound, and a Royal T-Rex) as new milestone
-- rewards -- same idea as 0025's legendary headwear. Purely
-- additive: fresh asset_keys and milestone_days, no existing row
-- touched. Days chosen to not collide with any existing milestone
-- threshold across any category.
--
-- Run this once in the Supabase SQL Editor, after 0030.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key) values
  ('Royal Lion', 'Mane, crown, three separate "Abt Lord" medallions. No notes.', 'companion', 'legendary', 'milestone', 8, 'companion.royal_lion'),
  ('Frost Tiger', 'Radiates cold. Radiates authority. Mostly cold.', 'companion', 'legendary', 'milestone', 22, 'companion.ice_tiger'),
  ('St. Bernardus Hound', 'Carries the good barrel. Never spills a drop.', 'companion', 'legendary', 'milestone', 48, 'companion.st_bernard'),
  ('Royal T-Rex', 'Tiny arms, enormous banner, undisputed apex predator of the office.', 'companion', 'legendary', 'milestone', 95, 'companion.royal_trex');
