-- =================================================================
-- SELF-TEST for 0075_titles.sql  (safe: everything is rolled back)
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
  a := public._new_assignment(d, case when d.type = 'group_weekly' then null else p_user end, p_user, 'TT' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
  update public.challenge_assignments set status = 'completed', progress = target where id = a;
  if d.type = 'group_weekly' then insert into public.challenge_contributions (assignment_id, user_id, amount) values (a, p_user, 1) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.claim_challenge(a);
end;
$$ language plpgsql;

do $$
declare
  v_report text := '';
  m uuid; m2 uuid; v_lord uuid; r jsonb; v_err text; v_n int; i int; v_sweep uuid; v_box uuid; v_got int; v_dups int;
begin
  v_lord := public._current_abt_lord();
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id is distinct from v_lord order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  delete from public.user_character_titles where user_id in (m, m2); delete from public.challenge_claims where user_id = m;
  delete from public.challenge_assignments where user_id = m; delete from public.mystery_boxes where user_id = m;
  update public.character_outfit_sets set sources = '[]' where unlock_kind = 'random_drop';
  perform pg_temp.imp(m);

  -- A. milestone titles from claims: the first quest of a family, then the 10th, never twice, never from another family
  r := pg_temp.done_claim(m, 'pd_quote_hunter');
  if not (r->'titles' @> '[{"id":"lore_1"}]'::jsonb) then raise exception 'FAIL A1: the first Lore quest gave no title: %', r; end if;
  if not (r->'titles' @> '[{"id":"dailies_1"}]'::jsonb) then raise exception 'FAIL A2: the first Daily gave no "all Dailies" title: %', r; end if;
  r := pg_temp.done_claim(m, 'pd_quote_hunter');
  if jsonb_array_length(r->'titles') <> 0 then raise exception 'FAIL A3: a title was granted twice: %', r; end if;
  if exists (select 1 from public.user_character_titles where user_id = m and title_id like 'poetry%') then raise exception 'FAIL A4: a Poetry title from a Lore quest'; end if;
  for i in 3..10 loop r := pg_temp.done_claim(m, 'pd_quote_hunter'); end loop;
  if not exists (select 1 from public.user_character_titles where user_id = m and title_id = 'lore_2') then raise exception 'FAIL A5: 10 Lore quests did not give The Lorekeeper'; end if;
  -- a repeated claim of one assignment does not count again
  select count(*) into v_n from public.challenge_claims c join public.challenge_assignments a on a.id = c.assignment_id where c.user_id = m and a.definition_id = 'pd_quote_hunter';
  if v_n <> 10 then raise exception 'FAIL A6: % claims counted', v_n; end if;
  -- group quests and the Group Daily count in their own families
  r := pg_temp.done_claim(m, 'gw_poets');
  if not (r->'titles' @> '[{"id":"gweekly_1"}]'::jsonb and r->'titles' @> '[{"id":"poetry_1"}]'::jsonb) then raise exception 'FAIL A7: a Group Quest should give Fellow and Verse Rookie: %', r; end if;
  r := pg_temp.done_claim(m, 'pw_beer_explorer');
  if not (r->'titles' @> '[{"id":"beer_1"}]'::jsonb) then raise exception 'FAIL A8: Beer Explorer should give Taproom Newcomer: %', r; end if;
  v_report := v_report || 'PASS 🏷️ claim titles: the 1st / 10th quest of a family, per family (Lore, Poetry, Beer discovery, All Dailies, Group Quests ...), never twice, never from the wrong family' || E'\n';

  -- B. Daily Sweeps and Mystery boxes
  insert into public.challenge_sweeps (user_id, period_key, reward) values (m, 'TS' || substr(md5(random()::text), 1, 6), '{"lines":[{"kind":"player_xp","amount":25}]}') returning id into v_sweep;
  r := public.claim_daily_sweep(v_sweep);
  if not (r->'titles' @> '[{"id":"sweep_1"}]'::jsonb) then raise exception 'FAIL B1: the first Sweep gave no title: %', r; end if;
  insert into public.mystery_boxes (user_id) values (m) returning id into v_box;
  r := public.open_mystery_box(v_box);
  if not (r->'titles' @> '[{"id":"box_1"}]'::jsonb) then raise exception 'FAIL B2: the first box gave no Box Opener title: %', r; end if;
  v_report := v_report || 'PASS 🧹 Sweep / box titles: Clean Sweep and Box Opener come with the first claimed Sweep / opened box' || E'\n';

  -- C. drop titles from boxes: a title, unowned first, never a duplicate, XP when all are owned, never for the cosmetic
  update public.challenge_config set value = jsonb_set(jsonb_set(value, '{pools,default,outcomes}', '{"title":1}'), '{pools,default,rarity}', '{"common":1,"rare":1,"epic":1,"legendary":1}') where key = 'mystery_rewards';
  -- the box opened in B may already have dropped one of them
  select count(*) into v_n from public.character_titles t where t.unlock_kind = 'drop' and t.is_active and not exists (select 1 from public.user_character_titles u where u.user_id = m and u.title_id = t.id);
  v_got := 0; v_dups := 0;
  for i in 1..(v_n + 6) loop
    insert into public.mystery_boxes (user_id) values (m) returning id into v_box;
    r := public.open_mystery_box(v_box);
    if r->'prize'->>'type' = 'title' then v_got := v_got + 1;
    elsif (r->'prize'->>'duplicate_bonus')::boolean is true then v_dups := v_dups + 1;
    else raise exception 'FAIL C1: strange prize %', r; end if;
  end loop;
  if v_got <> v_n then raise exception 'FAIL C2: expected to collect all % drop titles, got % (and % XP bonuses)', v_n, v_got, v_dups; end if;
  if v_dups < 6 then raise exception 'FAIL C3: once everything is owned a box must turn into an XP bonus (%)', v_dups; end if;
  if (select count(*) from public.user_character_titles u join public.character_titles t on t.id = u.title_id where u.user_id = m and t.unlock_kind = 'drop') <> (select count(*) from public.character_titles where unlock_kind = 'drop' and is_active) then raise exception 'FAIL C4: duplicate or missing drop titles'; end if;
  v_report := v_report || 'PASS 🎁 drop titles: boxes give a title you do not own yet (all ' || v_n || ' collected), then an XP bonus; a normal player never gets a cosmetic from them' || E'\n';

  -- D. wearing a title
  v_err := null; begin perform public.set_room_title('lore_3'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL D1: wore a title that was never earned'; end if;
  r := public.set_room_title('lore_2');
  if r->>'title' <> 'lore_2' then raise exception 'FAIL D2: %', r; end if;
  r := public.set_room_title('lore_1'); r := public.set_room_title(null);
  if r ? 'title' then raise exception 'FAIL D3: taking the title off did not work'; end if;
  perform pg_temp.imp(m2); perform public.set_room_title(null);
  if (select loadout ? 'title' from public.room_profiles where user_id = m) then raise exception 'FAIL D4: another member changed my title'; end if;
  perform pg_temp.imp(m);
  r := public.set_room_title('lore_2');
  v_report := v_report || 'PASS 🪪 wearing: only earned titles, one at a time, off again, nobody else can change it' || E'\n';
  raise exception 'ROLLBACK_OK';
exception when others then
  if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if;
  raise exception E'TITLES REPORT (nothing was saved)\n%', v_report;
end $$;
