-- =================================================================
-- OFFICE LORE — CLEANUP: DUPLICATE DAILY-PICK HEADWEAR FROM 0026
-- =================================================================
-- 0026 was accidentally run twice, inserting each of the 20 new
-- daily-pick headwear rows twice. Nothing had claimed/equipped any
-- of them yet (verified against user_abt_cosmetics/abt_daily_rewards
-- before writing this), so it's safe to just delete the newer
-- duplicate of each pair, keeping the earliest-created row.
--
-- Run this once in the Supabase SQL Editor, after 0026.
-- =================================================================

delete from public.abt_cosmetic_items a
  using public.abt_cosmetic_items b
  where a.category = 'headwear'
    and a.unlock_type = 'daily_pick'
    and a.asset_key = b.asset_key
    and a.created_at > b.created_at;
