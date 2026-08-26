-- =================================================================
-- OFFICE LORE — ABT AVATAR: DRAGON MILESTONE SET
-- =================================================================
-- Purely additive: 2 new catalog rows, same Day-40 threshold, granted
-- together the same way the Day-100 "full set" already is (multiple
-- unlock_type='milestone' rows sharing one milestone_days value --
-- sync_abt_milestones() already evaluates each row independently, no
-- code/function change needed). Does not touch any existing row.
--
-- Run this once in the Supabase SQL Editor, after 0019.
-- =================================================================

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, milestone_days, asset_key, render_tint) values
  ('Dragon Armor', 'Scaled plate with real wings. Roaring not included.', 'armor', 'legendary', 'milestone', 40, 'armor.dragon', '#2f7a4a'),
  ('Dragon-Head Helm', 'A dragon''s skull, worn as a hat. Deeply reasonable.', 'headwear', 'legendary', 'milestone', 40, 'headwear.dragon_helm', '#2f7a4a');
