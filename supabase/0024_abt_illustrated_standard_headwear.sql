-- =================================================================
-- OFFICE LORE — ABT AVATAR: ILLUSTRATED STANDARD HEADWEAR
-- =================================================================
-- Elien illustrated 31 headwear icons (crowns, hats, animal hoods,
-- accessories) as a new standard headwear set, available to everyone
-- from day one -- same idea as 0023's standard weapons. Purely
-- additive: fresh asset_keys, no existing row touched (the existing
-- 'headwear.simple_crown' asset_key stays flat-SVG, since it's shared
-- by tinted daily-pick variants that would lose their tint if
-- repointed to a single illustrated image).
--
-- Run this once in the Supabase SQL Editor, after 0023.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Gilded Crown', 'Classic. Effective. Slightly too big.', 'headwear', 'standard', 'standard', 'headwear.gold_crown_simple'),
  ('Jeweled Crown', 'More jewels than the last one. That''s the whole pitch.', 'headwear', 'standard', 'standard', 'headwear.gold_crown_jeweled'),
  ('Royal Velvet Crown', 'Fur trim included. Dry-clean only.', 'headwear', 'standard', 'standard', 'headwear.royal_crown_red'),
  ('Sapphire Tiara', 'Delicate, gleaming, and completely unearned.', 'headwear', 'standard', 'standard', 'headwear.tiara_laurel_gem'),
  ('Laurel Wreath', 'For lords who peaked in ancient Rome.', 'headwear', 'standard', 'standard', 'headwear.laurel_wreath'),
  ('Daisy Crown', 'Soft power. Very soft.', 'headwear', 'standard', 'standard', 'headwear.flower_crown'),
  ('Sun Hat', 'For the lord who reigns from a beach chair.', 'headwear', 'standard', 'standard', 'headwear.straw_hat_flower'),
  ('Ranch Hat', 'Yee. And also haw.', 'headwear', 'standard', 'standard', 'headwear.cowboy_hat_badge'),
  ('Sheriff''s Hat', 'Protecting the fridge, one star at a time.', 'headwear', 'standard', 'standard', 'headwear.cowboy_hat_star'),
  ('Pawprint Cap', 'Blue, white, and unreasonably loyal.', 'headwear', 'standard', 'standard', 'headwear.cap_paw_blue'),
  ('Sly Fox Cap', 'For lords who see everything and admit nothing.', 'headwear', 'standard', 'standard', 'headwear.cap_fox_black'),
  ('Cozy Beanie', 'Pompom included. Dignity optional.', 'headwear', 'standard', 'standard', 'headwear.beanie_paw_green'),
  ('Formal Top Hat', 'Extremely serious. Extremely a paw badge.', 'headwear', 'standard', 'standard', 'headwear.top_hat_paw'),
  ('Musketeer Hat', 'One for all, and mostly for the Abt Lord.', 'headwear', 'standard', 'standard', 'headwear.musketeer_hat'),
  ('Wizard''s Hat', 'Grants no spells. Grants excellent posture.', 'headwear', 'standard', 'standard', 'headwear.wizard_hat'),
  ('Party Hat', 'It is always someone''s reign-iversary somewhere.', 'headwear', 'standard', 'standard', 'headwear.party_hat'),
  ('Aviator Cap', 'For lords about to make a very questionable landing.', 'headwear', 'standard', 'standard', 'headwear.aviator_cap'),
  ('Viking Helm', 'Horns purely decorative. Please don''t headbutt anything.', 'headwear', 'standard', 'standard', 'headwear.viking_helmet'),
  ('Brown Bear Hood', 'Warm, fuzzy, mildly threatening.', 'headwear', 'standard', 'standard', 'headwear.bear_hood_brown'),
  ('Polar Bear Hood', 'Now with a decorative ice gem.', 'headwear', 'standard', 'standard', 'headwear.bear_hood_white'),
  ('Wolf Hood', 'Runs with a pack of exactly one.', 'headwear', 'standard', 'standard', 'headwear.wolf_hood'),
  ('Fox Hood', 'Cunning not included, unfortunately.', 'headwear', 'standard', 'standard', 'headwear.fox_hood'),
  ('Frog Hood', 'Ribbiting fashion choice.', 'headwear', 'standard', 'standard', 'headwear.frog_hood'),
  ('Chicken Hood', 'Bold. Fearless. Slightly egg-shaped.', 'headwear', 'standard', 'standard', 'headwear.chicken_hood'),
  ('Studio Headphones', 'For carefully curating the throne-room playlist.', 'headwear', 'standard', 'standard', 'headwear.headphones_paw'),
  ('Steampunk Goggles', 'Purpose unclear. Vibe immaculate.', 'headwear', 'standard', 'standard', 'headwear.steampunk_goggles'),
  ('Red Bandana', 'Simple. Practical. Slightly outlaw-coded.', 'headwear', 'standard', 'standard', 'headwear.bandana_red'),
  ('Blue Pawprint Bandana', 'The loyal cousin of the red one.', 'headwear', 'standard', 'standard', 'headwear.bandana_blue_paw'),
  ('White Lily', 'Tucked in, no questions asked.', 'headwear', 'standard', 'standard', 'headwear.flower_white'),
  ('Red Rose', 'A single rose. Extremely dramatic energy.', 'headwear', 'standard', 'standard', 'headwear.flower_rose'),
  ('Jack-o''-Lantern Hat', 'A pumpkin, a ghost, and questionable judgment.', 'headwear', 'standard', 'standard', 'headwear.witch_pumpkin');
