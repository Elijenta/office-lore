-- =================================================================
-- SELF-TEST for 0051_group_daily_challenge.sql  (safe: everything is rolled back)
-- =================================================================
-- Run in the Supabase SQL Editor AFTER 0048-0051. Two real members play the shared
-- Daily through the real RPCs: exactly one per day, entries, anonymous voting, the
-- vote rules, winners, participation vs winner rewards, the quiz clock. The
-- "error" at the end IS the report; NOTHING is saved.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;

create or replace function pg_temp.try(p_sql text) returns text as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end;
$$ language plpgsql;

-- today's shared Daily of a given kind (a fresh one each call)
create or replace function pg_temp.round_of(p_def text) returns uuid as $$
declare
  d public.challenge_definitions;
  a public.challenge_assignments;
  v_key text := 'G' || substr(md5(random()::text), 1, 10);
begin
  delete from public.challenge_assignments where type = 'group_daily';
  select * into d from public.challenge_definitions where id = p_def;
  insert into public.challenge_assignments
    (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
     target, period_key, starts_at, expires_at, completion, payload)
  values ('officelore', d.id, null, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.event_types, d.icon, d.requirements,
          public._assignment_reward(d), d.target, v_key, now() - interval '1 hour', now() + interval '20 hours', d.completion, public._group_payload(d, v_key))
  returning * into a;
  return (public._ensure_group_round(a.id)).id;
end;
$$ language plpgsql;

create or replace function pg_temp.end_round(p_round uuid) returns void as $$
begin
  update public.group_daily_rounds set ends_at = now() - interval '1 minute' where id = p_round;
  update public.challenge_assignments set expires_at = now() - interval '1 minute'
    where id = (select assignment_id from public.group_daily_rounds where id = p_round);
end;
$$ language plpgsql;

do $$
declare
  v_report text := '';
  m1 uuid; m2 uuid;
  rd uuid; v_json jsonb; v_cur jsonb; v_e1 uuid; v_e2 uuid; v_err text; v_n int; v_res jsonb;
  v_day int; v_def text; v_prev text; v_count int; v_repeat int := 0; q jsonb; v_ans jsonb; v_wrong jsonb;
  v_jpg constant text := 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP';
begin
  select p.id into m1 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m1 order by p.display_name limit 1;
  if m2 is null then raise exception 'ABORTED: need 2 members'; end if;
  v_report := format('tested as %s and %s', (select display_name from public.profiles where id = m1), (select display_name from public.profiles where id = m2)) || E'\n';
  delete from public.challenge_assignments;
  delete from public.challenge_reward_grants;
  delete from public.gauntlet_fragments;

  -- ===== A. exactly one shared Daily a day, the same for every member =====
  begin
    v_prev := null;
    for v_day in 0..9 loop
      perform public._ensure_challenge_assignments_for(m1, now() + make_interval(days => v_day));
      perform public._ensure_challenge_assignments_for(m2, now() + make_interval(days => v_day));
      select count(*), min(definition_id) into v_count, v_def from public.challenge_assignments
        where type = 'group_daily' and user_id is null and period_key = to_char((now() + make_interval(days => v_day)) at time zone 'Europe/Brussels', 'YYYY-MM-DD');
      if v_count <> 1 then raise exception 'FAIL A: day +%: % shared Dailies instead of exactly 1', v_day, v_count; end if;
      if v_def is not distinct from v_prev then v_repeat := v_repeat + 1; end if;
      v_prev := v_def;
    end loop;
    if v_repeat > 0 then raise exception 'FAIL A: the same shared Daily came two days in a row (% times)', v_repeat; end if;
    if exists (select 1 from public.challenge_assignments where type = 'group_daily' and user_id is not null) then raise exception 'FAIL A: a group Daily was assigned to one user'; end if;
    if (select count(distinct definition_id) from public.challenge_assignments where type = 'group_daily') < 2 then raise exception 'FAIL A: no variety over 10 days'; end if;
    v_report := v_report || 'PASS exactly one shared Daily per day for the whole workspace (10 days, both members, no repeat two days running, owned by nobody)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== B. Nickname of the Day: entry, anonymous vote, winner, rewards =====
  begin
    rd := pg_temp.round_of('gd_nickname_of_the_day');
    perform pg_temp.imp(m1);
    v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, null)', rd, '{"text":"x"}'));
    if v_err is null then raise exception 'FAIL B: a 1-character nickname was accepted'; end if;
    v_res := public.submit_group_entry(rd, '{"text":"Sir Toastalot"}', null); v_e1 := (v_res->>'id')::uuid;
    v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, null)', rd, '{"text":"Another One"}'));
    if v_err is null then raise exception 'FAIL B: a second entry was accepted'; end if;
    v_err := pg_temp.try(format('select public.vote_group_entry(%L, %L)', rd, v_e1));
    if v_err is null then raise exception 'FAIL B: voted for myself'; end if;
    perform pg_temp.imp(m2);
    v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, null)', rd, '{"text":"sir toastalot"}'));
    if v_err is null then raise exception 'FAIL B: an identical idea was accepted'; end if;
    -- while open: anonymous entries, no counts
    v_cur := (public.get_group_daily())->'current';
    if (v_cur->'entries'->0) ? 'user_id' then raise exception 'FAIL B: entries are not anonymous while voting'; end if;
    if (v_cur->'entries'->0) ? 'votes' then raise exception 'FAIL B: vote counts are visible while voting'; end if;
    v_res := public.submit_group_entry(rd, '{"text":"Madame Brewfoam"}', null); v_e2 := (v_res->>'id')::uuid;
    v_err := pg_temp.try(format('select public.vote_group_entry(%L, %L)', rd, v_e2));
    if v_err is null then raise exception 'FAIL B: m2 voted for their own entry'; end if;
    perform public.vote_group_entry(rd, v_e1);
    v_err := pg_temp.try(format('select public.vote_group_entry(%L, %L)', rd, v_e2));
    if v_err is null then raise exception 'FAIL B: a second vote was accepted'; end if;
    if (select count(*) from public.group_daily_votes where round_id = rd and voter_id = m2) <> 1 then raise exception 'FAIL B: double vote stored'; end if;
    -- a winner does not exist before the day ends
    if exists (select 1 from public.group_daily_winners where round_id = rd) then raise exception 'FAIL B: a winner before the end'; end if;
    perform pg_temp.end_round(rd);
    v_json := public.get_group_daily();
    if (v_json->'previous'->>'id')::uuid is distinct from rd or v_json->'previous'->>'status' <> 'finalized' then raise exception 'FAIL B: the round was not finalized after the end'; end if;
    if v_json->'previous'->'winners' <> to_jsonb(array[m1]) then raise exception 'FAIL B: the winner should be the entry with the vote: %', v_json->'previous'->'winners'; end if;
    if not (v_json->'previous'->'entries'->0) ? 'user_id' then raise exception 'FAIL B: authors are not revealed after the end'; end if;
    v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, null)', rd, '{"text":"Too Late"}'));
    -- participation: both claim once; winner bonus: only the winner, once, and no Gauntlet Fragment
    v_res := public.claim_challenge((select assignment_id from public.group_daily_rounds where id = rd));
    if v_res->>'status' <> 'claimed' then raise exception 'FAIL B: m2 could not claim the participation reward: %', v_res; end if;
    if (public.claim_challenge((select assignment_id from public.group_daily_rounds where id = rd)))->>'status' <> 'already_claimed' then raise exception 'FAIL B: claimed twice'; end if;
    v_err := pg_temp.try(format('select public.claim_group_winner(%L)', rd));
    if v_err is null then raise exception 'FAIL B: the runner-up claimed the winner reward'; end if;
    perform pg_temp.imp(m1);
    if (public.claim_challenge((select assignment_id from public.group_daily_rounds where id = rd)))->>'status' <> 'claimed' then raise exception 'FAIL B: the winner could not claim participation'; end if;
    if (public.claim_group_winner(rd))->>'status' <> 'claimed' then raise exception 'FAIL B: the winner could not claim the bonus'; end if;
    if (public.claim_group_winner(rd))->>'status' <> 'already_claimed' then raise exception 'FAIL B: the winner bonus paid twice'; end if;
    select sum(amount) into v_n from public.challenge_reward_grants where user_id = m1 and kind = 'player_xp';
    if v_n <> 45 then raise exception 'FAIL B: winner XP should be 15 + 30, got %', v_n; end if;
    if exists (select 1 from public.challenge_reward_grants where kind = 'gauntlet_fragments') then raise exception 'FAIL B: a Gauntlet Fragment was paid by default'; end if;
    v_report := v_report || 'PASS 🏷️ Nickname of the Day  (valid entries only, one each, no copies, anonymous while open, no self-vote, one vote, winner after the end, participation 15 XP for everyone + winner 30 XP once, no Fragment)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== C. nobody wins alone, nobody wins without votes =====
  begin
    rd := pg_temp.round_of('gd_emoji_showdown');
    perform pg_temp.imp(m1);
    v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, null)', rd, '{"emoji":"abc"}'));
    if v_err is null then raise exception 'FAIL C: letters accepted as emoji'; end if;
    v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, null)', rd, jsonb_build_object('emoji', '😀🍺👑🔥🎉🙈')::text));
    if v_err is null then raise exception 'FAIL C: 6 emoji accepted'; end if;
    perform public.submit_group_entry(rd, '{"emoji":"😀🍺👑"}', null);
    perform pg_temp.end_round(rd);
    perform public.get_group_daily();
    if exists (select 1 from public.group_daily_winners where round_id = rd) then raise exception 'FAIL C: somebody won alone'; end if;
    if (select no_winner_reason from public.group_daily_rounds where id = rd) is null then raise exception 'FAIL C: no reason recorded'; end if;
    -- two entries but no votes
    rd := pg_temp.round_of('gd_emoji_showdown');
    perform public.submit_group_entry(rd, '{"emoji":"🍺"}', null);
    perform pg_temp.imp(m2);
    perform public.submit_group_entry(rd, '{"emoji":"👑"}', null);
    perform pg_temp.end_round(rd);
    perform public.get_group_daily();
    if exists (select 1 from public.group_daily_winners where round_id = rd) then raise exception 'FAIL C: a winner without a single vote'; end if;
    -- a tie on votes gives co-winners
    rd := pg_temp.round_of('gd_emoji_showdown');
    perform pg_temp.imp(m1); v_e1 := (public.submit_group_entry(rd, '{"emoji":"🍺"}', null)->>'id')::uuid;
    perform pg_temp.imp(m2); v_e2 := (public.submit_group_entry(rd, '{"emoji":"👑"}', null)->>'id')::uuid;
    perform public.vote_group_entry(rd, v_e1);
    perform pg_temp.imp(m1); perform public.vote_group_entry(rd, v_e2);
    perform pg_temp.end_round(rd);
    perform public.get_group_daily();
    if (select count(*) from public.group_daily_winners where round_id = rd) <> 2 then raise exception 'FAIL C: a tie should give co-winners'; end if;
    v_report := v_report || 'PASS 😀 Emoji Showdown + winner rules  (emoji only, <= 5, no winner alone, no winner without a vote, ties = co-winners)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== D. Poetry + Daily Chaos validation =====
  begin
    rd := pg_temp.round_of('gd_poetry_showdown');
    perform pg_temp.imp(m1);
    v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, null)', rd, '{"text":"too short"}'));
    if v_err is null then raise exception 'FAIL D: a 9-character poem was accepted'; end if;
    perform public.submit_group_entry(rd, '{"text":"Roses are red, the coffee is cold, the stapler is lost, and the meeting is old."}', null);
    rd := pg_temp.round_of('gd_daily_chaos');
    if rd is null then raise exception 'FAIL D: no chaos round'; end if;
    if (select prompt->>'sub' from public.group_daily_rounds where id = rd) = 'photo' then
      v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, null)', rd, '{"note":"x"}'));
      if v_err is null then raise exception 'FAIL D: a photo round accepted no photo'; end if;
      v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, %L)', rd, '{}', 'http://x/y.jpg'));
      if v_err is null then raise exception 'FAIL D: a url was accepted as photo'; end if;
      perform public.submit_group_entry(rd, '{}', v_jpg || 'AA');
    else
      v_err := pg_temp.try(format('select public.submit_group_entry(%L, %L::jsonb, null)', rd, '{"text":"short"}'));
      if v_err is null then raise exception 'FAIL D: a short decree was accepted'; end if;
      perform public.submit_group_entry(rd, '{"text":"By royal order every chair shall now face the window."}', null);
    end if;
    v_report := v_report || 'PASS ✍️ Poetry Showdown / 🎭 Daily Chaos  (length and word limits, photo rounds need a real image)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== E. Daily Lore Quiz: private answers, server clock, score then speed =====
  begin
    if (select count(distinct btrim(person_real_name)) from public.nicknames where status = 'Actief' and btrim(person_real_name) <> '') < 4 then
      v_report := v_report || 'SKIP quiz: needs 4 different people on the Nickname Wall' || E'\n';
    else
      rd := pg_temp.round_of('gd_lore_quiz');
      perform pg_temp.imp(m1);
      v_cur := (public.get_group_daily())->'current';
      if jsonb_array_length(v_cur->'questions') <> 5 then raise exception 'FAIL E: expected 5 questions'; end if;
      if v_cur::text ~ '"answers"' then raise exception 'FAIL E: the answer key leaked to the client'; end if;
      select answers into v_ans from public.group_daily_secrets where round_id = rd;
      v_err := pg_temp.try(format('select public.submit_group_quiz(%L, %L::jsonb)', rd, v_ans::text));
      if v_err is null then raise exception 'FAIL E: submitted without starting'; end if;
      perform public.start_group_quiz(rd);
      v_err := pg_temp.try(format('select public.submit_group_quiz(%L, %L::jsonb)', rd, '[0,1]'));
      if v_err is null then raise exception 'FAIL E: a short answer list was accepted'; end if;
      v_res := public.submit_group_quiz(rd, v_ans);
      if (v_res->>'score')::int <> 5 then raise exception 'FAIL E: a perfect run did not score 5: %', v_res; end if;
      v_err := pg_temp.try(format('select public.submit_group_quiz(%L, %L::jsonb)', rd, v_ans::text));
      if v_err is null then raise exception 'FAIL E: took the quiz twice'; end if;
      perform pg_temp.imp(m2);
      perform public.start_group_quiz(rd);
      select jsonb_agg((((x)::int + 1) % 4)) into v_wrong from jsonb_array_elements_text(v_ans) x;
      v_res := public.submit_group_quiz(rd, v_ans);       -- also 5/5, to test the tie-break on speed
      update public.group_daily_entries set duration_ms = 9000 where round_id = rd and user_id = m1;
      update public.group_daily_entries set duration_ms = 4000 where round_id = rd and user_id = m2;
      perform pg_temp.end_round(rd);
      v_json := public.get_group_daily();
      if v_json->'previous'->'winners' <> to_jsonb(array[m2]) then raise exception 'FAIL E: the faster perfect run should win: %', v_json->'previous'->'winners'; end if;
      v_report := v_report || 'PASS 🧠 Daily Lore Quiz  (5 questions, answers never sent, must start first, one attempt, highest score wins, the faster server-measured run breaks a tie)' || E'\n';
    end if;
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  raise exception E'GROUP DAILY REPORT (nothing was saved)\n%', v_report;
end $$;
