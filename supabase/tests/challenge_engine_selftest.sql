-- =================================================================
-- SELF-TEST for 0048_challenge_engine.sql  (safe: everything is rolled back)
-- =================================================================
-- Run in the Supabase SQL Editor AFTER 0048. It swaps the definitions for a few
-- known test ones (inside the transaction), impersonates real members, drives
-- progress through the REAL triggers on the real tables, then claims, steps into
-- a new day and a new week, adds a "new user", and checks app scoping. It ends
-- with a deliberate exception: the "error" you get back IS the report. NOTHING
-- is saved. Needs 3 members.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;

create or replace function pg_temp.asg(p_user uuid, p_def text) returns public.challenge_assignments as $$
  select a from public.challenge_assignments a where a.definition_id = p_def and (a.user_id = p_user or a.user_id is null)
  order by a.created_at desc limit 1;
$$ language sql;

do $$
declare
  v_report text := '';
  m1 uuid; m2 uuid; m3 uuid; v_lord uuid;
  a public.challenge_assignments; b public.challenge_assignments;
  v_n int; v_n2 int; v_bal int; v_bal2 int; v_res jsonb; v_ok boolean;
  v_nick uuid[]; v_beer uuid; v_cnt int;
begin
  select array_agg(x.id) into v_nick from (select id from public.nicknames order by id limit 4) x;
  select id into v_beer from public.beers limit 1;
  select p.id into m1 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1 offset 0;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1 offset 1;
  select p.id into m3 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1 offset 2;
  select user_id into v_lord from public.abt_reigns where ended_at is null limit 1;
  if m3 is null or coalesce(cardinality(v_nick), 0) < 4 or v_beer is null then raise exception 'ABORTED: need 3 members, 4 nicknames and a beer'; end if;
  v_report := format('members: %s / %s / %s   (Abt Lord: %s)', (select display_name from public.profiles where id = m1), (select display_name from public.profiles where id = m2),
    (select display_name from public.profiles where id = m3), coalesce((select display_name from public.profiles where id = v_lord), '-')) || E'\n';

  -- a clean slate (rolled back with the rest): no real assignments, events or rewards in the way
  delete from public.challenge_assignments;
  delete from public.challenge_events;
  delete from public.challenge_reward_grants;
  delete from public.gauntlet_fragments;
  delete from public.nickname_votes where user_id in (m1, m2, m3);          -- earlier real votes would collide with the test votes
  delete from public.beer_ratings where user_id in (m1, m2, m3);
  -- known test definitions only (rolled back with the rest)
  update public.challenge_definitions set is_active = false;
  insert into public.challenge_definitions (id, type, category, title, description, difficulty, event_type, target, reward, audience) values
    ('t_pd1', 'personal_daily', 'nickname', 'T rate 3 nicknames', 't', 'easy', 'nickname_rated', 3, '{"lines":[{"kind":"player_xp","amount":10},{"kind":"gauntlet_fragments","amount":3}]}', 'everyone'),
    ('t_pd2', 'personal_daily', 'beer', 'T rate a beer', 't', 'easy', 'beer_rated', 1, '{"lines":[{"kind":"player_xp","amount":5}]}', 'everyone'),
    ('t_pd3', 'personal_daily', 'nickname', 'T new nickname', 't', 'normal', 'nickname_created', 1, '{"lines":[{"kind":"player_xp","amount":5}]}', 'everyone'),
    ('t_gd1', 'group_daily', 'beer', 'T team rates 2 beers', 't', 'normal', 'beer_rated', 2, '{"lines":[{"kind":"player_xp","amount":7},{"kind":"mystery","amount":1}]}', 'everyone'),
    ('t_pw1', 'personal_weekly', 'mixed', 'T 2 dailies', 't', 'hard', 'daily_completed', 2, '{"lines":[{"kind":"player_xp","amount":20}]}', 'everyone'),
    ('t_gw1', 'group_weekly', 'poetry', 'T team 3 poem reactions', 't', 'normal', 'poem_rated', 3, '{"lines":[]}', 'everyone'),
    ('t_rb1', 'rebellion', 'battle', 'T rebellion', 't', 'special', 'battle_voted', 1, '{"lines":[{"kind":"gauntlet_fragments","amount":1}]}', 'non_lord');

  -- ===== 1. assignment: created, deterministic, no duplicates (refresh / two tabs) =====
  begin
    select public._ensure_challenge_assignments_for(m1, now()) into v_n;
    select public._ensure_challenge_assignments_for(m1, now()) into v_n2;   -- "refresh" / second tab
    perform pg_temp.imp(m1); v_res := public.ensure_challenge_assignments();  -- the public RPC, third call
    select count(*) into v_cnt from public.challenge_assignments where user_id = m1;
    v_ok := v_n > 0 and v_n2 = 0 and (v_res->>'created')::int = 0
            and (select count(*) from public.challenge_assignments where user_id = m1 and type = 'personal_daily') = 3
            and (select count(*) from public.challenge_assignments where user_id is null and type = 'group_daily') = 1
            and (select count(*) from public.challenge_assignments where user_id = m1 and type = 'personal_weekly') = 1
            and (select count(*) from public.challenge_assignments where user_id is null and type = 'group_weekly') = 1
            and (select count(*) from public.challenge_assignments where user_id = m1 and type = 'rebellion') = case when m1 = v_lord then 0 else 1 end;
    v_report := v_report || format('%s assignment: %s created, repeat calls create 0 (refresh/second tab); 3 daily + 1 group daily + weekly (+1 rebellion only for a non-lord)',
      case when v_ok then 'PASS' else 'FAIL' end, v_n) || E'\n';
    if not v_ok then raise exception 'FAIL 1'; end if;
  exception when others then
    if sqlerrm <> 'FAIL 1' then v_report := v_report || 'FAIL 1: ' || sqlerrm || E'\n'; end if;
  end;

  -- ===== 2. progress through the REAL triggers; toggling a vote cannot farm progress =====
  begin
    perform public._ensure_challenge_assignments_for(m2, now());
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[1], m1, 'funny');
    delete from public.nickname_votes where nickname_id = v_nick[1] and user_id = m1;
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[1], m1, 'funny');  -- toggled on again
    a := pg_temp.asg(m1, 't_pd1');
    if a.progress <> 1 then raise exception 'FAIL 2: toggling the same nickname counted twice (progress %)', a.progress; end if;
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[2], m1, 'funny');
    a := pg_temp.asg(m1, 't_pd1');
    if a.progress <> 2 or a.status <> 'active' then raise exception 'FAIL 2: expected 2/3 active, got %/% %', a.progress, a.target, a.status; end if;
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[3], m1, 'savage');
    a := pg_temp.asg(m1, 't_pd1');
    if a.progress <> 3 or a.status <> 'completed' or a.completed_at is null then raise exception 'FAIL 2: expected COMPLETE 3/3, got %/% %', a.progress, a.target, a.status; end if;
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[4], m1, 'funny');  -- beyond the target
    if (pg_temp.asg(m1, 't_pd1')).progress <> 3 then raise exception 'FAIL 2: progress went past the target'; end if;
    -- another user's votes do not touch my personal challenge
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[1], m2, 'funny');
    if (pg_temp.asg(m2, 't_pd1')).progress <> 1 or (pg_temp.asg(m1, 't_pd1')).progress <> 3 then raise exception 'FAIL 2: personal progress leaked between users'; end if;
    v_report := v_report || 'PASS progress: 1/3 -> 2/3 -> 3/3 COMPLETE through nickname_votes triggers, vote toggling counts once per nickname, capped at the target, personal progress stays personal' || E'\n';
  exception when others then
    if sqlerrm not like 'FAIL 2%' then v_report := v_report || 'FAIL 2: ' || sqlerrm || E'\n'; else v_report := v_report || sqlerrm || E'\n'; end if;
  end;

  -- ===== 3. beer ratings: personal + group progress, daily_completed chain into the weekly =====
  begin
    insert into public.beer_ratings (beer_id, user_id, rating) values (v_beer, m1, 8);
    a := pg_temp.asg(m1, 't_pd2');
    if a.status <> 'completed' then raise exception 'FAIL 3: beer rating did not complete the daily (%/%)', a.progress, a.target; end if;
    b := pg_temp.asg(m1, 't_gd1');
    if b.progress <> 1 then raise exception 'FAIL 3: group progress should be 1 after M1 (is %)', b.progress; end if;
    -- two dailies done -> the weekly "2 dailies" is complete too
    a := pg_temp.asg(m1, 't_pw1');
    if a.progress <> 2 or a.status <> 'completed' then raise exception 'FAIL 3: the weekly "complete 2 dailies" is % (%/%)', a.status, a.progress, a.target; end if;
    -- the second member completes the group challenge together with the first
    insert into public.beer_ratings (beer_id, user_id, rating) values (v_beer, m2, 9);
    b := pg_temp.asg(m2, 't_gd1');
    if b.progress <> 2 or b.status <> 'completed' then raise exception 'FAIL 3: group challenge should be complete (%/% %)', b.progress, b.target, b.status; end if;
    if (select count(*) from public.challenge_contributions where assignment_id = b.id and amount = 1) <> 2 then raise exception 'FAIL 3: contributions not recorded per member'; end if;
    v_report := v_report || 'PASS beer ratings: daily done, group challenge 1/2 -> 2/2 with both members credited, completing dailies feeds the weekly (daily_completed chain)' || E'\n';
  exception when others then
    if sqlerrm not like 'FAIL 3%' then v_report := v_report || 'FAIL 3: ' || sqlerrm || E'\n'; else v_report := v_report || sqlerrm || E'\n'; end if;
  end;

  -- ===== 4. claiming: once, ever =====
  begin
    a := pg_temp.asg(m1, 't_pd1');
    -- the reward = exactly one Gauntlet worth of fragments (the rule is configurable: 5 now)
    update public.challenge_assignments set reward = jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('kind', 'gauntlet_fragments', 'amount', public._fragments_per_gauntlet()), jsonb_build_object('kind', 'player_xp', 'amount', 10))) where id = a.id;
    delete from public.royal_gauntlet_balances where user_id = m1;
    select coalesce(balance, 0) into v_bal from public.royal_gauntlet_balances where user_id = m1; v_bal := coalesce(v_bal, 0);
    perform pg_temp.imp(m1);
    v_res := public.claim_challenge(a.id);
    if v_res->>'status' <> 'claimed' then raise exception 'FAIL 4: first claim returned %', v_res; end if;
    select coalesce(balance, 0) into v_bal2 from public.royal_gauntlet_balances where user_id = m1; v_bal2 := coalesce(v_bal2, 0);
    if v_bal2 <> v_bal + 1 then raise exception 'FAIL 4: 3 fragments should forge a Royal Gauntlet (% -> %)', v_bal, v_bal2; end if;
    if coalesce((select fragments from public.gauntlet_fragments where user_id = m1), 0) <> 0 then raise exception 'FAIL 4: fragments left over'; end if;
    -- the double click, the refresh, the second tab, the realtime echo
    v_res := public.claim_challenge(a.id);
    v_res := public.claim_challenge(a.id);
    select coalesce(balance, 0) into v_bal2 from public.royal_gauntlet_balances where user_id = m1;
    select count(*) into v_cnt from public.challenge_reward_grants where assignment_id = a.id and user_id = m1;
    if v_res->>'status' <> 'already_claimed' or v_bal2 <> v_bal + 1 or v_cnt <> 2 then raise exception 'FAIL 4: a repeated claim paid again (status %, balance %, grants %)', v_res->>'status', v_bal2, v_cnt; end if;
    if (select status from public.challenge_assignments where id = a.id) <> 'claimed' then raise exception 'FAIL 4: assignment not marked claimed'; end if;
    -- somebody else's personal challenge cannot be claimed
    v_ok := false; begin perform pg_temp.imp(m2); perform public.claim_challenge(a.id); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL 4: another user claimed a personal challenge'; end if;
    -- an unfinished one cannot be claimed
    v_ok := false; begin perform pg_temp.imp(m1); perform public.claim_challenge((pg_temp.asg(m1, 't_pd3')).id); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL 4: an unfinished challenge was claimed'; end if;
    -- group: each contributor claims once; a non-contributor cannot
    b := pg_temp.asg(m1, 't_gd1');
    v_ok := false; begin perform pg_temp.imp(m3); perform public.claim_challenge(b.id); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL 4: a non-contributor claimed a group reward'; end if;
    perform pg_temp.imp(m1); perform public.claim_challenge(b.id); perform public.claim_challenge(b.id);
    perform pg_temp.imp(m2); perform public.claim_challenge(b.id);
    select count(*) into v_cnt from public.challenge_claims where assignment_id = b.id;
    select count(*) into v_n from public.challenge_reward_grants where assignment_id = b.id;
    if v_cnt <> 2 or v_n <> 4 then raise exception 'FAIL 4: group claims wrong (claims %, grants %)', v_cnt, v_n; end if;
    if (select count(*) from public.mystery_boxes mb join public.challenge_reward_grants g on g.id = mb.grant_id where g.assignment_id = b.id) <> (select count(*) from public.challenge_reward_grants where assignment_id = b.id and kind = 'mystery' and amount > 0) then raise exception 'FAIL 4: Mystery lines and boxes do not match'; end if;
    v_report := v_report || 'PASS claiming: paid once (fragments forged a Gauntlet), repeat/double/second-tab claims pay nothing, not claimable by others or before completion, group rewards once per contributor, every Mystery line made exactly one box' || E'\n';
  exception when others then
    if sqlerrm not like 'FAIL 4%' then v_report := v_report || 'FAIL 4: ' || sqlerrm || E'\n'; else v_report := v_report || sqlerrm || E'\n'; end if;
  end;

  -- ===== 5. a new day, then a new week =====
  begin
    a := pg_temp.asg(m1, 't_pd2');                         -- completed, never claimed
    select public._ensure_challenge_assignments_for(m1, now() + interval '1 day') into v_n;
    if v_n = 0 then raise exception 'FAIL 5: no new daily assignments tomorrow'; end if;
    if (select count(distinct period_key) from public.challenge_assignments where user_id = m1 and type = 'personal_daily') <> 2 then raise exception 'FAIL 5: tomorrow did not get its own period'; end if;
    if exists (select 1 from public.challenge_assignments where user_id = m1 and type = 'personal_daily' and status = 'active' and expires_at <= now() + interval '1 day') then
      raise exception 'FAIL 5: yesterday''s unfinished daily did not expire';
    end if;
    -- yesterday's completed daily is still claimable
    perform pg_temp.imp(m1); v_res := public.claim_challenge(a.id);
    if v_res->>'status' <> 'claimed' then raise exception 'FAIL 5: a completed daily was lost at midnight'; end if;
    -- progress goes to TODAY's assignment only (the new "day" is simulated, so move the clock window)
    select public._ensure_challenge_assignments_for(m1, now() + interval '8 days') into v_n2;
    if (select count(distinct period_key) from public.challenge_assignments where user_id = m1 and type = 'personal_weekly') < 2 then raise exception 'FAIL 5: a new week did not get new weeklies'; end if;
    v_report := v_report || format('PASS new day (%s new) + new week (%s new): new period keys, old unfinished ones expire, a completed-but-unclaimed daily stays claimable', v_n, v_n2) || E'\n';
  exception when others then
    if sqlerrm not like 'FAIL 5%' then v_report := v_report || 'FAIL 5: ' || sqlerrm || E'\n'; else v_report := v_report || sqlerrm || E'\n'; end if;
  end;

  -- ===== 6. a new user + app scoping =====
  begin
    select count(*) into v_cnt from public.challenge_assignments where user_id = m3;
    select public._ensure_challenge_assignments_for(m3, now()) into v_n;
    if v_cnt <> 0 or v_n = 0 then raise exception 'FAIL 6: the new user did not get a fresh set (had %, created %)', v_cnt, v_n; end if;
    if (select count(*) from public.challenge_assignments where user_id is null and type = 'group_daily' and period_key = (select period_key from public.challenge_assignments where user_id = m3 and type = 'personal_daily' limit 1)) <> 1 then
      raise exception 'FAIL 6: the new user created a second group challenge';
    end if;
    -- RLS: I can read my rows + group rows, never someone else's personal rows
    perform pg_temp.imp(m1);
    set local role authenticated;
    select count(*) into v_cnt from public.challenge_assignments where user_id = m2;
    select count(*) into v_n2 from public.challenge_assignments where user_id = m1;
    reset role;
    if v_cnt <> 0 or v_n2 = 0 then raise exception 'FAIL 6: RLS wrong (others'' rows visible %, own %)', v_cnt, v_n2; end if;
    -- a member who is NOT (or no longer) in the app: nothing counts, nothing is created, nothing is readable
    update public.app_memberships set is_active = false where user_id = m3 and app_id = 'officelore';
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[1], m3, 'funny');
    if (pg_temp.asg(m3, 't_pd1')).progress <> 0 then raise exception 'FAIL 6: an outsider made progress'; end if;
    if public._ensure_challenge_assignments_for(m3, now() + interval '2 days') <> 0 then raise exception 'FAIL 6: assignments were created for an outsider'; end if;
    v_ok := false; begin perform pg_temp.imp(m3); perform public.ensure_challenge_assignments(); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL 6: an outsider could call ensure_challenge_assignments'; end if;
    v_ok := false; begin perform pg_temp.imp(m3); perform public.claim_challenge((pg_temp.asg(m1, 't_gd1')).id); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL 6: an outsider could claim'; end if;
    v_report := v_report || 'PASS new user gets a fresh set and shares the single group challenge; RLS hides other people''s personal rows; a non-member makes no progress, gets nothing created, cannot call the RPCs' || E'\n';
  exception when others then
    reset role;
    if sqlerrm not like 'FAIL 6%' then v_report := v_report || 'FAIL 6: ' || sqlerrm || E'\n'; else v_report := v_report || sqlerrm || E'\n'; end if;
  end;

  -- ===== 7. direct writes are impossible from the client =====
  begin
    perform pg_temp.imp(m1);
    set local role authenticated;
    v_ok := false; begin update public.challenge_assignments set progress = 99, status = 'completed' where user_id = m1; get diagnostics v_cnt = row_count; v_ok := (v_cnt = 0); exception when others then v_ok := true; end;
    if not v_ok then reset role; raise exception 'FAIL 7: a client could write its own progress'; end if;
    v_ok := false; begin insert into public.challenge_reward_grants (assignment_id, user_id, line_no, kind, amount) values ((pg_temp.asg(m1, 't_pd3')).id, m1, 1, 'player_xp', 999); exception when others then v_ok := true; end;
    reset role;
    if not v_ok then raise exception 'FAIL 7: a client could write a reward'; end if;
    v_report := v_report || 'PASS clients cannot update progress or insert rewards directly (RLS)' || E'\n';
  exception when others then
    reset role;
    if sqlerrm not like 'FAIL 7%' then v_report := v_report || 'FAIL 7: ' || sqlerrm || E'\n'; else v_report := v_report || sqlerrm || E'\n'; end if;
  end;

  raise exception E'CHALLENGE ENGINE REPORT (nothing was saved)\n%', v_report;
end $$;
