-- =================================================================
-- OFFICE LORE — outfit set 'cp1' "Champion's Gala" (Completionist)
-- =================================================================
-- The golden set for people who finish everything. Claiming The Completionist ALWAYS gives
-- it (chance 1, the first time); Adventurer (5 different Dailies) and Social Creature (3
-- parts of the app) can drop it too, with a short pity counter (5 claims) because these
-- quests are rare. Codes: fcp1 (female) / mcp1 (male). Additive + idempotent. Run after 0069.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('cp1', 'Champion''s Gala', 'Complete The Completionist, or find it with Adventurer and Social Creature.', 'random_drop',
   '[{"def":"pw_completionist","chance":1},{"def":"pw_adventurer","chance":0.30},{"def":"pw_social_creature","chance":0.20}]', 5, 60)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
