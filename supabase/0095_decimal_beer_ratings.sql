-- =================================================================
-- OFFICE LORE / TRIPEL TALES — DECIMAL BEER RATINGS
-- =================================================================
-- Beer scores can now have one decimal (7,5 / 8,3). The column was an integer 1..10, so a score like 7.5 could not be saved.
-- Becomes numeric(3,1) between 0.5 and 10 (existing whole-number scores stay exactly as they are).
-- Additive + idempotent. Run any time.
-- =================================================================
alter table public.beer_ratings drop constraint if exists beer_ratings_rating_check;
alter table public.beer_ratings alter column rating type numeric(3,1) using rating::numeric;
alter table public.beer_ratings add constraint beer_ratings_rating_check check (rating is null or rating between 0.5 and 10);
