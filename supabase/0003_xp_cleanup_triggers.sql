-- =================================================================
-- OFFICE LORE — XP CLEANUP TRIGGERS (required, run after 0001)
-- =================================================================
-- xp_events.source_id is a plain uuid (it can point at rows in many
-- different tables, so it can't be a single foreign key), which means
-- it does NOT get cleaned up automatically when the source row is
-- deleted. Without this, deleting a nickname/quote/anecdote/counter/
-- beer, or moving a Perfect Pour vote, would leave stale XP behind.
-- These triggers remove the matching xp_events row(s) whenever their
-- source is deleted (including via cascade, e.g. deleting a nickname
-- cascades to its nickname_events, which fires the cleanup below too).
-- =================================================================

create or replace function public.xp_cleanup_by_source(p_source_type text, p_source_id uuid)
returns void as $$
begin
  delete from public.xp_events where source_type = p_source_type and source_id = p_source_id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.trg_fn_xp_cleanup_nickname()
returns trigger as $$ begin perform public.xp_cleanup_by_source('nickname', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_nickname_delete after delete on public.nicknames for each row execute procedure public.trg_fn_xp_cleanup_nickname();

create or replace function public.trg_fn_xp_cleanup_nickname_event()
returns trigger as $$ begin perform public.xp_cleanup_by_source('nickname_event', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_nickname_event_delete after delete on public.nickname_events for each row execute procedure public.trg_fn_xp_cleanup_nickname_event();

create or replace function public.trg_fn_xp_cleanup_quote()
returns trigger as $$ begin
  perform public.xp_cleanup_by_source('quote', old.id);
  perform public.xp_cleanup_by_source('quote_bonus', old.id);
  return old;
end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_quote_delete after delete on public.quotes for each row execute procedure public.trg_fn_xp_cleanup_quote();

create or replace function public.trg_fn_xp_cleanup_anecdote()
returns trigger as $$ begin
  perform public.xp_cleanup_by_source('anecdote', old.id);
  perform public.xp_cleanup_by_source('anecdote_bonus', old.id);
  return old;
end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_anecdote_delete after delete on public.anecdotes for each row execute procedure public.trg_fn_xp_cleanup_anecdote();

create or replace function public.trg_fn_xp_cleanup_counter_event()
returns trigger as $$ begin perform public.xp_cleanup_by_source('counter_event', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_counter_event_delete after delete on public.counter_events for each row execute procedure public.trg_fn_xp_cleanup_counter_event();

create or replace function public.trg_fn_xp_cleanup_beer_rating()
returns trigger as $$ begin perform public.xp_cleanup_by_source('rating_given', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_beer_rating_delete after delete on public.beer_ratings for each row execute procedure public.trg_fn_xp_cleanup_beer_rating();

create or replace function public.trg_fn_xp_cleanup_beer_consumption()
returns trigger as $$ begin
  perform public.xp_cleanup_by_source('per_drink', old.id);
  perform public.xp_cleanup_by_source('new_beer_tried', old.id);
  return old;
end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_beer_consumption_delete after delete on public.beer_consumption for each row execute procedure public.trg_fn_xp_cleanup_beer_consumption();

create or replace function public.trg_fn_xp_cleanup_beer()
returns trigger as $$ begin perform public.xp_cleanup_by_source('own_beer_adopted', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_beer_delete after delete on public.beers for each row execute procedure public.trg_fn_xp_cleanup_beer();

create or replace function public.trg_fn_xp_cleanup_perfect_pour()
returns trigger as $$ begin perform public.xp_cleanup_by_source('perfect_pour', old.id); return old; end; $$ language plpgsql security definer set search_path = public;
create trigger trg_xp_cleanup_perfect_pour_delete after delete on public.perfect_pours for each row execute procedure public.trg_fn_xp_cleanup_perfect_pour();
