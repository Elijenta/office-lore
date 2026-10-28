-- =================================================================
-- OFFICE LORE / TRIPEL TALES — MORE HALLOWEEN OUTFITS
-- =================================================================
-- Two new Halloween pictures: a male Vampire (hw2, was female only) and a female Zombie nurse (hw3, was male only).
-- Same ids, so only the 'genders' change. The pictures are in the app (supabase/tools/build_seasonal_images.py).
-- Additive + idempotent. Run after 0083.
-- =================================================================
update public.character_seasonal_outfits set genders = '{f,m}', name = 'Vampire' where id = 'hw2';
update public.character_seasonal_outfits set genders = '{f,m}', name = 'Zombie'  where id = 'hw3';
