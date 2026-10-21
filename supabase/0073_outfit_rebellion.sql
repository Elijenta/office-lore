-- =================================================================
-- OFFICE LORE — outfit set 'rb1' "Rebel Banner" (Rebellion)
-- =================================================================
-- Random drop when you claim a Rebellion quest (Seeds of Rebellion, The Pamphlet War,
-- The Gathering Storm). You get at most one Rebellion quest a week and only a member who is
-- not the Abt Lord can claim one, so the chance is high and the pity counter short (4 claims
-- without a drop, so about a month). Codes: frb1 (female) / mrb1 (male).
-- Additive + idempotent. Run after 0072.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('rb1', 'Rebel Banner', 'Drops from Rebellion quests (for everybody but the Abt Lord).', 'random_drop',
   '[{"def":"rb_seeds","chance":0.35},{"def":"rb_pamphlet","chance":0.35},{"def":"rb_storm","chance":0.35}]', 4, 90)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
