-- =================================================================
-- OFFICE LORE — ROYAL GAUNTLET x CHALLENGES: fragments, forging, inventory cap
-- =================================================================
-- Challenges pay Gauntlet FRAGMENTS. This migration makes the conversion a
-- first-class, centrally configured part of the Royal Gauntlet system.
--
--   challenge_config.gauntlet_rules = {"fragments_per_gauntlet": 5, "max_gauntlets": 2}
--
--   5 fragments  =  1 Royal Gauntlet
--   INVENTORY CAP  at most max_gauntlets (2) Royal Gauntlets are ever FORGED for a
--                  user. At the cap, fragment progress stops at 4/5: no third
--                  Gauntlet appears. Spending a Gauntlet makes room, and stored
--                  fragments forge again.
--   ABT LORD       the current Abt Lord keeps EARNING fragments, more than 5 may be
--                  stored, but nothing is forged while the reign lasts. When the
--                  reign ends, as many Gauntlets as the cap allows are forged at
--                  once; what remains stays stored.
--   FALLEN ABT    keeps Gauntlets and fragments. The challenge cooldown is a
--                  separate check in create_throne_challenge (and the Coup) and a
--                  Gauntlet NEVER skips it.
--
-- SAFETY. Forging is STATE-based, not event-based: _forge_gauntlets(user) looks
-- at the stored fragments and the balance and forges what is allowed, so it can
-- be called any number of times. Both it and _add_fragments take a per-user
-- advisory lock, and fragments are only added by _grant_challenge_reward2 after
-- its unique reward-grant row was inserted: a refresh, a double click, a
-- realtime echo or a second tab can never add a fragment twice.
--
-- Forging happens automatically when:
--   * fragments are granted, * the Abt Lord's reign ends, * a Gauntlet is spent.
-- A refund of a cancelled challenge gives the spent Gauntlet back as before
-- (it restores what was paid and is not capped).
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0053.
-- =================================================================

-- =================================================================
-- SECTION 1 — central config
-- =================================================================
insert into public.challenge_config (key, value) values
  ('gauntlet_rules', '{"fragments_per_gauntlet": 5, "max_gauntlets": 2}'::jsonb)
on conflict (key) do nothing;

create or replace function public._fragments_per_gauntlet() returns int as $$
  select greatest(coalesce((public._challenge_config('gauntlet_rules', '{}'::jsonb)->>'fragments_per_gauntlet')::int, 5), 1);
$$ language sql stable security definer set search_path = public;

create or replace function public._max_gauntlets() returns int as $$
  select greatest(coalesce((public._challenge_config('gauntlet_rules', '{}'::jsonb)->>'max_gauntlets')::int, 2), 1);
$$ language sql stable security definer set search_path = public;

create or replace function public._current_abt_lord() returns uuid as $$
  select user_id from public.abt_reigns where ended_at is null limit 1;
$$ language sql stable security definer set search_path = public;

create or replace function public.get_gauntlet_rules()
returns jsonb as $$
  select jsonb_build_object('fragments_per_gauntlet', public._fragments_per_gauntlet(), 'max_gauntlets', public._max_gauntlets())
  where public.is_app_member('officelore');
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 2 — forging
-- =================================================================
create or replace function public._forge_gauntlets(p_user uuid)
returns int as $$
declare
  v_per int := public._fragments_per_gauntlet();
  v_cap int := public._max_gauntlets();
  v_frag int; v_bal int; v_forged int := 0;
begin
  if p_user is null then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('gauntlet_forge:' || p_user::text));
  -- nothing is forged while the user is the Abt Lord: the fragments wait for the end of the reign
  if p_user is not distinct from public._current_abt_lord() then return 0; end if;
  select fragments into v_frag from public.gauntlet_fragments where user_id = p_user for update;
  if not found then return 0; end if;
  insert into public.royal_gauntlet_balances (user_id) values (p_user) on conflict do nothing;
  select balance into v_bal from public.royal_gauntlet_balances where user_id = p_user for update;
  while v_frag >= v_per and v_bal < v_cap loop
    v_frag := v_frag - v_per; v_bal := v_bal + 1; v_forged := v_forged + 1;
    insert into public.royal_gauntlet_ledger (user_id, delta, reason, note) values (p_user, 1, 'fragment_convert', v_per || ' fragments forged');
  end loop;
  if v_forged > 0 then
    update public.gauntlet_fragments set fragments = v_frag, updated_at = now() where user_id = p_user;
    update public.royal_gauntlet_balances set balance = v_bal, updated_at = now() where user_id = p_user;
  end if;
  return v_forged;
end;
$$ language plpgsql security definer set search_path = public;

-- the only way fragments are added
create or replace function public._add_fragments(p_user uuid, p_n int)
returns jsonb as $$
declare
  v_per int := public._fragments_per_gauntlet();
  v_cap int := public._max_gauntlets();
  v_lord boolean := p_user is not distinct from public._current_abt_lord();
  v_before int; v_after int; v_bal int; v_forged int; v_new int; v_stored int;
begin
  perform pg_advisory_xact_lock(hashtext('gauntlet_forge:' || p_user::text));
  insert into public.gauntlet_fragments (user_id, fragments) values (p_user, 0) on conflict do nothing;
  select fragments into v_before from public.gauntlet_fragments where user_id = p_user for update;
  update public.gauntlet_fragments set fragments = fragments + p_n, updated_at = now() where user_id = p_user;
  v_forged := public._forge_gauntlets(p_user);
  select fragments into v_after from public.gauntlet_fragments where user_id = p_user;
  select coalesce(balance, 0) into v_bal from public.royal_gauntlet_balances where user_id = p_user;
  v_new := v_after;
  -- a full inventory (and not the Abt Lord): progress stops at per-1, but nothing already stored is ever taken away
  if not v_lord and coalesce(v_bal, 0) >= v_cap then
    v_new := greatest(least(v_after, v_per - 1), least(v_before, v_after));
    if v_new <> v_after then update public.gauntlet_fragments set fragments = v_new, updated_at = now() where user_id = p_user; end if;
  end if;
  v_stored := least(p_n, greatest(v_new - (v_before - v_per * v_forged), 0));
  return jsonb_build_object('stored', v_stored, 'wasted', p_n - v_stored, 'forged', v_forged, 'lord', v_lord,
                            'fragments', v_new, 'balance', coalesce(v_bal, 0), 'full', coalesce(v_bal, 0) >= v_cap);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — the reward grant now goes through _add_fragments
-- =================================================================
create or replace function public._grant_challenge_reward2(p_user uuid, p_assignment uuid, p_sweep uuid, p_line jsonb, p_line_no int)
returns jsonb as $$
declare
  v_kind text := p_line->>'kind';
  v_amount int := coalesce((p_line->>'amount')::int, 0);
  v_chance numeric := coalesce((p_line->>'chance')::numeric, 1);
  v_hit boolean;
  v_status text;
  v_frag jsonb := '{}'::jsonb;
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

  -- only reached when this very grant row was just created: a replay never gets here
  if v_hit and v_kind = 'gauntlet_fragments' and v_amount > 0 then
    v_frag := public._add_fragments(p_user, v_amount);
  end if;
  return jsonb_build_object('kind', v_kind, 'amount', v_amount, 'category', p_line->>'category', 'hit', v_hit, 'chance', v_chance, 'status', v_status) || v_frag;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — automatic forging: reign ends, Gauntlet spent
-- =================================================================
create or replace function public._t_forge_on_reign_end() returns trigger as $$
begin
  if old.ended_at is null and new.ended_at is not null then
    -- the old Abt Lord is no longer the Lord (the next reign row is inserted after this update)
    perform public._forge_gauntlets(new.user_id);
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
drop trigger if exists trg_forge_on_reign_end on public.abt_reigns;
create trigger trg_forge_on_reign_end after update of ended_at on public.abt_reigns
  for each row execute procedure public._t_forge_on_reign_end();

create or replace function public._t_forge_on_spend() returns trigger as $$
begin
  if new.balance < old.balance then
    perform public._forge_gauntlets(new.user_id);
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
drop trigger if exists trg_forge_on_spend on public.royal_gauntlet_balances;
create trigger trg_forge_on_spend after update of balance on public.royal_gauntlet_balances
  for each row execute procedure public._t_forge_on_spend();

-- bring everybody in line with the (new) rules once: whatever can be forged is forged
do $$
declare u uuid;
begin
  for u in select user_id from public.gauntlet_fragments loop
    perform public._forge_gauntlets(u);
  end loop;
end $$;

-- =================================================================
-- SECTION 5 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array['_fragments_per_gauntlet()', '_max_gauntlets()', '_current_abt_lord()', '_forge_gauntlets(uuid)', '_add_fragments(uuid, int)',
                           '_grant_challenge_reward2(uuid, uuid, uuid, jsonb, int)', '_t_forge_on_reign_end()', '_t_forge_on_spend()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  revoke all on function public.get_gauntlet_rules() from public, anon;
  grant execute on function public.get_gauntlet_rules() to authenticated;
end $$;
