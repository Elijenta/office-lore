-- =================================================================
-- FULL-FLOW SELF-TEST  (safe: everything is rolled back)
-- =================================================================
-- Plays the whole Throne system end to end by impersonating the real members
-- from the SQL Editor, using only the public RPCs the app calls (plus the
-- admin Gauntlet grant). Ends with a deliberate exception: the "error" you get
-- back IS the report. NOTHING is saved.
--
--  A  Gauntlet -> challenge -> school pick -> Trial 1 -> Trial 2 -> Final Trial
--     (Royal Judge if a judged Trial is drawn) -> winner -> dethroning -> new reign
--     -> Fallen Abt -> High Brewmaster & Beer XP untouched -> cosmetics untouched
--  B  the Abt Lord defends: successful_defenses +1, loser cooldown, cooldown blocks
--  C  withdrawing refunds the Gauntlet
--  D  Throne Shield: window opens, invoke -> replacement Trial, once per challenge
--  E  Coup d'État succeeds -> Succession -> new Abt Lord
--  F  Coup d'État fails -> coups_survived +1, 30-day lock, duo cooldown
--
-- Needs: no open Throne Challenge, a current Abt Lord, 3 members.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;

create or replace function pg_temp.bal(p_user uuid) returns int as $$
  select coalesce((select balance from public.royal_gauntlet_balances where user_id = p_user), 0);
$$ language sql;

-- answers a question Trial: p_mode 'correct' | 'wrong'
create or replace function pg_temp.run(p_trial uuid, p_user uuid, p_mode text) returns void as $$
declare
  q public.throne_trial_questions;
  v_choice jsonb;
  v_res jsonb;
begin
  perform pg_temp.imp(p_user);
  perform public.start_throne_run(p_trial);
  for q in select * from public.throne_trial_questions where trial_id = p_trial and user_id = p_user order by seq loop
    if q.kind = 'numeric' then
      v_choice := jsonb_build_object('value', case when p_mode = 'correct' then (q.answer->>'value')::numeric else (q.answer->>'value')::numeric * 1.5 + 7 end);
    elsif p_mode = 'correct' then
      v_choice := jsonb_build_object('id', q.answer->>'id');
    else
      v_choice := jsonb_build_object('id', (select o->>'id' from jsonb_array_elements(q.options) o where o->>'id' <> q.answer->>'id' limit 1));
    end if;
    v_res := public.answer_throne_question(p_trial, q.seq, v_choice);
    exit when (v_res->>'finished')::boolean;
  end loop;
end;
$$ language plpgsql;

-- plays whatever Trial this is so that p_winner wins it, through the real RPCs
-- (a pure dice roll cannot be steered: that one is settled directly)
create or replace function pg_temp.finish(p_trial uuid, p_winner uuid) returns text as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  cat public.throne_trial_catalog;
  v_loser uuid;
  v_slot text;
begin
  select * into t from public.throne_challenge_trials where id = p_trial;
  select * into c from public.throne_challenges where id = t.challenge_id;
  v_loser := case when p_winner = c.challenger_user_id then c.defender_user_id else c.challenger_user_id end;

  if t.resolution in ('quiz', 'timed', 'streak') then
    perform pg_temp.run(p_trial, p_winner, 'correct');
    perform pg_temp.run(p_trial, v_loser, 'wrong');
  elsif t.resolution = 'answer' then
    select * into cat from public.throne_trial_catalog where id = t.catalog_id;
    perform pg_temp.imp(p_winner);
    perform public.submit_throne_trial(p_trial, jsonb_build_object('guess', public._throne_answer_value(cat.answer_key)));
    perform pg_temp.imp(v_loser);
    perform public.submit_throne_trial(p_trial, jsonb_build_object('guess', public._throne_answer_value(cat.answer_key) + 500));
  elsif t.resolution = 'creative' then
    perform pg_temp.imp(c.challenger_user_id); perform public.submit_throne_creative(p_trial, 'entry of the challenger side');
    perform pg_temp.imp(c.defender_user_id); perform public.submit_throne_creative(p_trial, 'entry of the defender side');
    select slot into v_slot from public.throne_trial_submissions where trial_id = p_trial and user_id = p_winner;
    perform pg_temp.imp(t.judge_user_id); perform public.judge_throne_verdict(p_trial, v_slot);
  elsif t.resolution = 'reallife' then
    perform pg_temp.imp(c.challenger_user_id); perform public.ready_throne_trial(p_trial);
    perform pg_temp.imp(c.defender_user_id); perform public.ready_throne_trial(p_trial);
    perform pg_temp.imp(t.judge_user_id);
    perform public.judge_throne_verdict(p_trial, case when p_winner = c.challenger_user_id then 'challenger' else 'defender' end);
  elsif t.resolution = 'judge' then
    perform pg_temp.imp(t.judge_user_id);
    perform public.judge_throne_verdict(p_trial, case when p_winner = c.challenger_user_id then 'challenger' else 'defender' end);
  else
    perform public._finish_throne_trial(p_trial, p_winner); -- dice: settled directly
    return t.resolution || ' (settled directly)';
  end if;
  return t.resolution;
end;
$$ language plpgsql;

create or replace function pg_temp.cur(p_ch uuid) returns uuid as $$
  select id from public.throne_challenge_trials where challenge_id = p_ch and status in ('active', 'awaiting_judge')
  order by trial_no desc, attempt desc limit 1;
$$ language sql;

do $$
declare
  v_report text := '';
  v_lord uuid; v_reign uuid; v_e uuid; v_third uuid;
  v_ch uuid; v_t uuid; v_kinds text := '';
  c public.throne_challenges; old_r public.abt_reigns; new_r public.abt_reigns;
  v_bal int; v_n int; v_ok boolean;
  v_xp_lord int; v_xp_e int; v_hb_before uuid; v_hb_after uuid; v_cos int;
  v_e2 uuid; v_cd timestamptz; v_cap int; v_def int; v_surv int;
  v_nm_e text; v_nm_third text; v_i int;
  v_t2 uuid;
begin
  select user_id, id into v_lord, v_reign from public.abt_reigns where ended_at is null limit 1;
  if v_lord is null then raise exception 'ABORTED: there is no Abt Lord'; end if;
  if exists (select 1 from public.throne_challenges where status in ('pending', 'active', 'awaiting_judge')) then
    raise exception 'ABORTED: an open Throne Challenge exists. Cancel it first.';
  end if;
  select p.id into v_e from public.profiles p join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active
    where p.id <> v_lord order by p.display_name limit 1;
  select p.id into v_third from public.profiles p join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active
    where p.id not in (v_lord, v_e) order by p.display_name limit 1;
  if v_e is null or v_third is null then raise exception 'ABORTED: need 3 members'; end if;
  select display_name into v_nm_e from public.profiles where id = v_e;
  select display_name into v_nm_third from public.profiles where id = v_third;
  -- a clean slate for the test (rolled back with everything else): no old cooldowns, no shields
  update public.throne_challenges set completed_at = completed_at - interval '90 days', created_at = created_at - interval '90 days' where status in ('completed', 'cancelled');
  delete from public.throne_shields;
  v_report := format('lord=%s  challenger=%s  third(judge)=%s', (select display_name from public.profiles where id = v_lord), v_nm_e, v_nm_third) || E'\n';

  -- =============== A: the whole flow, challenger wins ===============
  begin
    delete from public.throne_shields;
    select coalesce(beer_xp, 0) into v_xp_lord from public.user_xp_totals where user_id = v_lord;
    select coalesce(beer_xp, 0) into v_xp_e from public.user_xp_totals where user_id = v_e;
    select user_id into v_hb_before from public.user_xp_totals order by beer_xp desc, user_id limit 1;
    select count(*) into v_cos from public.user_abt_cosmetics;
    select count(*) into v_cap from public.abt_reigns where user_id = v_e;

    perform public.admin_grant_royal_gauntlets(v_nm_e, 1, 'selftest');
    v_bal := pg_temp.bal(v_e);
    perform pg_temp.imp(v_e);
    v_ch := public.create_throne_challenge(true, v_lord);
    if pg_temp.bal(v_e) <> v_bal - 1 then raise exception 'FAIL A: the Gauntlet was not consumed (% -> %)', v_bal, pg_temp.bal(v_e); end if;
    select * into c from public.throne_challenges where id = v_ch;
    if c.status <> 'pending' or c.challenger_user_id <> v_e or c.defender_user_id <> v_lord then raise exception 'FAIL A: wrong challenge state/roles'; end if;
    v_ok := false; begin perform public.create_throne_challenge(true, v_lord); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL A: a second open challenge was accepted'; end if;
    v_ok := false; begin perform pg_temp.imp(v_lord); perform public.create_throne_challenge(true, v_lord); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL A: the Abt Lord could challenge themselves'; end if;

    -- Trial 1: the challenger picks the school
    perform pg_temp.imp(v_e); perform public.pick_throne_trial_school(v_ch, 'lore');
    v_t := pg_temp.cur(v_ch);
    v_kinds := pg_temp.finish(v_t, v_e);
    select * into c from public.throne_challenges where id = v_ch;
    if c.challenger_score <> 1 or c.awaiting_pick_by is distinct from v_lord then raise exception 'FAIL A: after Trial 1 expected 1-0 and the Lord to pick (% - %, pick %)', c.challenger_score, c.defender_score, c.awaiting_pick_by; end if;

    -- Trial 2: the Abt Lord picks; the Lord wins -> 1-1
    perform pg_temp.imp(v_lord); perform public.pick_throne_trial_school(v_ch, 'wisdom');
    v_t := pg_temp.cur(v_ch);
    v_kinds := v_kinds || ', ' || pg_temp.finish(v_t, v_lord);
    select * into c from public.throne_challenges where id = v_ch;
    if c.challenger_score <> 1 or c.defender_score <> 1 then raise exception 'FAIL A: after Trial 2 expected 1-1 (% - %)', c.challenger_score, c.defender_score; end if;
    if c.status = 'completed' then raise exception 'FAIL A: the series ended at 1-1'; end if;

    -- THE FINAL TRIAL: the throne chose; the challenger wins
    v_t := pg_temp.cur(v_ch);
    select count(*) into v_n from public.throne_challenge_trials where challenge_id = v_ch and trial_no = 3 and picker_user_id is null;
    if v_n <> 1 then raise exception 'FAIL A: no Final Trial started at 1-1'; end if;
    v_kinds := v_kinds || ', FINAL ' || pg_temp.finish(v_t, v_e);

    -- the outcome
    select * into c from public.throne_challenges where id = v_ch;
    if c.status <> 'completed' or c.winner_user_id <> v_e or c.challenger_score <> 2 then raise exception 'FAIL A: wrong outcome (%, winner e=%, %-%)', c.status, c.winner_user_id = v_e, c.challenger_score, c.defender_score; end if;
    select * into old_r from public.abt_reigns where id = v_reign;
    select * into new_r from public.abt_reigns where user_id = v_e and ended_at is null;
    if old_r.ended_at is null or old_r.dethroned_by_user_id <> v_e or old_r.ended_by_challenge_id <> v_ch then raise exception 'FAIL A: the old reign was not closed correctly'; end if;
    if new_r.id is null or new_r.predecessor_reign_id <> v_reign or new_r.won_challenge_id <> v_ch then raise exception 'FAIL A: the new reign is wrong'; end if;
    select count(*) into v_n from public.abt_reigns where ended_at is null;
    if v_n <> 1 then raise exception 'FAIL A: % open reigns after the swap', v_n; end if;
    if (select count(*) from public.abt_reigns where user_id = v_e) <> v_cap + 1 then raise exception 'FAIL A: throne captures did not go up by one'; end if;
    -- Beer XP, High Brewmaster and cosmetics are untouched
    if (select coalesce(beer_xp, 0) from public.user_xp_totals where user_id = v_lord) <> v_xp_lord
       or (select coalesce(beer_xp, 0) from public.user_xp_totals where user_id = v_e) <> v_xp_e then raise exception 'FAIL A: Beer XP changed'; end if;
    select user_id into v_hb_after from public.user_xp_totals order by beer_xp desc, user_id limit 1;
    if v_hb_after is distinct from v_hb_before then raise exception 'FAIL A: the High Brewmaster changed'; end if;
    if (select count(*) from public.user_abt_cosmetics) <> v_cos then raise exception 'FAIL A: cosmetics changed'; end if;
    v_report := v_report || format('PASS A  full flow (trials: %s). Fallen Abt = the old Lord (reign ended %s); High Brewmaster stays %s (%s); new reign #%s; Beer XP and %s cosmetics untouched',
      v_kinds, to_char(old_r.ended_at, 'HH24:MI:SS'), (select display_name from public.profiles where id = v_hb_after),
      case when v_hb_after = v_lord then 'the dethroned Lord' else 'not the Lord' end, v_cap + 1, v_cos) || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then
    if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || 'FAIL A: ' || sqlerrm || E'\n'; end if;
  end;

  -- =============== B: the Lord defends ===============
  begin
    delete from public.throne_shields;
    perform public.admin_grant_royal_gauntlets(v_nm_e, 2, 'selftest');
    select successful_defenses into v_def from public.abt_reigns where id = v_reign;
    perform pg_temp.imp(v_e); v_ch := public.create_throne_challenge(true, v_lord);
    perform public.pick_throne_trial_school(v_ch, 'pint');
    perform pg_temp.finish(pg_temp.cur(v_ch), v_lord);
    perform pg_temp.imp(v_lord); perform public.pick_throne_trial_school(v_ch, 'lore');
    perform pg_temp.finish(pg_temp.cur(v_ch), v_lord);
    select * into c from public.throne_challenges where id = v_ch;
    if c.status <> 'completed' or c.winner_user_id <> v_lord then raise exception 'FAIL B: the Lord should have won 2-0 (%, %-%)', c.status, c.challenger_score, c.defender_score; end if;
    if (select successful_defenses from public.abt_reigns where id = v_reign) <> v_def + 1 then raise exception 'FAIL B: successful_defenses did not go up'; end if;
    if (select ended_at from public.abt_reigns where id = v_reign) is not null then raise exception 'FAIL B: the Lord lost the throne anyway'; end if;
    v_cd := public._throne_cooldown_until(v_e);
    if v_cd is null or v_cd <= now() then raise exception 'FAIL B: no cooldown after the lost challenge'; end if;
    v_ok := false; begin perform pg_temp.imp(v_e); perform public.create_throne_challenge(true, v_lord); exception when others then v_ok := sqlerrm like 'COOLDOWN%'; end;
    if not v_ok then raise exception 'FAIL B: the cooldown did not block a new challenge'; end if;
    v_report := v_report || format('PASS B  defense: successful_defenses %s -> %s, cooldown until %s blocks the challenger', v_def, v_def + 1, to_char(v_cd, 'DD Mon HH24:MI')) || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then
    if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || 'FAIL B: ' || sqlerrm || E'\n'; end if;
  end;

  -- =============== C: withdrawing refunds ===============
  begin
    perform public.admin_grant_royal_gauntlets(v_nm_e, 1, 'selftest');
    v_bal := pg_temp.bal(v_e);
    perform pg_temp.imp(v_e); v_ch := public.create_throne_challenge(false, v_lord);
    perform public.cancel_throne_challenge(v_ch);
    if pg_temp.bal(v_e) <> v_bal then raise exception 'FAIL C: the Gauntlet was not refunded (% -> %)', v_bal, pg_temp.bal(v_e); end if;
    v_report := v_report || 'PASS C  a withdrawn challenge refunds its Gauntlet' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then
    if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || 'FAIL C: ' || sqlerrm || E'\n'; end if;
  end;

  -- =============== D: the Throne Shield ===============
  begin
    delete from public.throne_shields;
    insert into public.throne_shields (user_id, reign_id) values (v_lord, v_reign);
    perform public.admin_grant_royal_gauntlets(v_nm_e, 1, 'selftest');
    perform pg_temp.imp(v_e); v_ch := public.create_throne_challenge(true, v_lord);
    perform public.pick_throne_trial_school(v_ch, 'pint');
    v_t := pg_temp.cur(v_ch);
    perform pg_temp.finish(v_t, v_e);               -- the Lord loses a digital Trial
    select * into c from public.throne_challenges where id = v_ch;
    if c.shield_window_trial_id is null then raise exception 'FAIL D: no Shield window opened after the Lord lost a digital Trial'; end if;
    if c.challenger_score <> 1 then raise exception 'FAIL D: expected 1-0 during the window'; end if;
    -- only the Lord may invoke
    v_ok := false; begin perform pg_temp.imp(v_e); perform public.invoke_throne_shield(v_ch); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL D: the challenger could invoke the Lord''s Shield'; end if;
    perform pg_temp.imp(v_lord); perform public.invoke_throne_shield(v_ch);
    select * into c from public.throne_challenges where id = v_ch;
    if c.challenger_score <> 0 or c.shield_used_at is null or c.shield_window_trial_id is not null then raise exception 'FAIL D: Shield state wrong after invoking (score %, used %)', c.challenger_score, c.shield_used_at; end if;
    if (select status from public.throne_challenge_trials where id = v_t) <> 'voided' then raise exception 'FAIL D: the lost Trial was not voided'; end if;
    v_t2 := pg_temp.cur(v_ch);
    if v_t2 is null or v_t2 = v_t or (select trial_no from public.throne_challenge_trials where id = v_t2) <> 1 then raise exception 'FAIL D: no replacement Trial 1'; end if;
    if (select used_at from public.throne_shields where user_id = v_lord and reign_id = v_reign) is null then raise exception 'FAIL D: the Shield is not broken'; end if;
    -- a second loss in the same challenge gets no window (once per challenge)
    perform pg_temp.finish(v_t2, v_e);
    select * into c from public.throne_challenges where id = v_ch;
    if c.shield_window_trial_id is not null then raise exception 'FAIL D: a second Shield window opened in the same challenge'; end if;
    v_report := v_report || 'PASS D  Throne Shield: window after a lost digital Trial, only the Lord can invoke, point taken back, replacement Trial, broken, once per challenge' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then
    if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || 'FAIL D: ' || sqlerrm || E'\n'; end if;
  end;

  -- =============== E: a Coup d'État succeeds, then the Succession ===============
  begin
    delete from public.throne_shields;
    perform public.admin_grant_royal_gauntlets(v_nm_e, 1, 'selftest');
    perform public.admin_grant_royal_gauntlets(v_nm_third, 1, 'selftest');
    v_e2 := v_third;
    v_bal := pg_temp.bal(v_e);
    perform pg_temp.imp(v_e); v_ch := public.propose_coup(v_e2);
    if pg_temp.bal(v_e) <> v_bal then raise exception 'FAIL E: a Gauntlet was spent before the partner confirmed'; end if;
    v_ok := false; begin perform pg_temp.imp(v_e); perform public.confirm_coup(v_ch); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL E: the proposer could confirm their own Coup'; end if;
    perform pg_temp.imp(v_e2); perform public.confirm_coup(v_ch);
    if pg_temp.bal(v_e) <> v_bal - 1 then raise exception 'FAIL E: the proposer''s Gauntlet was not spent'; end if;
    select * into c from public.throne_challenges where id = v_ch;
    if c.status <> 'active' or c.kind <> 'coup' or c.coup_plan is null then raise exception 'FAIL E: the Coup did not start (%)', c.status; end if;
    -- the duo wins three Trials (the representatives alternate)
    v_i := 0;
    loop
      v_i := v_i + 1; exit when v_i > 6;
      select * into c from public.throne_challenges where id = v_ch;
      exit when c.status = 'completed';
      v_t := pg_temp.cur(v_ch);
      exit when v_t is null;
      perform pg_temp.finish(v_t, c.challenger_user_id);     -- the current duo representative wins
    end loop;
    select * into c from public.throne_challenges where id = v_ch;
    if c.coup_result is distinct from 'team' or c.challenger_score <> 3 then raise exception 'FAIL E: the Coup should have succeeded (%, %, %-%)', c.status, c.coup_result, c.challenger_score, c.defender_score; end if;
    if (select ended_at from public.abt_reigns where id = v_reign) is not null then raise exception 'FAIL E: the Lord''s reign closed before the Succession'; end if;
    -- THE SUCCESSION
    select * into c from public.throne_challenges where parent_coup_id = v_ch and kind = 'succession';
    if c.id is null or c.status <> 'active' then raise exception 'FAIL E: no Succession started'; end if;
    v_ch := c.id;
    perform pg_temp.finish(pg_temp.cur(v_ch), v_e2);
    select * into old_r from public.abt_reigns where id = v_reign;
    select * into new_r from public.abt_reigns where ended_at is null;
    if old_r.ended_at is null or old_r.dethroned_by_user_id <> v_e2 then raise exception 'FAIL E: the Lord''s reign did not end by the Succession winner'; end if;
    if new_r.user_id <> v_e2 then raise exception 'FAIL E: the Succession winner is not the new Abt Lord'; end if;
    v_report := v_report || 'PASS E  Coup d''État: both confirmed, 2 Gauntlets spent, relay of Trials, duo won 3, Succession decided the new Abt Lord, throne never empty' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then
    if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || 'FAIL E: ' || sqlerrm || E'\n'; end if;
  end;

  -- =============== F: a Coup d'État fails ===============
  begin
    delete from public.throne_shields;
    perform public.admin_grant_royal_gauntlets(v_nm_e, 2, 'selftest');
    perform public.admin_grant_royal_gauntlets(v_nm_third, 2, 'selftest');
    select coups_survived, successful_defenses into v_surv, v_def from public.abt_reigns where id = v_reign;
    perform pg_temp.imp(v_e); v_ch := public.propose_coup(v_third);
    perform pg_temp.imp(v_third); perform public.confirm_coup(v_ch);
    v_i := 0;
    loop
      v_i := v_i + 1; exit when v_i > 6;
      select * into c from public.throne_challenges where id = v_ch;
      exit when c.status = 'completed';
      v_t := pg_temp.cur(v_ch);
      exit when v_t is null;
      perform pg_temp.finish(v_t, v_lord);                    -- the Lord wins every Trial
    end loop;
    select * into c from public.throne_challenges where id = v_ch;
    if c.coup_result is distinct from 'lord' or c.winner_user_id <> v_lord then raise exception 'FAIL F: the Lord should have survived (%, %)', c.status, c.coup_result; end if;
    select * into old_r from public.abt_reigns where id = v_reign;
    if old_r.ended_at is not null then raise exception 'FAIL F: the Lord fell anyway'; end if;
    if old_r.coups_survived <> v_surv + 1 or old_r.successful_defenses <> v_def + 1 then raise exception 'FAIL F: coups_survived / successful_defenses not registered (% / %)', old_r.coups_survived, old_r.successful_defenses; end if;
    if public._throne_cooldown_until(v_e) is null or public._throne_cooldown_until(v_third) is null then raise exception 'FAIL F: the failed duo is not in cooldown'; end if;
    -- a second Coup against this reign inside 30 days is refused even without a cooldown
    update public.throne_challenges set completed_at = completed_at - interval '30 days' where id = v_ch;
    v_ok := false; begin perform pg_temp.imp(v_e); perform public.propose_coup(v_third); exception when others then v_ok := sqlerrm like '%already attempted%'; end;
    if not v_ok then raise exception 'FAIL F: a second Coup against the same reign within 30 days was accepted'; end if;
    v_report := v_report || 'PASS F  failed Coup: the Lord survives, coups_survived +1 (UNTOUCHABLE ABT), successful_defenses +1, both duo members in cooldown, 30-day lock on the reign' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then
    if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || 'FAIL F: ' || sqlerrm || E'\n'; end if;
  end;

  raise exception E'FULL-FLOW REPORT (nothing was saved)\n%', v_report;
end $$;
