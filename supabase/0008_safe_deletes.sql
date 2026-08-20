-- =================================================================
-- OFFICE LORE — SAFE DELETES for Beer Sessions + counter events
-- =================================================================
-- 1) RLS broadening (same "shared session log" reasoning already used
--    in 0005_beer_session_editing.sql): any authenticated user may
--    delete a beer_sessions/perfect_pours/counter_events row, not
--    just its creator/giver/logger. Required for the app's new
--    "Delete Session" feature to work via a single cascading delete
--    regardless of who's deleting — Postgres checks RLS per-row even
--    for cascaded deletes, so a narrower policy would make the whole
--    delete fail with a foreign-key violation whenever a cascaded
--    row (e.g. someone else's Perfect Pour vote) belongs to another
--    user.
-- 2) Smarter beer_consumption delete cleanup: deleting the specific
--    row that earned "new beer tried" XP no longer just deletes that
--    XP — if the user still has OTHER consumption of the same beer,
--    the XP is reassigned to one of those rows instead of being lost.
--    Also revokes "own beer adopted" XP if a delete drops a beer's
--    distinct-drinker count back under 2.
-- =================================================================

-- ---- 1. RLS broadening ----
drop policy if exists "Beer sessions: only creator may delete" on public.beer_sessions;
create policy "Beer sessions: authenticated may delete"
  on public.beer_sessions for delete to authenticated using (true);

drop policy if exists "Perfect pours: only own vote may be retracted" on public.perfect_pours;
create policy "Perfect pours: authenticated may delete"
  on public.perfect_pours for delete to authenticated using (true);

drop policy if exists "Counter events: only own entry may be deleted" on public.counter_events;
create policy "Counter events: authenticated may delete"
  on public.counter_events for delete to authenticated using (true);


-- ---- 2. smarter beer_consumption delete cleanup ----
-- replaces the version from 0003_xp_cleanup_triggers.sql
create or replace function public.trg_fn_xp_cleanup_beer_consumption()
returns trigger as $$
declare
  v_new_beer_tried_event_id uuid;
  v_replacement_row_id uuid;
  v_remaining_drinkers int;
begin
  -- per_drink and per_drink_adjustment are simple 1:1 cleanups, unchanged
  perform public.xp_cleanup_by_source('per_drink', old.id);
  perform public.xp_cleanup_by_source('per_drink_adjustment', old.id);

  -- new_beer_tried: reassign to another remaining row for the same
  -- beer+user if one exists, instead of just losing the XP
  select id into v_new_beer_tried_event_id
  from public.xp_events
  where source_type = 'new_beer_tried' and source_id = old.id
  limit 1;

  if v_new_beer_tried_event_id is not null then
    select id into v_replacement_row_id
    from public.beer_consumption
    where beer_id = old.beer_id and user_id = old.user_id and id <> old.id
    order by created_at asc
    limit 1;

    if v_replacement_row_id is not null then
      update public.xp_events set source_id = v_replacement_row_id where id = v_new_beer_tried_event_id;
    else
      delete from public.xp_events where id = v_new_beer_tried_event_id;
    end if;
  end if;

  -- own_beer_adopted: revoke if this beer no longer has >=2 distinct drinkers
  select count(distinct user_id) into v_remaining_drinkers
  from public.beer_consumption
  where beer_id = old.beer_id;

  if v_remaining_drinkers < 2 then
    delete from public.xp_events where source_type = 'own_beer_adopted' and source_id = old.beer_id;
  end if;

  return old;
end;
$$ language plpgsql security definer set search_path = public;
