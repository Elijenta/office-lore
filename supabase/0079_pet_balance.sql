-- =================================================================
-- 0079 — Pet balance: pets drop slowly, the armor looks are rare
--
-- For a database that already ran the first 0078 (a re-run of the current 0078 gives the same result):
--   * pets: per claim 2% (Dailies) / 6% (Weeklies, Group Weeklies) / 8% (Rebellion, Daily Sweep), pity only after 40 claims
--   * Mystery boxes: a pet is a smaller part of the box (weight 12, Sweep boxes 15)
--   * the Battle Gear (armor) looks are EPIC: 3-10% per claim of Battle quests, pity after 30 claims;
--     the Legendary Guardian pity after 100 claims
-- Tunable afterwards: challenge_config 'pet_drops' and pet_outfits.sources / pity_after. Idempotent.
-- =================================================================
update public.challenge_config set value =
  '{"chance": {"personal_daily": 0.02, "group_daily": 0.02, "personal_weekly": 0.06, "group_weekly": 0.06, "rebellion": 0.08, "sweep": 0.08}, "pity_after": 40}'
  where key = 'pet_drops';
update public.challenge_config set value = jsonb_set(value, '{pools,default,outcomes,pet}', '12'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'default';
update public.challenge_config set value = jsonb_set(value, '{pools,sweep,outcomes,pet}', '15'::jsonb, true)
  where key = 'mystery_rewards' and value->'pools' ? 'sweep';
update public.pet_outfits set rarity = 'epic', pity_after = 30,
  sources = '[{"def":"pw_battle_hardened","chance":0.1},{"def":"rb_storm","chance":0.08},{"def":"rb_seeds","chance":0.04},{"def":"pd_pick_a_side","chance":0.03}]'::jsonb
  where family = 'battle';
update public.pet_outfits set pity_after = 100 where id = 'dobermann-legendary';
