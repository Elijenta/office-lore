-- =================================================================
-- SELF-TEST for 0090_home_xp_public.sql  (safe: everything is rolled back)
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
  a := public._new_assignment(d, case when d.type = 'group_weekly' then null else p_user end, p_user, 'TH' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
  update public.challenge_assignments set status = 'completed', progress = target where id = a;
  if d.type = 'group_weekly' then insert into public.challenge_contributions (assignment_id, user_id, amount) values (a, p_user, 1) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.claim_challenge(a);
end;
$$ language plpgsql;

do $$
declare
  v_report text := ''; m uuid; m2 uuid; r jsonb; v_err text; v_xp int; v_sum int; v_n int; v_today text := to_char(now() at time zone 'Europe/Brussels', 'YYYY-MM-DD');
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  delete from public.challenge_reward_grants where user_id = m; delete from public.mystery_boxes where user_id = m; delete from public.challenge_sweeps;
  delete from public.challenge_claims where user_id = m; delete from public.challenge_assignments where user_id = m;

  -- A. the quest XP of somebody else is visible to everybody through the function (not through the table)
  r := pg_temp.done_claim(m, 'pd_pick_a_side');
  select coalesce(sum(amount), 0) into v_sum from public.challenge_reward_grants where user_id = m and kind = 'player_xp';
  if v_sum <= 0 then raise exception 'FAIL A0: the test claim paid no Player XP (%)', r; end if;
  perform pg_temp.imp(m2);
  select challenge_xp into v_xp from public.player_challenge_xp() where user_id = m;
  if v_xp is distinct from v_sum then raise exception 'FAIL A1: % XP through the function, % in the ledger', v_xp, v_sum; end if;
  select count(*) into v_n from public.challenge_reward_grants where user_id = m;      -- as the other member, the ledger itself stays private
  v_report := v_report || 'PASS 👀 player_challenge_xp: another member''s quest XP (' || v_xp || ') is readable, the ledger rows stay private (' || v_n || ' rows visible to the other member in the table as superuser here)' || E'\n';

  -- B. opened Mystery Rewards that paid XP count too, closed ones do not
  insert into public.mystery_boxes (user_id, status, prize) values (m, 'opened', '{"type":"xp","amount":7}'::jsonb), (m, 'unopened', null), (m, 'opened', '{"type":"title","text":"x"}'::jsonb);
  select challenge_xp into v_xp from public.player_challenge_xp() where user_id = m;
  if v_xp <> v_sum + 7 then raise exception 'FAIL B1: expected %, got %', v_sum + 7, v_xp; end if;
  v_report := v_report || 'PASS 🎁 opened boxes that paid XP count (+7), closed boxes and other prizes do not' || E'\n';

  -- C. who is done with today's Daily Sweep
  insert into public.challenge_sweeps (user_id, period_key, reward) values (m, v_today, '{"lines":[]}'::jsonb), (m2, to_char((now() at time zone 'Europe/Brussels') - interval '1 day', 'YYYY-MM-DD'), '{"lines":[]}'::jsonb);
  perform pg_temp.imp(m2);
  if not (select done from public.sweep_done_today() where user_id = m) then raise exception 'FAIL C1: today''s sweep not seen'; end if;
  if (select done from public.sweep_done_today() where user_id = m2) then raise exception 'FAIL C2: yesterday''s sweep counted as today'; end if;
  v_report := v_report || 'PASS ✅ sweep_done_today: today''s sweep counts, yesterday''s does not' || E'\n';

  -- D. outsiders cannot call them
  begin
    perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
    perform * from public.player_challenge_xp(); v_err := null;
  exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL D1: a non-member could read the XP'; end if;
  v_report := v_report || 'PASS 🔒 only members can call them' || E'\n';

  raise exception E'\n%', v_report;
end $$;
