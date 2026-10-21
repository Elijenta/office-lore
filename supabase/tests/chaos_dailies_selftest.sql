-- =================================================================
-- SELF-TEST for 0050_chaos_dailies.sql  (safe: everything is rolled back)
-- =================================================================
-- Run in the Supabase SQL Editor AFTER 0048, 0049 and 0050. It submits every Chaos
-- Daily through the real RPCs as two real members, tries the cheats (empty or
-- repeated submissions, late Five Second, guessing your own, reading the answer)
-- and ends with a deliberate exception: the "error" you get back IS the report.
-- NOTHING is saved.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;

-- null when the statement worked, otherwise the error text
create or replace function pg_temp.try(p_sql text) returns text as $$
begin
  execute p_sql;
  return null;
exception when others then return sqlerrm;
end;
$$ language plpgsql;

create or replace function pg_temp.give(p_user uuid, p_def text) returns public.challenge_assignments as $$
declare
  a public.challenge_assignments;
  d public.challenge_definitions;
  v_key text := 'T' || substr(md5(random()::text), 1, 10);
begin
  select * into d from public.challenge_definitions where id = p_def;
  insert into public.challenge_assignments
    (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
     target, period_key, starts_at, expires_at, completion, payload)
  values ('officelore', d.id, p_user, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.event_types, d.icon, d.requirements,
          public._assignment_reward(d), d.target, v_key, now() - interval '1 hour', now() + interval '20 hours', d.completion, public._chaos_payload(d, p_user, v_key))
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
  m1 uuid; m2 uuid;
  a public.challenge_assignments; b public.challenge_assignments; c public.challenge_assignments;
  v_err text; v_res jsonb; v_id uuid; v_n int; v_feed jsonb; v_row jsonb; v_nicks text[];
  v_jpg constant text := 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP';
begin
  select p.id into m1 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m1 order by p.display_name limit 1;
  select count(*) into v_n from public.nicknames where status = 'Actief';
  if m2 is null or v_n < 4 then raise exception 'ABORTED: need 2 members and 4 active nicknames'; end if;
  select array_agg(nickname) into v_nicks from (select nickname from public.nicknames where status = 'Actief' and length(nickname) <= 30 order by length(nickname), nickname limit 3) x;     -- Five Second answers are at most 40 characters
  v_report := format('tested as %s (second member %s)', (select display_name from public.profiles where id = m1), (select display_name from public.profiles where id = m2)) || E'\n';

  delete from public.challenge_assignments;
  delete from public.challenge_sweeps;
  delete from public.challenge_events;
  delete from public.challenge_reward_grants;

  -- ===== A. the pool: exactly the 8 requested, none of the excluded =====
  begin
    select count(*) into v_n from public.challenge_definitions where category = 'chaos' and completion like 'chaos:%' and is_active;
    if v_n <> 8 then raise exception 'FAIL A: expected 8 Chaos Dailies, found %', v_n; end if;
    select count(*) into v_n from public.challenge_definitions
      where title ~* '(portrait|meme|corporate|sales|worst advice|voice)' and is_active;
    if v_n <> 0 then raise exception 'FAIL A: an excluded challenge exists'; end if;
    select count(*) into v_n from pg_policies where schemaname = 'public' and tablename in ('chaos_submissions', 'chaos_secrets', 'chaos_guesses', 'chaos_reactions', 'chaos_attempts', 'chaos_prompts') and cmd <> 'SELECT';
    if v_n <> 0 then raise exception 'FAIL A: a client write policy exists on a chaos table'; end if;
    if exists (select 1 from pg_policies where tablename in ('chaos_secrets', 'chaos_attempts', 'chaos_prompts')) then raise exception 'FAIL A: a private chaos table has a read policy'; end if;
    v_report := v_report || 'PASS pool: the 8 Chaos Dailies exist, none of the excluded ones, no client write policies, secrets/attempts/prompts unreadable' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== B. Royal Decree: needs a real submission, no repeats, no shortcuts =====
  begin
    a := pg_temp.give(m1, 'pd_royal_decree');
    if a.payload->>'text' is null then raise exception 'FAIL B: no curated topic picked'; end if;
    perform pg_temp.imp(m2);
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"text":"By royal order the stapler is now a duke"}'));
    if v_err is null then raise exception 'FAIL B: another user submitted my decree'; end if;
    perform pg_temp.imp(m1);
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"text":"too short"}'));
    if v_err is null then raise exception 'FAIL B: a 9-character decree was accepted'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"text":""}'));
    if v_err is null then raise exception 'FAIL B: an empty decree was accepted'; end if;
    if (pg_temp.cur(a.id)).status <> 'active' then raise exception 'FAIL B: the challenge completed without a valid submission'; end if;
    v_res := public.submit_chaos(a.id, '{"text":"By royal order the stapler is now a duke"}', null);
    if (pg_temp.cur(a.id)).status <> 'completed' or (pg_temp.cur(a.id)).progress <> 1 then raise exception 'FAIL B: a valid decree did not complete it'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"text":"By royal order the stapler is now a duke"}'));
    if v_err is null then raise exception 'FAIL B: submitted twice for one assignment'; end if;
    b := pg_temp.give(m1, 'pd_royal_decree');
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', b.id, '{"text":"By royal order the stapler is now a duke"}'));
    if v_err is null then raise exception 'FAIL B: the same decree was accepted again for reward farming'; end if;
    -- the reward is claimable exactly once
    v_res := public.claim_challenge(a.id);
    if v_res->>'status' <> 'claimed' then raise exception 'FAIL B: claim failed %', v_res; end if;
    if (public.claim_challenge(a.id))->>'status' <> 'already_claimed' then raise exception 'FAIL B: claimed twice'; end if;
    if not exists (select 1 from public.challenge_reward_grants where assignment_id = a.id and kind = 'player_xp' and amount > 0) then raise exception 'FAIL B: no XP paid'; end if;
    -- it shows in the feed for the others
    perform pg_temp.imp(m2);
    v_feed := public.get_chaos_feed(40);
    if not exists (select 1 from jsonb_array_elements(v_feed) e where e->>'kind' = 'decree') then raise exception 'FAIL B: the decree is not in the Chaos Feed'; end if;
    v_report := v_report || 'PASS 👑 Royal Decree  (validated, owner only, one submission, no repeated text, completes only through the submission, claim once, visible in the feed)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== C. photo prompts: Office Safari / The Photographer / Tiny Quest =====
  begin
    perform pg_temp.imp(m1);
    a := pg_temp.give(m1, 'pd_office_safari');
    v_err := pg_temp.try(format('select public.submit_chaos(%L, ''{}''::jsonb, null)', a.id));
    if v_err is null then raise exception 'FAIL C: submitted without a photo'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, ''{}''::jsonb, %L)', a.id, 'http://evil.example/x.jpg'));
    if v_err is null then raise exception 'FAIL C: a URL was accepted as media'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, ''{}''::jsonb, %L)', a.id, 'data:text/html;base64,PHNjcmlwdD4='));
    if v_err is null then raise exception 'FAIL C: html was accepted as media'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, ''{}''::jsonb, %L)', a.id, 'data:image/jpeg;base64,' || repeat('A', 1000000)));
    if v_err is null then raise exception 'FAIL C: an oversized image was accepted'; end if;
    perform public.submit_chaos(a.id, '{"note":"the stapler stares back"}', v_jpg || 'AA');
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL C: safari not completed'; end if;
    if not exists (select 1 from public.challenge_definitions where id = 'pd_office_safari') then raise exception 'FAIL C: setup'; end if;
    b := pg_temp.give(m1, 'pd_the_photographer');
    perform public.submit_chaos(b.id, '{}', v_jpg || 'BB');
    c := pg_temp.give(m1, 'pd_tiny_quest');
    perform public.submit_chaos(c.id, '{}', v_jpg || 'CC');
    if (pg_temp.cur(b.id)).status <> 'completed' or (pg_temp.cur(c.id)).status <> 'completed' then raise exception 'FAIL C: photographer / tiny quest not completed'; end if;
    -- the same image twice is refused
    a := pg_temp.give(m1, 'pd_office_safari');
    v_err := pg_temp.try(format('select public.submit_chaos(%L, ''{}''::jsonb, %L)', a.id, v_jpg || 'CC'));
    if v_err is null then raise exception 'FAIL C: the same photo was accepted twice'; end if;
    -- the feed list is light (no image), the image is fetched on its own
    perform pg_temp.imp(m2);
    if exists (select 1 from jsonb_array_elements(public.get_chaos_feed(40)) e where e ? 'media') then raise exception 'FAIL C: the feed carries raw media'; end if;
    select id into v_id from public.chaos_submissions where kind = 'safari' limit 1;
    if public.get_chaos_media(v_id) is null then raise exception 'FAIL C: a member cannot load the image'; end if;
    v_report := v_report || 'PASS 📸 Office Safari / 📷 The Photographer / 🧭 Tiny Quest  (a real image data URL only, size capped, no repeats, the feed stays light, image loads separately)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== D. The Impostor: 3 statements, guess the lie =====
  begin
    perform pg_temp.imp(m1);
    a := pg_temp.give(m1, 'pd_the_impostor');
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"statements":["I like beer a lot","I own a dog"],"fake":1}'));
    if v_err is null then raise exception 'FAIL D: 2 statements accepted'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"statements":["I like beer a lot","I own a dog","I climbed a mountain"],"fake":7}'));
    if v_err is null then raise exception 'FAIL D: an invalid fake index was accepted'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"statements":["I like beer a lot","I like beer a lot","I climbed a mountain"],"fake":2}'));
    if v_err is null then raise exception 'FAIL D: duplicate statements accepted'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"statements":["I like beer a lot","I own a dog","I climbed a mountain"]}'));
    if v_err is null then raise exception 'FAIL D: a missing fake index was accepted'; end if;
    v_res := public.submit_chaos(a.id, '{"statements":["I like beer a lot","I own a dog","I climbed a mountain"],"fake":1}', null);
    v_id := (v_res->>'id')::uuid;
    if (pg_temp.cur(a.id)).status <> 'completed' then raise exception 'FAIL D: not completed'; end if;
    v_err := pg_temp.try(format('select public.guess_chaos(%L, ''{"index":1}''::jsonb)', v_id));
    if v_err is null then raise exception 'FAIL D: guessed own submission'; end if;
    -- another member: cannot see the lie before guessing
    perform pg_temp.imp(m2);
    select e into v_row from jsonb_array_elements(public.get_chaos_feed(40)) e where (e->>'id')::uuid = v_id;
    if coalesce(jsonb_typeof(v_row->'answer'), 'null') <> 'null' then raise exception 'FAIL D: the feed leaked the answer before guessing: %', v_row->>'answer'; end if;
    v_res := public.guess_chaos(v_id, '{"index":0}');
    if (v_res->>'correct')::boolean then raise exception 'FAIL D: a wrong guess counted as right'; end if;
    v_err := pg_temp.try(format('select public.guess_chaos(%L, ''{"index":1}''::jsonb)', v_id));
    if v_err is null then raise exception 'FAIL D: guessed twice'; end if;
    select e into v_row from jsonb_array_elements(public.get_chaos_feed(40)) e where (e->>'id')::uuid = v_id;
    if (v_row->'answer'->>'fake') <> '1' then raise exception 'FAIL D: the answer is not revealed after guessing'; end if;
    -- reactions: toggle, never your own
    if not (public.react_chaos(v_id, '😂')->>'on')::boolean then raise exception 'FAIL D: reaction not set'; end if;
    if (public.react_chaos(v_id, '😂')->>'on')::boolean then raise exception 'FAIL D: reaction not toggled off'; end if;
    v_err := pg_temp.try(format('select public.react_chaos(%L, %L)', v_id, 'x'));
    if v_err is null then raise exception 'FAIL D: an unknown emoji was accepted'; end if;
    perform pg_temp.imp(m1);
    v_err := pg_temp.try(format('select public.react_chaos(%L, %L)', v_id, '🔥'));
    if v_err is null then raise exception 'FAIL D: reacted to own submission'; end if;
    v_report := v_report || 'PASS 🎲 The Impostor  (exactly 3 different statements + a valid lie, others guess once, never your own, the answer is hidden until you guessed, reactions toggle)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== E. Emoji Lore + Draw This: the nickname never appears as text =====
  begin
    perform pg_temp.imp(m1);
    a := pg_temp.give(m1, 'pd_emoji_lore');
    if (a.payload->>'nickname_id') is null then raise exception 'FAIL E: no nickname picked'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"emoji":"abc"}'));
    if v_err is null then raise exception 'FAIL E: letters accepted as emoji'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, jsonb_build_object('emoji', '😀🍺👑🔥🎉🙈')::text));
    if v_err is null then raise exception 'FAIL E: 6 emoji accepted'; end if;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, jsonb_build_object('emoji', a.payload->>'text')::text));
    if v_err is null then raise exception 'FAIL E: the nickname itself accepted as the answer'; end if;
    v_res := public.submit_chaos(a.id, jsonb_build_object('emoji', '😀🍺👑'), null);
    v_id := (v_res->>'id')::uuid;
    if (select prompt from public.chaos_submissions where id = v_id) is not null then raise exception 'FAIL E: the nickname was stored in the visible prompt'; end if;
    if (select jsonb_array_length(options) from public.chaos_submissions where id = v_id) < 2 then raise exception 'FAIL E: no options to guess from'; end if;
    perform pg_temp.imp(m2);
    v_res := public.guess_chaos(v_id, jsonb_build_object('option', a.payload->>'text'));
    if not (v_res->>'correct')::boolean then raise exception 'FAIL E: the right guess did not count'; end if;

    perform pg_temp.imp(m1);
    b := pg_temp.give(m1, 'pd_draw_this');
    v_err := pg_temp.try(format('select public.submit_chaos(%L, ''{}''::jsonb, null)', b.id));
    if v_err is null then raise exception 'FAIL E: a drawing without an image was accepted'; end if;
    v_res := public.submit_chaos(b.id, '{}', v_jpg || 'DD');
    v_id := (v_res->>'id')::uuid;
    if (select prompt from public.chaos_submissions where id = v_id) is not null or (select content::text from public.chaos_submissions where id = v_id) like '%' || (b.payload->>'text') || '%' then
      raise exception 'FAIL E: the nickname leaked into the visible Draw This submission';
    end if;
    perform pg_temp.imp(m2);
    v_res := public.guess_chaos(v_id, '{"option":"definitely not it"}');
    if (v_res->>'correct')::boolean then raise exception 'FAIL E: a wrong option counted as right'; end if;
    v_report := v_report || 'PASS 😀 Emoji Lore / 🎨 Draw This  (the app picks an existing nickname, emoji only and at most 5, drawing needs an image, the nickname never appears as text, others guess from options)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== F. Five Second: the server keeps the clock =====
  begin
    perform pg_temp.imp(m1);
    a := pg_temp.give(m1, 'pd_five_seconds');
    update public.challenge_assignments set payload = '{"text":"Name 3 things found in an office","verify":null}' where id = a.id;
    v_err := pg_temp.try(format('select public.submit_five_seconds(%L, %L::jsonb)', a.id, '["desk","chair","lamp"]'));
    if v_err is null then raise exception 'FAIL F: answered without pressing start'; end if;
    perform public.start_five_seconds(a.id);
    update public.chaos_attempts set started_at = clock_timestamp() - interval '30 seconds' where assignment_id = a.id;       -- the player took far too long
    v_res := public.submit_five_seconds(a.id, '["desk","chair","lamp"]');
    if v_res->>'status' <> 'failed' or (pg_temp.cur(a.id)).status <> 'active' then raise exception 'FAIL F: a late answer counted: %', v_res; end if;
    perform public.start_five_seconds(a.id);
    v_res := public.submit_five_seconds(a.id, '["desk","desk","lamp"]');                                                      -- duplicates are only 2 distinct answers
    if v_res->>'status' <> 'failed' then raise exception 'FAIL F: duplicate answers counted: %', v_res; end if;
    v_err := pg_temp.try(format('select public.start_five_seconds(%L)', a.id));
    if v_err is null then raise exception 'FAIL F: a third attempt was allowed'; end if;
    if (pg_temp.cur(a.id)).status <> 'active' then raise exception 'FAIL F: completed after failed attempts'; end if;

    b := pg_temp.give(m1, 'pd_five_seconds');
    update public.challenge_assignments set payload = '{"text":"Name 3 things found in an office","verify":null}' where id = b.id;
    perform public.start_five_seconds(b.id);
    v_res := public.submit_five_seconds(b.id, '["desk","chair","lamp"]');
    if v_res->>'status' <> 'submitted' or (pg_temp.cur(b.id)).status <> 'completed' then raise exception 'FAIL F: a fast valid answer was refused: %', v_res; end if;
    -- a category that is checked against our data
    c := pg_temp.give(m1, 'pd_five_seconds');
    update public.challenge_assignments set payload = '{"text":"Name 3 nicknames from the Nickname Wall","verify":"nicknames"}' where id = c.id;
    perform public.start_five_seconds(c.id);
    v_res := public.submit_five_seconds(c.id, '["zzzxxx","qqqwww","yyyuuu"]');
    if v_res->>'status' <> 'failed' then raise exception 'FAIL F: made-up nicknames were accepted'; end if;
    perform public.start_five_seconds(c.id);
    v_res := public.submit_five_seconds(c.id, to_jsonb(v_nicks));
    if v_res->>'status' <> 'submitted' then raise exception 'FAIL F: real nicknames were refused: %', v_res; end if;
    v_report := v_report || 'PASS 🧠 Five Second  (server-side clock, a late answer fails, 3 distinct answers, 2 attempts max, nickname categories are checked against the Wall)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== G. expiry, the Daily Sweep and the boosted rewards =====
  begin
    perform pg_temp.imp(m1);
    a := pg_temp.give(m1, 'pd_royal_decree');
    update public.challenge_assignments set expires_at = now() - interval '1 minute' where id = a.id;
    v_err := pg_temp.try(format('select public.submit_chaos(%L, %L::jsonb, null)', a.id, '{"text":"A very late royal decree about nothing"}'));
    if v_err is null then raise exception 'FAIL G: an expired challenge accepted a submission'; end if;

    -- 3 Dailies today (2 chaos + 1 normal) -> exactly one Daily Sweep
    delete from public.challenge_assignments;
    a := pg_temp.give(m1, 'pd_royal_decree');
    b := pg_temp.give(m1, 'pd_tiny_quest');
    c := pg_temp.give(m1, 'pd_office_safari');
    update public.challenge_assignments set period_key = 'SWEEPDAY' where id in (a.id, b.id, c.id);
    perform public.submit_chaos(a.id, '{"text":"The first decree: Fridays end at noon"}', null);
    perform public.submit_chaos(b.id, '{}', v_jpg || 'EE');
    if exists (select 1 from public.challenge_sweeps where user_id = m1) then raise exception 'FAIL G: sweep before 3/3'; end if;
    perform public.submit_chaos(c.id, '{}', v_jpg || 'FF');
    if (select count(*) from public.challenge_sweeps where user_id = m1 and period_key = 'SWEEPDAY') <> 1 then raise exception 'FAIL G: the Daily Sweep did not appear exactly once'; end if;

    -- boosted rewards come from the central config
    if (select (e->>'chance')::numeric from jsonb_array_elements(a.reward->'lines') e where e->>'kind' = 'mystery') <= 0.15 then raise exception 'FAIL G: Chaos Mystery chance is not raised above the normal 15%%'; end if;
    if not exists (select 1 from jsonb_array_elements((pg_temp.give(m1, 'pd_the_impostor')).reward->'lines') e where e->>'kind' = 'gauntlet_fragments') then raise exception 'FAIL G: a hard Chaos Daily has no fragment chance'; end if;
    update public.challenge_config set value = jsonb_set(value, '{normal}', '[{"kind":"player_xp","amount":99}]') where key = 'chaos_rewards';
    if ((pg_temp.give(m1, 'pd_royal_decree')).reward->'lines'->0->>'amount') <> '99' then raise exception 'FAIL G: chaos rewards are not configurable'; end if;
    v_report := v_report || 'PASS expiry + 🎁 Sweep + rewards  (expired = refused, 3/3 gives one Sweep, Chaos has a raised Mystery chance, hard ones a Fragment chance, all from challenge_config.chaos_rewards)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  raise exception E'CHAOS DAILIES REPORT (nothing was saved)\n%', v_report;
end $$;
