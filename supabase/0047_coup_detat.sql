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
