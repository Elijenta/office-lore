-- =================================================================
-- OFFICE LORE — the legendary headgear is Abt Lord gear
-- =================================================================
-- The legendary headgear set (abtlord-images/headgear-legendary-cropped) only DROPS
-- when the person opening the box is the current Abt Lord (lord_only_drop, the same
-- rule as the legendary companions). He keeps what he gets: it shows in the Royal
-- Wardrobe and in the Wardrobe of his profile. Everybody else no longer finds it in
-- boxes (anybody who already owns one keeps it). Additive + idempotent. Run after 0061.
-- =================================================================
update public.abt_cosmetic_items set lord_only_drop = true
  where is_active and category = 'headwear' and rarity = 'legendary' and unlock_type = 'milestone';
