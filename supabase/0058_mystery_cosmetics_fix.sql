-- =================================================================
-- OFFICE LORE — Mystery cosmetics: only what you can actually SEE
-- =================================================================
-- Found while looking at the cosmetics in the app:
--  * three of the new 'Mystery finds' pointed at art keys that have no illustration
--    (headwear.eternal_foam, weapon.sacred_blade, weapon.winged_bow), so they looked
--    like nothing at all. They now use illustrated keys (ice crystal tiara, sword,
--    hunting bow). Tints do not apply to illustrated art, so these carry none.
--  * the cape layer is switched off in the avatar renderer, so a cape prize would show
--    nothing. Capes are not mystery-eligible until that layer is back.
-- Additive + idempotent. Run after 0056.
-- =================================================================
update public.abt_cosmetic_items set asset_key = 'weapon.hunting_bow', render_tint = null where unlock_type = 'mystery' and name = 'Moonlit Warbow';
update public.abt_cosmetic_items set asset_key = 'headwear.ice_crystal_tiara', render_tint = null where unlock_type = 'mystery' and name = 'Phantom Crown of Foam';
update public.abt_cosmetic_items set asset_key = 'weapon.sword', render_tint = null where unlock_type = 'mystery' and name = 'Ember Sacred Blade';
update public.abt_cosmetic_items set mystery_eligible = false where category = 'cape';
