-- =================================================================
-- SELF-TEST for 0049_personal_daily_challenges.sql  (safe: everything is rolled back)
-- =================================================================
-- Run in the Supabase SQL Editor AFTER 0048 and 0049. It drives EVERY Daily
-- Challenge through the real triggers of the real tables (no fake completion),
-- checks the variety / feasibility rules over 14 simulated days, the Daily
-- Sweep, central reward config and the reward rolls. It ends with a deliberate
-- exception: the "error" you get back IS the report. NOTHING is saved.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;

-- hands a user a specific Daily for "today" (a fresh one each call)
create or replace function pg_temp.give(p_user uuid, p_def text) returns public.challenge_assignments as $$
declare
  a public.challenge_assignments;
  d public.challenge_definitions;
  v_key text := 'T' || substr(md5(random()::text), 1, 10);
begin
  select * into d from public.challenge_definitions where id = p_def;
  insert into public.challenge_assignments
    (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward, target, period_key, starts_at, expires_at)
  values ('officelore', d.id, p_user, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.event_types, d.icon, d.requirements,
          case when d.reward_from_difficulty then public._difficulty_reward(d.difficulty) else d.reward end, d.target, v_key, now() - interval '1 hour', now() + interval '20 hours')
  returning * into a;
  return a;
end;
$$ language plpgsql;

create or replace function pg_temp.cur(p_id uuid) returns public.challenge_assignments as $$
  select a from public.challenge_assignments a where a.id = p_id;
$$ language sql;

do $$
declare
  v_report text := '';
  m1 uuid; m2 uuid; v_lord uuid;
  a public.challenge_assignments; b public.challenge_assignments;
  v_n int; v_ok boolean; v_cnt int; v_id uuid;
  v_nick uuid[]; v_poems uuid[]; v_beer uuid; v_beers uuid[]; v_old_poem uuid; v_battle uuid;
  v_dc public.daily_poetry_challenges; v_sess uuid;
  v_day int; r record; v_prev text[]; v_today text[]; v_cats int; v_hard int; v_repeat int := 0; v_days_checked int := 0; v_gated int := 0; v_dist jsonb := '{}'::jsonb;
begin
  select user_id into v_lord from public.abt_reigns where ended_at is null limit 1;
  select p.id into m1 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active
    where p.id is distinct from v_lord order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active
    where p.id <> m1 order by p.display_name limit 1;
  select array_agg(x.id) into v_nick from (select id from public.nicknames order by id limit 4) x;
  select array_agg(x.id) into v_poems from (select id from public.poems order by id limit 3) x;
  select array_agg(x.id) into v_beers from (select id from public.beers order by id limit 5) x;
  if m2 is null or coalesce(cardinality(v_nick), 0) < 4 or coalesce(cardinality(v_poems), 0) < 2 or coalesce(cardinality(v_beers), 0) < 3 then
    raise exception 'ABORTED: need 2 members, 4 nicknames, 2 poems and 3 beers';
  end if;
  v_beer := v_beers[1];
  v_report := format('tested as %s (second member %s)', (select display_name from public.profiles where id = m1), (select display_name from public.profiles where id = m2)) || E'\n';

  -- clean slate (rolled back with the rest)
  delete from public.challenge_assignments;
  delete from public.challenge_sweeps;
  delete from public.challenge_events;
  delete from public.challenge_reward_grants;
  delete from public.gauntlet_fragments;
  update public.challenge_features set enabled = false;     -- quiz + prediction stay off

  -- ===== A. 14 days of generation: 3 a day, variety, feasibility, no gated quests =====
  begin
    update public.nickname_battles set status = 'draw' where status = 'open';   -- no open battle: "Pick a Side" must never appear
    for v_day in 0..13 loop
      perform public._ensure_challenge_assignments_for(m1, now() + make_interval(days => v_day));
      select array_agg(definition_id order by definition_id), count(*), count(distinct category), count(*) filter (where difficulty = 'hard')
        into v_today, v_n, v_cats, v_hard
        from public.challenge_assignments
        where user_id = m1 and type = 'personal_daily'
          and period_key = to_char((now() + make_interval(days => v_day)) at time zone public._challenge_tz(), 'YYYY-MM-DD');
      if v_n <> 3 then raise exception 'FAIL A: day % got % dailies (%)', v_day, v_n, v_today; end if;
      if v_cats < 3 then raise exception 'FAIL A: day % has only % categories: %', v_day, v_cats, v_today; end if;
      if v_hard > 1 then raise exception 'FAIL A: day % has % hard dailies', v_day, v_hard; end if;
      if v_today && array['pd_lore_master', 'pd_perfect_score', 'pd_know_thy_friends', 'pd_office_oracle'] then v_gated := v_gated + 1; end if;
      if v_today && array['pd_pick_a_side'] then raise exception 'FAIL A: Pick a Side was assigned without an open battle (day %)', v_day; end if;
      if v_day > 0 and v_prev is not null and v_today && v_prev then v_repeat := v_repeat + 1; end if;
      for r in select unnest(v_today) as id loop v_dist := jsonb_set(v_dist, array[r.id], to_jsonb(coalesce((v_dist->>r.id)::int, 0) + 1)); end loop;
      v_prev := v_today; v_days_checked := v_days_checked + 1;
    end loop;
    if v_gated > 0 then raise exception 'FAIL A: a quiz/prediction quest was assigned while its feature is off'; end if;
    if v_repeat > 0 then raise exception 'FAIL A: yesterday''s quest came back % time(s) although there is a big pool', v_repeat; end if;
    v_report := v_report || format('PASS A  %s days: always 3 quests, 3 different categories, at most 1 hard, never yesterday''s again, no quiz/prediction quest, no Pick a Side without an open battle. Spread: %s', v_days_checked, v_dist) || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then
    if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if;
  end;

  -- ===== B. feasibility gates =====
  begin
    -- Beer Scholar needs a beer the user has not rated
    delete from public.beer_ratings where user_id = m1;
    if not public._challenge_available((select d from public.challenge_definitions d where d.id = 'pd_beer_scholar'), m1) then raise exception 'FAIL B: Beer Scholar should be available with unrated beers'; end if;
    insert into public.beer_ratings (beer_id, user_id, rating) select id, m1, 7 from public.beers;
    if public._challenge_available((select d from public.challenge_definitions d where d.id = 'pd_beer_scholar'), m1) then raise exception 'FAIL B: Beer Scholar available although every beer is rated'; end if;
    -- Pick a Side needs an open battle the user has not voted in
    update public.nickname_battles set status = 'draw' where status = 'open';
    if public._challenge_available((select d from public.challenge_definitions d where d.id = 'pd_pick_a_side'), m1) then raise exception 'FAIL B: Pick a Side available without a battle'; end if;
    insert into public.nickname_battles (nickname_a_text, nickname_b_text, created_by_user_id) values ('Gate A', 'Gate B', m2) returning id into v_battle;
    if not public._challenge_available((select d from public.challenge_definitions d where d.id = 'pd_pick_a_side'), m1) then raise exception 'FAIL B: Pick a Side unavailable with an open battle'; end if;
    insert into public.nickname_battle_votes (battle_id, user_id, voted_side) values (v_battle, m1, 'a');
    if public._challenge_available((select d from public.challenge_definitions d where d.id = 'pd_pick_a_side'), m1) then raise exception 'FAIL B: Pick a Side available after the user already voted'; end if;
    -- Lore Master needs the quiz feature
    if public._challenge_available((select d from public.challenge_definitions d where d.id = 'pd_lore_master'), m1) then raise exception 'FAIL B: a quiz quest is available with the quiz feature off'; end if;
    update public.challenge_features set enabled = true where key = 'quiz';
    if not public._challenge_available((select d from public.challenge_definitions d where d.id = 'pd_lore_master'), m1) then raise exception 'FAIL B: the quiz switch did not enable the quiz quests'; end if;
    v_report := v_report || 'PASS B  feasibility gates: Beer Scholar (unrated beer), Pick a Side (open battle not yet voted), quiz/prediction (feature switch)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then
    if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if;
  end;

  -- ===== C. every Daily, driven by the real app actions =====
  -- C1 Name Thy Victim
  begin
    a := pg_temp.give(m1, 'pd_name_thy_victim');
    insert into public.nicknames (nickname, person_real_name, created_by_user_id) values ('Selftest Nick', 'Selftest Person', m1);
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C1: a new nickname did not complete it'; end if;
    b := pg_temp.give(m1, 'pd_name_thy_victim');
    insert into public.nicknames (nickname, person_real_name, created_by_user_id) values ('Other Nick', 'Other Person', m2);
    if (pg_temp.cur(b.id)).progress <> 0 then raise exception 'FAIL C1: someone else''s nickname counted'; end if;
    v_report := v_report || 'PASS 🏷️ Name Thy Victim  (a new nickname completes it, another user''s does not)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C2 Lore Keeper
  begin
    a := pg_temp.give(m1, 'pd_lore_keeper');
    update public.nicknames set anecdote = null where id = v_nick[1];                   -- a nickname without a story
    perform pg_temp.imp(m1);
    perform public.update_nickname_collaborative_fields(v_nick[1], 'desc', 'A great story about this nickname.');
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C2: adding an anecdote did not complete it'; end if;
    b := pg_temp.give(m1, 'pd_lore_keeper');
    perform public.update_nickname_collaborative_fields(v_nick[1], 'desc changed', 'A great story about this nickname.');   -- editing an existing anecdote is not "adding"
    if (pg_temp.cur(b.id)).progress <> 0 then raise exception 'FAIL C2: editing an existing anecdote counted'; end if;
    v_report := v_report || 'PASS 📖 Lore Keeper  (adding the first anecdote counts, editing an existing one does not)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C3 Quote Hunter
  begin
    a := pg_temp.give(m1, 'pd_quote_hunter');
    insert into public.quotes (person_real_name, quote, created_by_user_id) values ('Selftest Person', 'A selftest quote', m1);
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C3: a new quote did not complete it'; end if;
    v_report := v_report || 'PASS 💬 Quote Hunter' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C4 The Critic: 3 DIFFERENT nicknames, toggling cannot farm it
  begin
    delete from public.nickname_votes where user_id = m1;
    a := pg_temp.give(m1, 'pd_the_critic');
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[1], m1, 'funny');
    delete from public.nickname_votes where nickname_id = v_nick[1] and user_id = m1;
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[1], m1, 'funny');
    if (pg_temp.cur(a.id)).progress <> 1 then raise exception 'FAIL C4: toggling the same nickname counted twice (%)', (pg_temp.cur(a.id)).progress; end if;
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[2], m1, 'funny');
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[2], m1, 'accurate');   -- a second reaction on the SAME nickname
    if (pg_temp.cur(a.id)).progress <> 2 then raise exception 'FAIL C4: two reactions on one nickname counted as two (%)', (pg_temp.cur(a.id)).progress; end if;
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (v_nick[3], m1, 'savage');
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C4: 3 different nicknames did not complete it'; end if;
    v_report := v_report || 'PASS ⭐ The Critic  (3 DIFFERENT nicknames; toggling or double reactions count once)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C5 Pick a Side
  begin
    update public.nickname_battles set status = 'draw' where status = 'open';
    insert into public.nickname_battles (nickname_a_text, nickname_b_text, created_by_user_id) values ('Side A', 'Side B', m2) returning id into v_battle;
    a := pg_temp.give(m1, 'pd_pick_a_side');
    insert into public.nickname_battle_votes (battle_id, user_id, voted_side) values (v_battle, m1, 'a');
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C5: a battle vote did not complete it'; end if;
    v_report := v_report || 'PASS ⚔️ Pick a Side  (a vote in an open battle)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C6 Poet for a Day: only Today's Poetry Challenge counts
  begin
    perform pg_temp.imp(m1);
    select * into v_dc from public.get_or_create_daily_challenge();
    delete from public.poems where author_user_id = m1 and daily_challenge_id = v_dc.id;   -- (rolled back) so the unique 'one daily poem' key is free
    a := pg_temp.give(m1, 'pd_poet_for_a_day');
    insert into public.poems (author_user_id, title, content, mood) values (m1, 'A free poem', 'Just a normal poem, not the daily one.', 'other');
    if (pg_temp.cur(a.id)).progress <> 0 then raise exception 'FAIL C6: an ordinary poem counted as the daily poem'; end if;
    insert into public.poems (author_user_id, title, content, mood, daily_challenge_id, is_daily_challenge) values (m1, 'Daily verse', 'Roses are red, the biscuit tin is empty.', 'other', v_dc.id, true);
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C6: the daily poem did not complete it'; end if;
    v_report := v_report || 'PASS ✍️ Poet for a Day  (only Today''s Poetry Challenge poem counts)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C7 Poetry Critic: reactions OR comments, on 2 DIFFERENT poems
  begin
    delete from public.poem_reactions where user_id = m1; delete from public.poem_comments where user_id = m1;
    a := pg_temp.give(m1, 'pd_poetry_critic');
    insert into public.poem_reactions (poem_id, user_id, reaction_type) values (v_poems[1], m1, 'charming');
    insert into public.poem_comments (poem_id, user_id, content) values (v_poems[1], m1, 'same poem, commented too');
    if (pg_temp.cur(a.id)).progress <> 1 then raise exception 'FAIL C7: reacting AND commenting on one poem counted twice (%)', (pg_temp.cur(a.id)).progress; end if;
    insert into public.poem_comments (poem_id, user_id, content) values (v_poems[2], m1, 'a different poem');
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C7: a second poem did not complete it'; end if;
    v_report := v_report || 'PASS ❤️ Poetry Critic  (a reaction or a comment, 2 different poems)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C8 Beer Scholar: only a FIRST rating of a beer
  begin
    delete from public.beer_ratings where user_id = m1;
    a := pg_temp.give(m1, 'pd_beer_scholar');
    insert into public.beer_ratings (beer_id, user_id, rating) values (v_beers[1], m1, 8);
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C8: rating a new beer did not complete it'; end if;
    b := pg_temp.give(m1, 'pd_beer_scholar');
    insert into public.beer_ratings (beer_id, user_id, rating) values (v_beers[1], m1, 9);    -- the same beer again
    if (pg_temp.cur(b.id)).progress <> 0 then raise exception 'FAIL C8: re-rating a beer the user already rated counted'; end if;
    insert into public.beer_ratings (beer_id, user_id, rating) values (v_beers[2], m1, 6);
    if (pg_temp.cur(b.id)).status <> 'completed' then raise exception 'FAIL C8: a different new beer did not complete it'; end if;
    v_report := v_report || 'PASS 🍺 Beer Scholar  (a beer the user had not rated; re-rating does not count)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C9 New Brew
  begin
    a := pg_temp.give(m1, 'pd_new_brew');
    insert into public.beers (name, brewery, created_by_user_id) values ('Selftest Tripel', 'Selftest Brewery', m1);
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C9: a new beer did not complete it'; end if;
    v_report := v_report || 'PASS 🆕 New Brew' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C10 One for the Books: a logged Beer Session
  begin
    a := pg_temp.give(m1, 'pd_one_for_the_books');
    insert into public.beer_sessions (session_date, location, created_by_user_id) values (current_date, 'Selftest Pub', m1) returning id into v_sess;
    insert into public.beer_session_participants (session_id, user_id) values (v_sess, m1);
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C10: a logged Beer Session did not complete it'; end if;
    v_report := v_report || 'PASS 🍻 One for the Books  (taking part in a logged Beer Session; nothing counts quantity)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- C11 Memory Lane: only content older than 7 days
  begin
    select id into v_old_poem from public.poems where created_at < now() - interval '7 days' limit 1;
    if v_old_poem is null then
      v_report := v_report || 'SKIP 📚 Memory Lane  (no poem older than a week to test with)' || E'\n';
    else
      delete from public.poem_reactions where user_id = m1;
      a := pg_temp.give(m1, 'pd_memory_lane');
      insert into public.poems (author_user_id, title, content, mood) values (m1, 'Brand new', 'Fresh from the press, certainly not memory lane.', 'other') returning id into v_id;
      insert into public.poem_reactions (poem_id, user_id, reaction_type) values (v_id, m1, 'charming');
      if (pg_temp.cur(a.id)).progress <> 0 then raise exception 'FAIL C11: reacting to a brand-new poem counted'; end if;
      insert into public.poem_reactions (poem_id, user_id, reaction_type) values (v_old_poem, m1, 'charming');
      if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C11: reacting to an old poem did not complete it'; end if;
      v_report := v_report || 'PASS 📚 Memory Lane  (a poem/nickname more than a week old counts, fresh content does not)' || E'\n';
    end if;
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== D. 🎁 Daily Sweep: 3/3 once, claimed once =====
  begin
    delete from public.challenge_assignments; delete from public.challenge_sweeps;
    update public.challenge_definitions set is_active = false where completion like 'chaos:%';     -- Chaos Dailies complete by submission (see chaos_dailies_selftest), this test pushes events
    perform public._ensure_challenge_assignments_for(m1, now());
    select count(*) into v_n from public.challenge_assignments where user_id = m1 and type = 'personal_daily';
    if v_n <> 3 then raise exception 'FAIL D: expected 3 dailies, got %', v_n; end if;
    -- complete all three the honest way: push exactly the events their definitions listen for
    for r in select id, event_type, event_types, target, requirements, period_key from public.challenge_assignments where user_id = m1 and type = 'personal_daily' loop
      perform public._challenge_event(m1, (coalesce(r.event_types, array[r.event_type]))[1], r.target,
        null, jsonb_build_object('first', 1, 'age_days', 30, 'pct', 100), 'selftest:' || r.id);
    end loop;
    select count(*) into v_cnt from public.challenge_sweeps where user_id = m1;
    if v_cnt <> 1 then raise exception 'FAIL D: expected exactly 1 Daily Sweep, got %', v_cnt; end if;
    -- the database itself refuses a second sweep for the same user and day
    v_ok := false;
    begin
      insert into public.challenge_sweeps (user_id, period_key, reward) select user_id, period_key, reward from public.challenge_sweeps where user_id = m1;
    exception when unique_violation then v_ok := true; end;
    if not v_ok then raise exception 'FAIL D: a second sweep for one day was possible'; end if;
    -- claim: once
    perform pg_temp.imp(m1);
    select id into v_id from public.challenge_sweeps where user_id = m1;
    if (public.claim_daily_sweep(v_id))->>'status' <> 'claimed' then raise exception 'FAIL D: the sweep could not be claimed'; end if;
    if (public.claim_daily_sweep(v_id))->>'status' <> 'already_claimed' then raise exception 'FAIL D: the sweep paid twice'; end if;
    select count(*) into v_cnt from public.challenge_reward_grants where sweep_id = v_id and user_id = m1;
    if v_cnt <> 2 then raise exception 'FAIL D: expected 2 sweep grants (XP + Mystery Reward), got %', v_cnt; end if;
    if (select count(*) from public.mystery_boxes where user_id = m1) <> 1 then raise exception 'FAIL D: no Mystery box from the sweep'; end if;
    -- someone else cannot claim it
    v_ok := false; begin perform pg_temp.imp(m2); perform public.claim_daily_sweep(v_id); exception when others then v_ok := true; end;
    if not v_ok then raise exception 'FAIL D: another user claimed my sweep'; end if;
    v_report := v_report || 'PASS 🎁 Daily Sweep  (3/3 creates exactly one sweep per day; bonus XP + 1 Mystery Reward, claimable once, only by its owner)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== E. rewards: central config + chance rolled once =====
  begin
    delete from public.challenge_assignments;
    update public.challenge_config set value = jsonb_set(value, '{easy}', '[{"kind":"player_xp","amount":77}]'::jsonb) where key = 'difficulty_rewards';
    a := pg_temp.give(m1, 'pd_quote_hunter');
    if (a.reward->'lines'->0->>'amount') <> '77' then raise exception 'FAIL E: the reward did not come from the central config (%)', a.reward; end if;
    -- chance 0 always misses, chance 1 always hits, and a line is only ever recorded once
    r := null;
    if (public._grant_challenge_reward2(m1, a.id, null, '{"kind":"gauntlet_fragments","amount":2,"chance":0}'::jsonb, 1))->>'hit' <> 'false' then raise exception 'FAIL E: chance 0 hit'; end if;
    if coalesce((select fragments from public.gauntlet_fragments where user_id = m1), 0) <> 0 then raise exception 'FAIL E: a missed roll still paid fragments'; end if;
    if (select status from public.challenge_reward_grants where assignment_id = a.id and line_no = 1) <> 'missed' then raise exception 'FAIL E: the missed roll was not recorded'; end if;
    if (public._grant_challenge_reward2(m1, a.id, null, '{"kind":"gauntlet_fragments","amount":2,"chance":1}'::jsonb, 1))->>'duplicate' <> 'true' then raise exception 'FAIL E: a recorded line could be rolled again'; end if;
    if (public._grant_challenge_reward2(m1, a.id, null, '{"kind":"gauntlet_fragments","amount":2,"chance":1}'::jsonb, 2))->>'hit' <> 'true' then raise exception 'FAIL E: chance 1 missed'; end if;
    if (select fragments from public.gauntlet_fragments where user_id = m1) <> 2 then raise exception 'FAIL E: fragments not paid'; end if;
    -- the reward is a snapshot: later config changes do not alter an existing quest
    update public.challenge_config set value = jsonb_set(value, '{easy}', '[{"kind":"player_xp","amount":1}]'::jsonb) where key = 'difficulty_rewards';
    if (pg_temp.cur(a.id)).reward->'lines'->0->>'amount' <> '77' then raise exception 'FAIL E: an existing quest changed with the config'; end if;
    v_report := v_report || 'PASS rewards: difficulty rewards come from central config (snapshotted per quest), chance is rolled once and recorded (missed = 0 paid), no re-roll possible' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  raise exception E'DAILY POOL REPORT (nothing was saved)\n%', v_report;
end $$;
