-- =================================================================
-- SELF-TEST for 0092_outfit_legend3.sql  (safe: everything is rolled back)
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
  a := public._new_assignment(d, case when d.type = 'group_weekly' then null else p_user end, p_user, 'TL' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
  update public.challenge_assignments set status = 'completed', progress = target where id = a;
  if d.type = 'group_weekly' then insert into public.challenge_contributions (assignment_id, user_id, amount) values (a, p_user, 1) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.claim_challenge(a);
end;
$$ language plpgsql;

do $$
declare
  v_report text := ''; m uuid; r jsonb; i int; v_n int; v_def text;
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  delete from public.user_character_outfits where user_id = m; delete from public.character_outfit_pity where user_id = m;
  if not exists (select 1 from public.character_outfit_sets where id = 'lg3' and is_active and unlock_kind = 'random_drop') then raise exception 'FAIL 0: lg3 is missing'; end if;
  update public.character_outfit_sets set sources = '[]' where id <> 'lg3' and unlock_kind = 'random_drop';      -- only lg3 may drop in this test

  -- A. every beer quest of lg3 can give it, and the pity (15) guarantees it
  foreach v_def in array array['pw_social_creature', 'pw_completionist', 'pw_adventurer', 'gw_fellowship', 'gw_gathering', 'gw_nickname_factory', 'gw_council', 'rb_storm', 'rb_seeds', 'rb_pamphlet', 'gd_nickname_of_the_day'] loop
    delete from public.user_character_outfits where user_id = m; delete from public.character_outfit_pity where user_id = m;
    for i in 1..15 loop r := public._character_outfit_hook(m, v_def); end loop;                 -- (other sets may drop too: they are switched off above)
    if not exists (select 1 from public.user_character_outfits where user_id = m and set_id = 'lg3') then raise exception 'FAIL A: % did not give lg3 within the pity of 15 claims', v_def; end if;
  end loop;
  v_report := v_report || 'PASS 🎩 lg3 drops from each of its 11 quests, guaranteed by the pity (15)' || E'\n';

  -- B. an unrelated quest never gives it, and it never drops twice
  delete from public.user_character_outfits where user_id = m; delete from public.character_outfit_pity where user_id = m;
  for i in 1..30 loop r := public._character_outfit_hook(m, 'pd_poet_for_a_day'); if jsonb_array_length(r) > 0 then raise exception 'FAIL B1: a daily quest gave lg3'; end if; end loop;
  for i in 1..15 loop r := public._character_outfit_hook(m, 'gw_council'); end loop;
  select count(*) into v_n from public.user_character_outfits where user_id = m and set_id = 'lg3';
  for i in 1..40 loop r := public._character_outfit_hook(m, 'gw_council'); if jsonb_array_length(r) > 0 then raise exception 'FAIL B2: lg3 dropped twice'; end if; end loop;
  if v_n <> 1 then raise exception 'FAIL B3: % copies', v_n; end if;
  v_report := v_report || 'PASS 🔒 no other quest gives it, never twice' || E'\n';

  raise exception E'\n%', v_report;
end $$;
