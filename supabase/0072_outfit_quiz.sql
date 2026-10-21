-- =================================================================
-- OFFICE LORE — outfit set 'qz1' "Quiz Master" (Quizzes)
-- =================================================================
-- Random drop (same pity counter as the other random sets) when you claim a quiz quest:
-- Keeper of Knowledge (weekly), The Council (Group Quest), the Daily Lore Quiz (Group Daily)
-- and the personal quiz Dailies. Some of those stay switched off until a free-to-play quiz
-- exists (challenge_features.quiz); the set is ready for the day they come on.
-- Codes: fqz1 (female) / mqz1 (male). Additive + idempotent. Run after 0071.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('qz1', 'Quiz Master', 'Drops from quiz quests.', 'random_drop',
   '[{"def":"gw_council","chance":0.30},{"def":"pw_keeper_knowledge","chance":0.25},{"def":"pd_perfect_score","chance":0.12},{"def":"gd_lore_quiz","chance":0.10},{"def":"pd_lore_master","chance":0.06},{"def":"pd_know_thy_friends","chance":0.06}]', 8, 80)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
