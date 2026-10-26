-- =================================================================
-- SELF-TEST for 0088_room_furniture.sql  (safe: everything is rolled back)
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
  a := public._new_assignment(d, case when d.type = 'group_weekly' then null else p_user end, p_user, 'TR' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
  update public.challenge_assignments set status = 'completed', progress = target where id = a;
  if d.type = 'group_weekly' then insert into public.challenge_contributions (assignment_id, user_id, amount) values (a, p_user, 1) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.claim_challenge(a);
end;
$$ language plpgsql;

do $$
declare
  v_report text := ''; m uuid; m2 uuid; r jsonb; v_err text; v_n int; i int; v_hit int; v_box uuid; v_got int; v_dups int; v_total int;
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  delete from public.user_room_furniture; delete from public.room_furniture_pity;
  delete from public.challenge_claims where user_id = m; delete from public.challenge_assignments where user_id = m; delete from public.mystery_boxes where user_id = m;
  update public.character_outfit_sets set sources = '[]' where unlock_kind = 'random_drop';
  update public.pet_outfits set sources = '[]'; update public.challenge_config set value = '{"chance": {}, "pity_after": null}' where key = 'pet_drops';
  update public.nickname_frames set sources = '[]'; update public.poem_backgrounds set sources = '[]';
  -- only the starter desk ships for now: the droppable desks below exist only for this test (rolled back at the end)
  insert into public.room_furniture_items (id, slot, name, tag, rarity, sources, pity_after, hint, sort_order, is_starter) values
    ('desk-tavern', 'desk', 'Tapkast-bureau', '🍺 Tapkast', 'common', '[{"def": "pw_beer_explorer", "chance": 0.1}, {"def": "gw_gathering", "chance": 0.1}, {"def": "pd_beer_scholar", "chance": 0.06}, {"def": "pd_new_brew", "chance": 0.06}, {"def": "pd_one_for_the_books", "chance": 0.06}]'::jsonb, 12, 'Drops from the beer quests.', 20, false),
    ('desk-banker', 'desk', 'Bankiersbureau', '💡 Groene lamp', 'common', '[{"def": "pd_lore_master", "chance": 0.08}, {"def": "pd_office_oracle", "chance": 0.08}, {"def": "pd_know_thy_friends", "chance": 0.08}, {"def": "pd_memory_lane", "chance": 0.06}, {"def": "pd_perfect_score", "chance": 0.05}]'::jsonb, 12, 'Drops from the everyday quiz and lore quests.', 30, false),
    ('desk-writer', 'desk', 'Schrijftafel', '⌨️ Typemachine', 'rare', '[{"def": "pw_poet_laureate", "chance": 0.1}, {"def": "pd_poet_for_a_day", "chance": 0.1}, {"def": "pd_poetry_critic", "chance": 0.08}, {"def": "gw_poets", "chance": 0.08}, {"def": "rb_pamphlet", "chance": 0.08}]'::jsonb, 20, 'Drops from the poetry quests.', 40, false),
    ('desk-pirate', 'desk', 'Piratenbureau', '🏴‍☠️ Schatkaart', 'rare', '[{"def": "pw_adventurer", "chance": 0.1}, {"def": "pd_office_safari", "chance": 0.08}, {"def": "rb_storm", "chance": 0.08}, {"def": "gw_fellowship", "chance": 0.08}, {"def": "pd_the_photographer", "chance": 0.05}, {"def": "pd_draw_this", "chance": 0.05}]'::jsonb, 20, 'Drops from the adventure quests and Rebellions.', 50, false),
    ('desk-elven', 'desk', 'Elfenbureau', '🌿 Mos en ranken', 'epic', '[{"def": "pw_keeper_knowledge", "chance": 0.08}, {"def": "pw_social_creature", "chance": 0.08}, {"def": "gw_council", "chance": 0.08}, {"def": "pw_agent_of_chaos", "chance": 0.06}]'::jsonb, 25, 'Drops from the big weekly and Group Quests.', 60, false),
    ('desk-royal', 'desk', 'Koninklijk bureau', '👑 Fluweel', 'legendary', '[{"def": "pw_completionist", "chance": 0.05}, {"def": "gw_council", "chance": 0.04}]'::jsonb, 40, 'Almost only from Mystery Rewards.', 70, false)
    on conflict (id) do nothing;
  select count(*) into v_total from public.room_furniture_items where is_active and slot = 'desk';
  if v_total <> 7 then raise exception 'FAIL 0: expected 7 desks, got %', v_total; end if;
  if (select count(*) from public.room_furniture_items where is_starter) <> 1 then raise exception 'FAIL 0b: exactly one starter expected'; end if;

  -- A. the drop: pity guarantees it, unrelated quests never give it, never twice, the starter never drops
  r := public._furniture_hook(m, null);
  if jsonb_array_length(r) <> 0 then raise exception 'FAIL A1: furniture without a quest'; end if;
  v_hit := 0;
  for i in 1..25 loop r := public._furniture_hook(m, 'pw_keeper_knowledge'); if jsonb_array_length(r) > 0 then v_hit := i; exit; end if; end loop;
  if v_hit = 0 then raise exception 'FAIL A2: no Elven desk within the pity of 25 claims'; end if;
  if not exists (select 1 from public.user_room_furniture where user_id = m and item_id = 'desk-elven') then raise exception 'FAIL A3'; end if;
  if exists (select 1 from public.user_room_furniture where user_id = m and item_id <> 'desk-elven') then raise exception 'FAIL A4: furniture from the wrong quest'; end if;
  for i in 1..60 loop r := public._furniture_hook(m, 'pw_keeper_knowledge'); if jsonb_array_length(r) <> 0 then raise exception 'FAIL A5: dropped twice'; end if; end loop;
  v_hit := 0;
  for i in 1..12 loop r := public._furniture_hook(m, 'pd_beer_scholar'); if jsonb_array_length(r) > 0 then v_hit := i; exit; end if; end loop;
  if v_hit = 0 or not exists (select 1 from public.user_room_furniture where user_id = m and item_id = 'desk-tavern') then raise exception 'FAIL A6: the Tavern desk should come within 12 beer claims'; end if;
  if exists (select 1 from public.user_room_furniture where item_id = 'desk-classic') then raise exception 'FAIL A7: the starter dropped'; end if;
  v_report := v_report || 'PASS 🪑 drops: a desk comes from its own quests only, guaranteed by pity (Elven 25, Tavern 12), never twice, the starter never drops' || E'\n';

  -- B. through the real claim
  delete from public.user_room_furniture where user_id = m; delete from public.room_furniture_pity where user_id = m;
  update public.room_furniture_items set sources = '[{"def":"pd_pick_a_side","chance":1}]' where id = 'desk-pirate';
  perform pg_temp.imp(m);
  r := pg_temp.done_claim(m, 'pd_pick_a_side');
  if not (r ? 'furniture') or not (r->'furniture' @> '[{"id":"desk-pirate"}]'::jsonb) then raise exception 'FAIL B1: the claim did not report the desk: %', r; end if;
  select a.id into v_box from public.challenge_assignments a where a.user_id = m and a.definition_id = 'pd_pick_a_side' limit 1;
  r := public.claim_challenge(v_box);
  if r->>'status' <> 'already_claimed' then raise exception 'FAIL B2: %', r; end if;
  select count(*) into v_n from public.user_room_furniture where user_id = m;
  if v_n <> 1 then raise exception 'FAIL B3: % desks after one claim', v_n; end if;
  v_report := v_report || 'PASS 🎟️ claim: the claim reports the desk, a second click never rolls again' || E'\n';

  -- C. choosing: only owned (or the starter), only the right slot, kept next to the other loadout keys, back to the starter with null
  perform pg_temp.imp(m);
  insert into public.room_profiles (user_id, body_type, loadout) values (m, 'female', '{"outfit":"f1","pet":"kat"}') on conflict (user_id) do update set loadout = '{"outfit":"f1","pet":"kat"}';
  r := public.set_room_furniture('desk', 'desk-pirate');
  if r->'furniture'->>'desk' <> 'desk-pirate' or r->>'outfit' <> 'f1' or r->>'pet' <> 'kat' then raise exception 'FAIL C1: %', r; end if;
  begin perform public.set_room_furniture('desk', 'desk-royal'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C2: used a desk that is not owned'; end if;
  begin perform public.set_room_furniture('bed', 'desk-pirate'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C3: a desk in the wrong slot'; end if;
  begin perform public.set_room_furniture('desk', 'nope'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C4: unknown furniture accepted'; end if;
  r := public.set_room_furniture('desk', 'desk-classic');              -- the starter is everybody's, without any row
  if r->'furniture'->>'desk' <> 'desk-classic' then raise exception 'FAIL C5: %', r; end if;
  r := public.set_room_furniture('desk', null);
  if r ? 'furniture' or r->>'outfit' <> 'f1' then raise exception 'FAIL C6: %', r; end if;
  perform pg_temp.imp(m2);
  begin perform public.set_room_furniture('desk', 'desk-pirate'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL C7: somebody else used my desk'; end if;
  v_report := v_report || 'PASS 🪑 choosing: only desks you own (the starter is everybody''s), only the right slot, other room choices kept, null = back to the starter, others cannot use mine' || E'\n';

  -- D. a client can not write the ownership table directly
  begin
    set local role authenticated;
    insert into public.user_room_furniture (user_id, item_id) values (m2, 'desk-royal');
    v_err := null;
  exception when others then v_err := sqlerrm; end;
  reset role;
  if v_err is null then raise exception 'FAIL D1: a direct insert worked'; end if;
  v_report := v_report || 'PASS 🔒 security: no direct writes on the ownership table' || E'\n';

  -- E. boxes: a desk you do not own, XP when everything is owned
  perform pg_temp.imp(m);
  delete from public.user_room_furniture where user_id = m; delete from public.mystery_boxes where user_id = m;
  update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"furniture":1}'), '{pools,default,rarity}', '{"common":1,"rare":1,"epic":1,"legendary":1}') where key = 'mystery_rewards';
  v_got := 0; v_dups := 0;
  for i in 1..9 loop
    insert into public.mystery_boxes (user_id) values (m) returning id into v_box;
    r := public.open_mystery_box(v_box);
    if r->'prize'->>'type' = 'furniture' then v_got := v_got + 1;
    elsif (r->'prize'->>'duplicate_bonus')::boolean is true then v_dups := v_dups + 1;
    else raise exception 'FAIL E1: strange prize %', r; end if;
  end loop;
  if v_got <> 6 or v_dups <> 3 then raise exception 'FAIL E2: % desks and % bonuses (expected 6 and 3)', v_got, v_dups; end if;
  v_report := v_report || 'PASS 🎁 boxes: all 6 droppable desks found without duplicates, then an XP bonus' || E'\n';

  raise exception E'\n%', v_report;
end $$;
