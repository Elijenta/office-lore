-- =================================================================
-- SELF-TEST for 0089_more_poem_reactions.sql  (safe: everything is rolled back)
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
  a := public._new_assignment(d, case when d.type = 'group_weekly' then null else p_user end, p_user, 'TX' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
  update public.challenge_assignments set status = 'completed', progress = target where id = a;
  if d.type = 'group_weekly' then insert into public.challenge_contributions (assignment_id, user_id, amount) values (a, p_user, 1) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.claim_challenge(a);
end;
$$ language plpgsql;

do $$
declare
  v_report text := ''; m uuid; m2 uuid; v_err text; v_xp0 int; v_xp1 int; p1 uuid; v_n int;
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  insert into public.poems (author_user_id, title, content, mood) values (m, 'Reactions', 'a poem body long enough for the checks', 'other') returning id into p1;
  perform pg_temp.imp(m2);

  -- A. old and new reactions are accepted, a malformed key is not
  insert into public.poem_reactions (poem_id, user_id, reaction_type) values (p1, m2, 'charming');
  insert into public.poem_reactions (poem_id, user_id, reaction_type) values (p1, m2, 'standing_ovation');
  insert into public.poem_reactions (poem_id, user_id, reaction_type) values (p1, m2, 'mic_drop');
  begin insert into public.poem_reactions (poem_id, user_id, reaction_type) values (p1, m, 'Bad Key!'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL A1: a malformed reaction key was accepted'; end if;
  begin insert into public.poem_reactions (poem_id, user_id, reaction_type) values (p1, m2, 'standing_ovation'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL A2: the same reaction twice'; end if;
  v_report := v_report || 'PASS 👏 the old reaction and new keys are accepted; a malformed key and a duplicate are not' || E'\n';

  -- B. the rule of 3 different reactions per person per poem still holds
  begin insert into public.poem_reactions (poem_id, user_id, reaction_type) values (p1, m2, 'pure_magic'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL B1: a 4th different reaction was accepted'; end if;
  v_report := v_report || 'PASS 3️⃣ still at most 3 different reactions per person per poem' || E'\n';

  -- C. every received reaction is +1 Poetry XP for the author, new ones too
  select count(*) into v_n from public.xp_events where user_id = m and xp_type = 'poetry' and source_id::text = (select id::text from public.poem_reactions where poem_id = p1 and reaction_type = 'standing_ovation');
  if v_n <> 1 then raise exception 'FAIL C1: expected 1 XP event for the new reaction, got %', v_n; end if;
  v_report := v_report || 'PASS ⭐ a new reaction earns the author its Poetry XP like the old ones' || E'\n';

  raise exception E'\n%', v_report;
end $$;
