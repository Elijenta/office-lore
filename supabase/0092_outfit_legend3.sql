-- =================================================================
-- OFFICE LORE — LEGENDARY outfit set 'lg3' "Gala Night"
-- =================================================================
-- Third legendary set, for both bases (the red gala dress with the big hat / the pinstripe three-piece with the fedora).
-- Legendary but not ultra-rare (the other two legendary sets are): 6 to 15% per claim and a guarantee after 15 claims. Drops from the social and big quests:
-- Social Creature, Completionist, Adventurer, the Group Quests and the Rebellion quests (daily quests never roll for it).
-- Codes: flg3 (female) / mlg3 (male). Additive + idempotent. Run after 0091.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('lg3', 'Gala Night', 'Legendary. Drops from the social, group and rebellion quests.', 'random_drop',
   '[{"def":"pw_social_creature","chance":0.15},{"def":"pw_completionist","chance":0.15},{"def":"pw_adventurer","chance":0.12},
     {"def":"gw_fellowship","chance":0.12},{"def":"gw_gathering","chance":0.10},{"def":"gw_nickname_factory","chance":0.10},{"def":"gw_council","chance":0.12},
     {"def":"rb_storm","chance":0.10},{"def":"rb_seeds","chance":0.10},{"def":"rb_pamphlet","chance":0.10},{"def":"gd_nickname_of_the_day","chance":0.06}]', 15, 120)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
