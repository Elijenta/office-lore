-- =================================================================
-- SELF-TEST for 0084_taproom_wall.sql  (safe: everything is rolled back)
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;
create or replace function pg_temp.done_claim(p_user uuid, p_def text) returns jsonb as $$
declare d public.challenge_definitions; a uuid;
begin
  select * into d from public.challenge_definitions where id = p_def;
  a := public._new_assignment(d, case when d.type = 'group_weekly' then null else p_user end, p_user, 'TW' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
  update public.challenge_assignments set status = 'completed', progress = target where id = a;
  if d.type = 'group_weekly' then insert into public.challenge_contributions (assignment_id, user_id, amount) values (a, p_user, 1) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.claim_challenge(a);
end;
$$ language plpgsql;

do $$
declare
  v_report text := ''; m uuid; m2 uuid; r jsonb; v_err text; v_n int; i int; v_box uuid; v_neon int; v_coast int; v_dups int; v_beers int;
  d public.challenge_definitions; a1 uuid; a2 uuid; a3 uuid;
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  delete from public.wall_found_neons; delete from public.wall_coasters; delete from public.wall_pity; delete from public.wall_events;
  update public.wall_progress set value = 0; update public.wall_settings set value = '[]';
  delete from public.challenge_claims where user_id = m; delete from public.mystery_boxes where user_id = m;
  update public.character_outfit_sets set sources = '[]' where unlock_kind = 'random_drop'; update public.pet_outfits set sources = '[]';
  update public.challenge_config set value = '{"chance": {}, "pity_after": null}' where key = 'pet_drops'; update public.nickname_frames set sources = '[]';
  delete from public.beers;
  select count(*) into v_n from public.wall_neon_signs where is_active;
  if v_n <> 7 then raise exception 'FAIL 0: expected 7 neon signs, got %', v_n; end if;

  -- 0. the starter pack: PROOST! + OPEN hang, two coasters, only once
  delete from public.wall_settings where key = 'starter_given'; update public.wall_settings set value = '[]' where key = 'hung_neons';
  for i in 1..3 loop insert into public.beers (name, brewery, created_by_user_id) values ('Starter Beer ' || i, 'B', m); end loop;
  perform public._wall_starter_pack();
  if (select count(*) from public.wall_found_neons where neon_id in ('prost', 'open')) <> 2 or (select value from public.wall_settings where key = 'hung_neons') <> '["prost"]'::jsonb then raise exception 'FAIL S1: starter neons (PROOST! hangs, OPEN is only found)'; end if;
  select count(*) into v_n from public.wall_coasters;
  if v_n <> 2 then raise exception 'FAIL S2: % starter coasters (max 2)', v_n; end if;
  perform public._wall_starter_pack();
  if (select count(*) from public.wall_coasters) <> 2 then raise exception 'FAIL S3: the starter pack ran twice'; end if;
  v_report := v_report || 'PASS 🎁 starter pack: PROOST! hangs and OPEN is found, exactly 2 coasters, never given twice' || E'\n';
  delete from public.beers where name like 'Starter Beer %';
  delete from public.wall_found_neons; delete from public.wall_coasters;

  -- A. neon signs: found once for the whole group, pity guarantees them
  update public.wall_neon_signs set sources = '[]';
  update public.wall_neon_signs set sources = '[{"def":"gw_poets","chance":1}]', pity_after = null where id = 'tournee';
  update public.wall_neon_signs set sources = '[{"def":"pd_the_critic","chance":0}]', pity_after = 3 where id = 'open';
  r := public._wall_hook(m, 'pd_new_brew');
  if jsonb_array_length(r) <> 0 then raise exception 'FAIL A1: something dropped from an unrelated quest: %', r; end if;
  r := public._wall_hook(m, 'gw_poets');
  if not (r @> '[{"kind":"neon","id":"tournee"}]'::jsonb) then raise exception 'FAIL A2: %', r; end if;
  if (select found_by from public.wall_found_neons where neon_id = 'tournee') <> m then raise exception 'FAIL A3: finder not recorded'; end if;
  r := public._wall_hook(m2, 'gw_poets');
  if jsonb_array_length(r) <> 0 then raise exception 'FAIL A4: the same neon was found twice by the group'; end if;
  r := public._wall_hook(m, 'pd_the_critic'); r := public._wall_hook(m, 'pd_the_critic');
  r := public._wall_hook(m, 'pd_the_critic');
  if jsonb_array_length(r) <> 1 or not exists (select 1 from public.wall_found_neons where neon_id = 'open') then raise exception 'FAIL A5: pity of 3 did not give OPEN'; end if;
  v_report := v_report || 'PASS 🪧 neon signs: only from their own quests, found ONCE for the group (with the finder), pity guarantees them' || E'\n';

  -- B. bierviltjes: one per beer, never twice, a new beer = a new coaster
  update public.challenge_config set value = '{"sources": {"pd_new_brew": 1}, "pity_after": 8}' where key = 'wall_coasters';
  for i in 1..3 loop insert into public.beers (name, brewery, created_by_user_id) values ('Test Beer ' || i, 'Brewery', m); end loop;
  for i in 1..3 loop r := public._wall_hook(m, 'pd_new_brew'); if not (r @> '[{"kind":"coaster"}]'::jsonb) then raise exception 'FAIL B1: no coaster on drop %: %', i, r; end if; end loop;
  select count(distinct beer_id) into v_n from public.wall_coasters;
  if v_n <> 3 then raise exception 'FAIL B2: % different coasters', v_n; end if;
  r := public._wall_hook(m, 'pd_new_brew');
  if r @> '[{"kind":"coaster"}]'::jsonb then raise exception 'FAIL B3: a coaster dropped with no beer left'; end if;
  insert into public.beers (name, brewery, created_by_user_id) values ('Test Beer 4', 'Brewery', m);
  r := public._wall_hook(m2, 'pd_new_brew');
  if not (r @> '[{"kind":"coaster","name":"Test Beer 4"}]'::jsonb) then raise exception 'FAIL B4: the new beer did not get its coaster: %', r; end if;
  delete from public.beers where name = 'Test Beer 1';
  if exists (select 1 from public.wall_coasters c where not exists (select 1 from public.beers b where b.id = c.beer_id)) then raise exception 'FAIL B5: a coaster of a deleted beer'; end if;
  v_report := v_report || 'PASS 🍺 coasters: one per beer, never twice, a new beer gets its own, a deleted beer takes its coaster along' || E'\n';

  -- C. group progress: tap handles and the flag
  select * into d from public.challenge_definitions where id = 'gw_gathering';
  a1 := public._new_assignment(d, null, m, 'TWA' || substr(md5(random()::text), 1, 6), now() - interval '9 days', now() - interval '2 days');
  a2 := public._new_assignment(d, null, m, 'TWB' || substr(md5(random()::text), 1, 6), now() - interval '2 days', now() + interval '5 days');
  update public.challenge_assignments set status = 'completed' where id in (a1, a2);
  update public.challenge_assignments set status = 'completed', progress = progress where id = a1;     -- again: no double count
  if (select value from public.wall_progress where key = 'gatherings') <> 2 then raise exception 'FAIL C1: gatherings %', (select value from public.wall_progress where key = 'gatherings'); end if;
  select * into d from public.challenge_definitions where id = 'gw_nickname_factory';
  a3 := public._new_assignment(d, null, m, 'TWC' || substr(md5(random()::text), 1, 6), now() - interval '1 day', now() + interval '6 days');
  update public.challenge_assignments set status = 'completed' where id = a3;
  if (select value from public.wall_progress where key = 'factory') <> 1 then raise exception 'FAIL C2: factory'; end if;
  select * into d from public.challenge_definitions where id = 'gw_poets';
  perform public._new_assignment(d, null, m, 'TWD' || substr(md5(random()::text), 1, 6), now(), now() + interval '6 days');
  update public.challenge_assignments set status = 'completed' where definition_id = 'gw_poets' and status = 'active';
  if (select sum(value) from public.wall_progress) <> 3 then raise exception 'FAIL C3: an unrelated quest counted'; end if;
  v_report := v_report || 'PASS 🚩 group progress: every completed Gathering counts once (tap handles), the Nickname Factory raises the flag, other quests do not count' || E'\n';

  -- D. choosing the hanging signs
  perform pg_temp.imp(m2);
  r := public.set_wall_neons(array['tournee']);
  begin perform public.set_wall_neons(array['tournee', 'open']); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL D1: two signs on the wall'; end if;
  begin perform public.set_wall_neons(array['tripel']); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL D2: a sign that was not found'; end if;
  r := public.set_wall_neons(array['open']);
  if (select value from public.wall_settings where key = 'hung_neons') <> '["open"]'::jsonb then raise exception 'FAIL D4'; end if;
  v_report := v_report || 'PASS 🧲 hanging: exactly one sign hangs, only a found one; any member of the group can change it' || E'\n';

  -- E. a client can not write the wall tables directly
  begin set local role authenticated; insert into public.wall_found_neons (neon_id, found_by) values ('tripel', m2); v_err := null; exception when others then v_err := sqlerrm; end;
  reset role;
  if v_err is null then raise exception 'FAIL E1: a direct insert worked'; end if;
  begin set local role authenticated; update public.wall_progress set value = 99; v_err := null; if (select max(value) from public.wall_progress) = 99 then v_err := null; else v_err := 'blocked'; end if; exception when others then v_err := sqlerrm; end;
  reset role;
  if v_err is null then raise exception 'FAIL E2: progress could be changed by a client'; end if;
  v_report := v_report || 'PASS 🔒 security: no direct writes on the wall tables' || E'\n';

  -- F. the real claim and boxes
  perform pg_temp.imp(m);
  delete from public.wall_found_neons; delete from public.wall_coasters; delete from public.wall_pity;
  update public.wall_neon_signs set sources = '[{"def":"gw_poets","chance":1}]', pity_after = null where id = 'tournee';
  r := pg_temp.done_claim(m, 'gw_poets');
  if not (r ? 'wall') or not (r->'wall' @> '[{"kind":"neon","id":"tournee"}]'::jsonb) then raise exception 'FAIL F1: the claim did not report the wall item: %', r; end if;
  delete from public.wall_found_neons; delete from public.wall_coasters;
  update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"wall":1}'), '{pools,default,rarity}', '{"common":1,"rare":1,"epic":1,"legendary":1}') where key = 'mystery_rewards';
  select count(*) into v_beers from public.beers;
  v_neon := 0; v_coast := 0; v_dups := 0;
  for i in 1..(7 + v_beers + 4) loop
    insert into public.mystery_boxes (user_id) values (m) returning id into v_box;
    r := public.open_mystery_box(v_box);
    if r->'prize'->>'type' = 'wall' then
      if r->'prize'->>'kind' = 'neon' then v_neon := v_neon + 1; else v_coast := v_coast + 1; end if;
    elsif (r->'prize'->>'duplicate_bonus')::boolean is true then v_dups := v_dups + 1;
    else raise exception 'FAIL F2: strange prize %', r; end if;
  end loop;
  if v_neon <> 7 then raise exception 'FAIL F3: % neon signs from boxes (expected all 7)', v_neon; end if;
  if v_neon + v_coast + v_dups <> 7 + v_beers + 4 then raise exception 'FAIL F4'; end if;
  v_report := v_report || format('PASS 🎁 claim and boxes: the claim reports wall finds; boxes gave all %s neon signs and %s coasters, then an XP bonus (%s)', v_neon, v_coast, v_dups) || E'\n';
  raise exception E'\n%', v_report;
end $$;
