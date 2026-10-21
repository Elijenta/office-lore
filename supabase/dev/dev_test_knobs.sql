-- DEV ONLY: knoppen om sneller dingen te zien. Draai het in het DEV-project (nooit in productie).
-- Pets en outfits vallen bijna elke claim; kisten bevatten vooral pets. Zet terug met 0079 + 0080 opnieuw te draaien in dev.
update public.challenge_config set value =
  '{"chance": {"personal_daily": 0.5, "group_daily": 0.5, "personal_weekly": 1, "group_weekly": 1, "rebellion": 1, "sweep": 1}, "pity_after": 3}'
  where key = 'pet_drops';
update public.pet_outfits set pity_after = 3 where unlock_kind = 'random_drop';
update public.character_outfit_sets set pity_after = 3 where unlock_kind = 'random_drop';
