-- =================================================================
-- OFFICE LORE — ABT AVATAR: ILLUSTRATED DAILY-PICK HEADWEAR
-- =================================================================
-- Elien illustrated 20 fun/meme-themed headwear pieces for the Daily
-- Royal Pick pool. Purely additive: fresh asset_keys, no existing row
-- touched. Rarity spread mirrors the existing daily_pick set (mostly
-- common/rare, a few epic for the more elaborate pieces) so the
-- deterministic 3-choice offer stays varied.
--
-- Run this once in the Supabase SQL Editor, after 0025.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('Deal With It Crown', 'Pixelated shades. Undeniable authority.', 'headwear', 'rare', 'daily_pick', 'headwear.swag_crown_shades'),
  ('Beer Mode Backpack', 'A hands-free hydration system. For beer.', 'headwear', 'epic', 'daily_pick', 'headwear.beer_mode_cap'),
  ('Jester''s Cap', 'The wisest fool ever to hold the throne.', 'headwear', 'rare', 'daily_pick', 'headwear.jester_hat'),
  ('Disco Helmet', 'Saturday night at the office, apparently.', 'headwear', 'epic', 'daily_pick', 'headwear.disco_ball_shades'),
  ('Inflatable Flamingo', 'Worn as a hat. No further questions.', 'headwear', 'epic', 'daily_pick', 'headwear.flamingo_float'),
  ('Six-Pack Crown', 'Fully loaded. Somehow still standing upright.', 'headwear', 'common', 'daily_pick', 'headwear.beer_bottle_crown'),
  ('Frothy Top Hat', 'Formalwear, reimagined by a brewery.', 'headwear', 'common', 'daily_pick', 'headwear.beer_mug_hat'),
  ('Majestic Unicorn Hood', 'Rare, magical, deeply extra.', 'headwear', 'epic', 'daily_pick', 'headwear.unicorn_horn'),
  ('Bottled Royalty', 'Every bottle a tiny throne of its own.', 'headwear', 'common', 'daily_pick', 'headwear.royal_beer_crown'),
  ('Brewmaster''s Peak', 'For a lord of unusually specific expertise.', 'headwear', 'rare', 'daily_pick', 'headwear.wizard_beer_hat'),
  ('Braided Raider Helm', 'Pillages nothing but the fridge.', 'headwear', 'common', 'daily_pick', 'headwear.viking_braids'),
  ('Rainbow Goggle Panda', 'Sees the world in full color. Mostly beer-colored.', 'headwear', 'rare', 'daily_pick', 'headwear.panda_goggles'),
  ('Captain''s Bearing', 'Commands a fleet of exactly zero ships.', 'headwear', 'common', 'daily_pick', 'headwear.captain_hat'),
  ('Outlaw Bandana Hat', 'Wanted: for excessive reign length.', 'headwear', 'common', 'daily_pick', 'headwear.cowboy_bandana'),
  ('Taco Sombrero ''Stache', 'A full meal and a mustache in one hat.', 'headwear', 'epic', 'daily_pick', 'headwear.taco_mustache'),
  ('Blockhead Shades', 'Ssss. Deeply unbothered.', 'headwear', 'rare', 'daily_pick', 'headwear.creeper_shades'),
  ('Gamer Ears Headset', 'Callouts optional. Paw print mandatory.', 'headwear', 'rare', 'daily_pick', 'headwear.cat_ear_headphones'),
  ('Beach Day Hat', 'On break from ruling, technically.', 'headwear', 'common', 'daily_pick', 'headwear.sun_hat_tropical'),
  ('Living Hedge Wig', 'Fully landscaped. Butterflies included, free of charge.', 'headwear', 'epic', 'daily_pick', 'headwear.garden_bush'),
  ('Rainbow Clown Wig', 'Honk if you''ve reigned longer than expected.', 'headwear', 'rare', 'daily_pick', 'headwear.clown_wig');
