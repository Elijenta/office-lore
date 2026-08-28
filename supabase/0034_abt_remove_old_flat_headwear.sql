-- =================================================================
-- OFFICE LORE — ABT AVATAR: REMOVE OLD FLAT-SVG HEADWEAR ITEMS
-- =================================================================
-- Elien asked to remove the remaining flat-SVG headwear items that
-- never got illustrated art -- the last 4 daily-pick ones (all 5
-- milestone headwear rows were already repointed to her illustrated
-- art back in 0025, and the old standard placeholders were removed
-- in 0032).
--
-- "Silver Crown" was already earned/claimed by one user (a Daily
-- Royal Pick, not currently equipped) -- same treatment as 0033:
-- clear the claim ledger row and the earned-unlock row first (that
-- reign-day's pick is returned, same net effect as never spending it
-- here), then delete the catalog row itself.
--
-- Run this once in the Supabase SQL Editor, after 0033.
-- =================================================================

delete from public.abt_daily_rewards
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'headwear'
    and name in ('Golden Winged Helmet', 'Silver Crown', 'Hop Crown', 'Crown of Questionable Authority')
);

delete from public.user_abt_cosmetics
where cosmetic_item_id in (
  select id from public.abt_cosmetic_items
  where category = 'headwear'
    and name in ('Golden Winged Helmet', 'Silver Crown', 'Hop Crown', 'Crown of Questionable Authority')
);

delete from public.abt_cosmetic_items
where category = 'headwear'
  and name in ('Golden Winged Helmet', 'Silver Crown', 'Hop Crown', 'Crown of Questionable Authority');
