-- =================================================================
-- OFFICE LORE — ABT AVATAR: REMOVE OLD FLAT-SVG WEAPON ITEMS
-- =================================================================
-- Elien asked to remove the flat-SVG weapon items that never got
-- illustrated art -- same treatment as 0033 (armor) and 0034
-- (headwear): 2 standard (Axe, The Bottle Opener), 4 daily-pick
-- (Battle Axe, Hammer of Last Call, Mace, Giant Bottle Opener), and
-- 4 milestone (The Sacred Abt Blade, Winged Warbow, The Colossal Abt
-- Blade, Blade of the Eternal Abt).
--
-- "Giant Bottle Opener" was already earned/claimed (a Daily Royal
-- Pick, not currently equipped) and "Axe" is currently equipped as a
-- standard weapon -- both cleared first (claim ledger, earned-unlock
-- row, and the live loadout reference), same pattern as before.
--
-- Run this once in the Supabase SQL Editor, after 0034.
-- =================================================================

update public.abt_avatar_loadouts set weapon_item_id = null
where weapon_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'weapon'
    and name in ('Battle Axe', 'Hammer of Last Call', 'Mace', 'Giant Bottle Opener', 'The Sacred Abt Blade', 'Winged Warbow', 'The Colossal Abt Blade', 'Blade of the Eternal Abt', 'The Bottle Opener', 'Axe')
);

delete from public.abt_daily_rewards
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'weapon'
    and name in ('Battle Axe', 'Hammer of Last Call', 'Mace', 'Giant Bottle Opener', 'The Sacred Abt Blade', 'Winged Warbow', 'The Colossal Abt Blade', 'Blade of the Eternal Abt', 'The Bottle Opener', 'Axe')
);

delete from public.user_abt_cosmetics
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'weapon'
    and name in ('Battle Axe', 'Hammer of Last Call', 'Mace', 'Giant Bottle Opener', 'The Sacred Abt Blade', 'Winged Warbow', 'The Colossal Abt Blade', 'Blade of the Eternal Abt', 'The Bottle Opener', 'Axe')
);

delete from public.abt_cosmetic_items
where category = 'weapon'
  and name in ('Battle Axe', 'Hammer of Last Call', 'Mace', 'Giant Bottle Opener', 'The Sacred Abt Blade', 'Winged Warbow', 'The Colossal Abt Blade', 'Blade of the Eternal Abt', 'The Bottle Opener', 'Axe');
