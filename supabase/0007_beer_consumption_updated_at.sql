-- =================================================================
-- OFFICE LORE — beer_consumption.updated_at (required)
-- =================================================================
-- Additive-only: adds the one column named in the "per-participant
-- consumption" schema that was actually missing (updated_at), plus a
-- trigger to keep it current on quantity edits. No existing data is
-- touched, no constraints change — the unique(beer_id, session_id,
-- user_id) constraint this bugfix relies on already exists from
-- 0001_schema.sql.
-- =================================================================

alter table public.beer_consumption add column updated_at timestamptz not null default now();

create trigger trg_beer_consumption_updated_at
  before update on public.beer_consumption
  for each row execute procedure public.set_updated_at();
