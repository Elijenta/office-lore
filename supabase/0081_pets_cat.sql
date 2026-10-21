-- =================================================================
-- 0081 — The Cat is ready: plain Classic look + its Rebel Cloak
--
-- kat-standaard.png is now a plain cat, so the Cat (switched off in an earlier version of this file) is on again, and the
-- costume that used to be its "Classic" look becomes the Cat's Rebel Cloak (drops from Rebellion quests, like the Highland
-- Cow's). Safe to run whether or not the earlier version of 0081 was run, and safe to run twice.
-- =================================================================
update public.pet_species set is_active = true where id = 'kat';
insert into public.pet_outfits (id, species_id, family, name, rarity, unlock_kind, sources, pity_after, hint, sort_order) values
  ('kat-rebellion', 'kat', 'rebellion', 'Rebel Cloak', 'epic', 'random_drop',
   '[{"def":"rb_seeds","chance":0.35},{"def":"rb_pamphlet","chance":0.35},{"def":"rb_storm","chance":0.35}]'::jsonb, 8, 'Drops from Rebellion quests.', 169)
on conflict (id) do update set species_id = excluded.species_id, family = excluded.family, name = excluded.name, rarity = excluded.rarity,
  unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, hint = excluded.hint, sort_order = excluded.sort_order, is_active = true;
