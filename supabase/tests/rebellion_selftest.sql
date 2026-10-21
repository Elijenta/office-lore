-- =================================================================
-- SELF-TEST for 0055_rebellion_quests.sql  (safe: everything is rolled back)
-- =================================================================
-- Run in the Supabase SQL Editor AFTER 0048-0055. Checks the Rebellion quests
-- (not for the Lord), the long-reign milestones (once per reign and member, never
-- for the Lord, the inventory cap for the full Gauntlet, the reign end) and the
-- notification state. The "error" at the end IS the report; NOTHING is saved.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;
create or replace function pg_temp.ev(p_user uuid, p_event text, p_dedupe text default null, p_meta jsonb default '{}') returns void as $$
begin
  perform public._challenge_event(p_user, p_event, 1, p_dedupe, p_meta, 'T' || md5(random()::text));
end;
$$ language plpgsql;
create or replace function pg_temp.cur(p_id uuid) returns public.challenge_assignments as $$
  select a from public.challenge_assignments a where a.id = p_id;
$$ language sql;
create or replace function pg_temp.fr(p_user uuid) returns int as $$
  select coalesce((select fragments from public.gauntlet_fragments where user_id = p_user), 0);
$$ language sql;
create or replace function pg_temp.gb(p_user uuid) returns int as $$
  select coalesce((select balance from public.royal_gauntlet_balances where user_id = p_user), 0);
$$ language sql;

do $$
declare
  v_report text := '';
  v_lord uuid; m uuid; m2 uuid; v_reign uuid; a uuid; d public.challenge_definitions; v_err text; v_n int; r jsonb;
begin
  select id, user_id into v_reign, v_lord from public.abt_reigns where ended_at is null limit 1;
  if v_lord is null then raise exception 'ABORTED: there must be an Abt Lord to test the Rebellion'; end if;
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> v_lord order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> v_lord and p.id <> m order by p.display_name limit 1;
  if m is null then raise exception 'ABORTED: need a member besides the Lord'; end if;
  v_report := format('tested: Lord %s, rebel %s', (select display_name from public.profiles where id = v_lord), (select display_name from public.profiles where id = m)) || E'\n';
  delete from public.challenge_assignments; delete from public.challenge_events; delete from public.challenge_reward_grants;
  delete from public.gauntlet_fragments; delete from public.royal_gauntlet_balances; delete from public.rebellion_rewards;

  -- ===== A. the Rebellion quest is for rebels, not for the Lord =====
  begin
    perform public._ensure_challenge_assignments_for(m, now());
    perform public._ensure_challenge_assignments_for(v_lord, now());
    if (select count(*) from public.challenge_assignments where user_id = m and type = 'rebellion') <> 1 then raise exception 'FAIL A: a rebel should get exactly 1 Rebellion quest'; end if;
    if exists (select 1 from public.challenge_assignments where user_id = v_lord and type = 'rebellion') then raise exception 'FAIL A: the Abt Lord was given a Rebellion quest'; end if;

    select * into d from public.challenge_definitions where id = 'rb_seeds';
    a := public._new_assignment(d, m, m, 'RB' || substr(md5(random()::text), 1, 6), now() - interval '1 day', now() + interval '3 days');
    perform pg_temp.ev(m, 'daily_completed', 'd1'); perform pg_temp.ev(m, 'daily_completed', 'd2');
    perform pg_temp.ev(m, 'quote_added'); 
    if (pg_temp.cur(a)).status <> 'active' or (pg_temp.cur(a)).progress <> 3 then raise exception 'FAIL A: Seeds should be 3/4 without a battle (%)', (pg_temp.cur(a)).progress; end if;
    perform pg_temp.ev(m, 'battle_participated', 'battle:1');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL A: Seeds of Rebellion not completed (2 Dailies + lore + battle)'; end if;
    if not exists (select 1 from jsonb_array_elements((pg_temp.cur(a)).reward->'lines') l where l->>'kind' = 'gauntlet_fragments' and (l->>'amount')::int = 2) then raise exception 'FAIL A: Seeds should pay 2 Fragments'; end if;
    perform pg_temp.imp(m);
    perform public.claim_challenge(a);
    if pg_temp.fr(m) <> 2 then raise exception 'FAIL A: 2 Fragments expected, got %', pg_temp.fr(m); end if;
    -- the Lord can not claim one that was handed out earlier
    a := public._new_assignment(d, v_lord, v_lord, 'RL' || substr(md5(random()::text), 1, 6), now() - interval '1 day', now() + interval '3 days');
    update public.challenge_assignments set status = 'completed', progress = target where id = a;
    perform pg_temp.imp(v_lord);
    v_err := null; begin perform public.claim_challenge(a); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL A: the Abt Lord claimed a Rebellion reward'; end if;
    v_report := v_report || 'PASS ⚔️ Rebellion quests  (a rebel gets one, the Lord none, Seeds = 2 Dailies + lore + battle for 2 Fragments, the Lord can not claim one)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== B. long reign: 14 / 30 / 60 days, once, never for the Lord =====
  begin
    update public.abt_reigns set started_at = now() - interval '5 days' where id = v_reign;
    perform pg_temp.imp(m); r := public.get_rebellion_state();
    if pg_temp.fr(m) <> 0 or (r->'reign'->>'day')::int <> 6 then raise exception 'FAIL B: day 6 should pay nothing and say day 6 (%, %)', pg_temp.fr(m), r->'reign'->>'day'; end if;
    update public.abt_reigns set started_at = now() - interval '14 days' where id = v_reign;
    r := public.get_rebellion_state();
    if pg_temp.fr(m) <> 1 then raise exception 'FAIL B: 14 days should give +1 Fragment (%)', pg_temp.fr(m); end if;
    perform public.get_rebellion_state(); perform public.get_rebellion_state(); perform public.get_rebellion_state();
    if pg_temp.fr(m) <> 1 then raise exception 'FAIL B: repeated visits paid again (%)', pg_temp.fr(m); end if;
    if jsonb_array_length(r->'unseen') <> 1 then raise exception 'FAIL B: the 14 day notice should be unseen once'; end if;
    perform public.ack_rebellion_notice();
    if jsonb_array_length((public.get_rebellion_state())->'unseen') <> 0 then raise exception 'FAIL B: the notice was not acknowledged'; end if;
    update public.abt_reigns set started_at = now() - interval '30 days' where id = v_reign;
    perform public.get_rebellion_state();
    if pg_temp.fr(m) <> 3 then raise exception 'FAIL B: 30 days should add +2 (total 3, got %)', pg_temp.fr(m); end if;
    -- the Lord gets nothing and sees the pressure
    perform pg_temp.imp(v_lord); r := public.get_rebellion_state();
    if exists (select 1 from public.rebellion_rewards where user_id = v_lord) then raise exception 'FAIL B: the Abt Lord was rewarded'; end if;
    if (r->>'i_am_lord')::boolean is not true or r->>'pressure' is null then raise exception 'FAIL B: the Lord should see the reign pressure'; end if;
    -- 60 days: a full Gauntlet, but only with room in the inventory
    update public.royal_gauntlet_balances set balance = 2 where user_id = m;
    insert into public.royal_gauntlet_balances (user_id, balance) values (m, 2) on conflict (user_id) do update set balance = 2;
    update public.abt_reigns set started_at = now() - interval '60 days' where id = v_reign;
    perform pg_temp.imp(m); perform public.get_rebellion_state();
    if pg_temp.gb(m) <> 2 then raise exception 'FAIL B: a third Gauntlet appeared (%)', pg_temp.gb(m); end if;
    if (select status from public.rebellion_rewards where user_id = m and milestone_id = 'demand') <> 'deferred' then raise exception 'FAIL B: the full Gauntlet should be deferred at 2/2'; end if;
    update public.royal_gauntlet_balances set balance = 1 where user_id = m;          -- a Gauntlet was used
    perform public.get_rebellion_state(); perform public.get_rebellion_state();
    if pg_temp.gb(m) <> 2 then raise exception 'FAIL B: the deferred Gauntlet was not handed over exactly once (%)', pg_temp.gb(m); end if;
    if (select count(*) from public.royal_gauntlet_ledger where user_id = m and reason = 'rebellion_gauntlet') <> 1 then raise exception 'FAIL B: the ledger should show one rebellion Gauntlet'; end if;
    if (select count(*) from public.rebellion_rewards where user_id = m) <> 3 then raise exception 'FAIL B: expected 3 milestone rows'; end if;
    v_err := null; begin insert into public.rebellion_rewards (reign_id, user_id, milestone_id, status) values (v_reign, m, 'restless', 'granted'); exception when unique_violation then v_err := 'unique'; end;
    if v_err is null then raise exception 'FAIL B: the database allowed a milestone twice'; end if;
    v_report := v_report || 'PASS 👑 long reign  (day count, +1 at 14, +2 at 30, a full Gauntlet at 60 only with room and then exactly once, repeats pay nothing, unique constraint, the Lord gets pressure and nothing else)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== C. a reign that ends still pays what it reached =====
  begin
    update public.abt_reigns set started_at = now() - interval '15 days' where id = v_reign;
    update public.abt_reigns set ended_at = now(), dethroned_by_user_id = m where id = v_reign;      -- nobody opened the app in between
    if pg_temp.fr(m) <> 1 then raise exception 'FAIL C: the 14 day milestone was lost when the reign ended (%)', pg_temp.fr(m); end if;
    if exists (select 1 from public.rebellion_rewards where user_id = v_lord) then raise exception 'FAIL C: the dethroned Lord was paid'; end if;
    v_report := v_report || 'PASS reign end  (the milestones a reign reached are paid when it ends, also if nobody visited in between)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  raise exception E'REBELLION REPORT (nothing was saved)\n%', v_report;
end $$;
