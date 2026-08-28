-- =================================================================
-- OFFICE LORE — ABT AVATAR: REMOVE SUPERSEDED PLACEHOLDER ITEMS
-- =================================================================
-- Cleans up the flat-SVG placeholder content built before Elien's
-- illustrated art arrived, now that it's fully superseded:
--
--  - 'hair' (5 standard items): the category was disabled from the
--    Wardrobe the moment illustrated bodies arrived (hair is baked
--    into the body art) and has never been selectable since.
--  - 'cape' STANDARD tier only (5 items, incl. "No Cape"): the
--    category is disabled (superseded by the new 'companion' slot),
--    but its daily_pick (6) and milestone (4) rows are LEFT IN PLACE
--    -- they're still real earned/earnable rewards (one, "Purple
--    Cape", is already owned by a user) with no illustrated
--    replacement yet, so removing them would be a functional loss,
--    not a cleanup.
--  - 4 old standard headwear rows (Simple Crown/Monk Hood/Beer
--    Cap/Basic Knight Helmet) -- fully superseded by the 31
--    illustrated standard headwear items from 0024. "No Hat" is kept
--    (still the default). The 'headwear.simple_crown' flat SVG shape
--    stays in the client -- still used by 2 daily-pick items with
--    tints (Silver Crown, Crown of Questionable Authority).
--  - 5 old standard accessory rows (Beer Mug/Hop Necklace/Belt/Small
--    Shield/Tankard) -- fully superseded by the 22 illustrated
--    standard accessories from 0028. "None" is kept (still the
--    default). The flat shapes for necklace/tankard stay in the
--    client -- still used by 2 tinted daily-pick items.
--
-- Verified before writing this: none of these 19 rows are referenced
-- by any user_abt_cosmetics row (standard items never are). One user
-- currently has "Long Hair" set as their (invisible, unrendered)
-- hair_item_id -- cleared first so the delete doesn't hit the FK.
--
-- Run this once in the Supabase SQL Editor, after 0031.
-- =================================================================

update public.abt_avatar_loadouts set hair_item_id = null
where hair_item_id in (
  select id from public.abt_cosmetic_items where category = 'hair'
);

delete from public.abt_cosmetic_items
where (category = 'hair' and unlock_type = 'standard')
   or (category = 'cape' and unlock_type = 'standard')
   or (category = 'headwear' and unlock_type = 'standard' and name in ('Simple Crown', 'Monk Hood', 'Beer Cap', 'Basic Knight Helmet'))
   or (category = 'accessory' and unlock_type = 'standard' and name in ('Beer Mug', 'Hop Necklace', 'Belt', 'Small Shield', 'Tankard'));
