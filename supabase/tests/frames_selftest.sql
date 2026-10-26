-- =================================================================
-- SELF-TEST for 0082_nickname_frames.sql  (safe: everything is rolled back)
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
  a := public._new_assignment(d, case when d.type = 'group_weekly' then null else p_user end, p_user, 'TF' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
  update public.challenge_assignments set status = 'completed', progress = target where id = a;
  if d.type = 'group_weekly' then insert into public.challenge_contributions (assignment_id, user_id, amount) values (a, p_user, 1) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.claim_challenge(a);
end;
$$ language plpgsql;

do $$
declare
  v_report text := ''; m uuid; m2 uuid; r jsonb; v_err text; v_n int; i int; v_hit int; v_box uuid; v_got int; v_dups int;
  n1 uuid; n2 uuid; n3 uuid; n4 uuid; v_total int;
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  delete from public.nickname_frame_assignments; delete from public.user_nickname_frames; delete from public.nickname_frame_pity;
  delete from public.challenge_claims where user_id = m; delete from public.challenge_assignments where user_id = m; delete from public.mystery_boxes where user_id = m;
  update public.character_outfit_sets set sources = '[]' where unlock_kind = 'random_drop';
  update public.pet_outfits set sources = '[]'; update public.challenge_config set value = '{"chance": {}, "pity_after": null}' where key = 'pet_drops';
  select count(*) into v_total from public.nickname_frames where is_active;
  if v_total <> 7 then raise exception 'FAIL 0: expected 7 frames, got %', v_total; end if;

  -- A. the drop: pity guarantees it, unrelated quests never give it, never twice
  r := public._frame_hook(m, null);
  if jsonb_array_length(r) <> 0 then raise exception 'FAIL A1: a frame without a quest'; end if;
  r := public._frame_hook(m, 'pw_poet_laureate');
  update public.nickname_frame_pity set misses = 0 where user_id = m;
  v_hit := 0;
  for i in 1..30 loop r := public._frame_hook(m, 'pw_battle_hardened'); if jsonb_array_length(r) > 0 then v_hit := i; exit; end if; end loop;
  if v_hit = 0 then raise exception 'FAIL A2: no flame within the pity of 30 claims'; end if;
  if not exists (select 1 from public.user_nickname_frames where user_id = m and frame_id = 'flame') then raise exception 'FAIL A3'; end if;
  if exists (select 1 from public.user_nickname_frames where user_id = m and frame_id not in ('flame', 'heart')) then raise exception 'FAIL A4: a frame from the wrong quest'; end if;
  for i in 1..40 loop r := public._frame_hook(m, 'pw_battle_hardened'); if jsonb_array_length(r) <> 0 then raise exception 'FAIL A5: the flame dropped twice'; end if; end loop;
  v_hit := 0;
  for i in 1..10 loop r := public._frame_hook(m, 'gw_fellowship'); if jsonb_array_length(r) > 0 then v_hit := i; exit; end if; end loop;
  if v_hit = 0 or not exists (select 1 from public.user_nickname_frames where user_id = m and frame_id = 'conf') then raise exception 'FAIL A6: Confetti should come within 10 Group Quest claims'; end if;
  v_report := v_report || 'PASS 🖼️ drops: a frame comes from its own quests only, guaranteed by pity (Flame 30, Confetti 10), never twice' || E'\n';

  -- B. through the real claim
  delete from public.user_nickname_frames where user_id = m; delete from public.nickname_frame_pity where user_id = m;
  update public.nickname_frames set sources = '[{"def":"pd_pick_a_side","chance":1}]' where id = 'flame';
  perform pg_temp.imp(m);
  r := pg_temp.done_claim(m, 'pd_pick_a_side');
  if not (r ? 'frames') or not (r->'frames' @> '[{"id":"flame"}]'::jsonb) then raise exception 'FAIL B1: the claim did not report the frame: %', r; end if;
  select a.id into v_box from public.challenge_assignments a where a.user_id = m and a.definition_id = 'pd_pick_a_side' limit 1;
  r := public.claim_challenge(v_box);
  if r->>'status' <> 'already_claimed' then raise exception 'FAIL B2: %', r; end if;
  select count(*) into v_n from public.user_nickname_frames where user_id = m;
  if v_n <> 1 then raise exception 'FAIL B3: % frames after one claim', v_n; end if;
  v_report := v_report || 'PASS 🎟️ claim: the claim reports the frame, a second click never rolls again' || E'\n';

  -- C. giving a frame to your own nicknames: only yours, only owned, at most 2 per frame
  insert into public.nicknames (nickname, person_real_name, created_by_user_id) values ('Frame One', 'Kim', m) returning id into n1;
  insert into public.nicknames (nickname, person_real_name, created_by_user_id) values ('Frame Two', 'Kim', m) returning id into n2;
  insert into public.nicknames (nickname, person_real_name, created_by_user_id) values ('Frame Three', 'Kim', m) returning id into n3;
  insert into public.nicknames (nickname, person_real_name, created_by_user_id) values ('Not Mine', 'Kim', m2) returning id into n4;
  perform pg_temp.imp(m);
  r := public.set_nickname_frame(n1, 'flame');
  r := public.set_nickname_frame(n2, 'flame');
  begin perform public.set_nickname_frame(n3, 'flame'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C1: a third nickname got the same frame'; end if;
  r := public.set_nickname_frame(n1, 'flame');                         -- the same nickname again is fine
  begin perform public.set_nickname_frame(n4, 'flame'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C2: framed somebody else''s nickname'; end if;
  begin perform public.set_nickname_frame(n3, 'ice'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C3: used a frame that is not owned'; end if;
  r := public.set_nickname_frame(n2, null);
  r := public.set_nickname_frame(n3, 'flame');                         -- room again after removing one
  select count(*) into v_n from public.nickname_frame_assignments where user_id = m and frame_id = 'flame';
  if v_n <> 2 then raise exception 'FAIL C4: % uses', v_n; end if;
  perform pg_temp.imp(m2);
  begin perform public.set_nickname_frame(n1, null); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C5: somebody else removed my frame'; end if;
  perform pg_temp.imp(m);
  delete from public.nicknames where id = n1;
  if exists (select 1 from public.nickname_frame_assignments where nickname_id = n1) then raise exception 'FAIL C6: assignment survived the nickname'; end if;
  v_report := v_report || 'PASS 🖼️ giving frames: only your own nicknames, only frames you own, max 2 per frame, removable, others cannot touch it, gone with the nickname' || E'\n';

  -- D. a client can not write the table directly
  begin
    set local role authenticated;
    insert into public.nickname_frame_assignments (nickname_id, frame_id, user_id) values (n4, 'flame', m2);
    v_err := null;
  exception when others then v_err := sqlerrm; end;
  reset role;
  if v_err is null then raise exception 'FAIL D1: a direct insert worked'; end if;
  v_report := v_report || 'PASS 🔒 security: no direct writes on the assignments table' || E'\n';

  -- E. boxes: a frame you do not own, XP when everything is owned
  delete from public.user_nickname_frames where user_id = m; delete from public.mystery_boxes where user_id = m;
  update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"frame":1}'), '{pools,default,rarity}', '{"common":1,"rare":1,"epic":1,"legendary":1}') where key = 'mystery_rewards';
  v_got := 0; v_dups := 0;
  for i in 1..11 loop
    insert into public.mystery_boxes (user_id) values (m) returning id into v_box;
    r := public.open_mystery_box(v_box);
    if r->'prize'->>'type' = 'frame' then v_got := v_got + 1;
    elsif (r->'prize'->>'duplicate_bonus')::boolean is true then v_dups := v_dups + 1;
    else raise exception 'FAIL E1: strange prize %', r; end if;
  end loop;
  if v_got <> 7 or v_dups <> 4 then raise exception 'FAIL E2: % frames and % bonuses (expected 7 and 4)', v_got, v_dups; end if;
  v_report := v_report || 'PASS 🎁 boxes: all 7 frames found without duplicates, then an XP bonus' || E'\n';

  raise exception E'\n%', v_report;
end $$;
