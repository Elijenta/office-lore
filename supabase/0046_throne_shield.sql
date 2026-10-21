-- =================================================================
-- OFFICE LORE — 🛡️ THRONE SHIELD (a small defensive progression)
-- =================================================================
-- An Abt Lord who has held the throne for _throne_shield_days() days earns a
-- Throne Shield (config: 7). At most ONE can be held at a time.
--
-- It never blocks a challenge. It is a tactical tool: ONCE per Throne
-- Challenge the Abt Lord can "Invoke the Shield" to have ONE lost DIGITAL
-- Trial replaced by a new Trial (same Trial number, same school when possible,
-- a different Trial). It cannot be used on anything a Royal Judge decided
-- (Creative and Real Life Trials), only on automatically scored Trials
-- (roll, one-number guess, quiz, Rapid Fire, Sudden Death).
--
-- WHEN IT CAN BE USED: the SHIELD WINDOW
--   When the Abt Lord loses such a Trial while holding a ready Shield (and has
--   not used one in this challenge), the series is HELD for up to 24h before
--   going on, whatever the score. That includes the decisive loss: without the
--   window a Shield could never save the throne. In the window the Lord can
--     INVOKE THE SHIELD  the lost Trial is voided (its point is taken back),
--                        the Shield is broken, and a replacement Trial starts
--     CONTINUE           the loss stands, the series goes on, the Shield stays
--   If the Lord does nothing for 24h the window closes like CONTINUE.
--   Lost-by-timeout Trials (a no-show) never open a window.
--
-- LIFECYCLE (persistent, table throne_shields)
--   earned   a row for (user, reign) the first time the Lord's reign has lasted
--            the configured days, and again that many days after a Shield
--            broke. Granted lazily (no pg_cron) by sync_throne_shield().
--   ready    the row has used_at = null (and its reign is still the open one)
--   broken   used_at set, with the challenge and Trial it was used on
--   A Shield belongs to the reign: when the Lord is dethroned an unused Shield
--   is simply never usable again (the next reign starts from scratch).
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0045.
-- =================================================================

-- =================================================================
-- SECTION 1 — config, tables, columns
-- =================================================================
create or replace function public._throne_shield_days() returns int as $$
  select 7;
$$ language sql immutable;

create or replace function public.get_throne_rules()
returns jsonb as $$
  select jsonb_build_object(
    'cooldown_hours', extract(epoch from public._throne_cooldown()) / 3600,
    'gauntlet_cost', public._throne_gauntlet_cost(),
    'shield_days', public._throne_shield_days()
  );
$$ language sql stable security definer set search_path = public;

create table if not exists public.throne_shields (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  reign_id uuid not null references public.abt_reigns(id),
  earned_at timestamptz not null default now(),
  used_at timestamptz,
  used_challenge_id uuid references public.throne_challenges(id),
  used_trial_id uuid references public.throne_challenge_trials(id)
);
-- at most one UNUSED shield per user per reign: never more than one held
create unique index if not exists throne_shields_one_ready on public.throne_shields (user_id, reign_id) where used_at is null;
-- a challenge can use a shield only once
create unique index if not exists throne_shields_one_per_challenge on public.throne_shields (used_challenge_id) where used_challenge_id is not null;

alter table public.throne_shields enable row level security;
drop policy if exists "Throne shields: read" on public.throne_shields;
create policy "Throne shields: read" on public.throne_shields for select to authenticated
  using (public.is_app_member('officelore'));

do $$
begin
  begin
    alter publication supabase_realtime add table public.throne_shields;
  exception when duplicate_object then null;
  end;
end $$;

alter table public.throne_challenges
  add column if not exists shield_window_trial_id uuid references public.throne_challenge_trials(id),
  add column if not exists shield_window_until timestamptz,
  add column if not exists shield_used_at timestamptz;

-- =================================================================
-- SECTION 2 — the series, held and advanced
-- =================================================================
-- the continuation that used to live inside _finish_throne_trial
create or replace function public._advance_throne_series(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_last_no int;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.status in ('completed', 'cancelled') then return; end if;

  if c.challenger_score >= 2 then
    perform public._complete_throne_challenge(c.id, c.challenger_user_id);
  elsif c.defender_score >= 2 then
    perform public._complete_throne_challenge(c.id, c.defender_user_id);
  else
    select max(trial_no) into v_last_no from public.throne_challenge_trials where challenge_id = c.id and status = 'completed';
    if coalesce(v_last_no, 1) = 1 then
      -- Trial 2: the Abt Lord picks the school
      update public.throne_challenges
        set status = 'active', awaiting_pick_by = c.defender_user_id, step_deadline = now() + interval '48 hours'
        where id = c.id;
    else
      -- 1-1 after Trial 2: THE FINAL TRIAL, the throne chooses
      v_cat := public._pick_final_throne_trial(c.id);
      perform public._start_throne_trial(c.id, v_cat, null);
    end if;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._finish_throne_trial(p_trial_id uuid, p_winner uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_chal int;
  v_def int;
  v_shield boolean;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.status = 'completed' then
    return;
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id for update;
  if p_winner not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Trial winner must be a participant';
  end if;

  update public.throne_challenge_trials
    set status = 'completed', winner_user_id = p_winner, completed_at = now()
    where id = t.id;

  v_chal := c.challenger_score + case when p_winner = c.challenger_user_id then 1 else 0 end;
  v_def := c.defender_score + case when p_winner = c.defender_user_id then 1 else 0 end;
  update public.throne_challenges set challenger_score = v_chal, defender_score = v_def where id = c.id;

  -- the Abt Lord just lost an automatically scored Trial while holding a ready
  -- Throne Shield: hold the series for the Shield window
  v_shield := p_winner = c.challenger_user_id
    and t.resolution in ('roll', 'answer', 'quiz', 'timed', 'streak')
    and not coalesce((t.reveal->>'timeout')::boolean, false)
    and c.shield_used_at is null
    and exists (select 1 from public.abt_reigns r where r.id = c.reign_id and r.ended_at is null)
    and exists (select 1 from public.throne_shields s
                where s.user_id = c.defender_user_id and s.reign_id = c.reign_id and s.used_at is null);
  if v_shield then
    update public.throne_challenges
      set status = 'active', awaiting_pick_by = null,
          shield_window_trial_id = t.id, shield_window_until = now() + interval '24 hours',
          step_deadline = now() + interval '24 hours'
      where id = c.id;
    return;
  end if;

  perform public._advance_throne_series(c.id);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — earn, invoke, decline
-- =================================================================
-- Grants the Lord's shield when it is due. Idempotent. Returns the state.
create or replace function public.sync_throne_shield()
returns jsonb as $$
declare
  v_reign public.abt_reigns;
  v_days int := public._throne_shield_days();
  v_base timestamptz;
  v_granted boolean := false;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(hashtext('sync_throne_shield:' || auth.uid()::text));

  select * into v_reign from public.abt_reigns where user_id = auth.uid() and ended_at is null limit 1;
  if v_reign.id is null then
    return jsonb_build_object('state', 'none', 'granted', false);
  end if;

  if not exists (select 1 from public.throne_shields where user_id = auth.uid() and reign_id = v_reign.id and used_at is null) then
    -- the clock starts at the crowning, or when the last shield broke
    v_base := greatest(v_reign.started_at, coalesce((select max(used_at) from public.throne_shields where user_id = auth.uid() and reign_id = v_reign.id), v_reign.started_at));
    if now() >= v_base + make_interval(days => v_days) then
      insert into public.throne_shields (user_id, reign_id) values (auth.uid(), v_reign.id)
        on conflict do nothing;
      v_granted := true;
    end if;
  end if;

  return jsonb_build_object('state',
    case when exists (select 1 from public.throne_shields where user_id = auth.uid() and reign_id = v_reign.id and used_at is null) then 'ready'
         when exists (select 1 from public.throne_shields where user_id = auth.uid() and reign_id = v_reign.id) then 'broken'
         else 'building' end,
    'granted', v_granted);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.invoke_throne_shield(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
  t public.throne_challenge_trials;
  v_shield public.throne_shields;
  v_cat public.throne_trial_catalog;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.id is null or c.status <> 'active' or c.shield_window_trial_id is null or c.shield_window_until is null or c.shield_window_until <= now() then
    raise exception 'The Throne Shield cannot be invoked right now';
  end if;
  if auth.uid() <> c.defender_user_id then
    raise exception 'Only the Abt Lord can invoke the Throne Shield';
  end if;
  if c.shield_used_at is not null then
    raise exception 'The Throne Shield was already used in this challenge';
  end if;

  select * into v_shield from public.throne_shields
    where user_id = auth.uid() and reign_id = c.reign_id and used_at is null for update;
  if v_shield.id is null then
    raise exception 'You have no Throne Shield ready';
  end if;

  select * into t from public.throne_challenge_trials where id = c.shield_window_trial_id for update;
  if t.status <> 'completed' or t.winner_user_id <> c.challenger_user_id
     or t.resolution not in ('roll', 'answer', 'quiz', 'timed', 'streak') then
    raise exception 'The Shield only works on a lost, automatically scored Trial';
  end if;

  -- take the point back, void the Trial, break the Shield
  update public.throne_challenges
    set challenger_score = challenger_score - 1, shield_used_at = now(),
        shield_window_trial_id = null, shield_window_until = null
    where id = c.id;
  update public.throne_challenge_trials
    set status = 'voided',
        reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('voided', true, 'shield', true, 'shield_by', auth.uid())
    where id = t.id;
  update public.throne_shields
    set used_at = now(), used_challenge_id = c.id, used_trial_id = t.id
    where id = v_shield.id;

  -- the replacement Trial (same number, same school if possible, never one already used);
  -- if none is left this whole call rolls back and the Shield stays unbroken
  v_cat := public._pick_catalog_trial(c.id, t.school);
  perform public._start_throne_trial(c.id, v_cat, t.picker_user_id);
end;
$$ language plpgsql security definer set search_path = public;

-- "Continue": the loss stands, the Shield stays ready
create or replace function public.decline_throne_shield(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.id is null or c.status <> 'active' or c.shield_window_trial_id is null then
    raise exception 'There is no Shield decision pending';
  end if;
  if auth.uid() <> c.defender_user_id then
    raise exception 'Only the Abt Lord can decide about the Throne Shield';
  end if;

  update public.throne_challenges set shield_window_trial_id = null, shield_window_until = null where id = c.id;
  perform public._advance_throne_series(c.id);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — deadline resolver (replaces 0042's; adds the Shield window)
-- =================================================================
create or replace function public._resolve_expired_throne_challenge()
returns boolean as $$
declare
  c public.throne_challenges;
  t public.throne_challenge_trials;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_changed boolean := false;
  v_guard int := 0;
begin
  perform pg_advisory_xact_lock(918273645);

  if public._finalize_expired_runs() then
    v_changed := true;
  end if;

  loop
    v_guard := v_guard + 1;
    exit when v_guard > 10;

    select * into c from public.throne_challenges
      where status in ('pending', 'active', 'awaiting_judge')
        and step_deadline is not null and step_deadline <= now()
      limit 1;
    exit when c.id is null;
    v_changed := true;

    if c.shield_window_until is not null and c.shield_window_until <= now() then
      -- the Abt Lord let the Shield window close: same as CONTINUE
      update public.throne_challenges set shield_window_trial_id = null, shield_window_until = null where id = c.id;
      perform public._advance_throne_series(c.id);
      continue;
    end if;

    if c.status = 'pending' then
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;

    elsif c.awaiting_pick_by is not null then
      v_cat := public._pick_catalog_trial(c.id, null);
      perform public._start_throne_trial(c.id, v_cat, c.awaiting_pick_by);

    else
      select * into t from public.throne_challenge_trials
        where challenge_id = c.id and status in ('active', 'awaiting_judge')
        order by trial_no desc, attempt desc limit 1;

      if t.id is null then
        update public.throne_challenges
          set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
          where id = c.id;
      else
        if t.resolution in ('quiz', 'timed', 'streak') then
          perform public._finalize_throne_run(t.id, c.challenger_user_id, 'deadline');
          perform public._finalize_throne_run(t.id, c.defender_user_id, 'deadline');
          select * into t from public.throne_challenge_trials where id = t.id;
          continue when t.status = 'completed';
        end if;

        if t.status = 'awaiting_judge' then
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        elsif t.challenger_submitted and not t.defender_submitted then
          v_winner := c.challenger_user_id;
        elsif t.defender_submitted and not t.challenger_submitted then
          v_winner := c.defender_user_id;
        else
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        end if;
        update public.throne_challenge_trials
          set reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('timeout', true)
                       || case when t.resolution = 'creative' then jsonb_build_object('entries', public._throne_creative_reveal(t.id)) else '{}'::jsonb end
          where id = t.id;
        perform public._finish_throne_trial(t.id, v_winner);
      end if;
    end if;
  end loop;

  return v_changed;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — grants
-- =================================================================
revoke all on function public._throne_shield_days() from public, anon, authenticated;
revoke all on function public._advance_throne_series(uuid) from public, anon, authenticated;
revoke all on function public._finish_throne_trial(uuid, uuid) from public, anon, authenticated;
revoke all on function public._resolve_expired_throne_challenge() from public, anon, authenticated;

revoke all on function public.sync_throne_shield() from public, anon;
revoke all on function public.invoke_throne_shield(uuid) from public, anon;
revoke all on function public.decline_throne_shield(uuid) from public, anon;
grant execute on function public.sync_throne_shield() to authenticated;
grant execute on function public.invoke_throne_shield(uuid) to authenticated;
grant execute on function public.decline_throne_shield(uuid) to authenticated;
