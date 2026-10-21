-- =================================================================
-- OFFICE LORE — outfit set 'ch1' "Court Jester" (Chaos)
-- =================================================================
-- Random drop (same pity counter as the other random sets) when you claim a Chaos quest:
-- Agent of Chaos (weekly), any of the 8 Chaos Dailies and the Group Daily "Daily Chaos".
-- Codes: fch1 (female) / mch1 (male). Additive + idempotent. Run after 0068.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('ch1', 'Court Jester', 'Drops from Chaos quests.', 'random_drop',
   '[{"def":"pw_agent_of_chaos","chance":0.25},{"def":"gd_daily_chaos","chance":0.10},
     {"def":"pd_draw_this","chance":0.10},{"def":"pd_the_impostor","chance":0.10},{"def":"pd_the_photographer","chance":0.10},
     {"def":"pd_royal_decree","chance":0.06},{"def":"pd_office_safari","chance":0.06},{"def":"pd_emoji_lore","chance":0.06},
     {"def":"pd_five_seconds","chance":0.06},{"def":"pd_tiny_quest","chance":0.06}]', 10, 50)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
