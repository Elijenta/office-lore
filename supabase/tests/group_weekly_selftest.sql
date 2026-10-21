-- =================================================================
-- SELF-TEST for 0053_group_weekly_quests.sql  (safe: everything is rolled back)
-- =================================================================
-- Run in the Supabase SQL Editor AFTER 0048-0053. Real members, real events, the
-- real engine: the participant set, every group rule, late joiners, the shared
-- quiz average, and the once-only claims. The "error" at the end IS the report;
-- NOTHING is saved.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;

create or replace function pg_temp.givegw(p_def text) returns uuid as $$
declare d public.challenge_definitions;
begin
  select * into d from public.challenge_definitions where id = p_def;
  return public._new_assignment(d, null, (select user_id from public.app_memberships where app_id = 'officelore' and is_active limit 1),
                                'GW' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
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
  m1 uuid; m2 uuid; v_members int;
  a uuid; b uuid; r jsonb; v_rid uuid; v_ans jsonb; v_wrong jsonb; v_err text; v_n int;
begin
  select p.id into m1 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m1 order by p.display_name limit 1;
  if m2 is null then raise exception 'ABORTED: need 2 members'; end if;
  select count(*) into v_members from public.app_memberships where app_id = 'officelore' and is_active;
  v_report := format('tested with %s active members', v_members) || E'\n';
  delete from public.challenge_assignments;
  delete from public.challenge_events;
  delete from public.challenge_reward_grants;
  delete from public.gauntlet_fragments;

  -- ===== A. generation: shared by everybody, one participant set =====
  begin
    perform public._ensure_challenge_assignments_for(m1, now());
    perform public._ensure_challenge_assignments_for(m2, now());
    select count(*) into v_n from public.challenge_assignments where type = 'group_weekly' and user_id is null
      and period_key = to_char(now() at time zone 'Europe/Brussels', 'IYYY-"W"IW');
    if v_n <> public._challenge_slots('group_weekly') then raise exception 'FAIL A: % group weeklies instead of %', v_n, public._challenge_slots('group_weekly'); end if;
    if exists (select 1 from public.challenge_assignments g where g.type = 'group_weekly' and g.group_rule is not null
               and (select count(*) from public.challenge_member_progress mp where mp.assignment_id = g.id) <> v_members) then
      raise exception 'FAIL A: the participant set is not the active members'; end if;
    if exists (select 1 from public.challenge_assignments where type = 'group_weekly' and group_rule is null) then raise exception 'FAIL A: an old group weekly is still being assigned'; end if;
    v_report := v_report || 'PASS generation: the configured number of Group Weeklies, created once for the whole workspace (two members asked), participant set = the active members' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== B. The Fellowship: everybody, per person, claim once each =====
  begin
    a := pg_temp.givegw('gw_fellowship');
    if (pg_temp.cur(a)).target <> v_members then raise exception 'FAIL B: target should be the number of participants'; end if;
    perform pg_temp.ev(m1, 'daily_completed', 'd1'); perform pg_temp.ev(m1, 'daily_completed', 'd2');
    if (pg_temp.cur(a)).progress <> 1 or (pg_temp.cur(a)).status <> 'active' then raise exception 'FAIL B: one member done is 1/% and not complete', v_members; end if;
    if (select amount from public.challenge_member_progress where assignment_id = a and user_id = m1) <> 2 then raise exception 'FAIL B: per-person progress not stored'; end if;
    -- everybody else
    for r in select to_jsonb(x) from (select user_id from public.challenge_member_progress where assignment_id = a and user_id <> m1) x loop
      perform pg_temp.ev((r->>'user_id')::uuid, 'daily_completed', 'dd');
    end loop;
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL B: not completed after every participant did one Daily'; end if;
    perform pg_temp.imp(m1);
    if (public.claim_challenge(a))->>'status' <> 'claimed' then raise exception 'FAIL B: m1 could not claim'; end if;
    if (public.claim_challenge(a))->>'status' <> 'already_claimed' then raise exception 'FAIL B: m1 claimed twice'; end if;
    perform pg_temp.imp(m2);
    if (public.claim_challenge(a))->>'status' <> 'claimed' then raise exception 'FAIL B: m2 could not claim'; end if;
    if (select fragments from public.gauntlet_fragments where user_id = m2) <> 1 then raise exception 'FAIL B: every participant gets 1 Fragment'; end if;
    if (select count(*) from public.challenge_reward_grants where assignment_id = a and kind = 'player_xp' and user_id = m2) <> 1 then raise exception 'FAIL B: no Player XP'; end if;
    v_report := v_report || 'PASS 🤝 The Fellowship  (per-person progress, completes only when EVERY participant did one Daily, each participant claims XP + 1 Fragment + Mystery chance exactly once)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== C. a member who joins later can not corrupt the quest =====
  begin
    a := pg_temp.givegw('gw_poets');
    if (pg_temp.cur(a)).title not like 'The % Poets' then raise exception 'FAIL C: the title does not follow the head count: %', (pg_temp.cur(a)).title; end if;
    -- simulate a late joiner: m2 is not in the participant set
    delete from public.challenge_member_progress where assignment_id = a and user_id = m2;
    perform pg_temp.ev(m2, 'poem_created');
    if exists (select 1 from public.challenge_member_progress where assignment_id = a and user_id = m2) then raise exception 'FAIL C: a late joiner got a row'; end if;
    perform pg_temp.imp(m2);
    v_err := null; begin perform public.claim_challenge(a); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL C: a non-participant claimed'; end if;
    -- the others still finish it (the late joiner is not awaited and not counted)
    for r in select to_jsonb(x) from (select user_id from public.challenge_member_progress where assignment_id = a) x loop
      perform pg_temp.ev((r->>'user_id')::uuid, 'poem_created');
    end loop;
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL C: the quest could not finish for the original participants'; end if;
    v_report := v_report || 'PASS participant set  (events and claims of someone outside it are ignored, the quest still completes for the original members, the title follows the head count: ' || (pg_temp.cur(a)).title || ')' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== D. Nickname Factory: shared progress =====
  begin
    a := pg_temp.givegw('gw_nickname_factory');
    perform pg_temp.ev(m1, 'nickname_created'); perform pg_temp.ev(m1, 'quote_added'); perform pg_temp.ev(m2, 'anecdote_added');
    if (pg_temp.cur(a)).progress <> 3 or (pg_temp.cur(a)).target <> 5 then raise exception 'FAIL D: expected 3/5, got %/%', (pg_temp.cur(a)).progress, (pg_temp.cur(a)).target; end if;
    if (select amount from public.challenge_member_progress where assignment_id = a and user_id = m1) <> 2 then raise exception 'FAIL D: per-person contributions missing'; end if;
    perform pg_temp.ev(m2, 'nickname_created'); perform pg_temp.ev(m1, 'nickname_created'); perform pg_temp.ev(m1, 'nickname_created');
    if (pg_temp.cur(a)).status <> 'completed' or (pg_temp.cur(a)).progress <> 5 then raise exception 'FAIL D: not complete at 5 (%)', (pg_temp.cur(a)).progress; end if;
    v_report := v_report || 'PASS 🏭 Nickname Factory  (the group pools nickname / anecdote / quote contributions: 3/5, then complete at 5, per-person amounts kept)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== E. The Gathering: the SAME session =====
  begin
    a := pg_temp.givegw('gw_gathering');
    perform pg_temp.ev(m1, 'beer_session_participated', 'session:S1', '{"session_id":"S1"}');
    perform pg_temp.ev(m2, 'beer_session_participated', 'session:S2', '{"session_id":"S2"}');
    if (pg_temp.cur(a)).status <> 'active' or (pg_temp.cur(a)).progress <> 1 then raise exception 'FAIL E: two members at two different sessions are not a gathering (%)', (pg_temp.cur(a)).progress; end if;
    perform pg_temp.ev(m2, 'beer_session_participated', 'session:S1', '{"session_id":"S1"}');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL E: two members at the same session did not complete it'; end if;
    v_report := v_report || 'PASS 🍻 The Gathering  (counts existing session attendance of the SAME session, different sessions do not add up, no drinking amounts involved)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== F. The Council: one quiz for all, the average decides =====
  begin
    if (select count(distinct btrim(person_real_name)) from public.nicknames where status = 'Actief' and btrim(person_real_name) <> '') < 4 then
      v_report := v_report || 'SKIP The Council: needs 4 different people on the Nickname Wall' || E'\n';
    else
      a := pg_temp.givegw('gw_council');
      perform pg_temp.imp(m1);
      r := public.get_group_weekly_round(a);
      v_rid := (r->>'id')::uuid;
      if jsonb_array_length(r->'questions') <> 5 then raise exception 'FAIL F: expected 5 questions'; end if;
      select answers into v_ans from public.group_daily_secrets where round_id = v_rid;
      select jsonb_agg(((x::int + 1) % 4)) into v_wrong from jsonb_array_elements_text(v_ans) x;
      perform public.start_group_quiz(v_rid);
      perform public.submit_group_quiz(v_rid, v_ans);                                   -- m1: 100%
      if (pg_temp.cur(a)).status <> 'active' then raise exception 'FAIL F: complete before everybody played'; end if;
      for r in select to_jsonb(x) from (select user_id from public.challenge_member_progress where assignment_id = a and user_id <> m1) x loop
        perform pg_temp.imp((r->>'user_id')::uuid);
        perform public.start_group_quiz(v_rid);
        perform public.submit_group_quiz(v_rid, v_wrong);                               -- everybody else: 0%
      end loop;
      -- everyone played, the average is below 75%: not complete
      if (pg_temp.cur(a)).status = 'completed' and 100.0 / v_members < 75 then raise exception 'FAIL F: completed under the 75%% average'; end if;
      if (pg_temp.cur(a)).progress <> v_members then raise exception 'FAIL F: progress should be the number who played (%)', (pg_temp.cur(a)).progress; end if;
      if exists (select 1 from public.group_daily_winners w where w.round_id = v_rid) then raise exception 'FAIL F: the weekly quiz created a daily winner'; end if;
      perform public._finalize_due_group_rounds();
      -- second quest: everybody perfect -> complete
      delete from public.challenge_assignments where id = a;
      a := pg_temp.givegw('gw_council');
      perform pg_temp.imp(m1);
      v_rid := (public.get_group_weekly_round(a)->>'id')::uuid;
      select answers into v_ans from public.group_daily_secrets where round_id = v_rid;
      for r in select to_jsonb(x) from (select user_id from public.challenge_member_progress where assignment_id = a) x loop
        perform pg_temp.imp((r->>'user_id')::uuid);
        perform public.start_group_quiz(v_rid);
        perform public.submit_group_quiz(v_rid, v_ans);
      end loop;
      if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL F: everybody at 100%% did not complete the Council'; end if;
      v_report := v_report || 'PASS 🏛️ The Council  (the same quiz for all, awaits every participant, average below 75% does not complete it, everybody perfect does, no daily winner is created)' || E'\n';
    end if;
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  raise exception E'GROUP WEEKLY REPORT (nothing was saved)\n%', v_report;
end $$;
