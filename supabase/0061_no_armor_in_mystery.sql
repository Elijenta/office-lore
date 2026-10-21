-- =================================================================
-- OFFICE LORE — armors stay Abt Lord gear
-- =================================================================
-- The armor art (abtlord-images/armors-cropped) belongs to the Abt Lord. The one
-- armor I had put in the Mystery pool ('Obsidian Lionheart', a recoloured Lionheart
-- Armor) is taken out again. Nobody who already has it loses it: it stays owned,
-- it just no longer drops. Additive + idempotent. Run after 0060.
-- =================================================================
update public.abt_cosmetic_items set mystery_eligible = false, is_active = false
  where unlock_type = 'mystery' and category = 'armor';
