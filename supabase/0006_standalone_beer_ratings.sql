-- =================================================================
-- OFFICE LORE — RATE A BEER WITHOUT A SESSION (required)
-- =================================================================
-- Lets a user log a personal rating for a beer directly from its
-- detail page, with no Beer Session required (session_id = null).
--
-- Reuses the exact same beer_ratings / beer_consumption tables and
-- the exact same existing XP triggers (xp_on_beer_rating_insert,
-- xp_on_beer_consumption_insert, xp_on_beer_consumption_adoption_check,
-- xp_on_beer_consumption_update, and the 0003 cleanup triggers)
-- completely unchanged — none of them reference session_id anywhere
-- in their logic, so a standalone row earns/loses XP through exactly
-- the same rules as a session-logged one, automatically.
--
-- Multiple standalone ratings for the same beer by the same user are
-- intentionally allowed (each is its own tasting occasion, matching
-- the rest of the app's event-log philosophy) — Postgres already
-- treats NULL as distinct in the existing unique(beer_id, session_id,
-- user_id) constraint, so no constraint changes are needed for this.
-- =================================================================

alter table public.beer_ratings alter column session_id drop not null;
alter table public.beer_consumption alter column session_id drop not null;

-- standalone-only fields (harmless/unused on session-linked rows,
-- which keep using the session's own date/location instead)
alter table public.beer_ratings add column rated_at date not null default current_date;
alter table public.beer_ratings add column context text;
