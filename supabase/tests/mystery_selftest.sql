-- =================================================================
-- SELF-TEST for 0056_mystery_rewards.sql  (safe: everything is rolled back)
-- =================================================================
-- Run in the Supabase SQL Editor AFTER 0048-0056. Checks: a Mystery line makes one
-- box (replays do not), opening is once-only, the rarity floor, duplicates are
-- avoided, Gauntlet Fragments from boxes stay capped, boxes can not be opened by
-- others, the Daily Sweep gives a guaranteed box. The "error" at the end IS the
-- report; NOTHING is saved.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;
create or replace function pg_temp.rar_i(p text) returns int as $$
  select coalesce(array_position(array['common','rare','epic','legendary','dynasty'], p), 0);
$$ language sql;
create or replace function pg_temp.newbox(p_user uuid, p_floor text default null, p_pool text default 'default') returns uuid as $$
declare v_id uuid;
begin
  insert into public.mystery_boxes (user_id, pool, rarity_floor) values (p_user, p_pool, p_floor) returning id into v_id;
  return v_id;
end;
$$ language plpgsql;

do $$
declare
  v_report text := '';
  m uuid; m2 uuid; v_lord uuid; a uuid; d public.challenge_definitions; b uuid; r jsonb; r2 jsonb; i int; v_n int; v_min int; v_xp0 int;
  v_sweep uuid; v_eligible int; v_err text; v_frag int; v_item uuid; v_item2 uuid; v_item3 uuid; v_who uuid;
begin
  v_lord := public._current_abt_lord();
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id is distinct from v_lord order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  select count(*) into v_eligible from public.abt_cosmetic_items where is_active and mystery_eligible;
  v_report := format('tested as %s; %s mystery-eligible cosmetics', (select display_name from public.profiles where id = m), v_eligible) || E'\n';
  if v_eligible < 5 then raise exception 'ABORTED: too few mystery-eligible cosmetics (%)', v_eligible; end if;
  delete from public.user_abt_cosmetics where user_id = m and unlock_source = 'mystery';
  delete from public.gauntlet_fragments where user_id = m; delete from public.royal_gauntlet_balances where user_id = m;
  delete from public.mystery_boxes where user_id = m;

  -- ===== A. a reward line makes one box; a replay does not make another =====
  begin
    select * into d from public.challenge_definitions where id = 'pw_lorekeeper';
    a := public._new_assignment(d, m, m, 'MB' || substr(md5(random()::text), 1, 6), now() - interval '1 day', now() + interval '2 days');
    r := public._grant_challenge_reward2(m, a, null, '{"kind":"mystery","amount":1,"pool":"default","rarity_floor":"rare"}'::jsonb, 1);
    r2 := public._grant_challenge_reward2(m, a, null, '{"kind":"mystery","amount":1,"pool":"default","rarity_floor":"rare"}'::jsonb, 1);
    if (r->>'boxes')::int <> 1 or (r2->>'duplicate') is distinct from 'true' then raise exception 'FAIL A: grant result % / %', r, r2; end if;
    if (select count(*) from public.mystery_boxes where user_id = m) <> 1 then raise exception 'FAIL A: a replayed claim made another box'; end if;
    if (select rarity_floor from public.mystery_boxes where user_id = m) <> 'rare' then raise exception 'FAIL A: the floor was not stored'; end if;
    v_report := v_report || 'PASS box: a Mystery line makes exactly one box (floor kept), a replay makes none' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== B. opening: once-only, only the owner =====
  begin
    b := pg_temp.newbox(m);
    perform pg_temp.imp(m2);
    v_err := null; begin perform public.open_mystery_box(b); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL B: somebody else opened my box'; end if;
    perform pg_temp.imp(m);
    r := public.open_mystery_box(b);
    if r->>'status' <> 'opened' or r->'prize'->>'type' not in ('cosmetic', 'xp', 'fragment', 'title', 'pet', 'frame', 'wall', 'poem_bg') then raise exception 'FAIL B: strange prize %', r; end if;
    select count(*) into v_n from public.user_abt_cosmetics where user_id = m and unlock_source = 'mystery';
    r2 := public.open_mystery_box(b); perform public.open_mystery_box(b);
    if r2->>'status' <> 'already_opened' or r2->'prize' <> r->'prize' then raise exception 'FAIL B: a second open changed the prize'; end if;
    if (select count(*) from public.user_abt_cosmetics where user_id = m and unlock_source = 'mystery') <> v_n then raise exception 'FAIL B: re-opening unlocked another item'; end if;
    v_report := v_report || 'PASS open: only the owner, the prize is paid once, opening again returns the same prize' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== C. rarity floor =====
  begin
    perform pg_temp.imp(m);
    v_min := 99;
    for i in 1..60 loop
      r := public.open_mystery_box(pg_temp.newbox(m, 'epic'));
      v_min := least(v_min, pg_temp.rar_i(r->'prize'->>'rarity'));
    end loop;
    if v_min < pg_temp.rar_i('epic') then raise exception 'FAIL C: a prize below the epic floor (index %)', v_min; end if;
    v_report := v_report || 'PASS rarity floor: 60 boxes with an epic floor never gave less than epic' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== D. duplicates are avoided (cosmetics are for the Abt Lord) =====
  begin
    v_who := v_lord;
    perform pg_temp.imp(v_who);
    -- own everything except one item
    insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source)
      select v_who, i.id, 'mystery' from public.abt_cosmetic_items i where i.mystery_eligible and i.is_active
        and i.id <> (select id from public.abt_cosmetic_items where mystery_eligible and is_active order by name limit 1)
      on conflict do nothing;
    update public.challenge_config set value = jsonb_set(value, '{pools,default,outcomes}', '{"cosmetic":1}') where key = 'mystery_rewards';
    v_n := 0;
    for i in 1..30 loop
      r := public.open_mystery_box(pg_temp.newbox(v_who));
      if r->'prize'->>'type' = 'cosmetic' then v_n := v_n + 1; end if;
    end loop;
    if v_n > 1 then raise exception 'FAIL D: % cosmetic prizes although only one item was left unowned', v_n; end if;
    if (select count(*) from public.user_abt_cosmetics where user_id = v_who and unlock_source = 'mystery') > v_eligible then raise exception 'FAIL D: more unlocks than items'; end if;
    -- with nothing left: an XP bonus instead of a duplicate
    r := public.open_mystery_box(pg_temp.newbox(v_who));
    if r->'prize'->>'type' <> 'xp' or (r->'prize'->>'duplicate_bonus')::boolean is not true then raise exception 'FAIL D: with everything owned the prize should be a duplicate XP bonus: %', r; end if;
    v_report := v_report || 'PASS duplicates: only unowned cosmetics are given (at most the 1 left), with the whole catalogue owned the box turns into an XP bonus' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== E. Gauntlet progression stays controlled =====
  begin
    perform pg_temp.imp(m);
    update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"fragment":100}'), '{pools,default,rarity}', '{"epic":1}') where key = 'mystery_rewards';
    for i in 1..12 loop perform public.open_mystery_box(pg_temp.newbox(m)); end loop;
    select count(*) into v_n from public.mystery_boxes where user_id = m and prize->>'type' = 'fragment';
    if v_n > 2 then raise exception 'FAIL E: % fragments from boxes in one week (cap 2)', v_n; end if;
    select count(*) into v_n from public.mystery_boxes where user_id = m and prize->>'type' = 'xp';
    if v_n <> 10 then raise exception 'FAIL E: the rest should have become XP (got %)', v_n; end if;
    -- common boxes never give a fragment at all
    delete from public.mystery_boxes where user_id = m;
    update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"fragment":100}'), '{pools,default,rarity}', '{"common":1}') where key = 'mystery_rewards';
    for i in 1..10 loop perform public.open_mystery_box(pg_temp.newbox(m)); end loop;
    if exists (select 1 from public.mystery_boxes where user_id = m and prize->>'type' = 'fragment') then raise exception 'FAIL E: a common box gave a Fragment'; end if;
    v_report := v_report || 'PASS Gauntlet control: Fragments from boxes only from rare up, at most 2 a week, the rest turns into XP' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== F. the Daily Sweep always gives a box =====
  begin
    delete from public.challenge_sweeps where user_id = m;
    insert into public.challenge_sweeps (user_id, period_key, reward) values (m, 'SW' || substr(md5(random()::text), 1, 6), public._challenge_config('daily_sweep', '{}'::jsonb)) returning id into v_sweep;
    perform pg_temp.imp(m);
    perform public.claim_daily_sweep(v_sweep);
    if (select count(*) from public.mystery_boxes where user_id = m) <> 1 then raise exception 'FAIL F: the Daily Sweep did not give exactly 1 box'; end if;
    perform public.claim_daily_sweep(v_sweep);
    if (select count(*) from public.mystery_boxes where user_id = m) <> 1 then raise exception 'FAIL F: a second sweep claim made another box'; end if;
    if not exists (select 1 from public.challenge_config where key = 'weekly_rewards' and (value->'pw_completionist')::text like '%rarity_floor%') then raise exception 'FAIL F: the Completionist has no rarity floor'; end if;
    v_report := v_report || 'PASS 🎁 Daily Sweep: a guaranteed box, once; the hard Weeklies carry floors / guarantees' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== G. the drops are for the Personal Character too =====
  begin
    perform pg_temp.imp(m);
    delete from public.user_abt_cosmetics where user_id = m; delete from public.room_profiles where user_id = m;
    select id into v_item from public.abt_cosmetic_items where mystery_eligible and is_active and category = 'accessory' and not lord_only_drop order by name limit 1;
    select id into v_item2 from public.abt_cosmetic_items where mystery_eligible and is_active and category = 'weapon' order by name limit 1;
    if v_item is null then raise exception 'FAIL G: no accessory in the pool'; end if;
    v_err := null; begin perform public.equip_room_item('accessory', v_item); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL G: wore an item that was never unlocked'; end if;
    insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source) values (m, v_item, 'mystery');
    r := public.equip_room_item('accessory', v_item);
    if r->>'accessory' <> v_item::text then raise exception 'FAIL G: the item was not stored on the character: %', r; end if;
    v_err := null; begin perform public.equip_room_item('weapon', v_item); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL G: an item went into the wrong slot'; end if;
    v_err := null; begin perform public.equip_room_item('cape', v_item); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL G: the cape slot accepted an item'; end if;
    -- a Lord-only item (a milestone that is not in the pool) can not be worn by the character
    select id into v_item3 from public.abt_cosmetic_items where is_active and not mystery_eligible and unlock_type in ('milestone', 'beer_xp') and category in ('headwear', 'armor', 'companion', 'weapon', 'accessory') order by category limit 1;
    insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source) values (m, v_item3, 'milestone');
    v_err := null; begin perform public.equip_room_item((select category from public.abt_cosmetic_items where id = v_item3), v_item3); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL G: a Lord-only item was worn by the Personal Character'; end if;
    r := public.equip_room_item('accessory', null);
    if r ? 'accessory' then raise exception 'FAIL G: taking the item off did not work'; end if;
    -- another member can not touch my character
    perform pg_temp.imp(m2);
    perform public.equip_room_item('accessory', null);
    if (select loadout from public.room_profiles where user_id = m) <> '{}'::jsonb then raise exception 'FAIL G: somebody else changed my character'; end if;
    -- headwear is paused (not in the pool, not wearable)
    if exists (select 1 from public.abt_cosmetic_items where mystery_eligible and category = 'headwear') then raise exception 'FAIL G: headwear is paused but still in the pool'; end if;
    v_err := null; begin perform public.equip_room_item('headwear', (select id from public.abt_cosmetic_items where category = 'headwear' and is_active limit 1)); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL G: headwear could be worn while paused'; end if;
    if exists (select 1 from public.abt_cosmetic_items where mystery_eligible and rarity = 'dynasty') then raise exception 'FAIL G: a Dynasty item is in the pool'; end if;
    v_report := v_report || 'PASS 🧍 Personal Character: drops can be worn in My Room (owned items only, right slot only, no Lord-only items, no capes, off again, nobody else can change it); headwear is paused (not in the pool, not wearable)' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== H. Abt Lord gear drops for the Abt Lord only =====
  begin
    select count(*) into v_n from public.abt_cosmetic_items where is_active and lord_only_drop and category = 'companion' and rarity = 'legendary';
    if v_n <> 4 then raise exception 'FAIL H: expected the 4 legendary companions, found %', v_n; end if;
    update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"cosmetic":1}'), '{pools,default,rarity}', '{"legendary":1}') where key = 'mystery_rewards';
    -- everybody who is not the Lord: never a lord-only item
    perform pg_temp.imp(m); delete from public.user_abt_cosmetics where user_id = m;
    for i in 1..40 loop perform public.open_mystery_box(pg_temp.newbox(m)); end loop;
    if exists (select 1 from public.user_abt_cosmetics u join public.abt_cosmetic_items it on it.id = u.cosmetic_item_id where u.user_id = m and it.lord_only_drop) then
      raise exception 'FAIL H: a non-Lord received Abt Lord gear'; end if;
    -- the Lord does get them (only they are legendary-and-unowned at the end)
    if v_lord is null then raise exception 'ABORTED: no Abt Lord'; end if;
    perform pg_temp.imp(v_lord); delete from public.user_abt_cosmetics where user_id = v_lord;
    for i in 1..60 loop perform public.open_mystery_box(pg_temp.newbox(v_lord)); end loop;
    select count(*) into v_n from public.user_abt_cosmetics u join public.abt_cosmetic_items it on it.id = u.cosmetic_item_id where u.user_id = v_lord and it.lord_only_drop;
    if v_n <> (select count(*) from public.abt_cosmetic_items where is_active and mystery_eligible and lord_only_drop and rarity = 'legendary') then raise exception 'FAIL H: the Lord should be able to collect every legendary Lord item (got %)', v_n; end if;
    -- and he can wear one on his profile as well
    select cosmetic_item_id into v_item from public.user_abt_cosmetics u join public.abt_cosmetic_items it on it.id = u.cosmetic_item_id where u.user_id = v_lord and it.lord_only_drop and it.category = 'companion' limit 1;
    r := public.equip_room_item('companion', v_item);
    if r->>'companion' <> v_item::text then raise exception 'FAIL H: the Lord could not wear it on his profile'; end if;
    v_report := v_report || 'PASS 🦁 Abt Lord gear: the legendary companions drop only for the Abt Lord, he can collect all of them and wear them on his profile' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== I. a normal player never gets a cosmetic =====
  begin
    update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"cosmetic":100,"xp":1}'), '{pools,default,rarity}', '{"common":1}') where key = 'mystery_rewards';
    perform pg_temp.imp(m); delete from public.user_abt_cosmetics where user_id = m;
    for i in 1..40 loop r := public.open_mystery_box(pg_temp.newbox(m)); if r->'prize'->>'type' = 'cosmetic' then raise exception 'FAIL I: a normal player got a cosmetic'; end if; end loop;
    if exists (select 1 from public.user_abt_cosmetics where user_id = m) then raise exception 'FAIL I: a cosmetic was unlocked for a normal player'; end if;
    if (select count(*) from public.mystery_boxes where user_id = m and prize->>'type' = 'xp') <> 40 then raise exception 'FAIL I: the boxes should have paid XP'; end if;
    v_report := v_report || 'PASS 🧍 normal players: 40 boxes with a cosmetic-only pool never gave a cosmetic (XP instead); their character stays base + outfit' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  raise exception E'MYSTERY REPORT (nothing was saved)\n%', v_report;
end $$;
