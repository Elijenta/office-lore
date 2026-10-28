-- =================================================================
-- OFFICE LORE — outfit set 'be3' "Barista's Brew" (beer discovery)
-- =================================================================
-- A third beer outfit, for both bases. Random drop (its own pity counter, like the other random sets) when you claim a beer quest:
-- Beer Explorer (weekly), The Gathering (Group Quest), Beer Scholar, New Brew, One for the Books (Dailies) and the Group Weekly with 2 sessions.
-- Codes: fbe3 (female) / mbe3 (male). Additive + idempotent. Run after 0090.
-- =================================================================
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('be3', 'Barista''s Brew', 'Drops from beer quests.', 'random_drop',
   '[{"def":"pw_beer_explorer","chance":0.20},{"def":"gw_gathering","chance":0.15},{"def":"gw_sessions_2","chance":0.12},{"def":"pd_beer_scholar","chance":0.06},{"def":"pd_new_brew","chance":0.06},{"def":"pd_one_for_the_books","chance":0.06}]', 10, 25)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources, pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;
