-- =================================================================
-- OFFICE LORE — ABT AVATAR: REMOVE OLD FLAT-SVG ARMOR ITEMS
-- =================================================================
-- Elien asked to remove 7 flat-SVG armor items that never got
-- illustrated art: the 5 tinted 'armor.plate' daily-pick variants
-- (Bronze/Steel/Dark Iron/Blackened Steel/Golden Abt Plate) and 2
-- milestone relics (Armor of the Eternal Tap, Lionheart Armor).
--
-- 3 of these were already earned/equipped (Lionheart Armor by two
-- users, Dark Iron Armor by one -- currently equipped by them too),
-- so this clears those references first: unequips the item from
-- abt_avatar_loadouts (their avatar just falls back to the default
-- illustrated body/armor), then removes the earned-unlock rows from
-- user_abt_cosmetics, before deleting the catalog rows themselves
-- (required either way -- the FK would otherwise block the delete).
--
-- The underlying flat SVG shapes (AVATAR_ARMOR_SHAPES.knight_armor
-- via the 'plate' alias, .lion) stay in the client -- 'knight_armor'
-- is still the illustrated 'Knight Armor' standard item's own shape
-- key coincidentally, and removing shared code isn't needed for a
-- catalog-only cleanup.
--
-- Run this once in the Supabase SQL Editor, after 0032.
-- =================================================================

update public.abt_avatar_loadouts set armor_item_id = null
where armor_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'armor'
    and name in ('Bronze Armor', 'Steel Armor', 'Dark Iron Armor', 'Blackened Steel Armor', 'Golden Abt Plate', 'Armor of the Eternal Tap', 'Lionheart Armor')
);

-- Dark Iron Armor was claimed via a Daily Royal Pick, which also left a row
-- in the claim ledger (abt_daily_rewards, unique per reign-day) -- deleting
-- it "returns" that reign-day's pick, same net effect as never having spent
-- it on this item, consistent with also losing the item itself below.
delete from public.abt_daily_rewards
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'armor'
    and name in ('Bronze Armor', 'Steel Armor', 'Dark Iron Armor', 'Blackened Steel Armor', 'Golden Abt Plate', 'Armor of the Eternal Tap', 'Lionheart Armor')
);

delete from public.user_abt_cosmetics
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'armor'
    and name in ('Bronze Armor', 'Steel Armor', 'Dark Iron Armor', 'Blackened Steel Armor', 'Golden Abt Plate', 'Armor of the Eternal Tap', 'Lionheart Armor')
);

delete from public.abt_cosmetic_items
where category = 'armor'
  and name in ('Bronze Armor', 'Steel Armor', 'Dark Iron Armor', 'Blackened Steel Armor', 'Golden Abt Plate', 'Armor of the Eternal Tap', 'Lionheart Armor');
