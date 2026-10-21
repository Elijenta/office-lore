-- =================================================================
-- OFFICE LORE — outfit set 'lk1' "Scholar's Archive" (Lorekeeper)
-- =================================================================
-- Random drop (with the same pity counter as the other random sets) when you claim a
-- Lorekeeper-type quest: the Lorekeeper weekly, Lore Keeper, Quote Hunter, Memory Lane,
-- Name Thy Victim and the Nickname Factory group quest. Codes: flk1 (female) / mlk1 (male).
-- Additive + idempotent. Run after 0066.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('lk1', 'Scholar''s Archive', 'Drops from Lorekeeper quests.', 'random_drop',
   '[{"def":"pw_lorekeeper","chance":0.25},{"def":"gw_nickname_factory","chance":0.15},{"def":"pd_lore_keeper","chance":0.06},{"def":"pd_quote_hunter","chance":0.06},{"def":"pd_memory_lane","chance":0.06},{"def":"pd_name_thy_victim","chance":0.06}]', 10, 30)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
