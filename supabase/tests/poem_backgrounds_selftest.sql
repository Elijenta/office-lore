-- =================================================================
-- SELF-TEST for 0087_poem_backgrounds.sql  (safe: everything is rolled back)
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
  a := public._new_assignment(d, case when d.type = 'group_weekly' then null else p_user end, p_user, 'TP' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
  update public.challenge_assignments set status = 'completed', progress = target where id = a;
  if d.type = 'group_weekly' then insert into public.challenge_contributions (assignment_id, user_id, amount) values (a, p_user, 1) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.claim_challenge(a);
end;
$$ language plpgsql;

do $$
declare
  v_report text := ''; m uuid; m2 uuid; r jsonb; v_err text; v_n int; i int; v_hit int; v_box uuid; v_got int; v_dups int;
  p1 uuid; p2 uuid; p3 uuid; p4 uuid; v_total int;
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  delete from public.poem_background_assignments; delete from public.user_poem_backgrounds; delete from public.poem_background_pity;
  delete from public.challenge_claims where user_id = m; delete from public.challenge_assignments where user_id = m; delete from public.mystery_boxes where user_id = m;
  update public.character_outfit_sets set sources = '[]' where unlock_kind = 'random_drop';
  update public.pet_outfits set sources = '[]'; update public.challenge_config set value = '{"chance": {}, "pity_after": null}' where key = 'pet_drops';
  update public.nickname_frames set sources = '[]';
  select count(*) into v_total from public.poem_backgrounds where is_active;
  if v_total <> 9 then raise exception 'FAIL 0: expected 9 backgrounds, got %', v_total; end if;
  if (select count(*) from public.poem_backgrounds where is_starter) <> 1 then raise exception 'FAIL 0b: exactly one starter expected'; end if;

  -- A. the drop: pity guarantees it, unrelated quests never give it, never twice, the starter never drops
  r := public._poem_bg_hook(m, null);
  if jsonb_array_length(r) <> 0 then raise exception 'FAIL A1: a background without a quest'; end if;
  v_hit := 0;
  for i in 1..25 loop r := public._poem_bg_hook(m, 'pw_agent_of_chaos'); if jsonb_array_length(r) > 0 then v_hit := i; exit; end if; end loop;
  if v_hit = 0 then raise exception 'FAIL A2: no Starry Night within the pity of 25 claims'; end if;
  if not exists (select 1 from public.user_poem_backgrounds where user_id = m and background_id = 'night') then raise exception 'FAIL A3'; end if;
  if exists (select 1 from public.user_poem_backgrounds where user_id = m and background_id <> 'night') then raise exception 'FAIL A4: a background from the wrong quest'; end if;
  for i in 1..60 loop r := public._poem_bg_hook(m, 'pw_agent_of_chaos'); if jsonb_array_length(r) <> 0 then raise exception 'FAIL A5: dropped twice'; end if; end loop;
  v_hit := 0;
  for i in 1..12 loop r := public._poem_bg_hook(m, 'pd_the_critic'); if jsonb_array_length(r) > 0 then v_hit := i; exit; end if; end loop;
  if v_hit = 0 or not exists (select 1 from public.user_poem_backgrounds where user_id = m and background_id = 'type') then raise exception 'FAIL A6: the Typewriter should come within 12 daily claims'; end if;
  if exists (select 1 from public.user_poem_backgrounds where background_id = 'parch') then raise exception 'FAIL A7: the starter dropped'; end if;
  v_report := v_report || 'PASS 📜 drops: a background comes from its own quests only, guaranteed by pity (Starry Night 25, Typewriter 12), never twice, the starter never drops' || E'\n';

  -- B. through the real claim
  delete from public.user_poem_backgrounds where user_id = m; delete from public.poem_background_pity where user_id = m;
  update public.poem_backgrounds set sources = '[{"def":"pd_pick_a_side","chance":1}]' where id = 'love';
  perform pg_temp.imp(m);
  r := pg_temp.done_claim(m, 'pd_pick_a_side');
  if not (r ? 'poem_bgs') or not (r->'poem_bgs' @> '[{"id":"love"}]'::jsonb) then raise exception 'FAIL B1: the claim did not report the background: %', r; end if;
  select a.id into v_box from public.challenge_assignments a where a.user_id = m and a.definition_id = 'pd_pick_a_side' limit 1;
  r := public.claim_challenge(v_box);
  if r->>'status' <> 'already_claimed' then raise exception 'FAIL B2: %', r; end if;
  select count(*) into v_n from public.user_poem_backgrounds where user_id = m;
  if v_n <> 1 then raise exception 'FAIL B3: % backgrounds after one claim', v_n; end if;
  v_report := v_report || 'PASS 🎟️ claim: the claim reports the background, a second click never rolls again' || E'\n';

  -- C. choosing a background for your own poems: only yours, only owned (or the starter), at most 2 per background
  insert into public.poems (author_user_id, title, content, mood) values (m, 'One', 'first poem body for the test here', 'other') returning id into p1;
  insert into public.poems (author_user_id, title, content, mood) values (m, 'Two', 'second poem body for the test here', 'other') returning id into p2;
  insert into public.poems (author_user_id, title, content, mood) values (m, 'Three', 'third poem body for the test here', 'other') returning id into p3;
  insert into public.poems (author_user_id, title, content, mood) values (m2, 'Not mine', 'fourth poem body for the test here', 'other') returning id into p4;
  perform pg_temp.imp(m);
  r := public.set_poem_background(p1, 'love');
  r := public.set_poem_background(p2, 'love');
  begin perform public.set_poem_background(p3, 'love'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C1: a third poem got the same background'; end if;
  r := public.set_poem_background(p1, 'love');                        -- the same poem again is fine
  begin perform public.set_poem_background(p4, 'love'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C2: gave somebody else''s poem a background'; end if;
  begin perform public.set_poem_background(p3, 'magic'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C3: used a background that is not owned'; end if;
  r := public.set_poem_background(p3, 'parch');                       -- the starter gift: everybody owns it
  r := public.set_poem_background(p2, null);
  r := public.set_poem_background(p3, 'love');                        -- room again after removing one
  select count(*) into v_n from public.poem_background_assignments where user_id = m and background_id = 'love';
  if v_n <> 2 then raise exception 'FAIL C4: % uses', v_n; end if;
  perform pg_temp.imp(m2);
  begin perform public.set_poem_background(p1, null); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C5: somebody else removed my background'; end if;
  perform pg_temp.imp(m2);
  r := public.set_poem_background(p4, 'parch');                       -- the second member also has the starter, without any row
  perform pg_temp.imp(m);
  delete from public.poems where id = p1;
  if exists (select 1 from public.poem_background_assignments where poem_id = p1) then raise exception 'FAIL C6: assignment survived the poem'; end if;
  v_report := v_report || 'PASS 📜 choosing: only your own poems, only backgrounds you own (the starter is everybody''s), max 2 per background, removable, others cannot touch it, gone with the poem' || E'\n';

  -- D. a client can not write the table directly
  begin
    set local role authenticated;
    insert into public.poem_background_assignments (poem_id, background_id, user_id) values (p4, 'parch', m2);
    v_err := null;
  exception when others then v_err := sqlerrm; end;
  reset role;
  if v_err is null then raise exception 'FAIL D1: a direct insert worked'; end if;
  v_report := v_report || 'PASS 🔒 security: no direct writes on the assignments table' || E'\n';

  -- E. boxes: a background you do not own, XP when everything is owned
  delete from public.user_poem_backgrounds where user_id = m; delete from public.mystery_boxes where user_id = m;
  update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"poem_bg":1}'), '{pools,default,rarity}', '{"common":1,"rare":1,"epic":1,"legendary":1}') where key = 'mystery_rewards';
  v_got := 0; v_dups := 0;
  for i in 1..11 loop
    insert into public.mystery_boxes (user_id) values (m) returning id into v_box;
    r := public.open_mystery_box(v_box);
    if r->'prize'->>'type' = 'poem_bg' then v_got := v_got + 1;
    elsif (r->'prize'->>'duplicate_bonus')::boolean is true then v_dups := v_dups + 1;
    else raise exception 'FAIL E1: strange prize %', r; end if;
  end loop;
  if v_got <> 8 or v_dups <> 3 then raise exception 'FAIL E2: % backgrounds and % bonuses (expected 8 and 3)', v_got, v_dups; end if;
  if exists (select 1 from public.user_poem_backgrounds where user_id = m and background_id = 'parch') then raise exception 'FAIL E3: the starter came out of a box'; end if;
  v_report := v_report || 'PASS 🎁 boxes: all 8 droppable backgrounds found without duplicates, then an XP bonus' || E'\n';

  raise exception E'\n%', v_report;
end $$;
