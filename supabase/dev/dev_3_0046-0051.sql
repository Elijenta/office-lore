-- DEV bundle part 3/5: migrations 0046 to 0051. Run the parts in order, each once, in a NEW empty Supabase project (never in production).

-- =========== 0046_throne_shield.sql ===========
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

-- =========== 0047_coup_detat.sql ===========
-- =================================================================
-- OFFICE LORE — ⚔️⚔️ COUP D'ÉTAT (a rare 2 vs 1 Throne event)
-- =================================================================
-- Two members who are NOT the Abt Lord rise against the sitting Abt Lord
-- together. It is deliberately separate from (and rarer than) the normal
-- "Challenge the Throne", which stays the standard way to take the crown.
--
-- REQUIREMENTS
--   * both challengers hold a Royal Gauntlet and are not in cooldown
--   * both CONFIRM: one proposes (propose_coup), the other confirms
--     (confirm_coup). The Gauntlets (1 each) are spent only when the second
--     one confirms; an unconfirmed proposal lapses after 24h, nothing spent.
--   * at most one Coup per reign per 30 days (config, see below)
--   * no other Throne Challenge may be open
--
-- THE FORMAT: a relay, Lord against the duo   (best of 5, first to 3)
--   Five Trials, picked by the SYSTEM (not by any player): one from each of
--   Pint, Lore, Wisdom, Chaos and Real Life, in a random order. Chaos and Real
--   Life need an independent Royal Judge; with only three members there is none
--   (everybody is in the Coup), so those slots fall back to a Trial of another
--   school. With a fourth member they appear automatically.
--   Every Trial is an ordinary one-on-one Trial: the Lord against ONE duo
--   member, and the two duo members take turns (random who starts, then
--   alternating). The duo's score is the team's score; the Lord needs 3 wins
--   too. The bench member can never be the Royal Judge.
--
--   Why this is fair:
--    * the Lord plays alone, but never faces more than ONE opponent at a time
--      with the very same questions, clock and rules as any normal Trial
--    * the duo cannot pick the school (no home advantage) nor which of them
--      plays which Trial (no specialist)
--    * the Lord needs the same 3 wins as the duo needs (not 2), and keeps the
--      Throne Shield and the Royal Judge, like in any challenge
--    * the cost is on the duo: two Gauntlets, a cooldown for BOTH after a
--      failed Coup, and a 30-day lock on the reign
--
-- IF THE DUO WINS (3 Trials)  -> ⚔️ THE SUCCESSION
--   The Lord is deposed. The two duelists play ONE Final Trial against each
--   other (a normal one-Trial challenge, kind 'succession'); the Lord is free to
--   act as its Royal Judge. The winner becomes the new Abt Lord through the
--   normal reign swap (the old reign ends then, so the throne is never empty).
-- IF THE LORD WINS (3 Trials) -> 🛡️ THE COUP HAS FAILED
--   successful_defenses +1 and coups_survived +1 on the reign; the Lord is the
--   👑 UNTOUCHABLE ABT (derived from coups_survived).
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0046.
-- =================================================================

-- =================================================================
-- SECTION 1 — columns, config
-- =================================================================
alter table public.throne_challenges
  add column if not exists kind text not null default 'normal' check (kind in ('normal', 'coup', 'succession')),
  add column if not exists target_score int not null default 2,
  add column if not exists coup_a uuid references public.profiles(id),            -- the proposer
  add column if not exists coup_b uuid references public.profiles(id),            -- the confirmer
  add column if not exists coup_partner_user_id uuid references public.profiles(id), -- the bench member of the current Trial
  add column if not exists coup_confirmed_a boolean not null default false,
  add column if not exists coup_confirmed_b boolean not null default false,
  add column if not exists coup_plan text[],
  add column if not exists coup_first_rep uuid references public.profiles(id),
  add column if not exists coup_result text check (coup_result in ('team', 'lord')),
  add column if not exists parent_coup_id uuid references public.throne_challenges(id);

alter table public.abt_reigns add column if not exists coups_survived int not null default 0;

create or replace function public._coup_reign_cooldown() returns interval as $$ select interval '30 days'; $$ language sql immutable;
create or replace function public._coup_confirm_window() returns interval as $$ select interval '24 hours'; $$ language sql immutable;
create or replace function public._coup_target() returns int as $$ select 3; $$ language sql immutable;

create or replace function public.get_throne_rules()
returns jsonb as $$
  select jsonb_build_object(
    'cooldown_hours', extract(epoch from public._throne_cooldown()) / 3600,
    'gauntlet_cost', public._throne_gauntlet_cost(),
    'shield_days', public._throne_shield_days(),
    'coup_reign_cooldown_days', extract(epoch from public._coup_reign_cooldown()) / 86400,
    'coup_target', public._coup_target()
  );
$$ language sql stable security definer set search_path = public;

-- Gauntlet ledger: coups spend and refund per member
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.royal_gauntlet_ledger'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%reason%';
  if v_name is not null then execute format('alter table public.royal_gauntlet_ledger drop constraint %I', v_name); end if;
end $$;
alter table public.royal_gauntlet_ledger add constraint royal_gauntlet_ledger_reason_check
  check (reason in ('admin_grant', 'throne_challenge', 'throne_refund', 'throne_coup', 'coup_refund'));
create unique index if not exists royal_gauntlet_one_coup_spend on public.royal_gauntlet_ledger (challenge_id, user_id) where reason = 'throne_coup';
create unique index if not exists royal_gauntlet_one_coup_refund on public.royal_gauntlet_ledger (challenge_id, user_id) where reason = 'coup_refund';

-- =================================================================
-- SECTION 2 — cooldown, judge pool, refunds (now Coup-aware)
-- =================================================================
-- a lost normal challenge, or a failed Coup (for BOTH duo members)
create or replace function public._throne_cooldown_until(p_user uuid)
returns timestamptz as $$
  select max(completed_at) + public._throne_cooldown()
  from public.throne_challenges
  where status = 'completed' and (
    (kind = 'normal' and challenger_user_id = p_user and winner_user_id is not null and winner_user_id <> challenger_user_id)
    or (kind = 'coup' and coup_result = 'lord' and p_user in (coup_a, coup_b))
  );
$$ language sql stable security definer set search_path = public;

-- the Royal Judge is never anyone who takes part (in a Coup that includes the bench member)
create or replace function public._pick_judge(p_challenge_id uuid)
returns uuid as $$
  select m.user_id
  from public.app_memberships m, public.throne_challenges c
  where c.id = p_challenge_id
    and m.app_id = 'officelore' and m.is_active = true
    and m.user_id not in (c.challenger_user_id, c.defender_user_id, coalesce(c.coup_partner_user_id, c.defender_user_id))
  order by random() limit 1;
$$ language sql volatile security definer set search_path = public;

create or replace function public._pick_catalog_trial(p_challenge_id uuid, p_school text)
returns public.throne_trial_catalog as $$
declare
  c public.throne_challenges;
  v_judge_exists boolean;
  v_school text := p_school;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id;

  select exists (
    select 1 from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active = true
      and m.user_id not in (c.challenger_user_id, c.defender_user_id, coalesce(c.coup_partner_user_id, c.defender_user_id))
  ) into v_judge_exists;

  if v_school is not null then
    select t.* into v_cat from public.throne_trial_catalog t
      where t.is_active and t.school = v_school
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution not in ('judge', 'creative', 'reallife') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
        and t.id not in (select m.catalog_id from public.throne_mystery_tasks m
                         join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = p_challenge_id)
      order by random() limit 1;
    if v_cat.id is not null then
      return v_cat;
    end if;
  end if;

  select s.school into v_school from (
    select distinct t.school from public.throne_trial_catalog t
      where t.is_active
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution not in ('judge', 'creative', 'reallife') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
        and t.id not in (select m.catalog_id from public.throne_mystery_tasks m
                         join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = p_challenge_id)
  ) s order by random() limit 1;

  if v_school is null then
    raise exception 'No Trials available for this Throne Challenge';
  end if;

  select t.* into v_cat from public.throne_trial_catalog t
    where t.is_active and t.school = v_school
      and (c.allow_real_life or t.school <> 'real_life')
      and (t.resolution not in ('judge', 'creative', 'reallife') or v_judge_exists)
      and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
      and t.id not in (select m.catalog_id from public.throne_mystery_tasks m
                       join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = p_challenge_id)
    order by random() limit 1;
  return v_cat;
end;
$$ language plpgsql security definer set search_path = public;

-- a cancelled challenge gives its Gauntlet(s) back, once
create or replace function public._refund_gauntlet_on_cancel()
returns trigger as $$
declare
  r record;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    for r in
      select user_id, -delta as spent, reason from public.royal_gauntlet_ledger
      where challenge_id = new.id and reason in ('throne_challenge', 'throne_coup')
    loop
      insert into public.royal_gauntlet_ledger (user_id, delta, reason, challenge_id)
        values (r.user_id, r.spent, case when r.reason = 'throne_coup' then 'coup_refund' else 'throne_refund' end, new.id)
        on conflict do nothing;
      if found then
        insert into public.royal_gauntlet_balances (user_id, balance)
          values (r.user_id, r.spent)
          on conflict (user_id) do update
            set balance = public.royal_gauntlet_balances.balance + excluded.balance, updated_at = now();
      end if;
    end loop;
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — outcomes (replaces 0044's): normal, coup defence, succession
-- =================================================================
create or replace function public._complete_throne_challenge(p_challenge_id uuid, p_winner uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_reign record;
  v_def_total int;
  v_chal_total int;
  v_snapshot jsonb;
begin
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.status in ('completed', 'cancelled') then
    return; -- idempotent: an outcome is registered exactly once
  end if;

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;

  if c.kind = 'succession' then
    -- THE SUCCESSION: the winner of the Final Trial takes the deposed Lord's crown
    if v_reign is null or v_reign.id <> c.reign_id then
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null where id = c.id;
      return;
    end if;
    select coalesce(beer_xp, 0) into v_def_total from public.user_xp_totals where user_id = v_reign.user_id;
    select coalesce(beer_xp, 0) into v_chal_total from public.user_xp_totals where user_id = p_winner;
    select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = v_reign.user_id;
    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_def_total, dethroned_by_user_id = p_winner,
          ending_loadout_snapshot = v_snapshot, ended_by_challenge_id = c.id
      where id = v_reign.id;
    insert into public.abt_reigns (user_id, started_at, starting_beer_xp, predecessor_reign_id, won_challenge_id)
    values (p_winner, now(), v_chal_total, v_reign.id, c.id);

  elsif p_winner = c.challenger_user_id and c.kind = 'normal' then
    if v_reign is null or v_reign.id <> c.reign_id then
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;
      return;
    end if;
    select coalesce(beer_xp, 0) into v_def_total from public.user_xp_totals where user_id = c.defender_user_id;
    select coalesce(beer_xp, 0) into v_chal_total from public.user_xp_totals where user_id = c.challenger_user_id;
    select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = c.defender_user_id;
    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_def_total, dethroned_by_user_id = c.challenger_user_id,
          ending_loadout_snapshot = v_snapshot, ended_by_challenge_id = c.id
      where id = v_reign.id;
    insert into public.abt_reigns (user_id, started_at, starting_beer_xp, predecessor_reign_id, won_challenge_id)
    values (c.challenger_user_id, now(), v_chal_total, v_reign.id, c.id);

  elsif p_winner = c.defender_user_id then
    -- the throne stands. A failed Coup also counts as a survived Coup.
    update public.abt_reigns
      set successful_defenses = successful_defenses + 1,
          coups_survived = coups_survived + case when c.kind = 'coup' then 1 else 0 end
      where id = c.reign_id and ended_at is null;
  end if;

  update public.throne_challenges
    set status = 'completed', winner_user_id = p_winner, completed_at = now(), resolved_at = now(),
        awaiting_pick_by = null, step_deadline = null,
        coup_result = case when c.kind = 'coup' then 'lord' else coup_result end
    where id = c.id;

  perform public._sync_absolute_abt();
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — the Coup's trial loop, and the Succession
-- =================================================================
-- starts the next Coup Trial: the system picks the school (from the shuffled
-- plan), the duo members alternate as the team's representative
create or replace function public._start_coup_trial(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_n int;
  v_school text;
  v_rep uuid;
  v_bench uuid;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  select count(*) + 1 into v_n from public.throne_challenge_trials where challenge_id = c.id and status <> 'voided';
  v_school := c.coup_plan[least(v_n, coalesce(cardinality(c.coup_plan), 1))];
  v_rep := case when v_n % 2 = 1 then c.coup_first_rep
                when c.coup_first_rep = c.coup_a then c.coup_b else c.coup_a end;
  v_bench := case when v_rep = c.coup_a then c.coup_b else c.coup_a end;

  update public.throne_challenges set challenger_user_id = v_rep, coup_partner_user_id = v_bench where id = c.id;

  v_cat := public._pick_catalog_trial(c.id, v_school);
  perform public._start_throne_trial(c.id, v_cat, c.defender_user_id);
end;
$$ language plpgsql security definer set search_path = public;

-- the duo took 3 Trials: the Lord is deposed, the two play the Succession
create or replace function public._coup_succeeds(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_child uuid;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  update public.throne_challenges
    set status = 'completed', coup_result = 'team', completed_at = now(), resolved_at = now(),
        awaiting_pick_by = null, step_deadline = null
    where id = c.id;

  insert into public.throne_challenges
    (reign_id, defender_user_id, challenger_user_id, status, kind, target_score, allow_real_life, parent_coup_id, starts_at, started_at, step_deadline)
  values
    (c.reign_id, c.coup_b, c.coup_a, 'active', 'succession', 1, true, c.id, now(), now(), now() + interval '48 hours')
  returning id into v_child;

  v_cat := public._pick_final_throne_trial(v_child);
  perform public._start_throne_trial(v_child, v_cat, null);
end;
$$ language plpgsql security definer set search_path = public;

-- the series: normal best-of-3, the Coup's best-of-5, the one-Trial Succession
create or replace function public._advance_throne_series(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_last_no int;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.status in ('completed', 'cancelled') then return; end if;

  if c.kind = 'coup' then
    if c.challenger_score >= c.target_score then
      perform public._coup_succeeds(c.id);
    elsif c.defender_score >= c.target_score then
      perform public._complete_throne_challenge(c.id, c.defender_user_id);
    else
      perform public._start_coup_trial(c.id);
    end if;
    return;
  end if;

  if c.challenger_score >= c.target_score then
    perform public._complete_throne_challenge(c.id, c.challenger_user_id);
  elsif c.defender_score >= c.target_score then
    perform public._complete_throne_challenge(c.id, c.defender_user_id);
  else
    select max(trial_no) into v_last_no from public.throne_challenge_trials where challenge_id = c.id and status = 'completed';
    if coalesce(v_last_no, 1) = 1 then
      update public.throne_challenges
        set status = 'active', awaiting_pick_by = c.defender_user_id, step_deadline = now() + interval '48 hours'
        where id = c.id;
    else
      v_cat := public._pick_final_throne_trial(c.id);
      perform public._start_throne_trial(c.id, v_cat, null);
    end if;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — propose, confirm, cancel
-- =================================================================
create or replace function public.propose_coup(p_partner uuid)
returns uuid as $$
declare
  v_reign record;
  v_id uuid;
  v_who uuid;
  v_until timestamptz;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;
  if v_reign is null then raise exception 'There is no Abt Lord to rise against'; end if;
  if auth.uid() = v_reign.user_id or p_partner = v_reign.user_id then
    raise exception 'The Abt Lord cannot take part in a Coup against themselves';
  end if;
  if p_partner is null or p_partner = auth.uid() then raise exception 'Choose another member as your partner'; end if;
  if not exists (select 1 from public.app_memberships where app_id = 'officelore' and user_id = p_partner and is_active) then
    raise exception 'That member cannot take part';
  end if;
  if exists (select 1 from public.throne_challenges where status in ('pending', 'active', 'awaiting_judge')) then
    raise exception 'A Throne Challenge is already underway';
  end if;
  if exists (select 1 from public.throne_challenges
             where kind = 'coup' and reign_id = v_reign.id and status <> 'cancelled' and created_at > now() - public._coup_reign_cooldown()) then
    raise exception 'A Coup was already attempted against this reign recently';
  end if;

  foreach v_who in array array[auth.uid(), p_partner] loop
    v_until := public._throne_cooldown_until(v_who);
    if v_until is not null and v_until > now() then
      raise exception 'COOLDOWN: a Coup partner is still in cooldown';
    end if;
    if coalesce((select balance from public.royal_gauntlet_balances where user_id = v_who), 0) < public._throne_gauntlet_cost() then
      raise exception 'Both Coup members need a Royal Gauntlet';
    end if;
  end loop;

  insert into public.throne_challenges
    (reign_id, defender_user_id, challenger_user_id, status, kind, target_score, allow_real_life,
     coup_a, coup_b, coup_partner_user_id, coup_confirmed_a, starts_at, step_deadline)
  values
    (v_reign.id, v_reign.user_id, auth.uid(), 'pending', 'coup', public._coup_target(), true,
     auth.uid(), p_partner, p_partner, true, now(), now() + public._coup_confirm_window())
  returning id into v_id;
  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.confirm_coup(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_reign record;
  v_who uuid;
  v_until timestamptz;
  v_cost int := public._throne_gauntlet_cost();
  v_left int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.id is null or c.kind <> 'coup' or c.status <> 'pending' then raise exception 'There is no Coup waiting for your confirmation'; end if;
  if auth.uid() <> c.coup_b then raise exception 'Only the invited member can confirm this Coup'; end if;

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;
  if v_reign is null or v_reign.id <> c.reign_id then raise exception 'The throne has changed hands. The Coup is void'; end if;

  foreach v_who in array array[c.coup_a, c.coup_b] loop
    v_until := public._throne_cooldown_until(v_who);
    if v_until is not null and v_until > now() then raise exception 'COOLDOWN: a Coup member is still in cooldown'; end if;
    -- both Gauntlets are spent now, atomically
    update public.royal_gauntlet_balances set balance = balance - v_cost, updated_at = now()
      where user_id = v_who and balance >= v_cost returning balance into v_left;
    if not found then raise exception 'Both Coup members need a Royal Gauntlet'; end if;
    insert into public.royal_gauntlet_ledger (user_id, delta, reason, challenge_id) values (v_who, -v_cost, 'throne_coup', c.id);
  end loop;

  -- the five Trials: one per school, shuffled; the duo members alternate, random who starts
  update public.throne_challenges
    set coup_confirmed_b = true,
        coup_plan = (select array_agg(s order by random()) from unnest(array['pint', 'lore', 'wisdom', 'chaos', 'real_life']) s),
        coup_first_rep = case when random() < 0.5 then c.coup_a else c.coup_b end
    where id = c.id;
  perform public._start_coup_trial(c.id);
end;
$$ language plpgsql security definer set search_path = public;

-- either member can call the Coup off before it is confirmed
create or replace function public.cancel_coup(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.id is null or c.kind <> 'coup' or c.status <> 'pending' then raise exception 'This Coup cannot be called off any more'; end if;
  if auth.uid() not in (c.coup_a, c.coup_b) then raise exception 'Only the two plotters can call it off'; end if;
  update public.throne_challenges
    set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null where id = c.id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — grants
-- =================================================================
revoke all on function public._coup_reign_cooldown() from public, anon, authenticated;
revoke all on function public._coup_confirm_window() from public, anon, authenticated;
revoke all on function public._coup_target() from public, anon, authenticated;
revoke all on function public._start_coup_trial(uuid) from public, anon, authenticated;
revoke all on function public._coup_succeeds(uuid) from public, anon, authenticated;
revoke all on function public._advance_throne_series(uuid) from public, anon, authenticated;
revoke all on function public._complete_throne_challenge(uuid, uuid) from public, anon, authenticated;
revoke all on function public._pick_judge(uuid) from public, anon, authenticated;
revoke all on function public._pick_catalog_trial(uuid, text) from public, anon, authenticated;
revoke all on function public._throne_cooldown_until(uuid) from public, anon, authenticated;
revoke all on function public._refund_gauntlet_on_cancel() from public, anon, authenticated;

revoke all on function public.propose_coup(uuid) from public, anon;
revoke all on function public.confirm_coup(uuid) from public, anon;
revoke all on function public.cancel_coup(uuid) from public, anon;
grant execute on function public.propose_coup(uuid) to authenticated;
grant execute on function public.confirm_coup(uuid) to authenticated;
grant execute on function public.cancel_coup(uuid) to authenticated;

-- =========== 0048_challenge_engine.sql ===========
-- =================================================================
-- OFFICE LORE — THE CHALLENGE ENGINE (Daily & Weekly Challenges)
-- =================================================================
-- One generic engine for
--   ☀️ personal_daily   🌟 group_daily   📅 personal_weekly
--   🤝 group_weekly     ⚔️ rebellion
--
-- DEFINITION vs ASSIGNMENT
--   challenge_definitions  WHAT a challenge is ("Rate 3 nicknames": event type,
--                          target, rewards ...). Adding content = INSERT rows.
--   challenge_assignments  WHO has it WHEN ("Elien, 2026-10-04, 2/3"): a frozen
--                          snapshot of the definition plus progress. A personal
--                          assignment has a user_id, a group one has none (the
--                          whole workspace shares one progress counter).
--
-- AUTOMATIC PROGRESS (nobody presses "I did it")
--   Existing tables get AFTER INSERT triggers that call
--   _challenge_event(user, event_type, amount, dedupe_key, meta, source_key).
--   Events: nickname_created, nickname_rated, nickname_anecdote_added,
--   quote_added, anecdote_added, poem_created, poem_rated, poem_commented,
--   poetry_daily_completed, battle_created, battle_voted, battle_participated,
--   battle_won, beer_added, beer_rated, beer_session_participated,
--   perfect_pour, perfect_pour_given, daily_completed (the engine's own).
--   quiz_*, prediction_*, chaos_* have no source feature yet; the same hook
--   will serve them. There is deliberately NO client-callable event RPC: the
--   server derives progress from real rows, so it cannot be forged.
--   * a trigger never fails the original action (errors are swallowed)
--   * only active Office Lore members count (app scoping)
--   * source_key makes a replayed event a no-op; dedupe_key makes "rate 3
--     nicknames" mean 3 DIFFERENT nicknames (vote toggling cannot farm it)
--
-- REWARDS (modular): a reward is {"lines":[{kind, amount, category?}, ...]}.
--   _grant_challenge_reward dispatches on kind:
--     player_xp, category_xp   a row in the grant ledger (the ledger IS the XP)
--     gauntlet_fragments       fragments; every N (config) become a Royal Gauntlet
--     mystery / cosmetic / achievement   recorded as 'pending' until built
--   A new reward kind = one more WHEN branch.
--
-- CLAIMING is idempotent at the database: a unique claim row per
-- (assignment, user) and a unique grant per (assignment, user, line) mean a
-- double click, refresh, realtime echo, second tab or race can never pay twice.
--
-- RESET without cron: ensure_challenge_assignments() is called by the app on
-- first visit of a day/week and creates what is missing (deterministic
-- pick per user+period, conflict-safe). Day/week boundaries use one timezone
-- (_challenge_tz(), Europe/Brussels), weeks start on Monday (ISO weeks).
-- Completed-but-unclaimed challenges stay claimable after they expire.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0047.
-- =================================================================

-- =================================================================
-- SECTION 1 — config
-- =================================================================
create or replace function public._challenge_tz() returns text as $$ select 'Europe/Brussels'::text; $$ language sql immutable;
create or replace function public._fragments_per_gauntlet() returns int as $$ select 3; $$ language sql immutable;
-- how many of each type a user (or the group) gets per period
create or replace function public._challenge_slots(p_type text) returns int as $$
  select case p_type when 'personal_daily' then 3 when 'group_daily' then 1 when 'personal_weekly' then 2
                     when 'group_weekly' then 1 when 'rebellion' then 1 else 0 end;
$$ language sql immutable;

-- =================================================================
-- SECTION 2 — tables
-- =================================================================
create table if not exists public.challenge_definitions (
  id text primary key,
  app_id text not null default 'officelore',
  type text not null check (type in ('personal_daily', 'group_daily', 'personal_weekly', 'group_weekly', 'rebellion')),
  category text not null check (category in ('nickname', 'poetry', 'beer', 'battle', 'lore', 'quiz', 'social', 'chaos', 'mixed')),
  title text not null,
  description text not null,
  difficulty text not null default 'normal' check (difficulty in ('easy', 'normal', 'hard', 'special')),
  event_type text not null,
  target int not null check (target > 0),
  requirements jsonb not null default '{}',   -- e.g. {"min_rating": 8} against the event's meta
  reward jsonb not null default '{"lines":[]}',
  audience text not null default 'everyone' check (audience in ('everyone', 'non_lord', 'lord')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.challenge_assignments (
  id uuid primary key default gen_random_uuid(),
  app_id text not null default 'officelore',
  definition_id text not null references public.challenge_definitions(id),
  user_id uuid references public.profiles(id),      -- null = a group challenge
  type text not null,
  category text not null,
  title text not null,
  description text not null,
  difficulty text not null,
  event_type text not null,
  requirements jsonb not null default '{}',
  reward jsonb not null default '{"lines":[]}',
  target int not null,
  progress int not null default 0 check (progress >= 0),
  period_key text not null,                          -- '2026-10-04' or '2026-W41'
  starts_at timestamptz not null,
  expires_at timestamptz not null,
  completed_at timestamptz,
  claimed_at timestamptz,                            -- personal challenges (group claims live in challenge_claims)
  status text not null default 'active' check (status in ('active', 'completed', 'claimed', 'expired')),
  created_at timestamptz not null default now()
);
-- one assignment per definition per owner per period: generation is race-safe
create unique index if not exists challenge_assignments_unique
  on public.challenge_assignments (app_id, definition_id, (coalesce(user_id::text, 'group')), period_key);
create index if not exists challenge_assignments_user on public.challenge_assignments (user_id, status);
create index if not exists challenge_assignments_event on public.challenge_assignments (app_id, event_type, status);

create table if not exists public.challenge_contributions (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  amount int not null default 0,
  primary key (assignment_id, user_id)
);

-- every progress event ever seen (audit; source_key makes replays harmless)
create table if not exists public.challenge_events (
  id uuid primary key default gen_random_uuid(),
  app_id text not null default 'officelore',
  user_id uuid not null references public.profiles(id),
  event_type text not null,
  amount int not null default 1,
  dedupe_key text,
  source_key text,
  meta jsonb not null default '{}',
  occurred_at timestamptz not null default now()
);
create unique index if not exists challenge_events_source on public.challenge_events (source_key) where source_key is not null;
create index if not exists challenge_events_user on public.challenge_events (user_id, occurred_at desc);

-- "count each nickname once per challenge"
create table if not exists public.challenge_progress_marks (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null,
  dedupe_key text not null,
  primary key (assignment_id, user_id, dedupe_key)
);

create table if not exists public.challenge_claims (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  claimed_at timestamptz not null default now(),
  primary key (assignment_id, user_id)
);

-- the reward ledger: one row per reward line actually paid out
create table if not exists public.challenge_reward_grants (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  line_no int not null,
  kind text not null,
  amount int not null default 0,
  category text,
  status text not null default 'applied' check (status in ('applied', 'pending')),
  created_at timestamptz not null default now(),
  unique (assignment_id, user_id, line_no)
);

create table if not exists public.gauntlet_fragments (
  user_id uuid primary key references public.profiles(id),
  fragments int not null default 0 check (fragments >= 0),
  updated_at timestamptz not null default now()
);

-- Gauntlet ledger: converting fragments
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.royal_gauntlet_ledger'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%reason%';
  if v_name is not null then execute format('alter table public.royal_gauntlet_ledger drop constraint %I', v_name); end if;
end $$;
alter table public.royal_gauntlet_ledger add constraint royal_gauntlet_ledger_reason_check
  check (reason in ('admin_grant', 'throne_challenge', 'throne_refund', 'throne_coup', 'coup_refund', 'fragment_convert'));

-- =================================================================
-- SECTION 3 — RLS (reads only; every write goes through the functions below)
-- =================================================================
alter table public.challenge_definitions enable row level security;
alter table public.challenge_assignments enable row level security;
alter table public.challenge_contributions enable row level security;
alter table public.challenge_events enable row level security;
alter table public.challenge_progress_marks enable row level security;   -- no policy: private
alter table public.challenge_claims enable row level security;
alter table public.challenge_reward_grants enable row level security;
alter table public.gauntlet_fragments enable row level security;

drop policy if exists "Challenge definitions: read" on public.challenge_definitions;
create policy "Challenge definitions: read" on public.challenge_definitions for select to authenticated
  using (public.is_app_member(app_id));
drop policy if exists "Challenge assignments: read" on public.challenge_assignments;
create policy "Challenge assignments: read" on public.challenge_assignments for select to authenticated
  using (public.is_app_member(app_id) and (user_id is null or user_id = auth.uid()));
drop policy if exists "Challenge contributions: read" on public.challenge_contributions;
create policy "Challenge contributions: read" on public.challenge_contributions for select to authenticated
  using (exists (select 1 from public.challenge_assignments a where a.id = assignment_id and public.is_app_member(a.app_id)));
drop policy if exists "Challenge events: read own" on public.challenge_events;
create policy "Challenge events: read own" on public.challenge_events for select to authenticated
  using (user_id = auth.uid() and public.is_app_member(app_id));
drop policy if exists "Challenge claims: read own" on public.challenge_claims;
create policy "Challenge claims: read own" on public.challenge_claims for select to authenticated
  using (user_id = auth.uid());
drop policy if exists "Challenge grants: read own" on public.challenge_reward_grants;
create policy "Challenge grants: read own" on public.challenge_reward_grants for select to authenticated
  using (user_id = auth.uid());
drop policy if exists "Gauntlet fragments: read own" on public.gauntlet_fragments;
create policy "Gauntlet fragments: read own" on public.gauntlet_fragments for select to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

do $$
declare
  t text;
begin
  foreach t in array array['challenge_assignments', 'challenge_contributions', 'challenge_claims', 'challenge_reward_grants', 'gauntlet_fragments'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- =================================================================
-- SECTION 4 — the engine
-- =================================================================
-- requirement filter: {"min_rating": 8} needs meta.rating >= 8, {"eq_style": "Tripel"} needs meta.style = 'Tripel'
create or replace function public._challenge_requirements_met(p_req jsonb, p_meta jsonb)
returns boolean as $$
  select coalesce(bool_and(
    case when r.k like 'min\_%' then coalesce((p_meta->>substr(r.k, 5))::numeric, -1e18) >= r.v::numeric
         when r.k like 'eq\_%'  then (p_meta->>substr(r.k, 4)) = r.v
         else true end), true)
  from jsonb_each_text(coalesce(p_req, '{}'::jsonb)) as r(k, v);
$$ language sql immutable;

create or replace function public._challenge_event(
  p_user uuid, p_event text, p_amount int default 1, p_dedupe text default null,
  p_meta jsonb default '{}'::jsonb, p_source text default null)
returns void as $$
declare
  a record;
  v_add int;
  v_done boolean;
begin
  if p_user is null or p_amount is null or p_amount <= 0 then return; end if;
  -- app scoping: only active Office Lore members ever make progress here
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return;
  end if;

  insert into public.challenge_events (app_id, user_id, event_type, amount, dedupe_key, source_key, meta)
    values ('officelore', p_user, p_event, p_amount, p_dedupe, p_source, coalesce(p_meta, '{}'::jsonb))
    on conflict (source_key) where source_key is not null do nothing;
  if not found then return; end if;   -- this very event was already processed

  for a in
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements
    from public.challenge_assignments asg
    where asg.app_id = 'officelore' and asg.status = 'active' and asg.event_type = p_event
      and asg.starts_at <= now() and asg.expires_at > now()
      and (asg.user_id = p_user or asg.user_id is null)
    order by asg.id
    for update
  loop
    continue when not public._challenge_requirements_met(a.requirements, p_meta);
    if p_dedupe is not null then
      insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, p_dedupe)
        on conflict do nothing;
      continue when not found;
    end if;
    v_add := least(p_amount, a.target - a.progress);
    continue when v_add <= 0;
    v_done := a.progress + v_add >= a.target;
    update public.challenge_assignments
      set progress = progress + v_add,
          status = case when v_done then 'completed' else status end,
          completed_at = case when v_done then now() else completed_at end
      where id = a.id;
    if a.user_id is null then
      insert into public.challenge_contributions (assignment_id, user_id, amount) values (a.id, p_user, v_add)
        on conflict (assignment_id, user_id) do update set amount = public.challenge_contributions.amount + excluded.amount;
    end if;
    if v_done and a.type = 'personal_daily' then
      perform public._challenge_event(p_user, 'daily_completed', 1, a.id::text, '{}'::jsonb, 'daily_completed:' || a.id::text);
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- creates what is missing for p_user at moment p_at (the public RPC passes now();
-- internal so tests can step into another day or week)
create or replace function public._ensure_challenge_assignments_for(p_user uuid, p_at timestamptz)
returns int as $$
declare
  v_tz text := public._challenge_tz();
  v_local timestamp := p_at at time zone v_tz;
  v_day_start timestamptz := date_trunc('day', v_local) at time zone v_tz;
  v_day_end timestamptz := (date_trunc('day', v_local) + interval '1 day') at time zone v_tz;
  v_wk_start timestamptz := date_trunc('week', v_local) at time zone v_tz;
  v_wk_end timestamptz := (date_trunc('week', v_local) + interval '7 days') at time zone v_tz;
  v_day_key text := to_char(v_local, 'YYYY-MM-DD');
  v_wk_key text := to_char(v_local, 'IYYY-"W"IW');
  v_lord uuid := (select user_id from public.abt_reigns where ended_at is null limit 1);
  v_type text;
  v_key text; v_from timestamptz; v_to timestamptz;
  v_owner uuid;
  v_have int; v_want int; v_created int := 0; v_n int;
begin
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return 0;
  end if;
  perform pg_advisory_xact_lock(hashtext('challenge_gen:' || p_user::text));

  -- what is over is over (completed ones stay claimable)
  update public.challenge_assignments set status = 'expired'
    where app_id = 'officelore' and status = 'active' and expires_at <= p_at and (user_id = p_user or user_id is null);

  foreach v_type in array array['personal_daily', 'group_daily', 'personal_weekly', 'group_weekly', 'rebellion'] loop
    if v_type in ('personal_daily', 'group_daily') then v_key := v_day_key; v_from := v_day_start; v_to := v_day_end;
    else v_key := v_wk_key; v_from := v_wk_start; v_to := v_wk_end; end if;
    v_owner := case when v_type in ('group_daily', 'group_weekly') then null else p_user end;
    v_want := public._challenge_slots(v_type);

    if v_owner is null then perform pg_advisory_xact_lock(hashtext('challenge_group:' || v_type || ':' || v_key)); end if;

    select count(*) into v_have from public.challenge_assignments
      where app_id = 'officelore' and type = v_type and period_key = v_key and user_id is not distinct from v_owner;
    continue when v_have >= v_want;

    -- deterministic pick (same on refresh and in a second tab), never a definition already assigned
    insert into public.challenge_assignments
      (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, requirements, reward,
       target, period_key, starts_at, expires_at)
    select 'officelore', d.id, v_owner, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.requirements, d.reward,
           d.target, v_key, v_from, v_to
    from public.challenge_definitions d
    where d.app_id = 'officelore' and d.is_active and d.type = v_type
      and (d.audience = 'everyone'
           or (d.audience = 'non_lord' and p_user is distinct from v_lord)
           or (d.audience = 'lord' and p_user is not distinct from v_lord))
      and not exists (select 1 from public.challenge_assignments x
                      where x.app_id = 'officelore' and x.definition_id = d.id and x.period_key = v_key and x.user_id is not distinct from v_owner)
    order by md5(d.id || coalesce(v_owner::text, 'group') || v_key)
    limit v_want - v_have
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_created := v_created + v_n;
  end loop;
  return v_created;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.ensure_challenge_assignments()
returns jsonb as $$
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  return jsonb_build_object('created', public._ensure_challenge_assignments_for(auth.uid(), now()));
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — rewards (modular) and claiming (idempotent)
-- =================================================================
create or replace function public._grant_challenge_reward(p_user uuid, p_assignment uuid, p_line jsonb, p_line_no int)
returns void as $$
declare
  v_kind text := p_line->>'kind';
  v_amount int := coalesce((p_line->>'amount')::int, 0);
  v_status text := case when v_kind in ('player_xp', 'category_xp', 'gauntlet_fragments') then 'applied' else 'pending' end;
  v_frag int;
  v_per int := public._fragments_per_gauntlet();
begin
  -- the unique (assignment, user, line) is the last line of defence against a double payout
  insert into public.challenge_reward_grants (assignment_id, user_id, line_no, kind, amount, category, status)
    values (p_assignment, p_user, p_line_no, v_kind, v_amount, p_line->>'category', v_status)
    on conflict (assignment_id, user_id, line_no) do nothing;
  if not found then return; end if;

  if v_kind = 'gauntlet_fragments' and v_amount > 0 then
    insert into public.gauntlet_fragments (user_id, fragments) values (p_user, v_amount)
      on conflict (user_id) do update set fragments = public.gauntlet_fragments.fragments + excluded.fragments, updated_at = now()
      returning fragments into v_frag;
    -- every N fragments are forged into a Royal Gauntlet
    while v_frag >= v_per loop
      update public.gauntlet_fragments set fragments = fragments - v_per, updated_at = now() where user_id = p_user returning fragments into v_frag;
      insert into public.royal_gauntlet_balances (user_id, balance) values (p_user, 1)
        on conflict (user_id) do update set balance = public.royal_gauntlet_balances.balance + 1, updated_at = now();
      insert into public.royal_gauntlet_ledger (user_id, delta, reason, note) values (p_user, 1, 'fragment_convert', v_per || ' fragments');
    end loop;
  end if;
  -- player_xp / category_xp: the grant row IS the ledger entry.
  -- mystery / cosmetic / achievement: stored as 'pending' until their handler is built.
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.claim_challenge(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_line jsonb;
  v_no int := 0;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  -- serialize: two tabs / a double click queue up here, the second finds the claim and pays nothing
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if a.status not in ('completed', 'claimed') then raise exception 'This challenge is not complete yet'; end if;
  if a.user_id is not null and a.user_id <> auth.uid() then raise exception 'This is not your challenge'; end if;
  if a.user_id is null and not exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id and c.user_id = auth.uid() and c.amount > 0) then
    raise exception 'Only members who contributed can claim a group reward';
  end if;

  insert into public.challenge_claims (assignment_id, user_id) values (a.id, auth.uid()) on conflict do nothing;
  if not found then
    return jsonb_build_object('status', 'already_claimed');
  end if;

  for v_line in select * from jsonb_array_elements(coalesce(a.reward->'lines', '[]'::jsonb)) loop
    v_no := v_no + 1;
    perform public._grant_challenge_reward(auth.uid(), a.id, v_line, v_no);
  end loop;

  if a.user_id is not null then
    update public.challenge_assignments set status = 'claimed', claimed_at = now() where id = a.id;
  end if;
  return jsonb_build_object('status', 'claimed', 'lines', coalesce(a.reward->'lines', '[]'::jsonb));
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — event triggers on the existing features
-- =================================================================
-- Each one swallows its own errors: a challenge must never break a nickname, a poem or a beer.
create or replace function public._ch_t_nickname() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'nickname_created', 1, null, jsonb_build_object('nickname_id', new.id), 'nicknames:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_nickname_anecdote() returns trigger as $$
begin
  begin
    if coalesce(btrim(old.anecdote), '') = '' and coalesce(btrim(new.anecdote), '') <> '' then
      perform public._challenge_event(coalesce(new.updated_by_user_id, new.created_by_user_id), 'nickname_anecdote_added', 1, null,
        jsonb_build_object('nickname_id', new.id), 'nickname_anecdote:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_nickname_vote() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'nickname_rated', 1, 'nickname:' || new.nickname_id,
      jsonb_build_object('nickname_id', new.nickname_id, 'vote', new.vote_type), 'nickname_votes:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_quote() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'quote_added', 1, null, '{}'::jsonb, 'quotes:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_anecdote() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'anecdote_added', 1, null, '{}'::jsonb, 'anecdotes:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_poem() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.author_user_id, 'poem_created', 1, null, jsonb_build_object('poem_id', new.id, 'mood', new.mood), 'poems:' || new.id);
    if new.is_daily_challenge then
      perform public._challenge_event(new.author_user_id, 'poetry_daily_completed', 1, null, jsonb_build_object('poem_id', new.id), 'poems_daily:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_poem_reaction() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'poem_rated', 1, 'poem:' || new.poem_id,
      jsonb_build_object('poem_id', new.poem_id, 'reaction', new.reaction_type), 'poem_reactions:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_poem_comment() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'poem_commented', 1, null, jsonb_build_object('poem_id', new.poem_id), 'poem_comments:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_battle() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'battle_created', 1, null, jsonb_build_object('battle_id', new.id), 'battles:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_battle_vote() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'battle_voted', 1, 'battle:' || new.battle_id, jsonb_build_object('battle_id', new.battle_id), 'battle_votes:' || new.id);
    perform public._challenge_event(new.user_id, 'battle_participated', 1, 'battle:' || new.battle_id, jsonb_build_object('battle_id', new.battle_id), 'battle_part:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

-- a battle is WON by the person who created the winning nickname
create or replace function public._ch_t_battle_finished() returns trigger as $$
declare
  v_owner uuid;
begin
  begin
    if new.status = 'finished' and old.status is distinct from 'finished' and new.winner_nickname_id is not null then
      select created_by_user_id into v_owner from public.nicknames where id = new.winner_nickname_id;
      perform public._challenge_event(v_owner, 'battle_won', 1, null, jsonb_build_object('battle_id', new.id), 'battle_won:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_beer() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.created_by_user_id, 'beer_added', 1, null, jsonb_build_object('beer_id', new.id), 'beers:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_beer_rating() returns trigger as $$
begin
  begin
    if new.rating is not null then
      perform public._challenge_event(new.user_id, 'beer_rated', 1, 'beer:' || new.beer_id,
        jsonb_build_object('beer_id', new.beer_id, 'rating', new.rating), 'beer_ratings:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_session_participant() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.user_id, 'beer_session_participated', 1, 'session:' || new.session_id,
      jsonb_build_object('session_id', new.session_id), 'session_part:' || new.session_id || ':' || new.user_id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_perfect_pour() returns trigger as $$
begin
  begin
    perform public._challenge_event(new.received_by_user_id, 'perfect_pour', 1, null, jsonb_build_object('session_id', new.session_id), 'pp_recv:' || new.id);
    perform public._challenge_event(new.given_by_user_id, 'perfect_pour_given', 1, null, jsonb_build_object('session_id', new.session_id), 'pp_give:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_ch_nickname on public.nicknames;
create trigger trg_ch_nickname after insert on public.nicknames for each row execute procedure public._ch_t_nickname();
drop trigger if exists trg_ch_nickname_anecdote on public.nicknames;
create trigger trg_ch_nickname_anecdote after update of anecdote on public.nicknames for each row execute procedure public._ch_t_nickname_anecdote();
drop trigger if exists trg_ch_nickname_vote on public.nickname_votes;
create trigger trg_ch_nickname_vote after insert on public.nickname_votes for each row execute procedure public._ch_t_nickname_vote();
drop trigger if exists trg_ch_quote on public.quotes;
create trigger trg_ch_quote after insert on public.quotes for each row execute procedure public._ch_t_quote();
drop trigger if exists trg_ch_anecdote on public.anecdotes;
create trigger trg_ch_anecdote after insert on public.anecdotes for each row execute procedure public._ch_t_anecdote();
drop trigger if exists trg_ch_poem on public.poems;
create trigger trg_ch_poem after insert on public.poems for each row execute procedure public._ch_t_poem();
drop trigger if exists trg_ch_poem_reaction on public.poem_reactions;
create trigger trg_ch_poem_reaction after insert on public.poem_reactions for each row execute procedure public._ch_t_poem_reaction();
drop trigger if exists trg_ch_poem_comment on public.poem_comments;
create trigger trg_ch_poem_comment after insert on public.poem_comments for each row execute procedure public._ch_t_poem_comment();
drop trigger if exists trg_ch_battle on public.nickname_battles;
create trigger trg_ch_battle after insert on public.nickname_battles for each row execute procedure public._ch_t_battle();
drop trigger if exists trg_ch_battle_vote on public.nickname_battle_votes;
create trigger trg_ch_battle_vote after insert on public.nickname_battle_votes for each row execute procedure public._ch_t_battle_vote();
drop trigger if exists trg_ch_battle_finished on public.nickname_battles;
create trigger trg_ch_battle_finished after update of status on public.nickname_battles for each row execute procedure public._ch_t_battle_finished();
drop trigger if exists trg_ch_beer on public.beers;
create trigger trg_ch_beer after insert on public.beers for each row execute procedure public._ch_t_beer();
drop trigger if exists trg_ch_beer_rating on public.beer_ratings;
create trigger trg_ch_beer_rating after insert on public.beer_ratings for each row execute procedure public._ch_t_beer_rating();
drop trigger if exists trg_ch_session_participant on public.beer_session_participants;
create trigger trg_ch_session_participant after insert on public.beer_session_participants for each row execute procedure public._ch_t_session_participant();
drop trigger if exists trg_ch_perfect_pour on public.perfect_pours;
create trigger trg_ch_perfect_pour after insert on public.perfect_pours for each row execute procedure public._ch_t_perfect_pour();

-- =================================================================
-- SECTION 7 — a few TEST definitions (content comes later: just INSERT more rows)
-- =================================================================
insert into public.challenge_definitions (id, type, category, title, description, difficulty, event_type, target, reward, audience) values
  ('d_nick_rate_3', 'personal_daily', 'nickname', 'Rate 3 nicknames', 'React to three different nicknames on the Nickname Wall.', 'easy', 'nickname_rated', 3,
     '{"lines":[{"kind":"player_xp","amount":10},{"kind":"category_xp","category":"nickname","amount":5}]}', 'everyone'),
  ('d_beer_rate_1', 'personal_daily', 'beer', 'Rate a beer', 'Rate any beer you have tried.', 'easy', 'beer_rated', 1,
     '{"lines":[{"kind":"player_xp","amount":8},{"kind":"category_xp","category":"beer","amount":4}]}', 'everyone'),
  ('d_poem_react_1', 'personal_daily', 'poetry', 'React to a poem', 'Leave a reaction on a poem on the Poetry Wall.', 'easy', 'poem_rated', 1,
     '{"lines":[{"kind":"player_xp","amount":8},{"kind":"category_xp","category":"poetry","amount":4}]}', 'everyone'),
  ('d_battle_vote_1', 'personal_daily', 'battle', 'Cast a battle vote', 'Vote in a Nickname Battle.', 'normal', 'battle_voted', 1,
     '{"lines":[{"kind":"player_xp","amount":12},{"kind":"gauntlet_fragments","amount":1}]}', 'everyone'),
  ('d_nick_new_1', 'personal_daily', 'nickname', 'Invent a nickname', 'Add a brand-new nickname to the Wall.', 'normal', 'nickname_created', 1,
     '{"lines":[{"kind":"player_xp","amount":15}]}', 'everyone'),
  ('g_beer_rate_5', 'group_daily', 'beer', 'Together: rate 5 beers', 'The whole team: five beer ratings today.', 'normal', 'beer_rated', 5,
     '{"lines":[{"kind":"player_xp","amount":15},{"kind":"gauntlet_fragments","amount":1}]}', 'everyone'),
  ('w_nick_new_3', 'personal_weekly', 'nickname', 'Three new nicknames', 'Add three new nicknames this week.', 'normal', 'nickname_created', 3,
     '{"lines":[{"kind":"player_xp","amount":40},{"kind":"category_xp","category":"nickname","amount":15}]}', 'everyone'),
  ('w_dailies_5', 'personal_weekly', 'mixed', 'Daily devotion', 'Complete five Daily Challenges this week.', 'hard', 'daily_completed', 5,
     '{"lines":[{"kind":"player_xp","amount":50},{"kind":"gauntlet_fragments","amount":2}]}', 'everyone'),
  ('w_poem_write_2', 'personal_weekly', 'poetry', 'Two poems', 'Write two poems this week.', 'normal', 'poem_created', 2,
     '{"lines":[{"kind":"player_xp","amount":40},{"kind":"category_xp","category":"poetry","amount":15}]}', 'everyone'),
  ('gw_poem_react_8', 'group_weekly', 'poetry', 'The Poetry Wall lives', 'Together: eight reactions on the Poetry Wall this week.', 'normal', 'poem_rated', 8,
     '{"lines":[{"kind":"player_xp","amount":30},{"kind":"gauntlet_fragments","amount":1}]}', 'everyone'),
  ('gw_sessions_2', 'group_weekly', 'beer', 'Raise a glass together', 'Take part in two Beer Sessions this week.', 'hard', 'beer_session_participated', 2,
     '{"lines":[{"kind":"player_xp","amount":40},{"kind":"gauntlet_fragments","amount":2}]}', 'everyone'),
  ('r_rebel_votes_5', 'rebellion', 'battle', 'Rebellion: the people vote', 'You are not the Abt Lord. Cast five battle votes this week and stir the realm.', 'special', 'battle_voted', 5,
     '{"lines":[{"kind":"player_xp","amount":40},{"kind":"gauntlet_fragments","amount":3}]}', 'non_lord')
on conflict (id) do update set
  type = excluded.type, category = excluded.category, title = excluded.title, description = excluded.description,
  difficulty = excluded.difficulty, event_type = excluded.event_type, target = excluded.target, reward = excluded.reward, audience = excluded.audience;

-- =================================================================
-- SECTION 8 — grants
-- =================================================================
revoke all on function public._challenge_tz() from public, anon, authenticated;
revoke all on function public._fragments_per_gauntlet() from public, anon, authenticated;
revoke all on function public._challenge_slots(text) from public, anon, authenticated;
revoke all on function public._challenge_requirements_met(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public._challenge_event(uuid, text, int, text, jsonb, text) from public, anon, authenticated;
revoke all on function public._ensure_challenge_assignments_for(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public._grant_challenge_reward(uuid, uuid, jsonb, int) from public, anon, authenticated;

revoke all on function public.ensure_challenge_assignments() from public, anon;
revoke all on function public.claim_challenge(uuid) from public, anon;
grant execute on function public.ensure_challenge_assignments() to authenticated;
grant execute on function public.claim_challenge(uuid) to authenticated;

-- =========== 0049_personal_daily_challenges.sql ===========
-- =================================================================
-- OFFICE LORE — ☀️ PERSONAL DAILY CHALLENGES (the real pool)
-- =================================================================
-- Builds on the Challenge Engine (0048).
--
-- EVERY USER, EVERY DAY: 3 Personal Daily Challenges
--   * picked pseudo-randomly but DETERMINISTICALLY per (user, day), so a refresh
--     or a second tab sees the same three
--   * VARIETY: three different categories whenever the pool allows, at most one
--     'hard', and yesterday's exact challenges are avoided where there is an
--     alternative (three passes: strict -> relax the category rule -> relax all)
--   * FEASIBLE: a definition is only assignable when the app can actually let
--     the user do it right now (see _challenge_available): "Pick a side" needs an
--     open battle the user has not voted in, "Beer scholar" needs a beer the
--     user has not rated yet, "Lore keeper" needs a nickname without anecdote,
--     "Memory lane" needs old content, "The critic" needs 3 nicknames, ...
--   * FEATURE FLAGS: the three quiz challenges and the prediction challenge
--     need features that do not exist yet. They are defined and ready, but stay
--     unassignable until `challenge_features` says enabled = true.
--   * NOT included, by request: anything about the Interior Designer, room,
--     outfits or companions (only the Abt Lord can dress the Abt Avatar).
--   * Beer challenges are about ratings, discovery, data and sessions. Nothing
--     counts or rewards how much anyone drinks.
--
-- REWARDS are central config, not magic numbers in code (table challenge_config):
--   difficulty_rewards: easy / normal / hard / special -> reward lines
--   daily_sweep: the 3/3 bonus
--   A reward line may carry "chance" (0..1): it is rolled ONCE, at claim time,
--   inside the idempotent claim, and the roll is recorded ('missed' when it
--   misses), so a refresh can never re-roll it.
--
-- 🎁 DAILY SWEEP: when all 3 Personal Dailies of a day are complete, one
-- challenge_sweeps row appears for (user, day) (unique, so at most once a day),
-- claimable once: bonus Player XP + 1 Mystery Reward.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0048.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
alter table public.challenge_definitions
  add column if not exists icon text,
  add column if not exists requires text,                    -- availability rule, see _challenge_available
  add column if not exists event_types text[],               -- several events may count (default: just event_type)
  add column if not exists reward_from_difficulty boolean not null default false;
alter table public.challenge_assignments
  add column if not exists icon text,
  add column if not exists event_types text[];

-- central configuration
create table if not exists public.challenge_config (
  key text primary key,
  value jsonb not null
);
alter table public.challenge_config enable row level security;
drop policy if exists "Challenge config: read" on public.challenge_config;
create policy "Challenge config: read" on public.challenge_config for select to authenticated using (public.is_app_member('officelore'));

-- switches for challenges that depend on features that may not exist yet
create table if not exists public.challenge_features (
  key text primary key,
  enabled boolean not null default false,
  note text
);
alter table public.challenge_features enable row level security;
drop policy if exists "Challenge features: read" on public.challenge_features;
create policy "Challenge features: read" on public.challenge_features for select to authenticated using (public.is_app_member('officelore'));
insert into public.challenge_features (key, enabled, note) values
  ('quiz', false, 'Office Lore Quiz: the three quiz Dailies stay unassigned until a standalone quiz exists and this is set to true'),
  ('prediction', false, 'Prediction system: the Office Oracle Daily stays unassigned until it exists')
on conflict (key) do nothing;

insert into public.challenge_config (key, value) values
  ('difficulty_rewards', '{
      "easy":    [ {"kind":"player_xp","amount":10} ],
      "normal":  [ {"kind":"player_xp","amount":18}, {"kind":"mystery","amount":1,"chance":0.15} ],
      "hard":    [ {"kind":"player_xp","amount":30}, {"kind":"gauntlet_fragments","amount":1,"chance":0.5} ],
      "special": [ {"kind":"player_xp","amount":40}, {"kind":"gauntlet_fragments","amount":1} ]
   }'::jsonb),
  ('daily_sweep', '{"lines":[ {"kind":"player_xp","amount":25}, {"kind":"mystery","amount":1} ]}'::jsonb)
on conflict (key) do nothing;

-- the Daily Sweep, one per user per day
create table if not exists public.challenge_sweeps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  period_key text not null,
  reward jsonb not null,
  completed_at timestamptz not null default now(),
  claimed_at timestamptz,
  unique (user_id, period_key)
);
alter table public.challenge_sweeps enable row level security;
drop policy if exists "Challenge sweeps: read own" on public.challenge_sweeps;
create policy "Challenge sweeps: read own" on public.challenge_sweeps for select to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));
do $$
begin
  begin
    alter publication supabase_realtime add table public.challenge_sweeps;
  exception when duplicate_object then null;
  end;
end $$;

-- the reward ledger can now belong to a Sweep, and can record a missed roll
alter table public.challenge_reward_grants alter column assignment_id drop not null;
alter table public.challenge_reward_grants add column if not exists sweep_id uuid references public.challenge_sweeps(id) on delete cascade;
create unique index if not exists challenge_grants_sweep_line on public.challenge_reward_grants (sweep_id, user_id, line_no) where sweep_id is not null;
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.challenge_reward_grants'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%status%';
  if v_name is not null then execute format('alter table public.challenge_reward_grants drop constraint %I', v_name); end if;
end $$;
alter table public.challenge_reward_grants add constraint challenge_reward_grants_status_check check (status in ('applied', 'pending', 'missed'));
alter table public.challenge_reward_grants drop constraint if exists challenge_reward_grants_owner_check;
alter table public.challenge_reward_grants add constraint challenge_reward_grants_owner_check check (assignment_id is not null or sweep_id is not null);

-- =================================================================
-- SECTION 2 — config helpers + availability
-- =================================================================
create or replace function public._challenge_config(p_key text, p_default jsonb)
returns jsonb as $$
  select coalesce((select value from public.challenge_config where key = p_key), p_default);
$$ language sql stable security definer set search_path = public;

create or replace function public._difficulty_reward(p_difficulty text)
returns jsonb as $$
  select jsonb_build_object('lines', coalesce(public._challenge_config('difficulty_rewards', '{}'::jsonb) -> p_difficulty, '[]'::jsonb));
$$ language sql stable security definer set search_path = public;

-- can this user actually DO this challenge today?
create or replace function public._challenge_available(d public.challenge_definitions, p_user uuid)
returns boolean as $$
begin
  if d.requires is null then return true; end if;
  return case d.requires
    -- an open battle the user has not voted in yet
    when 'open_battle' then exists (
      select 1 from public.nickname_battles b
      where b.status = 'open'
        and not exists (select 1 from public.nickname_battle_votes v where v.battle_id = b.id and v.user_id = p_user))
    -- a beer the user has never personally rated
    when 'unrated_beer' then exists (
      select 1 from public.beers b
      where not exists (select 1 from public.beer_ratings r where r.beer_id = b.id and r.user_id = p_user and r.rating is not null))
    -- a nickname that still has no anecdote (anyone may add one)
    when 'anecdote_target' then exists (select 1 from public.nicknames n where coalesce(btrim(n.anecdote), '') = '')
    -- content older than a week to revisit
    when 'old_content' then exists (select 1 from public.poems p where p.created_at < now() - interval '7 days')
                         or exists (select 1 from public.nicknames n where n.created_at < now() - interval '7 days')
    when 'nicknames_3' then (select count(*) from public.nicknames) >= 3
    when 'poems_2' then (select count(*) from public.poems) >= 2
    -- everything else is a feature flag
    else coalesce((select f.enabled from public.challenge_features f where f.key = d.requires), false)
  end;
end;
$$ language plpgsql stable security definer set search_path = public;

-- =================================================================
-- SECTION 3 — the engine (replaces 0048's): several event types, the Daily Sweep
-- =================================================================
create or replace function public._challenge_event(
  p_user uuid, p_event text, p_amount int default 1, p_dedupe text default null,
  p_meta jsonb default '{}'::jsonb, p_source text default null)
returns void as $$
declare
  a record;
  v_add int;
  v_done boolean;
  v_complete int;
begin
  if p_user is null or p_amount is null or p_amount <= 0 then return; end if;
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return;
  end if;

  insert into public.challenge_events (app_id, user_id, event_type, amount, dedupe_key, source_key, meta)
    values ('officelore', p_user, p_event, p_amount, p_dedupe, p_source, coalesce(p_meta, '{}'::jsonb))
    on conflict (source_key) where source_key is not null do nothing;
  if not found then return; end if;

  for a in
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements, asg.period_key
    from public.challenge_assignments asg
    where asg.app_id = 'officelore' and asg.status = 'active'
      and p_event = any (coalesce(asg.event_types, array[asg.event_type]))
      and asg.starts_at <= now() and asg.expires_at > now()
      and (asg.user_id = p_user or asg.user_id is null)
    order by asg.id
    for update
  loop
    continue when not public._challenge_requirements_met(a.requirements, p_meta);
    if p_dedupe is not null then
      insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, p_dedupe)
        on conflict do nothing;
      continue when not found;
    end if;
    v_add := least(p_amount, a.target - a.progress);
    continue when v_add <= 0;
    v_done := a.progress + v_add >= a.target;
    update public.challenge_assignments
      set progress = progress + v_add,
          status = case when v_done then 'completed' else status end,
          completed_at = case when v_done then now() else completed_at end
      where id = a.id;
    if a.user_id is null then
      insert into public.challenge_contributions (assignment_id, user_id, amount) values (a.id, p_user, v_add)
        on conflict (assignment_id, user_id) do update set amount = public.challenge_contributions.amount + excluded.amount;
    end if;
    if v_done and a.type = 'personal_daily' then
      perform public._challenge_event(p_user, 'daily_completed', 1, a.id::text, '{}'::jsonb, 'daily_completed:' || a.id::text);
      -- 🎁 DAILY SWEEP: every Personal Daily of that day is complete (the unique key makes it once a day)
      select count(*) into v_complete from public.challenge_assignments x
        where x.app_id = 'officelore' and x.user_id = a.user_id and x.type = 'personal_daily'
          and x.period_key = a.period_key and x.status in ('completed', 'claimed');
      if v_complete >= public._challenge_slots('personal_daily') then
        insert into public.challenge_sweeps (user_id, period_key, reward)
          values (a.user_id, a.period_key, public._challenge_config('daily_sweep', '{"lines":[]}'::jsonb))
          on conflict (user_id, period_key) do nothing;
      end if;
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — generation with variety
-- =================================================================
-- picks p_missing Personal Daily definitions for the user and day
create or replace function public._pick_personal_dailies(p_user uuid, p_key text, p_prev_key text, p_lord uuid, p_missing int)
returns text[] as $$
declare
  v_list jsonb;
  v_chosen text[] := '{}';
  v_cats text[];
  v_hard int;
  el jsonb;
  v_pass int;
begin
  -- what the user already has today (generation can be partial)
  select coalesce(array_agg(category), '{}'), count(*) filter (where difficulty = 'hard')
    into v_cats, v_hard
    from public.challenge_assignments
    where app_id = 'officelore' and user_id = p_user and type = 'personal_daily' and period_key = p_key;

  -- every definition that is assignable right now; yesterday's last, then a stable per-user shuffle
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'cat', d.category, 'diff', d.difficulty)
           order by (exists (select 1 from public.challenge_assignments y
                             where y.app_id = 'officelore' and y.user_id = p_user and y.period_key = p_prev_key and y.definition_id = d.id)),
                    md5(d.id || p_user::text || p_key)), '[]'::jsonb)
    into v_list
    from public.challenge_definitions d
    where d.app_id = 'officelore' and d.is_active and d.type = 'personal_daily'
      and (d.audience = 'everyone'
           or (d.audience = 'non_lord' and p_user is distinct from p_lord)
           or (d.audience = 'lord' and p_user is not distinct from p_lord))
      and public._challenge_available(d, p_user)
      and not exists (select 1 from public.challenge_assignments x
                      where x.app_id = 'officelore' and x.user_id = p_user and x.period_key = p_key and x.definition_id = d.id);

  for v_pass in 1..3 loop
    for el in select * from jsonb_array_elements(v_list) loop
      exit when cardinality(v_chosen) >= p_missing;
      continue when (el->>'id') = any (v_chosen);
      if v_pass = 1 and ((el->>'cat') = any (v_cats) or ((el->>'diff') = 'hard' and v_hard >= 1)) then continue; end if;   -- strict: new category, one hard at most
      if v_pass = 2 and ((el->>'diff') = 'hard' and v_hard >= 1) then continue; end if;                                    -- relax the category rule
      v_chosen := v_chosen || (el->>'id');
      v_cats := v_cats || (el->>'cat');
      if (el->>'diff') = 'hard' then v_hard := v_hard + 1; end if;
    end loop;
  end loop;
  return v_chosen;
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public._ensure_challenge_assignments_for(p_user uuid, p_at timestamptz)
returns int as $$
declare
  v_tz text := public._challenge_tz();
  v_local timestamp := p_at at time zone v_tz;
  v_day_start timestamptz := date_trunc('day', v_local) at time zone v_tz;
  v_day_end timestamptz := (date_trunc('day', v_local) + interval '1 day') at time zone v_tz;
  v_wk_start timestamptz := date_trunc('week', v_local) at time zone v_tz;
  v_wk_end timestamptz := (date_trunc('week', v_local) + interval '7 days') at time zone v_tz;
  v_day_key text := to_char(v_local, 'YYYY-MM-DD');
  v_prev_key text := to_char(v_local - interval '1 day', 'YYYY-MM-DD');
  v_wk_key text := to_char(v_local, 'IYYY-"W"IW');
  v_lord uuid := (select user_id from public.abt_reigns where ended_at is null limit 1);
  v_type text;
  v_key text; v_from timestamptz; v_to timestamptz;
  v_owner uuid;
  v_have int; v_want int; v_created int := 0; v_n int;
  v_ids text[];
begin
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return 0;
  end if;
  perform pg_advisory_xact_lock(hashtext('challenge_gen:' || p_user::text));

  update public.challenge_assignments set status = 'expired'
    where app_id = 'officelore' and status = 'active' and expires_at <= p_at and (user_id = p_user or user_id is null);

  foreach v_type in array array['personal_daily', 'group_daily', 'personal_weekly', 'group_weekly', 'rebellion'] loop
    if v_type in ('personal_daily', 'group_daily') then v_key := v_day_key; v_from := v_day_start; v_to := v_day_end;
    else v_key := v_wk_key; v_from := v_wk_start; v_to := v_wk_end; end if;
    v_owner := case when v_type in ('group_daily', 'group_weekly') then null else p_user end;
    v_want := public._challenge_slots(v_type);
    if v_owner is null then perform pg_advisory_xact_lock(hashtext('challenge_group:' || v_type || ':' || v_key)); end if;

    select count(*) into v_have from public.challenge_assignments
      where app_id = 'officelore' and type = v_type and period_key = v_key and user_id is not distinct from v_owner;
    continue when v_have >= v_want;

    if v_type = 'personal_daily' then
      v_ids := public._pick_personal_dailies(p_user, v_key, v_prev_key, v_lord, v_want - v_have);
    else
      select coalesce(array_agg(x.id), '{}') into v_ids from (
        select d.id from public.challenge_definitions d
        where d.app_id = 'officelore' and d.is_active and d.type = v_type
          and (d.audience = 'everyone'
               or (d.audience = 'non_lord' and p_user is distinct from v_lord)
               or (d.audience = 'lord' and p_user is not distinct from v_lord))
          and public._challenge_available(d, p_user)
          and not exists (select 1 from public.challenge_assignments x2
                          where x2.app_id = 'officelore' and x2.definition_id = d.id and x2.period_key = v_key and x2.user_id is not distinct from v_owner)
        order by md5(d.id || coalesce(v_owner::text, 'group') || v_key)
        limit v_want - v_have) x;
    end if;
    continue when cardinality(v_ids) = 0;

    insert into public.challenge_assignments
      (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
       target, period_key, starts_at, expires_at)
    select 'officelore', d.id, v_owner, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.event_types, d.icon, d.requirements,
           case when d.reward_from_difficulty then public._difficulty_reward(d.difficulty) else d.reward end,
           d.target, v_key, v_from, v_to
    from public.challenge_definitions d
    where d.id = any (v_ids)
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_created := v_created + v_n;
  end loop;
  return v_created;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — rewards with chance, claims, the sweep
-- =================================================================
-- one reward line. Returns what happened so the UI can tell the player.
create or replace function public._grant_challenge_reward2(p_user uuid, p_assignment uuid, p_sweep uuid, p_line jsonb, p_line_no int)
returns jsonb as $$
declare
  v_kind text := p_line->>'kind';
  v_amount int := coalesce((p_line->>'amount')::int, 0);
  v_chance numeric := coalesce((p_line->>'chance')::numeric, 1);
  v_hit boolean;
  v_status text;
  v_frag int;
  v_per int := public._fragments_per_gauntlet();
begin
  v_hit := v_chance >= 1 or random() < v_chance;     -- rolled once: the grant row below records it
  v_status := case when not v_hit then 'missed'
                   when v_kind in ('player_xp', 'category_xp', 'gauntlet_fragments') then 'applied'
                   else 'pending' end;
  insert into public.challenge_reward_grants (assignment_id, sweep_id, user_id, line_no, kind, amount, category, status)
    values (p_assignment, p_sweep, p_user, p_line_no, v_kind, case when v_hit then v_amount else 0 end, p_line->>'category', v_status)
    on conflict do nothing;
  if not found then
    return jsonb_build_object('kind', v_kind, 'duplicate', true);
  end if;

  if v_hit and v_kind = 'gauntlet_fragments' and v_amount > 0 then
    insert into public.gauntlet_fragments (user_id, fragments) values (p_user, v_amount)
      on conflict (user_id) do update set fragments = public.gauntlet_fragments.fragments + excluded.fragments, updated_at = now()
      returning fragments into v_frag;
    while v_frag >= v_per loop
      update public.gauntlet_fragments set fragments = fragments - v_per, updated_at = now() where user_id = p_user returning fragments into v_frag;
      insert into public.royal_gauntlet_balances (user_id, balance) values (p_user, 1)
        on conflict (user_id) do update set balance = public.royal_gauntlet_balances.balance + 1, updated_at = now();
      insert into public.royal_gauntlet_ledger (user_id, delta, reason, note) values (p_user, 1, 'fragment_convert', v_per || ' fragments');
    end loop;
  end if;
  return jsonb_build_object('kind', v_kind, 'amount', v_amount, 'category', p_line->>'category', 'hit', v_hit, 'chance', v_chance, 'status', v_status);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.claim_challenge(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_line jsonb;
  v_no int := 0;
  v_results jsonb := '[]'::jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if a.status not in ('completed', 'claimed') then raise exception 'This challenge is not complete yet'; end if;
  if a.user_id is not null and a.user_id <> auth.uid() then raise exception 'This is not your challenge'; end if;
  if a.user_id is null and not exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id and c.user_id = auth.uid() and c.amount > 0) then
    raise exception 'Only members who contributed can claim a group reward';
  end if;

  insert into public.challenge_claims (assignment_id, user_id) values (a.id, auth.uid()) on conflict do nothing;
  if not found then
    return jsonb_build_object('status', 'already_claimed');
  end if;

  for v_line in select * from jsonb_array_elements(coalesce(a.reward->'lines', '[]'::jsonb)) loop
    v_no := v_no + 1;
    v_results := v_results || public._grant_challenge_reward2(auth.uid(), a.id, null, v_line, v_no);
  end loop;

  if a.user_id is not null then
    update public.challenge_assignments set status = 'claimed', claimed_at = now() where id = a.id;
  end if;
  return jsonb_build_object('status', 'claimed', 'results', v_results);
end;
$$ language plpgsql security definer set search_path = public;

-- 🎁 claim the Daily Sweep (once)
create or replace function public.claim_daily_sweep(p_sweep_id uuid)
returns jsonb as $$
declare
  s public.challenge_sweeps;
  v_line jsonb;
  v_no int := 0;
  v_results jsonb := '[]'::jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into s from public.challenge_sweeps where id = p_sweep_id for update;
  if s.id is null or s.user_id <> auth.uid() then raise exception 'This is not your Daily Sweep'; end if;
  if s.claimed_at is not null then return jsonb_build_object('status', 'already_claimed'); end if;

  update public.challenge_sweeps set claimed_at = now() where id = s.id;
  for v_line in select * from jsonb_array_elements(coalesce(s.reward->'lines', '[]'::jsonb)) loop
    v_no := v_no + 1;
    v_results := v_results || public._grant_challenge_reward2(auth.uid(), null, s.id, v_line, v_no);
  end loop;
  return jsonb_build_object('status', 'claimed', 'results', v_results);
end;
$$ language plpgsql security definer set search_path = public;

drop function if exists public._grant_challenge_reward(uuid, uuid, jsonb, int);

-- =================================================================
-- SECTION 6 — richer events from the existing features
-- =================================================================
-- age_days: how old the content was (Memory Lane). first: the user's FIRST rating of that beer (Beer Scholar).
create or replace function public._ch_t_nickname_vote() returns trigger as $$
declare v_age int;
begin
  begin
    select floor(extract(epoch from (now() - created_at)) / 86400)::int into v_age from public.nicknames where id = new.nickname_id;
    perform public._challenge_event(new.user_id, 'nickname_rated', 1, 'nickname:' || new.nickname_id,
      jsonb_build_object('nickname_id', new.nickname_id, 'vote', new.vote_type, 'age_days', coalesce(v_age, 0)), 'nickname_votes:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_nickname_anecdote() returns trigger as $$
begin
  begin
    if coalesce(btrim(old.anecdote), '') = '' and coalesce(btrim(new.anecdote), '') <> '' then
      perform public._challenge_event(coalesce(new.updated_by_user_id, new.created_by_user_id), 'nickname_anecdote_added', 1, null,
        jsonb_build_object('nickname_id', new.id, 'age_days', floor(extract(epoch from (now() - new.created_at)) / 86400)::int),
        'nickname_anecdote:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_poem_reaction() returns trigger as $$
declare v_age int;
begin
  begin
    select floor(extract(epoch from (now() - created_at)) / 86400)::int into v_age from public.poems where id = new.poem_id;
    perform public._challenge_event(new.user_id, 'poem_rated', 1, 'poem:' || new.poem_id,
      jsonb_build_object('poem_id', new.poem_id, 'reaction', new.reaction_type, 'age_days', coalesce(v_age, 0)), 'poem_reactions:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

-- a comment counts like a reaction: "2 DIFFERENT poems" is one poem whichever way you respond
create or replace function public._ch_t_poem_comment() returns trigger as $$
declare v_age int;
begin
  begin
    select floor(extract(epoch from (now() - created_at)) / 86400)::int into v_age from public.poems where id = new.poem_id;
    perform public._challenge_event(new.user_id, 'poem_commented', 1, 'poem:' || new.poem_id,
      jsonb_build_object('poem_id', new.poem_id, 'age_days', coalesce(v_age, 0)), 'poem_comments:' || new.id);
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

create or replace function public._ch_t_beer_rating() returns trigger as $$
begin
  begin
    if new.rating is not null then
      perform public._challenge_event(new.user_id, 'beer_rated', 1, 'beer:' || new.beer_id,
        jsonb_build_object('beer_id', new.beer_id, 'rating', new.rating,
          'first', case when exists (select 1 from public.beer_ratings r where r.beer_id = new.beer_id and r.user_id = new.user_id and r.rating is not null and r.id <> new.id) then 0 else 1 end),
        'beer_ratings:' || new.id);
    end if;
  exception when others then raise warning 'challenge event failed: %', sqlerrm; end;
  return new;
end; $$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 7 — the Daily pool
-- =================================================================
-- the 0048 sample dailies make way for the real pool (the weekly/group/rebellion samples stay)
update public.challenge_definitions set is_active = false where id in ('d_nick_rate_3', 'd_beer_rate_1', 'd_poem_react_1', 'd_battle_vote_1', 'd_nick_new_1');

insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, event_types, target, requirements, reward_from_difficulty, icon, requires, audience) values
  -- NICKNAME / LORE
  ('pd_name_thy_victim', 'personal_daily', 'nickname', 'Name Thy Victim', 'Add 1 new nickname to the Nickname Wall.', 'normal', 'nickname_created', null, 1, '{}', true, '🏷️', null, 'everyone'),
  ('pd_lore_keeper', 'personal_daily', 'nickname', 'Lore Keeper', 'Add an anecdote to an existing nickname that has none yet.', 'normal', 'nickname_anecdote_added', null, 1, '{}', true, '📖', 'anecdote_target', 'everyone'),
  ('pd_quote_hunter', 'personal_daily', 'lore', 'Quote Hunter', 'Add a quote to the Lore.', 'easy', 'quote_added', null, 1, '{}', true, '💬', null, 'everyone'),
  ('pd_the_critic', 'personal_daily', 'nickname', 'The Critic', 'Rate 3 different nicknames.', 'easy', 'nickname_rated', null, 3, '{}', true, '⭐', 'nicknames_3', 'everyone'),
  ('pd_pick_a_side', 'personal_daily', 'battle', 'Pick a Side', 'Cast your vote in an open Nickname Battle.', 'easy', 'battle_voted', null, 1, '{}', true, '⚔️', 'open_battle', 'everyone'),
  -- POETRY
  ('pd_poet_for_a_day', 'personal_daily', 'poetry', 'Poet for a Day', 'Complete Today''s Poetry Challenge.', 'hard', 'poetry_daily_completed', null, 1, '{}', true, '✍️', null, 'everyone'),
  ('pd_poetry_critic', 'personal_daily', 'poetry', 'Poetry Critic', 'React to, or comment on, 2 different poems.', 'easy', 'poem_rated', array['poem_rated', 'poem_commented'], 2, '{}', true, '❤️', 'poems_2', 'everyone'),
  -- BEER (ratings, discovery, data, sessions: never quantity)
  ('pd_beer_scholar', 'personal_daily', 'beer', 'Beer Scholar', 'Rate a beer you have not rated yet.', 'easy', 'beer_rated', null, 1, '{"min_first": 1}', true, '🍺', 'unrated_beer', 'everyone'),
  ('pd_new_brew', 'personal_daily', 'beer', 'New Brew', 'Add a new beer to the Beer Fridge.', 'normal', 'beer_added', null, 1, '{}', true, '🆕', null, 'everyone'),
  ('pd_one_for_the_books', 'personal_daily', 'beer', 'One for the Books', 'Take part in a Beer Session that gets logged.', 'normal', 'beer_session_participated', null, 1, '{}', true, '🍻', null, 'everyone'),
  -- QUIZ / LORE (waiting for the quiz feature)
  ('pd_lore_master', 'personal_daily', 'quiz', 'Lore Master', 'Complete an Office Lore Quiz.', 'normal', 'quiz_completed', null, 1, '{}', true, '🧠', 'quiz', 'everyone'),
  ('pd_perfect_score', 'personal_daily', 'quiz', 'Perfect Score', 'Score at least 80% on an Office Lore Quiz.', 'hard', 'quiz_completed', null, 1, '{"min_pct": 80}', true, '🎯', 'quiz', 'everyone'),
  ('pd_know_thy_friends', 'personal_daily', 'quiz', 'Know Thy Friends', 'Answer a question about another member.', 'normal', 'quiz_about_friend', null, 1, '{}', true, '👀', 'quiz', 'everyone'),
  -- OTHER
  ('pd_office_oracle', 'personal_daily', 'social', 'Office Oracle', 'Make one prediction.', 'easy', 'prediction_created', null, 1, '{}', true, '🔮', 'prediction', 'everyone'),
  -- MEMORY LANE counts: reacting to or commenting on a poem that is more than a week old, reacting to a nickname more than a week old, or adding an anecdote to a nickname more than a week old
  ('pd_memory_lane', 'personal_daily', 'lore', 'Memory Lane', 'Revisit old content: react to or comment on a poem, or react to a nickname, or add a story to a nickname, that is more than a week old.', 'normal',
     'poem_rated', array['poem_rated', 'poem_commented', 'nickname_rated', 'nickname_anecdote_added'], 1, '{"min_age_days": 7}', true, '📚', 'old_content', 'everyone')
on conflict (id) do update set
  type = excluded.type, category = excluded.category, title = excluded.title, description = excluded.description, difficulty = excluded.difficulty,
  event_type = excluded.event_type, event_types = excluded.event_types, target = excluded.target, requirements = excluded.requirements,
  reward_from_difficulty = excluded.reward_from_difficulty, icon = excluded.icon, requires = excluded.requires, audience = excluded.audience, is_active = true;

-- =================================================================
-- SECTION 8 — grants
-- =================================================================
revoke all on function public._challenge_config(text, jsonb) from public, anon, authenticated;
revoke all on function public._difficulty_reward(text) from public, anon, authenticated;
revoke all on function public._challenge_available(public.challenge_definitions, uuid) from public, anon, authenticated;
revoke all on function public._pick_personal_dailies(uuid, text, text, uuid, int) from public, anon, authenticated;
revoke all on function public._grant_challenge_reward2(uuid, uuid, uuid, jsonb, int) from public, anon, authenticated;
revoke all on function public._challenge_event(uuid, text, int, text, jsonb, text) from public, anon, authenticated;
revoke all on function public._ensure_challenge_assignments_for(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.claim_challenge(uuid) from public, anon;
revoke all on function public.claim_daily_sweep(uuid) from public, anon;
grant execute on function public.claim_challenge(uuid) to authenticated;
grant execute on function public.claim_daily_sweep(uuid) to authenticated;

-- =========== 0050_chaos_dailies.sql ===========
-- =================================================================
-- OFFICE LORE — 🎭 CHAOS DAILIES (human-input Personal Dailies + the Chaos Feed)
-- =================================================================
-- Playful Dailies the database cannot watch happen. They live in the same
-- engine (a definition, a personal_daily assignment, the same rewards and the
-- Daily Sweep) but complete through a SUBMISSION instead of a trigger.
--
--   👑 Royal Decree      one useless royal decree (text)               -> shown in the feed
--   🎨 Draw This         draw the app-picked nickname                  -> others GUESS which
--   📸 Office Safari     photo of a curated, object-only prompt        -> feed
--   🎲 The Impostor      3 statements, 2 true, 1 false                 -> others GUESS the lie
--   😀 Emoji Lore        a nickname in at most 5 emoji                 -> others GUESS which
--   🧠 Five Second       3 answers to a safe category in 5 seconds     -> server-timed
--   📸 The Photographer  a creative / composition photo prompt         -> feed
--   🧭 Tiny Quest        find and photograph something simple          -> feed
--   (not built, by request: Royal Portrait, Meme Lord, Corporate Bullshit,
--    The Salesman, Worst Advice, Voice Actor)
--
-- NO FARMING. There is no "Done" button. A Daily completes only when the
-- SERVER accepts a valid submission for THAT assignment:
--   * one submission per assignment (unique), one assignment per definition per
--     day, and the daily variety rule keeps Chaos to about one a day
--   * submissions are validated (length, 3 distinct statements, emoji only,
--     a real image), a user cannot resubmit the same text twice (content hash)
--   * Five Second is TIMED ON THE SERVER: start_five_seconds records the clock,
--     submit_five_seconds refuses a late answer; max 2 attempts; categories
--     marked "verify" (nicknames, our beers) check the answers against the data
--
-- GUESSING. The right answer of Draw This / Impostor / Emoji Lore sits in a
-- private table (chaos_secrets, no client policy). Others see the submission and
-- guess through guess_chaos(): one guess each, never your own, and the answer
-- is only revealed to you after you guessed.
--
-- IMAGES are a separate, swappable component: for now a client-resized JPEG/PNG
-- data URL in chaos_submissions.media (the same approach the app already uses
-- for beer photos), validated and size-capped here, with media_kind recording
-- how it is stored so Supabase Storage can replace it later without touching
-- the challenges.
--
-- Photo prompts come from a CURATED list and are about objects only: never
-- people, screens, papers or whiteboards.
--
-- REWARDS: configurable in challenge_config.chaos_rewards (XP + a raised Mystery
-- Reward chance; harder Chaos Dailies also a Gauntlet Fragment chance).
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0049.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
alter table public.challenge_definitions
  add column if not exists completion text not null default 'auto',   -- 'auto' (events) or 'chaos:<kind>' (a submission)
  add column if not exists reward_key text,                           -- challenge_config key holding this definition's reward table
  add column if not exists prompt_kind text;                          -- which curated prompt list to draw from
alter table public.challenge_assignments
  add column if not exists completion text not null default 'auto',
  add column if not exists payload jsonb not null default '{}';       -- what the app picked for THIS assignment (prompt, nickname ...)

create table if not exists public.chaos_prompts (
  id serial primary key,
  kind text not null,
  text text not null,
  verify text,                              -- 'nicknames' | 'beers': Five Second answers must exist in our data
  is_active boolean not null default true,
  unique (kind, text)
);
alter table public.chaos_prompts enable row level security;   -- server-side only: the pick is copied onto the assignment

create table if not exists public.chaos_submissions (
  id uuid primary key default gen_random_uuid(),
  app_id text not null default 'officelore',
  user_id uuid not null references public.profiles(id),
  assignment_id uuid not null unique references public.challenge_assignments(id) on delete cascade,   -- ONE submission per assignment
  definition_id text not null,
  kind text not null check (kind in ('decree', 'draw', 'safari', 'photographer', 'tiny', 'impostor', 'emoji', 'five')),
  prompt text,
  content jsonb not null default '{}',
  options jsonb,                            -- the choices others pick from (draw / emoji)
  media text,                               -- data URL for now
  media_kind text default 'data_url' check (media_kind in ('data_url')),
  content_hash text,
  created_at timestamptz not null default now()
);
create unique index if not exists chaos_submissions_no_repeat on public.chaos_submissions (user_id, content_hash) where content_hash is not null;
create index if not exists chaos_submissions_recent on public.chaos_submissions (app_id, created_at desc);

create table if not exists public.chaos_secrets (
  submission_id uuid primary key references public.chaos_submissions(id) on delete cascade,
  answer jsonb not null
);
alter table public.chaos_secrets enable row level security;     -- deliberately NO policy

create table if not exists public.chaos_guesses (
  submission_id uuid not null references public.chaos_submissions(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  guess jsonb not null,
  correct boolean not null,
  created_at timestamptz not null default now(),
  primary key (submission_id, user_id)
);

create table if not exists public.chaos_reactions (
  submission_id uuid not null references public.chaos_submissions(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  emoji text not null check (emoji in ('😂', '🔥', '👑', '🤯', '❤️')),
  created_at timestamptz not null default now(),
  primary key (submission_id, user_id, emoji)
);

create table if not exists public.chaos_attempts (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  attempt_no int not null,
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  ok boolean,
  primary key (assignment_id, attempt_no)
);
alter table public.chaos_attempts enable row level security;    -- deliberately NO policy

alter table public.chaos_submissions enable row level security;
alter table public.chaos_guesses enable row level security;
alter table public.chaos_reactions enable row level security;
drop policy if exists "Chaos submissions: read" on public.chaos_submissions;
create policy "Chaos submissions: read" on public.chaos_submissions for select to authenticated using (public.is_app_member(app_id));
drop policy if exists "Chaos guesses: read own" on public.chaos_guesses;
create policy "Chaos guesses: read own" on public.chaos_guesses for select to authenticated using (user_id = auth.uid());
drop policy if exists "Chaos reactions: read" on public.chaos_reactions;
create policy "Chaos reactions: read" on public.chaos_reactions for select to authenticated using (public.is_app_member('officelore'));

do $$
declare t text;
begin
  foreach t in array array['chaos_submissions', 'chaos_reactions', 'chaos_guesses'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- =================================================================
-- SECTION 2 — rewards and the curated prompts
-- =================================================================
insert into public.challenge_config (key, value) values
  ('chaos_rewards', '{
      "easy":   [ {"kind":"player_xp","amount":12}, {"kind":"mystery","amount":1,"chance":0.20} ],
      "normal": [ {"kind":"player_xp","amount":20}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "hard":   [ {"kind":"player_xp","amount":30}, {"kind":"mystery","amount":1,"chance":0.35}, {"kind":"gauntlet_fragments","amount":1,"chance":0.6} ]
   }'::jsonb),
  ('chaos_rules', '{"five_seconds":5, "five_seconds_grace":3, "five_attempts":2, "media_max_chars":900000}'::jsonb)
on conflict (key) do nothing;

insert into public.chaos_prompts (kind, text, verify) values
  ('decree_topic', 'Decree about: coffee', null), ('decree_topic', 'Decree about: meetings', null), ('decree_topic', 'Decree about: the printer', null),
  ('decree_topic', 'Decree about: Fridays', null), ('decree_topic', 'Decree about: the last biscuit', null), ('decree_topic', 'Decree about: reply-all', null),
  ('decree_topic', 'Decree about: chairs', null), ('decree_topic', 'Decree about: the fridge', null),
  ('safari', 'Photograph the most mysterious object in the office.', null),
  ('safari', 'Photograph something absurdly everyday as if it were a work of art.', null),
  ('safari', 'Photograph something blue.', null), ('safari', 'Photograph something yellow.', null), ('safari', 'Photograph something green.', null),
  ('safari', 'Make a dramatic photo of a perfectly normal object.', null),
  ('safari', 'Photograph the most suspicious-looking cable, plant or chair.', null),
  ('photographer', 'Shoot an everyday object from a hero angle: low, looking up.', null),
  ('photographer', 'Take a photo with a strong, interesting shadow.', null),
  ('photographer', 'Take a perfectly symmetrical photo.', null),
  ('photographer', 'Make a photo that looks like a movie poster, using only objects.', null),
  ('photographer', 'Compose a still life of three items that should never be together.', null),
  ('photographer', 'Find a leading line and make it the whole photo.', null),
  ('tiny_quest', 'Find something red.', null), ('tiny_quest', 'Find something round.', null), ('tiny_quest', 'Find something tiny.', null),
  ('tiny_quest', 'Find something unnecessarily complicated.', null), ('tiny_quest', 'Find something that looks older than it should.', null),
  ('five_seconds', 'Name 3 Belgian beers', null),
  ('five_seconds', 'Name 3 beers from our Beer Fridge', 'beers'),
  ('five_seconds', 'Name 3 nicknames from the Nickname Wall', 'nicknames'),
  ('five_seconds', 'Name 3 things found in an office', null),
  ('five_seconds', 'Name 3 things that are round', null),
  ('five_seconds', 'Name 3 types of cheese', null),
  ('five_seconds', 'Name 3 things you take to a terrace', null)
on conflict (kind, text) do nothing;

-- =================================================================
-- SECTION 3 — engine hooks (replace 0048/0049's)
-- =================================================================
create or replace function public._assignment_reward(d public.challenge_definitions)
returns jsonb as $$
  select case
    when d.reward_key is not null then jsonb_build_object('lines', coalesce(public._challenge_config(d.reward_key, '{}'::jsonb) -> d.difficulty, '[]'::jsonb))
    when d.reward_from_difficulty then public._difficulty_reward(d.difficulty)
    else d.reward end;
$$ language sql stable security definer set search_path = public;

-- the app's own pick for this assignment: a curated prompt, or a nickname
create or replace function public._chaos_payload(d public.challenge_definitions, p_user uuid, p_key text)
returns jsonb as $$
declare
  v_kind text := split_part(d.completion, ':', 2);
  v_row jsonb;
begin
  if d.completion = 'auto' then return '{}'::jsonb; end if;
  if v_kind in ('draw', 'emoji') then
    select jsonb_build_object('nickname_id', n.id, 'text', n.nickname) into v_row
      from public.nicknames n where n.status = 'Actief' order by md5(n.id::text || p_user::text || p_key) limit 1;
  elsif d.prompt_kind is not null then
    select jsonb_build_object('text', p.text, 'verify', p.verify) into v_row
      from public.chaos_prompts p where p.kind = d.prompt_kind and p.is_active
        and (p.verify is null
             or (p.verify = 'nicknames' and (select count(*) from public.nicknames where status = 'Actief') >= 3)
             or (p.verify = 'beers' and (select count(*) from public.beers) >= 3))
      order by md5(p.id::text || p_user::text || p_key) limit 1;
  end if;
  return coalesce(v_row, '{}'::jsonb);
end;
$$ language plpgsql stable security definer set search_path = public;

-- when a Personal Daily completes (by any route): feed the weekly chain, and the Daily Sweep
create or replace function public._after_personal_daily_completed(p_user uuid, p_assignment uuid, p_period text)
returns void as $$
declare
  v_complete int;
begin
  perform public._challenge_event(p_user, 'daily_completed', 1, p_assignment::text, '{}'::jsonb, 'daily_completed:' || p_assignment::text);
  select count(*) into v_complete from public.challenge_assignments x
    where x.app_id = 'officelore' and x.user_id = p_user and x.type = 'personal_daily'
      and x.period_key = p_period and x.status in ('completed', 'claimed');
  if v_complete >= public._challenge_slots('personal_daily') then
    insert into public.challenge_sweeps (user_id, period_key, reward)
      values (p_user, p_period, public._challenge_config('daily_sweep', '{"lines":[]}'::jsonb))
      on conflict (user_id, period_key) do nothing;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._challenge_event(
  p_user uuid, p_event text, p_amount int default 1, p_dedupe text default null,
  p_meta jsonb default '{}'::jsonb, p_source text default null)
returns void as $$
declare
  a record;
  v_add int;
  v_done boolean;
begin
  if p_user is null or p_amount is null or p_amount <= 0 then return; end if;
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return;
  end if;

  insert into public.challenge_events (app_id, user_id, event_type, amount, dedupe_key, source_key, meta)
    values ('officelore', p_user, p_event, p_amount, p_dedupe, p_source, coalesce(p_meta, '{}'::jsonb))
    on conflict (source_key) where source_key is not null do nothing;
  if not found then return; end if;

  for a in
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements, asg.period_key
    from public.challenge_assignments asg
    where asg.app_id = 'officelore' and asg.status = 'active' and asg.completion = 'auto'      -- a Chaos Daily only completes by submission
      and p_event = any (coalesce(asg.event_types, array[asg.event_type]))
      and asg.starts_at <= now() and asg.expires_at > now()
      and (asg.user_id = p_user or asg.user_id is null)
    order by asg.id
    for update
  loop
    continue when not public._challenge_requirements_met(a.requirements, p_meta);
    if p_dedupe is not null then
      insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, p_dedupe)
        on conflict do nothing;
      continue when not found;
    end if;
    v_add := least(p_amount, a.target - a.progress);
    continue when v_add <= 0;
    v_done := a.progress + v_add >= a.target;
    update public.challenge_assignments
      set progress = progress + v_add,
          status = case when v_done then 'completed' else status end,
          completed_at = case when v_done then now() else completed_at end
      where id = a.id;
    if a.user_id is null then
      insert into public.challenge_contributions (assignment_id, user_id, amount) values (a.id, p_user, v_add)
        on conflict (assignment_id, user_id) do update set amount = public.challenge_contributions.amount + excluded.amount;
    end if;
    if v_done and a.type = 'personal_daily' then
      perform public._after_personal_daily_completed(p_user, a.id, a.period_key);
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- generation: now also stores completion kind + the app's pick (0049's, extended)
create or replace function public._ensure_challenge_assignments_for(p_user uuid, p_at timestamptz)
returns int as $$
declare
  v_tz text := public._challenge_tz();
  v_local timestamp := p_at at time zone v_tz;
  v_day_start timestamptz := date_trunc('day', v_local) at time zone v_tz;
  v_day_end timestamptz := (date_trunc('day', v_local) + interval '1 day') at time zone v_tz;
  v_wk_start timestamptz := date_trunc('week', v_local) at time zone v_tz;
  v_wk_end timestamptz := (date_trunc('week', v_local) + interval '7 days') at time zone v_tz;
  v_day_key text := to_char(v_local, 'YYYY-MM-DD');
  v_prev_key text := to_char(v_local - interval '1 day', 'YYYY-MM-DD');
  v_wk_key text := to_char(v_local, 'IYYY-"W"IW');
  v_lord uuid := (select user_id from public.abt_reigns where ended_at is null limit 1);
  v_type text;
  v_key text; v_from timestamptz; v_to timestamptz;
  v_owner uuid;
  v_have int; v_want int; v_created int := 0; v_n int;
  v_ids text[];
begin
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return 0;
  end if;
  perform pg_advisory_xact_lock(hashtext('challenge_gen:' || p_user::text));

  update public.challenge_assignments set status = 'expired'
    where app_id = 'officelore' and status = 'active' and expires_at <= p_at and (user_id = p_user or user_id is null);

  foreach v_type in array array['personal_daily', 'group_daily', 'personal_weekly', 'group_weekly', 'rebellion'] loop
    if v_type in ('personal_daily', 'group_daily') then v_key := v_day_key; v_from := v_day_start; v_to := v_day_end;
    else v_key := v_wk_key; v_from := v_wk_start; v_to := v_wk_end; end if;
    v_owner := case when v_type in ('group_daily', 'group_weekly') then null else p_user end;
    v_want := public._challenge_slots(v_type);
    if v_owner is null then perform pg_advisory_xact_lock(hashtext('challenge_group:' || v_type || ':' || v_key)); end if;

    select count(*) into v_have from public.challenge_assignments
      where app_id = 'officelore' and type = v_type and period_key = v_key and user_id is not distinct from v_owner;
    continue when v_have >= v_want;

    if v_type = 'personal_daily' then
      v_ids := public._pick_personal_dailies(p_user, v_key, v_prev_key, v_lord, v_want - v_have);
    else
      select coalesce(array_agg(x.id), '{}') into v_ids from (
        select d.id from public.challenge_definitions d
        where d.app_id = 'officelore' and d.is_active and d.type = v_type
          and (d.audience = 'everyone'
               or (d.audience = 'non_lord' and p_user is distinct from v_lord)
               or (d.audience = 'lord' and p_user is not distinct from v_lord))
          and public._challenge_available(d, p_user)
          and not exists (select 1 from public.challenge_assignments x2
                          where x2.app_id = 'officelore' and x2.definition_id = d.id and x2.period_key = v_key and x2.user_id is not distinct from v_owner)
        order by md5(d.id || coalesce(v_owner::text, 'group') || v_key)
        limit v_want - v_have) x;
    end if;
    continue when cardinality(v_ids) = 0;

    insert into public.challenge_assignments
      (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
       target, period_key, starts_at, expires_at, completion, payload)
    select 'officelore', d.id, v_owner, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.event_types, d.icon, d.requirements,
           public._assignment_reward(d),
           d.target, v_key, v_from, v_to, d.completion, public._chaos_payload(d, p_user, v_key)
    from public.challenge_definitions d
    where d.id = any (v_ids)
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_created := v_created + v_n;
  end loop;
  return v_created;
end;
$$ language plpgsql security definer set search_path = public;

-- finishing a Chaos Daily after its submission was accepted
create or replace function public._complete_chaos_assignment(p_assignment uuid)
returns void as $$
declare
  a public.challenge_assignments;
begin
  select * into a from public.challenge_assignments where id = p_assignment for update;
  update public.challenge_assignments set progress = target, status = 'completed', completed_at = now() where id = a.id;
  perform public._challenge_event(a.user_id, 'chaos_completed', 1, null, jsonb_build_object('kind', split_part(a.completion, ':', 2)), 'chaos_completed:' || a.id::text);
  perform public._after_personal_daily_completed(a.user_id, a.id, a.period_key);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — submitting
-- =================================================================
create or replace function public._chaos_options(p_correct text)
returns jsonb as $$
  select coalesce(jsonb_agg(q.t order by random()), '[]'::jsonb) from (
    select p_correct as t
    union all
    (select x.nickname from (
       select distinct on (lower(btrim(nickname))) nickname from public.nicknames
       where status = 'Actief' and lower(btrim(nickname)) <> lower(btrim(p_correct))
       order by lower(btrim(nickname)), random()) x
     order by random() limit 3)
  ) q;
$$ language sql volatile security definer set search_path = public;

create or replace function public.submit_chaos(p_assignment_id uuid, p_content jsonb, p_media text default null)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_kind text;
  v_text text;
  v_content jsonb := '{}'::jsonb;
  v_options jsonb;
  v_answer jsonb;
  v_media text := null;
  v_hash text;
  v_id uuid;
  v_max int := coalesce((public._challenge_config('chaos_rules', '{}'::jsonb)->>'media_max_chars')::int, 900000);
  v_stmts jsonb; v_fake int; v_i int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.user_id is distinct from auth.uid() then raise exception 'This is not your challenge'; end if;
  if a.completion not like 'chaos:%' then raise exception 'This challenge completes by itself'; end if;
  if a.status <> 'active' or a.expires_at <= now() then raise exception 'This challenge is no longer open'; end if;
  if exists (select 1 from public.chaos_submissions where assignment_id = a.id) then raise exception 'Already submitted'; end if;
  v_kind := split_part(a.completion, ':', 2);

  if v_kind = 'decree' then
    v_text := btrim(coalesce(p_content->>'text', ''));
    if length(v_text) < 15 or length(v_text) > 280 then raise exception 'A decree needs 15 to 280 characters'; end if;
    if array_length(regexp_split_to_array(v_text, '\s+'), 1) < 5 then raise exception 'A decree needs at least 5 words'; end if;
    v_content := jsonb_build_object('text', v_text);
    v_hash := md5(lower(v_text));

  elsif v_kind in ('safari', 'photographer', 'tiny') then
    v_media := p_media;
    v_content := jsonb_build_object('note', left(btrim(coalesce(p_content->>'note', '')), 120));
    v_hash := md5(substr(coalesce(p_media, ''), 1, 4000) || length(coalesce(p_media, '')));

  elsif v_kind = 'draw' then
    v_media := p_media;
    v_answer := jsonb_build_object('text', a.payload->>'text');
    v_options := public._chaos_options(a.payload->>'text');
    v_hash := md5(substr(coalesce(p_media, ''), 1, 4000) || length(coalesce(p_media, '')));

  elsif v_kind = 'emoji' then
    v_text := btrim(coalesce(p_content->>'emoji', ''));
    if v_text ~ '[A-Za-z0-9]' or length(translate(v_text, chr(65039) || chr(8205) || ' ', '')) not between 1 and 5 then raise exception 'Use emoji only, at most 5'; end if;
    v_content := jsonb_build_object('emoji', v_text);
    v_answer := jsonb_build_object('text', a.payload->>'text');
    v_options := public._chaos_options(a.payload->>'text');
    v_hash := md5(v_text || ':' || (a.payload->>'nickname_id'));

  elsif v_kind = 'impostor' then
    v_stmts := p_content->'statements';
    v_fake := (p_content->>'fake')::int;
    if coalesce(jsonb_typeof(v_stmts), '') <> 'array' or jsonb_array_length(v_stmts) <> 3 or coalesce(v_fake, -1) not between 0 and 2 then raise exception 'Write 3 statements and mark the false one'; end if;
    for v_i in 0..2 loop
      if length(btrim(coalesce(v_stmts->>v_i, ''))) < 8 or length(btrim(v_stmts->>v_i)) > 140 then raise exception 'Each statement needs 8 to 140 characters'; end if;
    end loop;
    if (select count(distinct lower(btrim(s))) from jsonb_array_elements_text(v_stmts) s) <> 3 then raise exception 'The 3 statements must be different'; end if;
    v_content := jsonb_build_object('statements', (select jsonb_agg(btrim(s)) from jsonb_array_elements_text(v_stmts) s));
    v_answer := jsonb_build_object('fake', v_fake);
    v_hash := md5(lower(v_content::text));

  else
    raise exception 'This challenge is submitted differently';
  end if;

  if v_kind in ('safari', 'photographer', 'tiny', 'draw') then
    if v_media is null or v_media !~ '^data:image/(jpeg|png);base64,[A-Za-z0-9+/=]+$' then raise exception 'Add a photo or drawing first'; end if;
    if length(v_media) > v_max then raise exception 'That image is too large'; end if;
  end if;

  begin
    insert into public.chaos_submissions (user_id, assignment_id, definition_id, kind, prompt, content, options, media, content_hash)
      values (auth.uid(), a.id, a.definition_id, v_kind, case when v_kind in ('draw', 'emoji') then null else a.payload->>'text' end, v_content, v_options, v_media, v_hash)
      returning id into v_id;
  exception when unique_violation then
    raise exception 'You already sent exactly this before. Make something new';
  end;
  if v_answer is not null then insert into public.chaos_secrets (submission_id, answer) values (v_id, v_answer); end if;

  perform public._complete_chaos_assignment(a.id);
  return jsonb_build_object('status', 'submitted', 'id', v_id);
end;
$$ language plpgsql security definer set search_path = public;

-- 🧠 Five Second: the clock is the server's
create or replace function public.start_five_seconds(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_rules jsonb := public._challenge_config('chaos_rules', '{}'::jsonb);
  v_no int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.user_id is distinct from auth.uid() or a.completion <> 'chaos:five' then raise exception 'This is not your Five Second challenge'; end if;
  if a.status <> 'active' or a.expires_at <= now() then raise exception 'This challenge is no longer open'; end if;
  -- an attempt that was started but never answered counts as used
  update public.chaos_attempts set finished_at = clock_timestamp(), ok = false where assignment_id = a.id and finished_at is null;
  select count(*) into v_no from public.chaos_attempts where assignment_id = a.id;
  if v_no >= coalesce((v_rules->>'five_attempts')::int, 2) then raise exception 'No attempts left'; end if;
  insert into public.chaos_attempts (assignment_id, attempt_no) values (a.id, v_no + 1);
  return jsonb_build_object('attempt', v_no + 1, 'attempts_left', coalesce((v_rules->>'five_attempts')::int, 2) - v_no - 1,
    'category', a.payload->>'text', 'seconds', coalesce((v_rules->>'five_seconds')::int, 5));
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.submit_five_seconds(p_assignment_id uuid, p_answers jsonb)
returns jsonb as $$
declare
  a public.challenge_assignments;
  t public.chaos_attempts;
  v_rules jsonb := public._challenge_config('chaos_rules', '{}'::jsonb);
  v_secs numeric := coalesce((v_rules->>'five_seconds')::numeric, 5) + coalesce((v_rules->>'five_seconds_grace')::numeric, 3);
  v_ans text[];
  v_left int;
  v_ok boolean := true;
  v_why text := null;
  x text;
  v_id uuid;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.user_id is distinct from auth.uid() or a.completion <> 'chaos:five' then raise exception 'This is not your Five Second challenge'; end if;
  if a.status <> 'active' then raise exception 'This challenge is no longer open'; end if;
  select * into t from public.chaos_attempts where assignment_id = a.id and finished_at is null order by attempt_no desc limit 1;
  if t.assignment_id is null then raise exception 'Press start first'; end if;

  select array_agg(distinct lower(btrim(e))) into v_ans from jsonb_array_elements_text(coalesce(p_answers, '[]'::jsonb)) e where length(btrim(e)) >= 2;
  if extract(epoch from (clock_timestamp() - t.started_at)) > v_secs then v_ok := false; v_why := 'Too slow';
  elsif coalesce(cardinality(v_ans), 0) < 3 then v_ok := false; v_why := 'Three different answers, please';
  else
    foreach x in array v_ans loop
      if length(x) > 40 then v_ok := false; v_why := 'Answers must be short'; end if;
      if a.payload->>'verify' = 'nicknames' and not exists (select 1 from public.nicknames n where lower(n.nickname) like '%' || x || '%') then v_ok := false; v_why := '"' || x || '" is not on the Wall'; end if;
      if a.payload->>'verify' = 'beers' and not exists (select 1 from public.beers b where lower(b.name) like '%' || x || '%') then v_ok := false; v_why := '"' || x || '" is not in our Beer Fridge'; end if;
    end loop;
  end if;

  update public.chaos_attempts set finished_at = clock_timestamp(), ok = v_ok where assignment_id = a.id and attempt_no = t.attempt_no;
  select coalesce((v_rules->>'five_attempts')::int, 2) - count(*) into v_left from public.chaos_attempts where assignment_id = a.id;
  if not v_ok then
    return jsonb_build_object('status', 'failed', 'reason', v_why, 'attempts_left', greatest(v_left, 0));
  end if;

  insert into public.chaos_submissions (user_id, assignment_id, definition_id, kind, prompt, content)
    values (auth.uid(), a.id, a.definition_id, 'five', a.payload->>'text', jsonb_build_object('answers', to_jsonb(v_ans)))
    returning id into v_id;
  perform public._complete_chaos_assignment(a.id);
  return jsonb_build_object('status', 'submitted', 'id', v_id);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — the Chaos Feed: guess, react, read
-- =================================================================
create or replace function public.guess_chaos(p_submission_id uuid, p_guess jsonb)
returns jsonb as $$
declare
  s public.chaos_submissions;
  v_answer jsonb;
  v_correct boolean;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into s from public.chaos_submissions where id = p_submission_id;
  if s.id is null or s.app_id <> 'officelore' then raise exception 'Unknown submission'; end if;
  if s.user_id = auth.uid() then raise exception 'You cannot guess your own submission'; end if;
  select answer into v_answer from public.chaos_secrets where submission_id = s.id;
  if v_answer is null then raise exception 'There is nothing to guess here'; end if;
  if exists (select 1 from public.chaos_guesses where submission_id = s.id and user_id = auth.uid()) then raise exception 'You already guessed'; end if;

  v_correct := case s.kind
    when 'impostor' then (p_guess->>'index')::int = (v_answer->>'fake')::int
    else lower(btrim(p_guess->>'option')) = lower(btrim(v_answer->>'text')) end;
  insert into public.chaos_guesses (submission_id, user_id, guess, correct) values (s.id, auth.uid(), p_guess, v_correct);
  perform public._challenge_event(auth.uid(), 'chaos_guess', 1, 'sub:' || s.id, jsonb_build_object('correct', case when v_correct then 1 else 0 end), 'chaos_guess:' || s.id || ':' || auth.uid());
  return jsonb_build_object('correct', v_correct, 'answer', v_answer);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.react_chaos(p_submission_id uuid, p_emoji text)
returns jsonb as $$
declare
  s public.chaos_submissions;
  v_on boolean;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into s from public.chaos_submissions where id = p_submission_id;
  if s.id is null or s.app_id <> 'officelore' then raise exception 'Unknown submission'; end if;
  if s.user_id = auth.uid() then raise exception 'React to somebody else''s chaos'; end if;
  delete from public.chaos_reactions where submission_id = s.id and user_id = auth.uid() and emoji = p_emoji;
  if found then v_on := false;
  else
    insert into public.chaos_reactions (submission_id, user_id, emoji) values (s.id, auth.uid(), p_emoji);
    v_on := true;
    perform public._challenge_event(auth.uid(), 'chaos_reaction', 1, 'sub:' || s.id, '{}'::jsonb, 'chaos_reaction:' || s.id || ':' || auth.uid());
  end if;
  return jsonb_build_object('on', v_on);
end;
$$ language plpgsql security definer set search_path = public;

-- the feed, without the heavy images and without the answers
create or replace function public.get_chaos_feed(p_limit int default 40)
returns jsonb as $$
  select coalesce(jsonb_agg(f order by f->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', s.id, 'user_id', s.user_id, 'kind', s.kind, 'prompt', s.prompt, 'content', s.content,
      'options', s.options, 'has_media', s.media is not null, 'created_at', s.created_at,
      'guessable', exists (select 1 from public.chaos_secrets k where k.submission_id = s.id),
      'my_guess', (select jsonb_build_object('guess', g.guess, 'correct', g.correct) from public.chaos_guesses g where g.submission_id = s.id and g.user_id = auth.uid()),
      -- the answer is only shown to the author and to anyone who has guessed
      'answer', (select k.answer from public.chaos_secrets k where k.submission_id = s.id
                 and (s.user_id = auth.uid() or exists (select 1 from public.chaos_guesses g where g.submission_id = s.id and g.user_id = auth.uid()))),
      'guess_count', (select count(*) from public.chaos_guesses g where g.submission_id = s.id),
      'correct_count', (select count(*) from public.chaos_guesses g where g.submission_id = s.id and g.correct),
      'reactions', coalesce((select jsonb_object_agg(e, n) from (select emoji as e, count(*) as n from public.chaos_reactions r where r.submission_id = s.id group by emoji) q), '{}'::jsonb),
      'my_reactions', coalesce((select jsonb_agg(r.emoji) from public.chaos_reactions r where r.submission_id = s.id and r.user_id = auth.uid()), '[]'::jsonb)
    ) as f
    from public.chaos_submissions s
    where public.is_app_member('officelore') and s.app_id = 'officelore' and s.created_at > now() - interval '14 days'
    order by s.created_at desc limit greatest(least(p_limit, 100), 1)
  ) x;
$$ language sql stable security definer set search_path = public;

create or replace function public.get_chaos_media(p_submission_id uuid)
returns text as $$
  select s.media from public.chaos_submissions s where s.id = p_submission_id and s.app_id = 'officelore' and public.is_app_member('officelore');
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 6 — the Chaos pool
-- =================================================================
insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, target, requirements, reward_from_difficulty, reward_key, completion, prompt_kind, icon, requires, audience) values
  ('pd_royal_decree', 'personal_daily', 'chaos', 'Royal Decree', 'Write one completely useless royal decree. The court will read it in the Chaos Feed.', 'normal', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:decree', 'decree_topic', '👑', null, 'everyone'),
  ('pd_draw_this', 'personal_daily', 'chaos', 'Draw This', 'Draw the nickname the app picks for you, without writing it. The others will guess which one it is.', 'hard', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:draw', null, '🎨', 'nicknames_3', 'everyone'),
  ('pd_office_safari', 'personal_daily', 'chaos', 'Office Safari', 'A safe photo mission: objects only. No people, screens or papers.', 'normal', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:safari', 'safari', '📸', null, 'everyone'),
  ('pd_the_impostor', 'personal_daily', 'chaos', 'The Impostor', 'Write three statements about yourself or the office: two true, one false. The others hunt the lie.', 'hard', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:impostor', null, '🎲', null, 'everyone'),
  ('pd_emoji_lore', 'personal_daily', 'chaos', 'Emoji Lore', 'Describe the nickname the app picks for you with at most 5 emoji. The others guess which one it is.', 'normal', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:emoji', null, '😀', 'nicknames_3', 'everyone'),
  ('pd_five_seconds', 'personal_daily', 'chaos', 'Five Second Challenge', 'Name 3 answers to a safe category before the clock runs out. The server keeps time.', 'normal', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:five', 'five_seconds', '🧠', null, 'everyone'),
  ('pd_the_photographer', 'personal_daily', 'chaos', 'The Photographer', 'Make a creative photo from a simple, safe prompt. Composition counts. Objects only.', 'hard', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:photographer', 'photographer', '📷', null, 'everyone'),
  ('pd_tiny_quest', 'personal_daily', 'chaos', 'Tiny Quest', 'Find and photograph something that matches one simple property. Objects only.', 'easy', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:tiny', 'tiny_quest', '🧭', null, 'everyone')
on conflict (id) do update set
  title = excluded.title, description = excluded.description, difficulty = excluded.difficulty, event_type = excluded.event_type,
  reward_key = excluded.reward_key, completion = excluded.completion, prompt_kind = excluded.prompt_kind, icon = excluded.icon,
  requires = excluded.requires, is_active = true;

-- =================================================================
-- SECTION 7 — grants
-- =================================================================
revoke all on function public._assignment_reward(public.challenge_definitions) from public, anon, authenticated;
revoke all on function public._chaos_payload(public.challenge_definitions, uuid, text) from public, anon, authenticated;
revoke all on function public._after_personal_daily_completed(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public._challenge_event(uuid, text, int, text, jsonb, text) from public, anon, authenticated;
revoke all on function public._ensure_challenge_assignments_for(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public._complete_chaos_assignment(uuid) from public, anon, authenticated;
revoke all on function public._chaos_options(text) from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array['submit_chaos(uuid, jsonb, text)', 'start_five_seconds(uuid)', 'submit_five_seconds(uuid, jsonb)',
                           'guess_chaos(uuid, jsonb)', 'react_chaos(uuid, text)', 'get_chaos_feed(int)', 'get_chaos_media(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- =========== 0051_group_daily_challenge.sql ===========
-- =================================================================
-- OFFICE LORE — 🌟 TODAY'S GROUP CHALLENGE
-- =================================================================
-- Next to the 3 Personal Dailies, the whole workspace gets exactly ONE shared
-- Daily Challenge a day. Everyone sees the same one. It is a normal
-- group_daily assignment (so the generation, the reset, the timezone and the
-- "exactly one per day" rule are the engine's), plus a ROUND on top of it:
--
--   🏷️ Nickname of the Day   invent a nickname for an object, then vote
--   ✍️ Poetry Showdown        everyone writes to the same Poetry prompt, then vote
--   😀 Emoji Showdown         describe the same Office Lore item with <= 5 emoji, then vote
--   🎭 Daily Chaos            the same safe Chaos prompt (a decree or an objects-only photo), then vote
--   🧠 Daily Lore Quiz        the same 5 questions; highest score wins, fastest valid run breaks a tie
--   (🔮 Office Oracle is not part of this: predictions need a result that is determined later.)
--
-- PARTICIPATION vs WINNING
--   * every valid entry earns the PARTICIPATION reward (default: Player XP), claimed
--     through the existing claim_challenge (the entry makes you a contributor)
--   * the WINNER (decided when the day ends) claims the WINNER reward through
--     claim_group_winner: bonus XP + a Mystery Reward chance. No Gauntlet Fragment by
--     default, so a winner cannot farm one daily. Both are lines in
--     challenge_config.group_daily_rewards.
--   * a winner needs at least min_participants entries (default 2). Nobody wins alone.
--
-- FAIRNESS
--   * one entry per user; one vote per user and round, final; no vote for yourself
--   * entries are shown ANONYMOUSLY and in a per-viewer shuffled order while voting;
--     counts and authors appear only when the round ends
--   * ties on votes: co-winners. Quiz: score, then the server-measured run time
--   * the quiz answers live in a private table; the clock starts at start_group_quiz
--     and stops at submit_group_quiz, both on the server; one attempt, resumable
--   * everything is written by the RPCs below; clients only read
--   * persistent, and live: the round/participants/winners tables are in realtime
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0050.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
create table if not exists public.group_daily_rounds (
  id uuid primary key default gen_random_uuid(),
  app_id text not null default 'officelore',
  assignment_id uuid not null unique references public.challenge_assignments(id) on delete cascade,
  kind text not null check (kind in ('nickname', 'poetry', 'emoji', 'chaos', 'quiz')),
  day_key text not null,
  prompt jsonb not null default '{}',
  questions jsonb,                                   -- quiz questions WITHOUT answers
  winner_lines jsonb not null default '[]',          -- snapshot of the winner reward
  min_participants int not null default 2,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'open' check (status in ('open', 'finalized')),
  entry_count int not null default 0,
  vote_count int not null default 0,
  finalized_at timestamptz,
  no_winner_reason text,
  updated_at timestamptz not null default now()
);
create table if not exists public.group_daily_participants (
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  entered_at timestamptz not null default now(),
  primary key (round_id, user_id)
);
create table if not exists public.group_daily_entries (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  content jsonb not null default '{}',
  media text,
  score int,
  duration_ms int,
  content_hash text,
  created_at timestamptz not null default now(),
  unique (round_id, user_id)                          -- ONE entry per user and round
);
create unique index if not exists group_daily_entries_no_copy on public.group_daily_entries (round_id, content_hash) where content_hash is not null;
create table if not exists public.group_daily_votes (
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  voter_id uuid not null references public.profiles(id),
  entry_id uuid not null references public.group_daily_entries(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (round_id, voter_id)                    -- ONE vote per user and round
);
create table if not exists public.group_daily_secrets (
  round_id uuid primary key references public.group_daily_rounds(id) on delete cascade,
  answers jsonb not null
);
create table if not exists public.group_daily_attempts (
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  started_at timestamptz not null default clock_timestamp(),
  primary key (round_id, user_id)
);
create table if not exists public.group_daily_winners (
  round_id uuid not null references public.group_daily_rounds(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  entry_id uuid references public.group_daily_entries(id) on delete set null,
  claimed_at timestamptz,
  primary key (round_id, user_id)
);

alter table public.group_daily_rounds enable row level security;
alter table public.group_daily_participants enable row level security;
alter table public.group_daily_entries enable row level security;
alter table public.group_daily_votes enable row level security;
alter table public.group_daily_secrets enable row level security;     -- deliberately NO policy
alter table public.group_daily_attempts enable row level security;    -- deliberately NO policy
alter table public.group_daily_winners enable row level security;
drop policy if exists "Group rounds: read" on public.group_daily_rounds;
create policy "Group rounds: read" on public.group_daily_rounds for select to authenticated using (public.is_app_member(app_id));
drop policy if exists "Group participants: read" on public.group_daily_participants;
create policy "Group participants: read" on public.group_daily_participants for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "Group winners: read" on public.group_daily_winners;
create policy "Group winners: read" on public.group_daily_winners for select to authenticated using (public.is_app_member('officelore'));
-- entries and votes are read through the RPC only (anonymity); a user may read their own
drop policy if exists "Group entries: read own" on public.group_daily_entries;
create policy "Group entries: read own" on public.group_daily_entries for select to authenticated using (user_id = auth.uid());
drop policy if exists "Group votes: read own" on public.group_daily_votes;
create policy "Group votes: read own" on public.group_daily_votes for select to authenticated using (voter_id = auth.uid());

do $$
declare t text;
begin
  foreach t in array array['group_daily_rounds', 'group_daily_participants', 'group_daily_winners'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- =================================================================
-- SECTION 2 — config and curated subjects
-- =================================================================
insert into public.challenge_config (key, value) values
  ('group_daily_rewards', '{
      "participation": [ {"kind":"player_xp","amount":15} ],
      "winner":        [ {"kind":"player_xp","amount":30}, {"kind":"mystery","amount":1,"chance":0.25} ],
      "min_participants": 2
   }'::jsonb)
on conflict (key) do nothing;

insert into public.chaos_prompts (kind, text) values
  ('group_nickname', 'the coffee machine'), ('group_nickname', 'the office printer'), ('group_nickname', 'the meeting room without windows'),
  ('group_nickname', 'the office plant'), ('group_nickname', 'a Monday morning'), ('group_nickname', 'the last biscuit'),
  ('group_nickname', 'the broken chair'), ('group_nickname', 'the shared fridge'), ('group_nickname', 'the stapler'), ('group_nickname', 'the Wi-Fi')
on conflict (kind, text) do nothing;

-- =================================================================
-- SECTION 3 — engine hooks: availability, the shared pick, rewards, one-per-day generation
-- =================================================================
create or replace function public._challenge_available(d public.challenge_definitions, p_user uuid)
returns boolean as $$
begin
  if d.requires is null then return true; end if;
  return case d.requires
    when 'open_battle' then exists (
      select 1 from public.nickname_battles b
      where b.status = 'open'
        and not exists (select 1 from public.nickname_battle_votes v where v.battle_id = b.id and v.user_id = p_user))
    when 'unrated_beer' then exists (
      select 1 from public.beers b
      where not exists (select 1 from public.beer_ratings r where r.beer_id = b.id and r.user_id = p_user and r.rating is not null))
    when 'anecdote_target' then exists (select 1 from public.nicknames n where coalesce(btrim(n.anecdote), '') = '')
    when 'old_content' then exists (select 1 from public.poems p where p.created_at < now() - interval '7 days')
                         or exists (select 1 from public.nicknames n where n.created_at < now() - interval '7 days')
    when 'nicknames_3' then (select count(*) from public.nicknames) >= 3
    when 'poems_2' then (select count(*) from public.poems) >= 2
    -- 0051: the shared Daily needs real data to ask about / write about
    when 'group_quiz_data' then (select count(distinct btrim(person_real_name)) from public.nicknames where status = 'Actief' and btrim(person_real_name) <> '') >= 4
    when 'poetry_prompt_data' then exists (select 1 from public.poetry_prompts where is_active and is_daily_eligible)
    else coalesce((select f.enabled from public.challenge_features f where f.key = d.requires), false)
  end;
end;
$$ language plpgsql stable security definer set search_path = public;

-- the ONE shared pick (the same for everybody: it is stored once on the group assignment)
create or replace function public._group_payload(d public.challenge_definitions, p_key text)
returns jsonb as $$
declare
  v_kind text := split_part(d.completion, ':', 2);
  v_row jsonb;
  v_cfg jsonb := public._challenge_config('group_daily_rewards', '{}'::jsonb);
begin
  if v_kind = 'nickname' then
    select jsonb_build_object('text', 'Invent a nickname for: ' || p.text) into v_row
      from public.chaos_prompts p where p.kind = 'group_nickname' and p.is_active order by md5(p.id::text || p_key) limit 1;
  elsif v_kind = 'poetry' then
    select jsonb_build_object('text', pp.prompt_text) into v_row
      from public.poetry_prompts pp where pp.is_active and pp.is_daily_eligible order by md5(pp.id::text || p_key) limit 1;
  elsif v_kind = 'emoji' then
    select jsonb_build_object('nickname_id', n.id, 'text', n.nickname) into v_row
      from public.nicknames n where n.status = 'Actief' order by md5(n.id::text || p_key) limit 1;
  elsif v_kind = 'chaos' then
    select jsonb_build_object('text', p.text, 'sub', case p.kind when 'decree_topic' then 'decree' else 'photo' end) into v_row
      from public.chaos_prompts p where p.kind in ('decree_topic', 'safari', 'tiny_quest', 'photographer') and p.is_active
      order by md5(p.id::text || p_key) limit 1;
  end if;
  return coalesce(v_row, '{}'::jsonb) || jsonb_build_object(
    'winner', coalesce(v_cfg->'winner', '[]'::jsonb),
    'min_participants', coalesce((v_cfg->>'min_participants')::int, 2));
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public._chaos_payload(d public.challenge_definitions, p_user uuid, p_key text)
returns jsonb as $$
declare
  v_kind text := split_part(d.completion, ':', 2);
  v_row jsonb;
begin
  if d.completion = 'auto' then return '{}'::jsonb; end if;
  if d.completion like 'group:%' then return public._group_payload(d, p_key); end if;
  if v_kind in ('draw', 'emoji') then
    select jsonb_build_object('nickname_id', n.id, 'text', n.nickname) into v_row
      from public.nicknames n where n.status = 'Actief' order by md5(n.id::text || p_user::text || p_key) limit 1;
  elsif d.prompt_kind is not null then
    select jsonb_build_object('text', p.text, 'verify', p.verify) into v_row
      from public.chaos_prompts p where p.kind = d.prompt_kind and p.is_active
        and (p.verify is null
             or (p.verify = 'nicknames' and (select count(*) from public.nicknames where status = 'Actief') >= 3)
             or (p.verify = 'beers' and (select count(*) from public.beers) >= 3))
      order by md5(p.id::text || p_user::text || p_key) limit 1;
  end if;
  return coalesce(v_row, '{}'::jsonb);
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public._assignment_reward(d public.challenge_definitions)
returns jsonb as $$
  select case
    when d.completion like 'group:%' then jsonb_build_object('lines', coalesce(public._challenge_config('group_daily_rewards', '{}'::jsonb) -> 'participation', '[]'::jsonb))
    when d.reward_key is not null then jsonb_build_object('lines', coalesce(public._challenge_config(d.reward_key, '{}'::jsonb) -> d.difficulty, '[]'::jsonb))
    when d.reward_from_difficulty then public._difficulty_reward(d.difficulty)
    else d.reward end;
$$ language sql stable security definer set search_path = public;

-- generation: the same as before, but the shared Group Daily avoids yesterday's
create or replace function public._ensure_challenge_assignments_for(p_user uuid, p_at timestamptz)
returns int as $$
declare
  v_tz text := public._challenge_tz();
  v_local timestamp := p_at at time zone v_tz;
  v_day_start timestamptz := date_trunc('day', v_local) at time zone v_tz;
  v_day_end timestamptz := (date_trunc('day', v_local) + interval '1 day') at time zone v_tz;
  v_wk_start timestamptz := date_trunc('week', v_local) at time zone v_tz;
  v_wk_end timestamptz := (date_trunc('week', v_local) + interval '7 days') at time zone v_tz;
  v_day_key text := to_char(v_local, 'YYYY-MM-DD');
  v_prev_key text := to_char(v_local - interval '1 day', 'YYYY-MM-DD');
  v_wk_key text := to_char(v_local, 'IYYY-"W"IW');
  v_lord uuid := (select user_id from public.abt_reigns where ended_at is null limit 1);
  v_type text;
  v_key text; v_from timestamptz; v_to timestamptz;
  v_owner uuid;
  v_have int; v_want int; v_created int := 0; v_n int;
  v_ids text[];
begin
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return 0;
  end if;
  perform pg_advisory_xact_lock(hashtext('challenge_gen:' || p_user::text));

  update public.challenge_assignments set status = 'expired'
    where app_id = 'officelore' and status = 'active' and expires_at <= p_at and (user_id = p_user or user_id is null);

  foreach v_type in array array['personal_daily', 'group_daily', 'personal_weekly', 'group_weekly', 'rebellion'] loop
    if v_type in ('personal_daily', 'group_daily') then v_key := v_day_key; v_from := v_day_start; v_to := v_day_end;
    else v_key := v_wk_key; v_from := v_wk_start; v_to := v_wk_end; end if;
    v_owner := case when v_type in ('group_daily', 'group_weekly') then null else p_user end;
    v_want := public._challenge_slots(v_type);
    if v_owner is null then perform pg_advisory_xact_lock(hashtext('challenge_group:' || v_type || ':' || v_key)); end if;

    select count(*) into v_have from public.challenge_assignments
      where app_id = 'officelore' and type = v_type and period_key = v_key and user_id is not distinct from v_owner;
    continue when v_have >= v_want;

    if v_type = 'personal_daily' then
      v_ids := public._pick_personal_dailies(p_user, v_key, v_prev_key, v_lord, v_want - v_have);
    else
      select coalesce(array_agg(x.id), '{}') into v_ids from (
        select d.id from public.challenge_definitions d
        where d.app_id = 'officelore' and d.is_active and d.type = v_type
          and (d.audience = 'everyone'
               or (d.audience = 'non_lord' and p_user is distinct from v_lord)
               or (d.audience = 'lord' and p_user is not distinct from v_lord))
          and public._challenge_available(d, p_user)
          and not exists (select 1 from public.challenge_assignments x2
                          where x2.app_id = 'officelore' and x2.definition_id = d.id and x2.period_key = v_key and x2.user_id is not distinct from v_owner)
        order by (v_type = 'group_daily' and exists (select 1 from public.challenge_assignments y
                         where y.app_id = 'officelore' and y.definition_id = d.id and y.user_id is null and y.period_key = v_prev_key)),     -- not the same Group Daily two days in a row
                 md5(d.id || coalesce(v_owner::text, 'group') || v_key)
        limit v_want - v_have) x;
    end if;
    continue when cardinality(v_ids) = 0;

    insert into public.challenge_assignments
      (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
       target, period_key, starts_at, expires_at, completion, payload)
    select 'officelore', d.id, v_owner, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.event_types, d.icon, d.requirements,
           public._assignment_reward(d),
           d.target, v_key, v_from, v_to, d.completion, public._chaos_payload(d, p_user, v_key)
    from public.challenge_definitions d
    where d.id = any (v_ids)
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_created := v_created + v_n;
  end loop;
  return v_created;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — rounds and the quiz
-- =================================================================
create or replace function public._gq_item(p_q text, p_correct text, p_pool text[], p_seed text, out item jsonb, out ans int) as $$
declare
  v_opts text[];
begin
  select array_agg(w.x order by md5(w.x || p_seed)) into v_opts from (
    select p_correct as x
    union all
    (select y from unnest(p_pool) y where y is not null and y <> p_correct group by y order by md5(y || p_seed || 'p') limit 3)
  ) w;
  item := jsonb_build_object('q', p_q, 'options', to_jsonb(v_opts));
  ans := array_position(v_opts, p_correct) - 1;
end;
$$ language plpgsql immutable;

create or replace function public._gq_count(p_q text, p_count int, p_seed text, out item jsonb, out ans int) as $$
declare
  v_pool text[];
begin
  select array_agg(c::text) into v_pool from unnest(array[p_count - 3, p_count - 2, p_count - 1, p_count + 1, p_count + 2, p_count + 3, p_count + 5, p_count + 8]) c where c >= 0;
  select * into item, ans from public._gq_item(p_q, p_count::text, v_pool, p_seed);
end;
$$ language plpgsql immutable;

-- 5 questions, the same for everybody, built from the day's key
create or replace function public._group_quiz(p_key text, out questions jsonb, out answers jsonb) as $$
declare
  n1 record; n2 record;
  v_items jsonb := '[]'::jsonb; v_ans jsonb := '[]'::jsonb;
  r record;
begin
  select nickname, btrim(person_real_name) as person into n1
    from public.nicknames where status = 'Actief' and btrim(person_real_name) <> '' order by md5(id::text || p_key || '1') limit 1;
  select * into r from public._gq_item('Who is known as “' || n1.nickname || '”?', n1.person,
    (select array_agg(distinct btrim(person_real_name)) from public.nicknames where status = 'Actief' and btrim(person_real_name) <> ''), p_key || 'q1');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);

  select nickname, btrim(person_real_name) as person into n2
    from public.nicknames where status = 'Actief' and btrim(person_real_name) <> '' and btrim(person_real_name) <> n1.person order by md5(id::text || p_key || '2') limit 1;
  select * into r from public._gq_item('Which nickname belongs to ' || n2.person || '?', n2.nickname,
    (select array_agg(nickname) from public.nicknames where status = 'Actief' and btrim(person_real_name) <> n2.person), p_key || 'q2');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);

  select * into r from public._gq_count('How many nicknames were on the Wall when today began?', (select count(*) from public.nicknames)::int, p_key || 'q3');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);
  select * into r from public._gq_count('How many beers were registered when today began?', (select count(*) from public.beers)::int, p_key || 'q4');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);
  select * into r from public._gq_count('How many poems were on the Poetry Wall when today began?', (select count(*) from public.poems)::int, p_key || 'q5');
  v_items := v_items || r.item; v_ans := v_ans || to_jsonb(r.ans);
  questions := v_items; answers := v_ans;
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public._ensure_group_round(p_assignment uuid)
returns public.group_daily_rounds as $$
declare
  a public.challenge_assignments;
  r public.group_daily_rounds;
  v_q jsonb; v_ans jsonb; v_kind text;
begin
  select * into r from public.group_daily_rounds where assignment_id = p_assignment;
  if found then return r; end if;
  perform pg_advisory_xact_lock(hashtext('group_round:' || p_assignment::text));
  select * into r from public.group_daily_rounds where assignment_id = p_assignment;
  if found then return r; end if;
  select * into a from public.challenge_assignments where id = p_assignment;
  v_kind := split_part(a.completion, ':', 2);
  if v_kind = 'quiz' then select g.questions, g.answers into v_q, v_ans from public._group_quiz(a.period_key) g; end if;
  insert into public.group_daily_rounds (app_id, assignment_id, kind, day_key, prompt, questions, winner_lines, min_participants, starts_at, ends_at)
    values (a.app_id, a.id, v_kind, a.period_key, a.payload - 'winner' - 'min_participants', v_q,
            coalesce(a.payload->'winner', '[]'::jsonb), coalesce((a.payload->>'min_participants')::int, 2), a.starts_at, a.expires_at)
    returning * into r;
  if v_ans is not null then insert into public.group_daily_secrets (round_id, answers) values (r.id, v_ans); end if;
  return r;
end;
$$ language plpgsql security definer set search_path = public;

-- the entry makes the member a contributor of the group assignment, which is what lets them claim the participation reward
create or replace function public._group_participated(p_round uuid, p_user uuid)
returns void as $$
declare
  r public.group_daily_rounds;
begin
  select * into r from public.group_daily_rounds where id = p_round;
  insert into public.group_daily_participants (round_id, user_id) values (p_round, p_user) on conflict do nothing;
  update public.challenge_assignments set progress = target, status = case when status = 'active' then 'completed' else status end,
         completed_at = coalesce(completed_at, now())
    where id = r.assignment_id;
  insert into public.challenge_contributions (assignment_id, user_id, amount) values (r.assignment_id, p_user, 1)
    on conflict (assignment_id, user_id) do nothing;
  update public.group_daily_rounds set entry_count = entry_count + 1, updated_at = now() where id = p_round;
end;
$$ language plpgsql security definer set search_path = public;

-- winners: decided once, when the day has ended
create or replace function public._finalize_group_round(p_round uuid)
returns void as $$
declare
  r public.group_daily_rounds;
  v_top int; v_top_ms int;
begin
  select * into r from public.group_daily_rounds where id = p_round for update;
  if r.id is null or r.status <> 'open' or r.ends_at > now() then return; end if;

  if r.entry_count < r.min_participants then
    update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now(),
      no_winner_reason = 'Not enough entries: at least ' || r.min_participants || ' are needed for a winner.' where id = r.id;
    return;
  end if;

  if r.kind = 'quiz' then
    select max(e.score) into v_top from public.group_daily_entries e where e.round_id = r.id;
    if coalesce(v_top, 0) <= 0 then
      update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now(), no_winner_reason = 'Nobody scored a point.' where id = r.id;
      return;
    end if;
    select min(e.duration_ms) into v_top_ms from public.group_daily_entries e where e.round_id = r.id and e.score = v_top;
    insert into public.group_daily_winners (round_id, user_id, entry_id)
      select r.id, e.user_id, e.id from public.group_daily_entries e where e.round_id = r.id and e.score = v_top and e.duration_ms = v_top_ms;
  else
    select max(c) into v_top from (select count(*) as c from public.group_daily_votes v where v.round_id = r.id group by v.entry_id) q;
    if coalesce(v_top, 0) < 1 then
      update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now(), no_winner_reason = 'Nobody voted.' where id = r.id;
      return;
    end if;
    insert into public.group_daily_winners (round_id, user_id, entry_id)
      select r.id, e.user_id, e.id from public.group_daily_entries e
      where e.round_id = r.id and (select count(*) from public.group_daily_votes v where v.entry_id = e.id) = v_top;
  end if;
  update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now() where id = r.id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._finalize_due_group_rounds()
returns void as $$
declare
  x uuid;
begin
  for x in select id from public.group_daily_rounds where status = 'open' and ends_at <= now() and app_id = 'officelore' loop
    perform public._finalize_group_round(x);
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — reading
-- =================================================================
create or replace function public._group_round_json(r public.group_daily_rounds, p_uid uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_entries jsonb;
begin
  select * into a from public.challenge_assignments where id = r.assignment_id;
  if r.status = 'open' then
    v_entries := case when r.kind = 'quiz' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'content', e.content, 'has_media', e.media is not null, 'mine', e.user_id = p_uid)
                       order by md5(e.id::text || p_uid::text))
      from public.group_daily_entries e where e.round_id = r.id), '[]'::jsonb) end;
  else
    v_entries := coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'user_id', e.user_id, 'content', e.content, 'has_media', e.media is not null,
                                          'score', e.score, 'duration_ms', e.duration_ms,
                                          'votes', (select count(*) from public.group_daily_votes v where v.entry_id = e.id),
                                          'winner', exists (select 1 from public.group_daily_winners w where w.round_id = r.id and w.user_id = e.user_id))
                       order by e.score desc nulls last, e.duration_ms, (select count(*) from public.group_daily_votes v where v.entry_id = e.id) desc, e.created_at)
      from public.group_daily_entries e where e.round_id = r.id), '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'id', r.id, 'assignment_id', r.assignment_id, 'kind', r.kind, 'day_key', r.day_key, 'prompt', r.prompt, 'questions', r.questions,
    'status', r.status, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'entry_count', r.entry_count, 'vote_count', r.vote_count,
    'min_participants', r.min_participants, 'no_winner_reason', r.no_winner_reason,
    'reward', jsonb_build_object('participation', coalesce(a.reward->'lines', '[]'::jsonb), 'winner', r.winner_lines),
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'entered', exists (select 1 from public.group_daily_participants p where p.round_id = r.id and p.user_id = m.user_id))
                       order by pr.display_name)
      from public.app_memberships m join public.profiles pr on pr.id = m.user_id
      where m.app_id = 'officelore' and m.is_active), '[]'::jsonb),
    'my_entry', (select jsonb_build_object('id', e.id, 'content', e.content, 'has_media', e.media is not null, 'score', e.score, 'duration_ms', e.duration_ms)
                 from public.group_daily_entries e where e.round_id = r.id and e.user_id = p_uid),
    'my_vote', (select v.entry_id from public.group_daily_votes v where v.round_id = r.id and v.voter_id = p_uid),
    'quiz_started_at', (select t.started_at from public.group_daily_attempts t where t.round_id = r.id and t.user_id = p_uid),
    'entries', v_entries,
    'winners', coalesce((select jsonb_agg(w.user_id) from public.group_daily_winners w where w.round_id = r.id), '[]'::jsonb),
    'winner_claimed', (select w.claimed_at is not null from public.group_daily_winners w where w.round_id = r.id and w.user_id = p_uid)
  );
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public.get_group_daily()
returns jsonb as $$
declare
  a public.challenge_assignments;
  r public.group_daily_rounds;
  p public.group_daily_rounds;
  v_cur jsonb := null; v_prev jsonb := null;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform public._finalize_due_group_rounds();
  select * into a from public.challenge_assignments
    where app_id = 'officelore' and type = 'group_daily' and user_id is null and completion like 'group:%'
      and starts_at <= now() and expires_at > now() order by starts_at desc limit 1;
  if a.id is not null then
    r := public._ensure_group_round(a.id);
    v_cur := public._group_round_json(r, auth.uid());
  end if;
  select * into p from public.group_daily_rounds
    where app_id = 'officelore' and status = 'finalized' and id is distinct from r.id and ends_at > now() - interval '3 days'
    order by ends_at desc limit 1;
  if p.id is not null then v_prev := public._group_round_json(p, auth.uid()); end if;
  return jsonb_build_object('current', v_cur, 'previous', v_prev);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.get_group_media(p_entry_id uuid)
returns text as $$
  select e.media from public.group_daily_entries e join public.group_daily_rounds r on r.id = e.round_id
  where e.id = p_entry_id and r.app_id = 'officelore' and public.is_app_member('officelore');
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 6 — writing: enter, vote, quiz, claim
-- =================================================================
create or replace function public.submit_group_entry(p_round_id uuid, p_content jsonb, p_media text default null)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  v_text text; v_content jsonb := '{}'::jsonb; v_media text := null; v_hash text;
  v_sub text; v_id uuid;
  v_max int := coalesce((public._challenge_config('chaos_rules', '{}'::jsonb)->>'media_max_chars')::int, 900000);
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.group_daily_rounds where id = p_round_id for update;
  if r.id is null or r.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if r.status <> 'open' or r.ends_at <= now() then raise exception 'This challenge has ended'; end if;
  if r.kind = 'quiz' then raise exception 'Take the quiz instead'; end if;
  if exists (select 1 from public.group_daily_entries where round_id = r.id and user_id = auth.uid()) then raise exception 'You already entered'; end if;

  v_text := btrim(coalesce(p_content->>'text', p_content->>'emoji', ''));
  if r.kind = 'nickname' then
    if length(v_text) not between 2 and 30 or v_text !~ '[[:alpha:]]' then raise exception 'A nickname needs 2 to 30 characters, with letters'; end if;
    v_content := jsonb_build_object('text', v_text); v_hash := md5(lower(v_text));
  elsif r.kind = 'poetry' then
    if length(v_text) not between 20 and 400 then raise exception 'A poem needs 20 to 400 characters'; end if;
    if array_length(regexp_split_to_array(v_text, '\s+'), 1) < 6 then raise exception 'A poem needs at least 6 words'; end if;
    v_content := jsonb_build_object('text', v_text); v_hash := md5(lower(v_text));
  elsif r.kind = 'emoji' then
    if v_text ~ '[A-Za-z0-9]' or length(translate(v_text, chr(65039) || chr(8205) || ' ', '')) not between 1 and 5 then raise exception 'Use emoji only, at most 5'; end if;
    v_content := jsonb_build_object('emoji', v_text); v_hash := md5(v_text);
  elsif r.kind = 'chaos' then
    v_sub := r.prompt->>'sub';
    if v_sub = 'decree' then
      if length(v_text) not between 15 and 280 or array_length(regexp_split_to_array(v_text, '\s+'), 1) < 5 then raise exception 'A decree needs 15 to 280 characters and at least 5 words'; end if;
      v_content := jsonb_build_object('text', v_text); v_hash := md5(lower(v_text));
    else
      if p_media is null or p_media !~ '^data:image/(jpeg|png);base64,[A-Za-z0-9+/=]+$' then raise exception 'Add a photo first'; end if;
      if length(p_media) > v_max then raise exception 'That image is too large'; end if;
      v_media := p_media; v_content := jsonb_build_object('note', left(btrim(coalesce(p_content->>'note', '')), 120));
      v_hash := md5(substr(p_media, 1, 4000) || length(p_media));
    end if;
  end if;

  begin
    insert into public.group_daily_entries (round_id, user_id, content, media, content_hash) values (r.id, auth.uid(), v_content, v_media, v_hash) returning id into v_id;
  exception when unique_violation then
    raise exception 'Somebody already sent exactly that. Make it your own';
  end;
  perform public._group_participated(r.id, auth.uid());
  return jsonb_build_object('status', 'entered', 'id', v_id);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.vote_group_entry(p_round_id uuid, p_entry_id uuid)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  e public.group_daily_entries;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.group_daily_rounds where id = p_round_id for update;
  if r.id is null or r.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if r.status <> 'open' or r.ends_at <= now() then raise exception 'Voting has ended'; end if;
  if r.kind = 'quiz' then raise exception 'There is nothing to vote on'; end if;
  select * into e from public.group_daily_entries where id = p_entry_id and round_id = r.id;
  if e.id is null then raise exception 'Unknown entry'; end if;
  if e.user_id = auth.uid() then raise exception 'You cannot vote for yourself'; end if;
  begin
    insert into public.group_daily_votes (round_id, voter_id, entry_id) values (r.id, auth.uid(), e.id);
  exception when unique_violation then
    raise exception 'You already voted';
  end;
  update public.group_daily_rounds set vote_count = vote_count + 1, updated_at = now() where id = r.id;
  return jsonb_build_object('status', 'voted');
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.start_group_quiz(p_round_id uuid)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  t public.group_daily_attempts;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.group_daily_rounds where id = p_round_id;
  if r.id is null or r.kind <> 'quiz' or r.app_id <> 'officelore' then raise exception 'Unknown quiz'; end if;
  if r.status <> 'open' or r.ends_at <= now() then raise exception 'This quiz has ended'; end if;
  if exists (select 1 from public.group_daily_entries where round_id = r.id and user_id = auth.uid()) then raise exception 'You already took the quiz'; end if;
  insert into public.group_daily_attempts (round_id, user_id) values (r.id, auth.uid()) on conflict do nothing;
  select * into t from public.group_daily_attempts where round_id = r.id and user_id = auth.uid();
  return jsonb_build_object('questions', r.questions, 'started_at', t.started_at);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.submit_group_quiz(p_round_id uuid, p_answers jsonb)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  t public.group_daily_attempts;
  v_key jsonb;
  v_n int; v_score int := 0; v_ms int; i int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.group_daily_rounds where id = p_round_id for update;
  if r.id is null or r.kind <> 'quiz' or r.app_id <> 'officelore' then raise exception 'Unknown quiz'; end if;
  if r.status <> 'open' or r.ends_at <= now() then raise exception 'This quiz has ended'; end if;
  select * into t from public.group_daily_attempts where round_id = r.id and user_id = auth.uid();
  if t.round_id is null then raise exception 'Start the quiz first'; end if;
  if exists (select 1 from public.group_daily_entries where round_id = r.id and user_id = auth.uid()) then raise exception 'You already took the quiz'; end if;
  select answers into v_key from public.group_daily_secrets where round_id = r.id;
  v_n := jsonb_array_length(v_key);
  if jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) <> v_n then raise exception 'Answer all % questions', v_n; end if;
  for i in 0..v_n - 1 loop
    if p_answers->>i is not null and p_answers->>i = v_key->>i then v_score := v_score + 1; end if;
  end loop;
  v_ms := least(extract(epoch from (clock_timestamp() - t.started_at)) * 1000, 3600000)::int;
  insert into public.group_daily_entries (round_id, user_id, content, score, duration_ms)
    values (r.id, auth.uid(), jsonb_build_object('score', v_score, 'total', v_n), v_score, v_ms);
  perform public._group_participated(r.id, auth.uid());
  return jsonb_build_object('status', 'done', 'score', v_score, 'total', v_n, 'duration_ms', v_ms);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.claim_group_winner(p_round_id uuid)
returns jsonb as $$
declare
  r public.group_daily_rounds;
  w public.group_daily_winners;
  v_line jsonb; v_no int := 100; v_results jsonb := '[]'::jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform public._finalize_due_group_rounds();
  select * into r from public.group_daily_rounds where id = p_round_id;
  if r.id is null or r.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  select * into w from public.group_daily_winners where round_id = r.id and user_id = auth.uid() for update;
  if w.round_id is null then raise exception 'You did not win this one'; end if;
  if w.claimed_at is not null then return jsonb_build_object('status', 'already_claimed'); end if;
  update public.group_daily_winners set claimed_at = now() where round_id = r.id and user_id = auth.uid();
  for v_line in select * from jsonb_array_elements(r.winner_lines) loop
    v_no := v_no + 1;
    v_results := v_results || public._grant_challenge_reward2(auth.uid(), r.assignment_id, null, v_line, v_no);
  end loop;
  return jsonb_build_object('status', 'claimed', 'results', v_results);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 7 — the pool: five shared Dailies, exactly one a day
-- =================================================================
-- the older cooperative samples would add a second Group Daily: retire them
-- (only if nobody has touched today's: nothing is lost)
update public.challenge_definitions set is_active = false where type = 'group_daily' and completion = 'auto';
delete from public.challenge_assignments a
  where a.type = 'group_daily' and a.completion = 'auto' and a.status = 'active' and a.progress = 0
    and not exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id)
    and not exists (select 1 from public.challenge_claims c where c.assignment_id = a.id);

insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, target, requirements, reward_from_difficulty, completion, icon, requires, audience) values
  ('gd_nickname_of_the_day', 'group_daily', 'nickname', 'Nickname of the Day', 'Everyone invents a nickname for the same thing. Then everyone votes. The best one wins.', 'normal', 'group_entry', 1, '{}', false, 'group:nickname', '🏷️', null, 'everyone'),
  ('gd_poetry_showdown', 'group_daily', 'poetry', 'Daily Poetry Showdown', 'Everyone writes to the same Poetry prompt. Vote for the best one.', 'normal', 'group_entry', 1, '{}', false, 'group:poetry', '✍️', 'poetry_prompt_data', 'everyone'),
  ('gd_emoji_showdown', 'group_daily', 'chaos', 'Emoji Showdown', 'Describe the same Office Lore item with at most 5 emoji. Vote for the best description.', 'normal', 'group_entry', 1, '{}', false, 'group:emoji', '😀', 'nicknames_3', 'everyone'),
  ('gd_daily_chaos', 'group_daily', 'chaos', 'Daily Chaos', 'The whole office gets the same safe Chaos prompt. Vote for the best.', 'normal', 'group_entry', 1, '{}', false, 'group:chaos', '🎭', null, 'everyone'),
  ('gd_lore_quiz', 'group_daily', 'quiz', 'Daily Lore Quiz', 'The same 5 questions for everyone. The highest score wins; the fastest run breaks a tie.', 'normal', 'group_entry', 1, '{}', false, 'group:quiz', '🧠', 'group_quiz_data', 'everyone')
on conflict (id) do update set
  title = excluded.title, description = excluded.description, event_type = excluded.event_type, completion = excluded.completion,
  icon = excluded.icon, requires = excluded.requires, is_active = true;

-- =================================================================
-- SECTION 8 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array[
    '_group_payload(public.challenge_definitions, text)', '_chaos_payload(public.challenge_definitions, uuid, text)',
    '_assignment_reward(public.challenge_definitions)', '_challenge_available(public.challenge_definitions, uuid)',
    '_ensure_challenge_assignments_for(uuid, timestamptz)',
    '_gq_item(text, text, text[], text)', '_gq_count(text, int, text)', '_group_quiz(text)', '_ensure_group_round(uuid)',
    '_group_participated(uuid, uuid)', '_finalize_group_round(uuid)', '_finalize_due_group_rounds()', '_group_round_json(public.group_daily_rounds, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['get_group_daily()', 'get_group_media(uuid)', 'submit_group_entry(uuid, jsonb, text)', 'vote_group_entry(uuid, uuid)',
                           'start_group_quiz(uuid)', 'submit_group_quiz(uuid, jsonb)', 'claim_group_winner(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
