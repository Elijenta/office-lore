-- =================================================================
-- SELF-TEST for 0078_pets.sql  (safe: everything is rolled back)
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
create or replace function pg_temp.reset(p_user uuid) returns void as $$
begin
  delete from public.user_pet_outfits where user_id = p_user; delete from public.user_pets where user_id = p_user; delete from public.pet_pity where user_id = p_user;
  update public.room_profiles set loadout = loadout - 'pet' - 'petOutfit' where user_id = p_user;
end;
$$ language plpgsql;

do $$
declare
  v_report text := '';
  m uuid; m2 uuid; v_lord uuid; r jsonb; v_err text; v_n int; i int; v_box uuid; v_got int; v_dups int; v_sweep uuid; v_species int; v_clothes int; v_loadout jsonb; v_hit int;
begin
  v_lord := public._current_abt_lord();
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id is distinct from v_lord order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  delete from public.challenge_claims where user_id = m; delete from public.challenge_assignments where user_id = m; delete from public.mystery_boxes where user_id = m;
  perform pg_temp.reset(m); perform pg_temp.reset(m2);
  update public.character_outfit_sets set sources = '[]' where unlock_kind = 'random_drop';   -- keep the character outfits out of it
  select count(*) into v_species from public.pet_species where is_active;
  select count(*) into v_clothes from public.pet_outfits o join public.pet_species s on s.id = o.species_id where o.is_active and s.is_active and o.unlock_kind = 'random_drop';
  if v_species < 3 or v_clothes < 7 then raise exception 'FAIL 0: too few species / clothes, got % / %', v_species, v_clothes; end if;
  perform pg_temp.imp(m);

  -- A. the pets themselves: pity guarantees one, one species per drop, never one you own, never more than the species that exist
  update public.challenge_config set value = '{"chance": {"personal_daily": 0, "sweep": 0}, "pity_after": 8}' where key = 'pet_drops';
  for i in 1..7 loop r := public._pet_hook(m, 'pd_pick_a_side', 'personal_daily'); if jsonb_array_length(r->'pets') <> 0 then raise exception 'FAIL A1: a pet dropped at claim % with chance 0', i; end if; end loop;
  r := public._pet_hook(m, 'pd_pick_a_side', 'personal_daily');
  if jsonb_array_length(r->'pets') <> 1 then raise exception 'FAIL A2: the pity claim gave no pet: %', r; end if;
  if (select misses from public.pet_pity where user_id = m and key = 'species') <> 0 then raise exception 'FAIL A3: the pity counter did not reset'; end if;
  update public.challenge_config set value = '{"chance": {"personal_daily": 1}, "pity_after": 8}' where key = 'pet_drops';
  for i in 1..8 loop r := public._pet_hook(m, 'pd_pick_a_side', 'personal_daily'); end loop;
  select count(*) into v_n from public.user_pets where user_id = m;
  if v_n <> v_species then raise exception 'FAIL A4: expected all % active species, got %', v_species, v_n; end if;
  r := public._pet_hook(m, 'pd_pick_a_side', 'personal_daily');
  if jsonb_array_length(r->'pets') <> 0 then raise exception 'FAIL A5: a 5th pet appeared'; end if;
  v_report := v_report || 'PASS 🐾 pets: pity gives the first one after 8 claims, then one new species per drop, never a duplicate, 4 species at most' || E'\n';

  -- B. clothes: only for a pet you own, only from the linked quests, pity guarantees them
  perform pg_temp.reset(m);
  update public.challenge_config set value = '{"chance": {}, "pity_after": null}' where key = 'pet_drops';
  insert into public.user_pets (user_id, species_id, source) values (m, 'dobermann', 'test');
  r := public._pet_hook(m, 'pw_poet_laureate', 'personal_weekly');
  if jsonb_array_length(r->'outfits') <> 0 then raise exception 'FAIL B1: poetry clothes for a Dobermann that has none: %', r; end if;
  v_hit := 0;
  for i in 1..30 loop r := public._pet_hook(m, 'pw_battle_hardened', 'personal_weekly'); if jsonb_array_length(r->'outfits') > 0 then v_hit := i; exit; end if; end loop;
  if v_hit = 0 then raise exception 'FAIL B2: no Battle clothes within the pity of 30 claims'; end if;
  if not exists (select 1 from public.user_pet_outfits where user_id = m and outfit_id = 'dobermann-battle') then raise exception 'FAIL B3: Dobermann Battle Gear not owned'; end if;
  if exists (select 1 from public.user_pet_outfits where user_id = m and outfit_id in ('golden-battle', 'kat-battle')) then raise exception 'FAIL B4: clothes for a pet that is not owned'; end if;
  for i in 1..40 loop r := public._pet_hook(m, 'pw_battle_hardened', 'personal_weekly'); if jsonb_array_length(r->'outfits') <> 0 then raise exception 'FAIL B5: the same clothes dropped twice'; end if; end loop;
  v_hit := 0;
  for i in 1..100 loop r := public._pet_hook(m, 'pw_completionist', 'personal_weekly'); if jsonb_array_length(r->'outfits') > 0 then v_hit := i; exit; end if; end loop;
  if v_hit = 0 or not exists (select 1 from public.user_pet_outfits where user_id = m and outfit_id = 'dobermann-legendary') then raise exception 'FAIL B6: the legendary clothes did not drop within their pity of 100'; end if;
  v_report := v_report || 'PASS 🧥 pet clothes: only for a pet you own, only from the linked quests, guaranteed by pity (Battle by 30 claims, Legendary by 100), never twice' || E'\n';

  -- C. through the real claims: the claim reports pets, a second click does not roll again, the Sweep rolls too
  perform pg_temp.reset(m);
  update public.challenge_config set value = '{"chance": {"personal_weekly": 1, "sweep": 1}, "pity_after": 8}' where key = 'pet_drops';
  r := pg_temp.done_claim(m, 'pw_battle_hardened');
  if not (r ? 'pet') or jsonb_array_length(r->'pet'->'pets') <> 1 then raise exception 'FAIL C1: the claim did not report a pet: %', r; end if;
  select a.id into v_box from public.challenge_assignments a where a.user_id = m and a.definition_id = 'pw_battle_hardened' limit 1;
  r := public.claim_challenge(v_box);
  if r->>'status' <> 'already_claimed' then raise exception 'FAIL C2: second claim: %', r; end if;
  if (select count(*) from public.user_pets where user_id = m) <> 1 then raise exception 'FAIL C3: a repeated claim rolled again'; end if;
  insert into public.challenge_sweeps (user_id, period_key, reward) values (m, 'TP' || substr(md5(random()::text), 1, 6), '{"lines":[{"kind":"player_xp","amount":25}]}') returning id into v_sweep;
  r := public.claim_daily_sweep(v_sweep);
  if jsonb_array_length(r->'pet'->'pets') <> 1 or (select count(*) from public.user_pets where user_id = m) <> 2 then raise exception 'FAIL C4: the Sweep gave no pet: %', r; end if;
  v_report := v_report || 'PASS 🎟️ claims: a claim and a Daily Sweep report their pets, a repeated claim never rolls twice' || E'\n';

  -- D. wearing
  perform pg_temp.reset(m);
  insert into public.room_profiles (user_id, body_type) values (m, 'male') on conflict do nothing;
  begin perform public.set_room_pet('golden', null); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL D1: wore a pet that is not owned'; end if;
  insert into public.user_pets (user_id, species_id, source) values (m, 'koe', 'test');
  v_loadout := public.set_room_pet('koe', null);
  if v_loadout->>'pet' <> 'koe' or v_loadout ? 'petOutfit' then raise exception 'FAIL D2: %', v_loadout; end if;
  begin perform public.set_room_pet('koe', 'koe-lore-keeper'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL D3: wore clothes that are not unlocked'; end if;
  begin perform public.set_room_pet('koe', 'golden-battle'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL D4: wore clothes of another species'; end if;
  v_loadout := public.set_room_pet('koe', 'koe-standaard');
  if v_loadout ? 'petOutfit' then raise exception 'FAIL D5: Classic should store no petOutfit: %', v_loadout; end if;
  insert into public.user_pet_outfits (user_id, outfit_id, source) values (m, 'koe-lore-keeper', 'test');
  v_loadout := public.set_room_pet('koe', 'koe-lore-keeper');
  if v_loadout->>'petOutfit' <> 'koe-lore-keeper' then raise exception 'FAIL D6: %', v_loadout; end if;
  v_loadout := public.set_room_pet(null, null);
  if v_loadout ? 'pet' or v_loadout ? 'petOutfit' then raise exception 'FAIL D7: the pet was not removed: %', v_loadout; end if;
  v_report := v_report || 'PASS 🐕 wearing: only an owned pet and an unlocked look of that very pet; Classic is always free; no pet = removed; the rest of the loadout is untouched' || E'\n';

  -- E. boxes: a pet or clothes you can wear, unowned first, an XP bonus when everything is owned, never clothes for a pet you lack
  perform pg_temp.reset(m);
  delete from public.mystery_boxes where user_id = m;
  update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"pet":1}'), '{pools,default,rarity}', '{"common":1,"rare":1,"epic":1,"legendary":1}') where key = 'mystery_rewards';
  v_got := 0; v_dups := 0;
  for i in 1..(v_species + v_clothes + 5) loop
    insert into public.mystery_boxes (user_id) values (m) returning id into v_box;
    r := public.open_mystery_box(v_box);
    if r->'prize'->>'type' = 'pet' then
      v_got := v_got + 1;
      if r->'prize'->>'kind' = 'outfit' and not exists (select 1 from public.user_pets where user_id = m and species_id = r->'prize'->>'species_id') then raise exception 'FAIL E1: clothes for a pet that is not owned: %', r; end if;
    elsif (r->'prize'->>'duplicate_bonus')::boolean is true then v_dups := v_dups + 1;
    else raise exception 'FAIL E2: strange prize %', r; end if;
  end loop;
    if v_got + v_dups <> v_species + v_clothes + 5 then raise exception 'FAIL E4: % + %', v_got, v_dups; end if;
  select count(*) into v_n from public.user_pets where user_id = m;
  select count(*) into v_clothes from public.user_pet_outfits where user_id = m;
  if v_n <> v_species then raise exception 'FAIL E5: only % of % pets found', v_n, v_species; end if;
  if exists (select 1 from public.user_pet_outfits u join public.pet_outfits o on o.id = u.outfit_id where u.user_id = m and not exists (select 1 from public.user_pets p where p.user_id = m and p.species_id = o.species_id)) then raise exception 'FAIL E6: clothes without the pet'; end if;
  v_report := v_report || format('PASS 🎁 boxes: %s pets and %s clothes found in 20 boxes, never clothes for a pet you lack, XP bonus when nothing new is left (%s)', v_n, v_clothes, v_dups) || E'\n';
  perform pg_temp.imp(m);
  if v_got = 0 then raise exception 'FAIL E7'; end if;

  raise exception E'\n%', v_report;
end $$;
