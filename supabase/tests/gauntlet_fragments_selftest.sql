-- =================================================================
-- SELF-TEST for 0054_gauntlet_fragments_integration.sql  (safe: everything is rolled back)
-- =================================================================
-- Run in the Supabase SQL Editor AFTER 0048-0054. Checks the 5 = 1 rule, the
-- inventory cap (4/5 stays 4/5), the Abt Lord rule (store, do not forge, forge on
-- reign end), the idempotent reward grant, forging after a spend, and that a
-- Gauntlet never skips the cooldown. The "error" at the end IS the report;
-- NOTHING is saved.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;
create or replace function pg_temp.st(p_user uuid) returns text as $$
  select format('%s fragments / %s gauntlets', coalesce((select fragments from public.gauntlet_fragments where user_id = p_user), 0), coalesce((select balance from public.royal_gauntlet_balances where user_id = p_user), 0));
$$ language sql;

do $$
declare
  v_report text := '';
  m uuid; v_lord uuid; v_per int; v_cap int; r jsonb; a uuid; d public.challenge_definitions; v_err text; v_n int; v_until timestamptz;
begin
  v_per := public._fragments_per_gauntlet(); v_cap := public._max_gauntlets();
  if v_per <> 5 or v_cap <> 2 then raise exception 'ABORTED: expected the defaults 5 / 2, found % / %', v_per, v_cap; end if;
  v_lord := public._current_abt_lord();
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active
    where p.id is distinct from v_lord order by p.display_name limit 1;
  v_report := format('tested as %s (Abt Lord: %s)', (select display_name from public.profiles where id = m), coalesce((select display_name from public.profiles where id = v_lord), 'none')) || E'\n';
  delete from public.gauntlet_fragments where user_id = m;
  delete from public.royal_gauntlet_balances where user_id = m;
  update public.challenge_config set value = value || '{"weekly_fragment_cap": 1000}'::jsonb where key = 'gauntlet_rules';     -- the weekly cap has its own test (audit_selftest)

  -- ===== A. 5 fragments = 1 Gauntlet, the cap, no third Gauntlet =====
  begin
    r := public._add_fragments(m, 4);
    if pg_temp.st(m) <> '4 fragments / 0 gauntlets' then raise exception 'FAIL A: 4 fragments should stay 4/5 (%)', pg_temp.st(m); end if;
    r := public._add_fragments(m, 1);
    if pg_temp.st(m) <> '0 fragments / 1 gauntlets' or (r->>'forged')::int <> 1 then raise exception 'FAIL A: the 5th fragment should forge a Gauntlet (%)', pg_temp.st(m); end if;
    r := public._add_fragments(m, 5);
    if pg_temp.st(m) <> '0 fragments / 2 gauntlets' then raise exception 'FAIL A: second Gauntlet (%)', pg_temp.st(m); end if;
    r := public._add_fragments(m, 3);
    if pg_temp.st(m) <> '3 fragments / 2 gauntlets' then raise exception 'FAIL A: at 2/2 progress may still grow (%)', pg_temp.st(m); end if;
    r := public._add_fragments(m, 3);
    if pg_temp.st(m) <> '4 fragments / 2 gauntlets' then raise exception 'FAIL A: at 2/2 progress must stop at 4/5 (%)', pg_temp.st(m); end if;
    if (r->>'wasted')::int <> 2 or (r->>'full')::boolean is not true then raise exception 'FAIL A: the result should report 2 wasted + full: %', r; end if;
    r := public._add_fragments(m, 9);
    if pg_temp.st(m) <> '4 fragments / 2 gauntlets' then raise exception 'FAIL A: a third Gauntlet or more than 4 fragments appeared (%)', pg_temp.st(m); end if;
    -- spending a Gauntlet makes room: the next fragment completes the 5th and forges again
    update public.royal_gauntlet_balances set balance = balance - 1 where user_id = m;
    if pg_temp.st(m) <> '4 fragments / 1 gauntlets' then raise exception 'FAIL A: after a spend (%)', pg_temp.st(m); end if;
    r := public._add_fragments(m, 1);
    if pg_temp.st(m) <> '0 fragments / 2 gauntlets' then raise exception 'FAIL A: forging after a spend (%)', pg_temp.st(m); end if;
    -- many at once: forges to the cap and clamps the rest
    delete from public.gauntlet_fragments where user_id = m; delete from public.royal_gauntlet_balances where user_id = m; delete from public.royal_gauntlet_ledger where user_id = m;
    r := public._add_fragments(m, 13);
    if pg_temp.st(m) <> '3 fragments / 2 gauntlets' then raise exception 'FAIL A: 13 fragments at once should give 2 Gauntlets + 3 (%)', pg_temp.st(m); end if;
    if (select count(*) from public.royal_gauntlet_ledger where user_id = m and reason = 'fragment_convert') <> 2 then raise exception 'FAIL A: the ledger should show 2 forgings'; end if;
    v_report := v_report || 'PASS 5 = 1, cap 2: 4/5 stays 4/5, never a third Gauntlet, a spent Gauntlet makes room and stored fragments forge, one grant of 13 forges 2 and keeps 3' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== B. idempotent rewards: a replay never adds a fragment =====
  begin
    select * into d from public.challenge_definitions where id = 'pw_lorekeeper';
    a := public._new_assignment(d, m, m, 'GX' || substr(md5(random()::text), 1, 6), now() - interval '1 day', now() + interval '2 days');
    perform public._grant_challenge_reward2(m, a, null, '{"kind":"gauntlet_fragments","amount":2}'::jsonb, 1);
    r := public._grant_challenge_reward2(m, a, null, '{"kind":"gauntlet_fragments","amount":2}'::jsonb, 1);
    perform public._grant_challenge_reward2(m, a, null, '{"kind":"gauntlet_fragments","amount":2}'::jsonb, 1);
    if (r->>'duplicate') is distinct from 'true' then raise exception 'FAIL B: a replayed grant was not recognised'; end if;
    if pg_temp.st(m) <> '2 fragments / 0 gauntlets' then raise exception 'FAIL B: replays added fragments (%)', pg_temp.st(m); end if;
    -- and through the claim, twice
    update public.challenge_assignments set status = 'completed', progress = target where id = a;
    update public.challenge_assignments set reward = '{"lines":[{"kind":"gauntlet_fragments","amount":1}]}' where id = a;
    delete from public.challenge_reward_grants where assignment_id = a;
    delete from public.gauntlet_fragments where user_id = m;
    perform pg_temp.imp(m);
    perform public.claim_challenge(a); perform public.claim_challenge(a); perform public.claim_challenge(a);
    if pg_temp.st(m) <> '1 fragments / 0 gauntlets' then raise exception 'FAIL B: claiming three times gave % ', pg_temp.st(m); end if;
    v_report := v_report || 'PASS idempotent: the same reward line replayed, and a claim clicked three times, add the fragment exactly once' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== C. the Abt Lord: earn, store more than 5, forge only when the reign ends =====
  begin
    if v_lord is null then
      v_report := v_report || 'SKIP Abt Lord: there is no Abt Lord right now' || E'\n';
    else
      delete from public.gauntlet_fragments where user_id = v_lord; delete from public.royal_gauntlet_balances where user_id = v_lord;
      r := public._add_fragments(v_lord, 8);
      if pg_temp.st(v_lord) <> '8 fragments / 0 gauntlets' or (r->>'lord')::boolean is not true then raise exception 'FAIL C: the Lord should store 8 without forging (%)', pg_temp.st(v_lord); end if;
      r := public._add_fragments(v_lord, 17);
      if pg_temp.st(v_lord) <> '25 fragments / 0 gauntlets' then raise exception 'FAIL C: more than 5 must be storable for the Lord (%)', pg_temp.st(v_lord); end if;
      if public._forge_gauntlets(v_lord) <> 0 then raise exception 'FAIL C: forged while ruling'; end if;
      -- the reign ends
      update public.abt_reigns set ended_at = now(), dethroned_by_user_id = m where ended_at is null;
      if pg_temp.st(v_lord) <> '15 fragments / 2 gauntlets' then raise exception 'FAIL C: at the end of the reign 25 fragments should become 2 Gauntlets and keep 15 (%)', pg_temp.st(v_lord); end if;
      -- the Fallen Abt keeps everything, and a third never appears
      if public._forge_gauntlets(v_lord) <> 0 then raise exception 'FAIL C: a third Gauntlet was forged'; end if;
      v_report := v_report || 'PASS 👑 Abt Lord  (8 then 25 fragments stored while ruling, nothing forged, on reign end exactly the cap of 2 Gauntlets forged and 15 fragments kept, no third)' || E'\n';
    end if;
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== D. a Gauntlet never skips the cooldown =====
  begin
    if v_lord is null then
      v_report := v_report || 'SKIP cooldown: there is no Abt Lord right now' || E'\n';
    else
      begin
        insert into public.throne_challenges (reign_id, defender_user_id, challenger_user_id, status, winner_user_id, completed_at, starts_at)
          select id, user_id, m, 'completed', user_id, now(), now() - interval '1 hour' from public.abt_reigns where ended_at is null;
      exception when others then
        v_report := v_report || 'SKIP cooldown: could not stage a lost challenge (' || sqlerrm || ')' || E'\n';
        raise exception 'ROLLBACK_OK';
      end;
      v_until := public._throne_cooldown_until(m);
      if v_until is null or v_until <= now() then raise exception 'FAIL D: setup: the staged loss gave no cooldown'; end if;
      insert into public.royal_gauntlet_balances (user_id, balance) values (m, 2) on conflict (user_id) do update set balance = 2;
      perform pg_temp.imp(m);
      v_err := null; begin perform public.create_throne_challenge(false, null); exception when others then v_err := sqlerrm; end;
      if v_err is null or v_err not like 'COOLDOWN%' then raise exception 'FAIL D: a Gauntlet in cooldown was not refused with COOLDOWN (%)', coalesce(v_err, 'accepted'); end if;
      if (select balance from public.royal_gauntlet_balances where user_id = m) <> 2 then raise exception 'FAIL D: the Gauntlet was spent anyway'; end if;
      v_report := v_report || 'PASS cooldown: with 2 Gauntlets in the inventory the challenge is still refused (COOLDOWN) and nothing is spent' || E'\n';
    end if;
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  raise exception E'GAUNTLET FRAGMENTS REPORT (nothing was saved)\n%', v_report;
end $$;
