-- =================================================================
-- OFFICE LORE — BEER SESSION EDITING (required)
-- =================================================================
-- 1) Broadens Beer Club RLS so any of the 3 authenticated users can
--    edit an existing session (date/location, participants, beers,
--    ratings, consumption) on behalf of the group, not just the
--    original creator / row-owner.
--
--    This also fixes a latent bug in the ORIGINAL "create session"
--    flow: the score matrix already lets one person fill in every
--    OTHER participant's score/quantity too (that's the whole point
--    of a shared session log) — but the old owner-only policies
--    (`with check (user_id = auth.uid())`) would silently reject any
--    row in that batch insert that wasn't the creator's own,  which
--    (because Postgres RLS-checks a bulk insert atomically) likely
--    failed the ENTIRE beer_ratings/beer_consumption insert whenever
--    a session had more than one participant with data filled in.
--
-- 2) Adds a delta-XP trigger for beer_consumption UPDATEs, so editing
--    an existing quantity only awards/revokes XP for the DIFFERENCE,
--    never re-awards the full amount. Editing a rating (vs adding a
--    new one) already awards no extra XP by design — there's no
--    UPDATE trigger on beer_ratings, only the existing INSERT one.
-- =================================================================

-- ---- beer_sessions: date/location editable by any authenticated user ----
drop policy if exists "Beer sessions: only creator may update" on public.beer_sessions;
create policy "Beer sessions: authenticated may update"
  on public.beer_sessions for update to authenticated using (true) with check (true);

-- ---- beer_session_participants: add/remove by any authenticated user ----
drop policy if exists "Session participants: only session creator may add" on public.beer_session_participants;
drop policy if exists "Session participants: only session creator may remove" on public.beer_session_participants;
create policy "Session participants: authenticated may add"
  on public.beer_session_participants for insert to authenticated with check (true);
create policy "Session participants: authenticated may remove"
  on public.beer_session_participants for delete to authenticated using (true);

-- ---- beer_ratings: a session's scores are a shared group log, not
--      private per-user data -> any authenticated user may log/edit/
--      remove any row (row still always records the real user_id it
--      belongs to; this only changes who is ALLOWED to write it) ----
drop policy if exists "Beer ratings: only own rating may be added" on public.beer_ratings;
drop policy if exists "Beer ratings: only own rating may be updated" on public.beer_ratings;
drop policy if exists "Beer ratings: only own rating may be deleted" on public.beer_ratings;
create policy "Beer ratings: authenticated may add"
  on public.beer_ratings for insert to authenticated with check (true);
create policy "Beer ratings: authenticated may update"
  on public.beer_ratings for update to authenticated using (true) with check (true);
create policy "Beer ratings: authenticated may delete"
  on public.beer_ratings for delete to authenticated using (true);

-- ---- beer_consumption: same reasoning ----
drop policy if exists "Beer consumption: only own entry may be added" on public.beer_consumption;
drop policy if exists "Beer consumption: only own entry may be updated" on public.beer_consumption;
drop policy if exists "Beer consumption: only own entry may be deleted" on public.beer_consumption;
create policy "Beer consumption: authenticated may add"
  on public.beer_consumption for insert to authenticated with check (true);
create policy "Beer consumption: authenticated may update"
  on public.beer_consumption for update to authenticated using (true) with check (true);
create policy "Beer consumption: authenticated may delete"
  on public.beer_consumption for delete to authenticated using (true);


-- =================================================================
-- delta XP when an existing quantity is edited
-- =================================================================
create or replace function public.xp_on_beer_consumption_update()
returns trigger as $$
declare
  v_delta int;
begin
  v_delta := new.quantity - old.quantity;
  if v_delta <> 0 then
    insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
    values (new.user_id, 'beer', 'per_drink_adjustment', new.id, v_delta, 'Aanpassing aantal (' || old.quantity || ' -> ' || new.quantity || ')');
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_xp_beer_consumption_update
  after update on public.beer_consumption
  for each row
  when (old.quantity is distinct from new.quantity)
  execute procedure public.xp_on_beer_consumption_update();

-- extend the existing cleanup (0003_xp_cleanup_triggers.sql) so
-- adjustment XP is also removed if the consumption row is later
-- deleted entirely
create or replace function public.trg_fn_xp_cleanup_beer_consumption()
returns trigger as $$ begin
  perform public.xp_cleanup_by_source('per_drink', old.id);
  perform public.xp_cleanup_by_source('new_beer_tried', old.id);
  perform public.xp_cleanup_by_source('per_drink_adjustment', old.id);
  return old;
end; $$ language plpgsql security definer set search_path = public;
