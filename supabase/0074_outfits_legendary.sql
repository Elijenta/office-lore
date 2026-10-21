-- =================================================================
-- OFFICE LORE — two LEGENDARY outfit sets (very low drop chance)
-- =================================================================
--   lg1 "Crimson Court"    red royal regalia. Drops from the big quests: Completionist, Adventurer,
--                          Social Creature, every Group Quest and every Rebellion quest.
--   lg2 "Starlit Scribe"   the starry archmage. Drops from lore, poetry, quiz, chaos, beer and battle
--                          quests and the quiz / poetry group quests.
-- The chance per claim is only 2 to 6%, and the pity counter is 60 claims (about three months of
-- weekly and group quests). Daily quests never roll for them. Codes: flg1 / mlg1 and flg2 / mlg2.
-- Additive + idempotent. Run after 0073.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('lg1', 'Crimson Court', 'Legendary. Very rare drop from the big weekly, group and rebellion quests.', 'random_drop',
   '[{"def":"pw_completionist","chance":0.06},{"def":"pw_adventurer","chance":0.04},{"def":"pw_social_creature","chance":0.04},
     {"def":"gw_fellowship","chance":0.03},{"def":"gw_gathering","chance":0.03},{"def":"gw_poets","chance":0.03},{"def":"gw_nickname_factory","chance":0.03},{"def":"gw_council","chance":0.04},
     {"def":"rb_seeds","chance":0.03},{"def":"rb_pamphlet","chance":0.03},{"def":"rb_storm","chance":0.03}]', 60, 100),
  ('lg2', 'Starlit Scribe', 'Legendary. Very rare drop from lore, poetry, quiz and other weekly quests.', 'random_drop',
   '[{"def":"pw_lorekeeper","chance":0.04},{"def":"pw_poet_laureate","chance":0.04},{"def":"pw_keeper_knowledge","chance":0.04},
     {"def":"pw_agent_of_chaos","chance":0.03},{"def":"pw_beer_explorer","chance":0.03},{"def":"pw_battle_hardened","chance":0.03},
     {"def":"gw_council","chance":0.05},{"def":"gw_poets","chance":0.04},{"def":"gw_nickname_factory","chance":0.04},
     {"def":"gd_lore_quiz","chance":0.02},{"def":"gd_poetry_showdown","chance":0.02}]', 60, 110)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
