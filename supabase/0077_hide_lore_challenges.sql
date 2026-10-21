-- =================================================================
-- 0077 — Lore-challenges tijdelijk verbergen (te weinig lore in de app)
--
-- Zet de lore-gerelateerde challenge-definities op inactief, zodat ze
-- niet meer getrokken worden voor nieuwe dailies/weeklies:
--   pd_quote_hunter  (Quote Hunter)
--   pd_memory_lane   (Memory Lane)
--   pd_lore_keeper   (Lore Keeper, anekdote bij een nickname)
--   pw_lorekeeper    (The Lorekeeper, weekly)
-- Bestaande assignments (al getrokken) blijven gewoon spelen en
-- claimbaar; niets wordt verwijderd.
--
-- TERUGZETTEN zodra er genoeg lore is:
--   update public.challenge_definitions set is_active = true
--    where id in ('pd_quote_hunter','pd_memory_lane','pd_lore_keeper','pw_lorekeeper');
-- (Let op: 0049/0052 opnieuw draaien zet ze ook weer aan.)
-- Idempotent.
-- =================================================================
update public.challenge_definitions
   set is_active = false
 where id in ('pd_quote_hunter','pd_memory_lane','pd_lore_keeper','pw_lorekeeper');
