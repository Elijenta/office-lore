-- =================================================================
-- OFFICE LORE — outfit set 'pt1' "Poet's Salon" (Poetry)
-- =================================================================
-- Random drop (same pity counter as the other random sets) when you claim a poetry quest:
-- Poet Laureate (weekly), Poet for a Day and Poetry Critic (Dailies), the Poetry Showdown
-- (Group Daily), The Poets (Group Quest) and the Rebellion quest The Pamphlet War.
-- Codes: fpt1 (female) / mpt1 (male). Additive + idempotent. Run after 0070.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('pt1', 'Poet''s Salon', 'Drops from poetry quests.', 'random_drop',
   '[{"def":"pw_poet_laureate","chance":0.25},{"def":"gw_poets","chance":0.15},{"def":"gd_poetry_showdown","chance":0.10},{"def":"pd_poet_for_a_day","chance":0.10},{"def":"rb_pamphlet","chance":0.10},{"def":"pd_poetry_critic","chance":0.06}]', 10, 70)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
