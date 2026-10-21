-- =================================================================
-- OFFICE LORE — outfit set 'bt1' "Office Gladiator" (Battle)
-- =================================================================
-- Random drop (same pity counter as the other random sets) when you claim a battle quest:
-- Battle Hardened (weekly), Pick a Side (daily) and the Rebellion quests Gathering Storm
-- and Seeds of Rebellion. Codes: fbt1 (female) / mbt1 (male). Additive + idempotent.
-- Run after 0067.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('bt1', 'Office Gladiator', 'Drops from battle quests.', 'random_drop',
   '[{"def":"pw_battle_hardened","chance":0.25},{"def":"rb_storm","chance":0.20},{"def":"rb_seeds","chance":0.10},{"def":"pd_pick_a_side","chance":0.08}]', 10, 40)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
