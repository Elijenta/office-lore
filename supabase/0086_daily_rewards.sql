-- =================================================================
-- 0086 — Fun rewards from the daily quests too
--
-- Until now an easy Daily paid XP only (10), a normal Daily had a 15% Mystery Reward and the Group Daily paid XP to everybody who took part.
-- A Mystery Reward is where the fun things live (pets and pet looks, nickname frames, wall items, titles, fragments, XP), so:
--   easy    10 XP + 10% Mystery Reward         (was: 10 XP)
--   normal  18 XP + 20% Mystery Reward         (was: 15%)
--   hard    30 XP + 50% Gauntlet Fragment + 20% Mystery Reward   (was: no box)
--   Group Daily, taking part: 15 XP + 10% Mystery Reward        (the winner keeps 30 XP + 25%)
-- (Chaos Dailies keep their own, already generous, table: 20 / 30 / 35% boxes.) Together with the Daily Sweep (a guaranteed box at 3 / 3) a
-- player now finds a box roughly every other day from Dailies alone. Tune it later in challenge_config ('difficulty_rewards',
-- 'group_daily_rewards'). New Dailies get these rewards from the next midnight on; a Daily that already exists keeps its old reward.
-- Idempotent.
-- =================================================================
update public.challenge_config set value = jsonb_set(jsonb_set(jsonb_set(value,
    '{easy}',   '[{"kind":"player_xp","amount":10},{"kind":"mystery","amount":1,"chance":0.10}]'::jsonb, true),
    '{normal}', '[{"kind":"player_xp","amount":18},{"kind":"mystery","amount":1,"chance":0.20}]'::jsonb, true),
    '{hard}',   '[{"kind":"player_xp","amount":30},{"kind":"gauntlet_fragments","amount":1,"chance":0.5},{"kind":"mystery","amount":1,"chance":0.20}]'::jsonb, true)
  where key = 'difficulty_rewards';
update public.challenge_config set value = jsonb_set(value, '{participation}', '[{"kind":"player_xp","amount":15},{"kind":"mystery","amount":1,"chance":0.10}]'::jsonb, true)
  where key = 'group_daily_rewards';
