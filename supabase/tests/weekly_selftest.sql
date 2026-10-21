-- =================================================================
-- SELF-TEST for 0052_personal_weekly_challenges.sql  (safe: everything is rolled back)
-- =================================================================
-- Run in the Supabase SQL Editor AFTER 0048-0052. It checks the weekly set per
-- member (2 normal + 1 big, configurable), every weekly's progress rules through
-- the real event engine, the week-long persistence, the expiry rules (no
-- Fragments for an unfinished weekly, a small consolation above 50%) and the
-- once-only claims. The "error" at the end IS the report; NOTHING is saved.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;

create or replace function pg_temp.givew(p_user uuid, p_def text) returns uuid as $$
declare d public.challenge_definitions;
begin
  select * into d from public.challenge_definitions where id = p_def;
  return public._new_assignment(d, p_user, p_user, 'W' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
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

do $$
declare
  v_report text := '';
  m1 uuid; m2 uuid;
  a uuid; b uuid; c uuid; v_res jsonb; v_err text; v_n int; v_w int; v_key text; v_prev text[]; v_now text[]; v_tiers text; v_repeat int := 0;
begin
  select p.id into m1 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m1 order by p.display_name limit 1;
  if m2 is null then raise exception 'ABORTED: need 2 members'; end if;
  v_report := format('tested as %s', (select display_name from public.profiles where id = m1)) || E'\n';
  delete from public.challenge_assignments;
  delete from public.challenge_events;
  delete from public.challenge_reward_grants;
  delete from public.gauntlet_fragments;
  update public.challenge_features set enabled = false;
  -- all features are off here, so the weekly pool is tiny: bring the hidden lore weekly back (0077) so there are enough to rotate
  update public.challenge_definitions set is_active = true where id = 'pw_lorekeeper';

  -- ===== A. the weekly set =====
  begin
    v_prev := '{}';
    for v_w in 0..5 loop
      perform public._ensure_challenge_assignments_for(m1, now() + make_interval(days => 7 * v_w));
      v_key := to_char((now() + make_interval(days => 7 * v_w)) at time zone 'Europe/Brussels', 'IYYY-"W"IW');
      select count(*), string_agg(coalesce(dd.weekly_tier, 'normal'), ',' order by coalesce(dd.weekly_tier, 'normal')), array_agg(x.definition_id order by x.definition_id)
        into v_n, v_tiers, v_now
        from public.challenge_assignments x join public.challenge_definitions dd on dd.id = x.definition_id
        where x.user_id = m1 and x.type = 'personal_weekly' and x.period_key = v_key;
      if v_n <> 3 or v_tiers <> 'big,normal,normal' then raise exception 'FAIL A: week +%: % weeklies with tiers %', v_w, v_n, v_tiers; end if;
      if 'pw_keeper_knowledge' = any (v_now) then raise exception 'FAIL A: the quiz weekly was assigned while the quiz switch is off'; end if;
      if v_now && v_prev then v_repeat := v_repeat + 1; end if;
      v_prev := v_now;
    end loop;
    if v_repeat > 0 then raise exception 'FAIL A: a weekly repeated in consecutive weeks (% times)', v_repeat; end if;
    -- calling it again changes nothing (reload / second tab)
    select count(*) into v_n from public.challenge_assignments where user_id = m1 and type = 'personal_weekly';
    perform public._ensure_challenge_assignments_for(m1, now());
    if (select count(*) from public.challenge_assignments where user_id = m1 and type = 'personal_weekly') <> v_n then raise exception 'FAIL A: a second call created more'; end if;
    -- configurable
    update public.challenge_config set value = '{"normal": 3, "big": 0}' where key = 'weekly_slots';
    perform public._ensure_challenge_assignments_for(m1, now() + interval '60 days');
    select count(*) into v_n from public.challenge_assignments where user_id = m1 and type = 'personal_weekly' and period_key = to_char((now() + interval '60 days') at time zone 'Europe/Brussels', 'IYYY-"W"IW');
    if v_n <> 3 then raise exception 'FAIL A: weekly_slots config ignored (% )', v_n; end if;
    v_report := v_report || 'PASS weekly set: 2 normal + 1 big every week for 6 weeks, no repeat in consecutive weeks, gated quiz weekly absent, idempotent, slots configurable' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== B. The Lorekeeper: three counters, dedupe, persistence, 2 Fragments =====
  begin
    a := pg_temp.givew(m1, 'pw_lorekeeper');
    perform pg_temp.ev(m1, 'nickname_created'); perform pg_temp.ev(m1, 'nickname_created'); perform pg_temp.ev(m1, 'nickname_created');
    if (pg_temp.cur(a)).progress <> 2 then raise exception 'FAIL B: the contribution counter should cap at 2, progress %', (pg_temp.cur(a)).progress; end if;
    perform pg_temp.ev(m1, 'anecdote_added'); perform pg_temp.ev(m1, 'quote_added');
    perform pg_temp.ev(m1, 'nickname_rated', 'nickname:A'); perform pg_temp.ev(m1, 'nickname_rated', 'nickname:A'); perform pg_temp.ev(m1, 'nickname_rated', 'nickname:B');
    if (pg_temp.cur(a)).progress <> 6 or (pg_temp.cur(a)).status <> 'active' then raise exception 'FAIL B: expected 6/7 active (same nickname rated twice counts once), got %', (pg_temp.cur(a)).progress; end if;
    if (pg_temp.cur(a)).part_progress->>'ratings' <> '2' then raise exception 'FAIL B: the week-long progress is not stored per counter'; end if;
    perform pg_temp.ev(m1, 'nickname_rated', 'nickname:C');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL B: not completed after all counters were met'; end if;
    if not exists (select 1 from jsonb_array_elements((pg_temp.cur(a)).reward->'lines') l where l->>'kind' = 'gauntlet_fragments' and (l->>'amount')::int = 2) then raise exception 'FAIL B: no 2 Fragments in the reward'; end if;
    perform pg_temp.imp(m1);
    perform public.claim_challenge(a);
    if (select fragments from public.gauntlet_fragments where user_id = m1) <> 2 then raise exception 'FAIL B: the 2 Fragments were not paid'; end if;
    if (public.claim_challenge(a))->>'status' <> 'already_claimed' then raise exception 'FAIL B: claimed twice'; end if;
    v_report := v_report || 'PASS 🏷️ The Lorekeeper  (3 counters with caps, a nickname rated twice counts once, progress stored, reward XP + 2 Fragments, claim once)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== C. Beer Explorer: DIFFERENT activities, not volume =====
  begin
    a := pg_temp.givew(m1, 'pw_beer_explorer');
    perform pg_temp.ev(m1, 'beer_rated', 'beer:1', '{"first":1}'); perform pg_temp.ev(m1, 'beer_rated', 'beer:2', '{"first":1}'); perform pg_temp.ev(m1, 'beer_rated', 'beer:3', '{"first":1}');
    if (pg_temp.cur(a)).progress <> 1 or (pg_temp.cur(a)).status <> 'active' then raise exception 'FAIL C: rating many beers must not complete it (progress %)', (pg_temp.cur(a)).progress; end if;
    perform pg_temp.ev(m1, 'beer_added');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL C: a second kind of beer activity did not complete it'; end if;
    if not exists (select 1 from jsonb_array_elements((pg_temp.cur(a)).reward->'lines') l where l->>'kind' = 'mystery' and (l->>'chance')::numeric > 0) then raise exception 'FAIL C: no Mystery chance'; end if;
    v_report := v_report || 'PASS 🍺 Beer Explorer  (needs two different kinds of activity: rating five beers is still 1/2; XP + Mystery chance, no alcohol volume anywhere)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== D. Poet Laureate + Agent of Chaos + Battle Hardened =====
  begin
    a := pg_temp.givew(m1, 'pw_poet_laureate');
    perform pg_temp.ev(m1, 'poem_created'); perform pg_temp.ev(m1, 'poem_commented', 'poem:X'); perform pg_temp.ev(m1, 'poem_commented', 'poem:X');
    if (pg_temp.cur(a)).progress <> 2 then raise exception 'FAIL D: the same poem commented twice counted twice (%)', (pg_temp.cur(a)).progress; end if;
    perform pg_temp.ev(m1, 'poem_created');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL D: Poet Laureate not completed'; end if;
    if not exists (select 1 from jsonb_array_elements((pg_temp.cur(a)).reward->'lines') l where l->>'kind' = 'gauntlet_fragments' and (l->>'amount')::int = 2) then raise exception 'FAIL D: no 2 Fragments'; end if;

    b := pg_temp.givew(m1, 'pw_agent_of_chaos');
    perform pg_temp.ev(m1, 'chaos_guess'); perform pg_temp.ev(m1, 'chaos_completed'); perform pg_temp.ev(m1, 'chaos_completed');
    if (pg_temp.cur(b)).progress <> 2 then raise exception 'FAIL D: only completed Chaos challenges count (%)', (pg_temp.cur(b)).progress; end if;
    perform pg_temp.ev(m1, 'chaos_completed');
    if (pg_temp.cur(b)).status <> 'completed' then raise exception 'FAIL D: Agent of Chaos not completed'; end if;

    c := pg_temp.givew(m1, 'pw_battle_hardened');
    perform pg_temp.ev(m1, 'battle_participated', 'battle:1'); perform pg_temp.ev(m1, 'battle_participated', 'battle:1');
    perform pg_temp.ev(m1, 'battle_won'); perform pg_temp.ev(m1, 'battle_won');
    if (pg_temp.cur(c)).progress <> 2 then raise exception 'FAIL D: a win must give ONE bonus step only (progress %)', (pg_temp.cur(c)).progress; end if;
    perform pg_temp.ev(m1, 'battle_participated', 'battle:2');
    if (pg_temp.cur(c)).status <> 'completed' then raise exception 'FAIL D: Battle Hardened not completed (1 battle + win + battle)'; end if;
    v_report := v_report || 'PASS ✍️ Poet Laureate / 🎭 Agent of Chaos / ⚔️ Battle Hardened  (dedupe per poem and battle, guesses are not Chaos challenges, a win is one bonus step, once)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== E. Adventurer, Social Creature, Completionist: DIFFERENT things =====
  begin
    a := pg_temp.givew(m1, 'pw_adventurer');
    perform pg_temp.ev(m1, 'daily_completed', 'a1', '{"definition_id":"pd_x"}'); perform pg_temp.ev(m1, 'daily_completed', 'a2', '{"definition_id":"pd_x"}'); perform pg_temp.ev(m1, 'daily_completed', 'a3', '{"definition_id":"pd_x"}');
    if (pg_temp.cur(a)).progress <> 1 then raise exception 'FAIL E: the same Daily type counted more than once (%)', (pg_temp.cur(a)).progress; end if;
    perform pg_temp.ev(m1, 'daily_completed', 'a4', '{"definition_id":"pd_b"}'); perform pg_temp.ev(m1, 'daily_completed', 'a5', '{"definition_id":"pd_c"}');
    perform pg_temp.ev(m1, 'daily_completed', 'a6', '{"definition_id":"pd_d"}');
    if (pg_temp.cur(a)).status <> 'active' or (pg_temp.cur(a)).progress <> 4 then raise exception 'FAIL E: expected 4/5, got %', (pg_temp.cur(a)).progress; end if;
    perform pg_temp.ev(m1, 'daily_completed', 'a7', '{"definition_id":"pd_e"}');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL E: Adventurer not completed with 5 different Dailies'; end if;

    b := pg_temp.givew(m1, 'pw_social_creature'); c := pg_temp.givew(m1, 'pw_completionist');
    perform pg_temp.ev(m1, 'nickname_rated', 'n:1'); perform pg_temp.ev(m1, 'nickname_created');            -- both nickname
    if (pg_temp.cur(b)).progress <> 1 then raise exception 'FAIL E: two nickname actions are still one category (%)', (pg_temp.cur(b)).progress; end if;
    perform pg_temp.ev(m1, 'poem_created'); perform pg_temp.ev(m1, 'beer_added');
    if (pg_temp.cur(b)).status <> 'completed' or (pg_temp.cur(c)).progress <> 3 then raise exception 'FAIL E: Social Creature at 3 categories / Completionist at 3, got % / %', (pg_temp.cur(b)).progress, (pg_temp.cur(c)).progress; end if;
    perform pg_temp.ev(m1, 'battle_voted', 'b:1');
    if (pg_temp.cur(c)).status <> 'active' then raise exception 'FAIL E: Completionist done at 4 categories'; end if;
    perform pg_temp.ev(m1, 'chaos_completed');
    if (pg_temp.cur(c)).status <> 'completed' then raise exception 'FAIL E: Completionist not done at 5 categories'; end if;
    v_n := (select count(*) from jsonb_array_elements((pg_temp.cur(c)).reward->'lines') l where l->>'kind' = 'gauntlet_fragments' and (l->>'amount')::int = 3);
    if v_n <> 1 or not exists (select 1 from jsonb_array_elements((pg_temp.cur(c)).reward->'lines') l where l->>'kind' = 'mystery' and (coalesce((l->>'chance')::numeric, 1) >= 0.5 or l ? 'rarity_floor')) then raise exception 'FAIL E: Completionist reward should be XP + 3 Fragments + a raised Mystery chance'; end if;
    v_report := v_report || 'PASS 🧭 Adventurer / 🌍 Social Creature / 🏆 Completionist  (the same Daily or category twice counts once, 3 and 5 different categories, Completionist pays XP + 3 Fragments + raised Mystery chance)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== F. Keeper of Knowledge: 3 quizzes AND an average of 70% =====
  begin
    a := pg_temp.givew(m1, 'pw_keeper_knowledge');
    perform pg_temp.ev(m1, 'quiz_completed', null, '{"pct":50}'); perform pg_temp.ev(m1, 'quiz_completed', null, '{"pct":60}'); perform pg_temp.ev(m1, 'quiz_completed', null, '{"pct":60}');
    if (pg_temp.cur(a)).progress <> 3 or (pg_temp.cur(a)).status <> 'active' then raise exception 'FAIL F: 3 quizzes at 57%% average must not complete it'; end if;
    perform pg_temp.ev(m1, 'quiz_completed', null, '{"pct":100}');
    if (pg_temp.cur(a)).status <> 'active' then raise exception 'FAIL F: completed at a 67.5%% average'; end if;
    perform pg_temp.ev(m1, 'quiz_completed', null, '{"pct":100}');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL F: not completed at a 74%% average'; end if;
    v_report := v_report || 'PASS 🧠 Keeper of Knowledge  (3 quizzes are not enough below an average of 70%, more quizzes can lift the average; note: it is only assigned while the quiz switch is on)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== G. the end of the week: no full reward, no Fragments, a small consolation =====
  begin
    perform pg_temp.imp(m1);
    a := pg_temp.givew(m1, 'pw_adventurer');                                    -- big: consolation 10 XP
    perform pg_temp.ev(m1, 'daily_completed', 'a1', '{"definition_id":"pd_a"}'); perform pg_temp.ev(m1, 'daily_completed', 'a2', '{"definition_id":"pd_b"}');
    perform pg_temp.ev(m1, 'daily_completed', 'a3', '{"definition_id":"pd_c"}');
    b := pg_temp.givew(m1, 'pw_adventurer');                                    -- a second copy would be refused by the unique index, so use another
    update public.challenge_assignments set expires_at = now() - interval '1 minute' where id = a;
    -- progress stops when the week is over
    perform pg_temp.ev(m1, 'daily_completed', 'a4', '{"definition_id":"pd_d"}'); perform pg_temp.ev(m1, 'daily_completed', 'a5', '{"definition_id":"pd_e"}');
    if (pg_temp.cur(a)).progress <> 3 or (pg_temp.cur(a)).status = 'completed' then raise exception 'FAIL G: an expired weekly kept progressing / completed'; end if;
    v_res := public.claim_challenge(a);
    if v_res->>'status' <> 'consolation' then raise exception 'FAIL G: 3/5 should offer a consolation: %', v_res; end if;
    if (select sum(amount) from public.challenge_reward_grants where assignment_id = a and kind = 'player_xp') <> 10 then raise exception 'FAIL G: the consolation should be 10 XP'; end if;
    if exists (select 1 from public.challenge_reward_grants where assignment_id = a and kind <> 'player_xp') then raise exception 'FAIL G: the consolation paid more than XP'; end if;
    if coalesce((select fragments from public.gauntlet_fragments where user_id = m1), 0) <> 0 then raise exception 'FAIL G: a Fragment was paid for an unfinished weekly'; end if;
    if (public.claim_challenge(a))->>'status' <> 'already_claimed' then raise exception 'FAIL G: the consolation paid twice'; end if;
    -- under the threshold: nothing
    c := pg_temp.givew(m1, 'pw_poet_laureate');
    perform pg_temp.ev(m1, 'poem_created');                                      -- 1 of 3 = 33%
    update public.challenge_assignments set expires_at = now() - interval '1 minute' where id = c;
    v_err := null; begin perform public.claim_challenge(c); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL G: 33%% progress still got a reward'; end if;
    -- an active weekly cannot be claimed early
    b := pg_temp.givew(m1, 'pw_agent_of_chaos');
    perform pg_temp.ev(m1, 'chaos_completed'); perform pg_temp.ev(m1, 'chaos_completed');
    v_err := null; begin perform public.claim_challenge(b); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL G: a running weekly could be claimed early'; end if;
    -- another member cannot claim mine
    perform pg_temp.imp(m2);
    v_err := null; begin perform public.claim_challenge(a); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL G: another user claimed my weekly'; end if;
    v_report := v_report || 'PASS expiry  (nothing progresses after the week, 3/5 gets a 10 XP consolation once, 33% gets nothing, never a Fragment, no early or foreign claims)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  raise exception E'WEEKLY REPORT (nothing was saved)\n%', v_report;
end $$;
