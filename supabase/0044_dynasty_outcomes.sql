-- =================================================================
-- OFFICE LORE — THE OUTCOME OF A THRONE CHALLENGE (Dynasty history)
-- =================================================================
-- Makes the end of a Throne Challenge fully recorded in the Dynasty:
--
--   CHALLENGER WINS  the old reign is closed (ended_at, ending_beer_xp,
--                    dethroned_by, loadout snapshot, and now also WHICH
--                    challenge ended it), a new reign is opened for the
--                    challenger (linked to its predecessor and to the winning
--                    challenge). The challenger's "throne captures" go up
--                    because a capture IS a reign. Beer XP is never touched:
--                    starting_beer_xp / ending_beer_xp are only snapshots.
--   DEFENDER WINS    abt_reigns.successful_defenses +1 on the reign that was
--                    defended (a stored counter, so it can become an
--                    achievement / statistic later without recomputing).
--
-- New abt_reigns columns (all additive, history is preserved):
--   predecessor_reign_id   the reign this one followed
--   won_challenge_id       the Throne Challenge that started this reign
--   ended_by_challenge_id  the Throne Challenge that ended this reign
--   successful_defenses    challenges successfully defended during this reign
--
-- Challenge wins / losses are derived from throne_challenges (completed rows),
-- not stored twice.
--
-- THE FALLEN ABT is derived (the lord whose reign ended most recently, for a
-- limited window, see the client). Nothing is deleted: cosmetics, loadouts and
-- Beer XP stay exactly as they were.
--
-- HIGH BREWMASTER is independent of the throne: whoever has the most Beer XP
-- (user_xp_totals) is High Brewmaster whether or not they sit on the throne,
-- so a dethroned lord with the most Beer XP simply stays High Brewmaster.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0043.
-- =================================================================

-- =================================================================
-- SECTION 1 — columns + backfill
-- =================================================================
alter table public.abt_reigns
  add column if not exists predecessor_reign_id uuid references public.abt_reigns(id),
  add column if not exists won_challenge_id uuid references public.throne_challenges(id),
  add column if not exists ended_by_challenge_id uuid references public.throne_challenges(id),
  add column if not exists successful_defenses int not null default 0;

-- predecessor of every existing reign = the reign before it
update public.abt_reigns r
  set predecessor_reign_id = p.prev_id
  from (select id, lag(id) over (order by started_at) as prev_id from public.abt_reigns) p
  where p.id = r.id and r.predecessor_reign_id is null and p.prev_id is not null;

-- successful defenses so far = completed challenges the sitting lord won
update public.abt_reigns r
  set successful_defenses = d.n
  from (select reign_id, count(*) as n from public.throne_challenges
        where status = 'completed' and winner_user_id = defender_user_id group by reign_id) d
  where d.reign_id = r.id;

-- link reigns to the challenge that ended / started them
update public.abt_reigns r
  set ended_by_challenge_id = c.id
  from public.throne_challenges c
  where c.reign_id = r.id and c.status = 'completed' and c.winner_user_id = c.challenger_user_id
    and r.ended_at is not null and r.dethroned_by_user_id = c.challenger_user_id and r.ended_by_challenge_id is null;
update public.abt_reigns r
  set won_challenge_id = x.ended_by_challenge_id
  from public.abt_reigns x
  where r.predecessor_reign_id = x.id and x.ended_by_challenge_id is not null and r.won_challenge_id is null;

-- =================================================================
-- SECTION 2 — the outcome (replaces 0038's)
-- =================================================================
create or replace function public._complete_throne_challenge(p_challenge_id uuid, p_winner uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_reign record;
  v_def_total int;
  v_chal_total int;
  v_snapshot jsonb;
  v_new_reign uuid;
begin
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.status in ('completed', 'cancelled') then
    return; -- idempotent: an outcome is registered exactly once
  end if;

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;

  if p_winner = c.challenger_user_id then
    if v_reign is null or v_reign.id <> c.reign_id then
      -- the challenged reign is no longer the open one: nothing to take
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;
      return;
    end if;

    -- Beer XP is only READ here, as a snapshot for the history. It is never changed.
    select coalesce(beer_xp, 0) into v_def_total from public.user_xp_totals where user_id = c.defender_user_id;
    select coalesce(beer_xp, 0) into v_chal_total from public.user_xp_totals where user_id = c.challenger_user_id;
    select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = c.defender_user_id;

    -- close the old reign
    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_def_total, dethroned_by_user_id = c.challenger_user_id,
          ending_loadout_snapshot = v_snapshot, ended_by_challenge_id = c.id
      where id = v_reign.id;

    -- open the new one: the challenger is the Abt Lord (this is a throne capture)
    insert into public.abt_reigns (user_id, started_at, starting_beer_xp, predecessor_reign_id, won_challenge_id)
    values (c.challenger_user_id, now(), v_chal_total, v_reign.id, c.id)
    returning id into v_new_reign;

  elsif p_winner = c.defender_user_id then
    -- the throne stands: register the successful defense on the defended reign
    update public.abt_reigns set successful_defenses = successful_defenses + 1
      where id = c.reign_id and ended_at is null;
  end if;

  update public.throne_challenges
    set status = 'completed', winner_user_id = p_winner, completed_at = now(), resolved_at = now(),
        awaiting_pick_by = null, step_deadline = null
    where id = c.id;

  perform public._sync_absolute_abt();
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public._complete_throne_challenge(uuid, uuid) from public, anon, authenticated;
