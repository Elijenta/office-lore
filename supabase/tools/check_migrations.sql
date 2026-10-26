-- Plak dit in de Supabase SQL editor: het toont per migratie of die al is toegepast (alleen lezen, past niets aan).
-- Alles met "toegepast = false" moet je nog draaien, in nummervolgorde, elk bestand 1x.
select * from (values
  (48, 'challenge engine',        to_regclass('public.challenge_definitions') is not null),
  (49, 'personal dailies',        exists (select 1 from public.challenge_definitions where id = 'pd_poet_for_a_day')),
  (50, 'chaos dailies',           exists (select 1 from public.challenge_definitions where id = 'pd_royal_decree')),
  (51, 'group daily',             exists (select 1 from public.challenge_definitions where id = 'gd_daily_chaos')),
  (52, 'personal weeklies',       exists (select 1 from public.challenge_definitions where id = 'pw_beer_explorer')),
  (53, 'group weekly quests',     exists (select 1 from public.challenge_definitions where id = 'gw_fellowship')),
  (54, 'gauntlet fragments',      to_regclass('public.gauntlet_fragments') is not null),
  (55, 'rebellion quests',        exists (select 1 from public.challenge_definitions where id = 'rb_seeds')),
  (56, 'mystery rewards',         to_regclass('public.mystery_boxes') is not null),
  (63, 'character outfits (RPC)', to_regprocedure('public.set_room_character(text,text)') is not null),
  (66, 'outfit unlocks',          to_regclass('public.character_outfit_sets') is not null),
  (75, 'titles',                  to_regclass('public.character_titles') is not null),
  (76, 'daily poem templates',    to_regclass('public.daily_poem_templates') is not null),
  (77, 'lore quests verborgen',   exists (select 1 from public.challenge_definitions where id = 'pd_quote_hunter' and not is_active)),
  (78, 'pets',                    to_regclass('public.pet_species') is not null),
  (79, 'pet balance',             exists (select 1 from public.challenge_config where key = 'pet_drops' and (value->'chance'->>'personal_daily')::numeric = 0.02)),
  (80, 'quest guide',             to_regprocedure('public.get_quest_guide()') is not null),
  (82, 'nickname frames',         to_regclass('public.nickname_frames') is not null),
  (83, 'seasonal outfits',        to_regclass('public.character_seasonal_outfits') is not null),
  (84, 'taproom wall',            to_regclass('public.wall_neon_signs') is not null),
  (85, 'wall: 1 neon sign',       exists (select 1 from pg_proc where proname = 'set_wall_neons' and pg_get_functiondef(oid) like '%Only 1 neon sign%')),
  (86, 'daily rewards',           exists (select 1 from public.challenge_config where key = 'difficulty_rewards' and (value->'easy') @> '[{"kind":"mystery"}]'::jsonb)),
  (87, 'poem backgrounds',        to_regclass('public.poem_backgrounds') is not null),
  (88, 'room furniture',          to_regclass('public.room_furniture_items') is not null),
  (89, 'more poem reactions',     exists (select 1 from pg_constraint where conname = 'poem_reactions_type_format'))
) as t(migration, wat, toegepast) order by migration;
-- (de outfit-sets 67 t/m 74 zie je met:  select id, name from public.character_outfit_sets order by sort_order;
--  verwacht: be1, be2, lk1, bt1, ch1, cp1, pt1, qz1, rb1, lg1, lg2)
