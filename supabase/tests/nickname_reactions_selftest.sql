-- =================================================================
-- SELF-TEST for 0093_more_nickname_reactions.sql  (safe: everything is rolled back)
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;

do $$
declare
  v_report text := ''; m uuid; m2 uuid; v_err text; n1 uuid; v_n int; v_xp0 int; v_xp1 int;
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  insert into public.nicknames (person_real_name, nickname, created_by_user_id) values ('Test Person', 'Reactie-test', m) returning id into n1;
  select coalesce(sum(points), 0) into v_xp0 from public.xp_events where user_id = m;
  perform pg_temp.imp(m2);

  -- A. old and new reactions are accepted (as the voter themself), a malformed key and a duplicate are not
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values (n1, m2, 'funny');
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values (n1, m2, 'genius');
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values (n1, m2, 'inside_joke');
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values (n1, m2, 'hall_of_fame');
  begin insert into public.nickname_votes (nickname_id, user_id, vote_type) values (n1, m2, 'Bad Key!'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL A1: a malformed reaction key was accepted'; end if;
  begin insert into public.nickname_votes (nickname_id, user_id, vote_type) values (n1, m2, 'genius'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL A2: the same reaction twice'; end if;
  v_report := v_report || 'PASS 🧠 old and new reaction keys are accepted; a malformed key and a duplicate are not' || E'\n';

  -- B. you can only vote as yourself (row level security still holds), under the app role
  set local role authenticated;
  begin insert into public.nickname_votes (nickname_id, user_id, vote_type) values (n1, m, 'genius'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL B1: voting in someone else''s name was accepted'; end if;
  select count(*) into v_n from public.nickname_votes where nickname_id = n1;
  if v_n <> 4 then raise exception 'FAIL B2: expected 4 readable votes, got %', v_n; end if;
  -- ... and withdrawing your own vote works
  delete from public.nickname_votes where nickname_id = n1 and user_id = m2 and vote_type = 'hall_of_fame';
  select count(*) into v_n from public.nickname_votes where nickname_id = n1;
  if v_n <> 3 then raise exception 'FAIL B3: expected 3 votes after withdrawing, got %', v_n; end if;
  reset role;
  v_report := v_report || 'PASS 🔒 only your own vote can be added; your own vote can be withdrawn; everyone can read them' || E'\n';

  -- C. votes never give XP, new ones neither
  select coalesce(sum(points), 0) into v_xp1 from public.xp_events where user_id = m;
  if v_xp1 <> v_xp0 then raise exception 'FAIL C1: XP changed from % to % by reactions', v_xp0, v_xp1; end if;
  v_report := v_report || 'PASS ⭐ reactions give no XP' || E'\n';

  raise exception E'\n%', v_report;
end $$;
