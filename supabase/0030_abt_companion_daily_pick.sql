-- =================================================================
-- OFFICE LORE — ABT AVATAR: COMPANION DAILY-PICK SET
-- =================================================================
-- Elien illustrated 6 armored/regal companions (a black horse, a
-- leopard, a buffalo, a penguin, a kitten, and an eagle) for the
-- Daily Royal Pick pool -- same idea as 0026's daily-pick headwear.
-- Purely additive: fresh asset_keys, no existing row touched.
--
-- Run this once in the Supabase SQL Editor, after 0029.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Royal Warhorse', 'Feathered hooves, unshakeable poise, one banner.', 'companion', 'epic', 'daily_pick', 'companion.royal_black_horse'),
  ('Royal Leopard', 'Prowls the office in a very small cape.', 'companion', 'epic', 'daily_pick', 'companion.royal_leopard'),
  ('Royal Buffalo', 'Nose ring, chain, banner. Fully committed.', 'companion', 'epic', 'daily_pick', 'companion.royal_buffalo'),
  ('Royal Penguin', 'Scarf, cape, and a mug of St. Bernardus. Living the dream.', 'companion', 'rare', 'daily_pick', 'companion.royal_penguin'),
  ('Royal Kitten', 'Tiny crown, enormous authority.', 'companion', 'common', 'daily_pick', 'companion.royal_kitten'),
  ('Royal Eagle', 'Flies the banner. Files the paperwork never.', 'companion', 'epic', 'daily_pick', 'companion.royal_eagle');
