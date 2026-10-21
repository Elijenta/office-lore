-- =================================================================
-- AUDIT SELF-TEST (0048-0057)  (safe: everything is rolled back)
-- =================================================================
-- Replays and double counting, the weekly fragment cap, the Nickname Factory
-- cap, inactive members in a group quest, the Lord can not challenge himself,
-- beer safety (no consumption anywhere), Beer Explorer, feasibility over 30 days.
-- The "error" at the end IS the report; NOTHING is saved.
-- =================================================================
create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;
create or replace function pg_temp.ev(p_user uuid, p_event text, p_dedupe text default null, p_meta jsonb default '{}') returns void as $$
begin
  perform public._challenge_event(p_user, p_event, 1, p_dedupe, p_meta, 'T' || md5(random()::text));
end;
$$ language plpgsql;
create or replace function pg_temp.cur(p_id uuid) returns public.challenge_assignments as $$
  select a from public.challenge_assignments a where a.id = p_id;
$$ language sql;
create or replace function pg_temp.givew(p_def text, p_user uuid) returns uuid as $$
declare d public.challenge_definitions;
begin
  select * into d from public.challenge_definitions where id = p_def;
  return public._new_assignment(d, case when d.type in ('group_weekly', 'group_daily') then null else p_user end, p_user, 'AU' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
end;
$$ language plpgsql;

do $$
declare
  v_report text := '';
  m1 uuid; m2 uuid; m3 uuid; v_lord uuid; a uuid; r jsonb; v_n int; v_err text; i int; v_tot int; nid uuid; bid uuid;
begin
  select user_id into v_lord from public.abt_reigns where ended_at is null limit 1;
  select p.id into m1 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id is distinct from v_lord order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id is distinct from v_lord and p.id <> m1 order by p.display_name limit 1;
  select p.id into m3 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m1 and p.id <> m2 order by p.display_name limit 1;
  delete from public.challenge_assignments; delete from public.challenge_events; delete from public.challenge_reward_grants;
  delete from public.gauntlet_fragments; delete from public.royal_gauntlet_balances; delete from public.gauntlet_fragment_log;
  delete from public.nickname_votes where user_id in (m1, m2, m3);
  update public.challenge_features set enabled = false;

  -- ===== A. one database action = one count =====
  begin
    a := pg_temp.givew('pw_lorekeeper', m1);
    select id into nid from public.nicknames order by created_at limit 1;
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (nid, m1, 'funny');
    v_n := (pg_temp.cur(a)).progress;
    -- the same source replayed (a retried trigger, a duplicated event) changes nothing
    perform public._challenge_event(m1, 'nickname_rated', 1, 'nickname:' || nid, '{}', 'nickname_votes:' || (select id from public.nickname_votes where nickname_id = nid and user_id = m1 limit 1));
    perform public._challenge_event(m1, 'nickname_rated', 1, 'nickname:' || nid, '{}', 'nickname_votes:' || (select id from public.nickname_votes where nickname_id = nid and user_id = m1 limit 1));
    if (pg_temp.cur(a)).progress <> v_n or v_n <> 1 then raise exception 'FAIL A: one rating counted % times', (pg_temp.cur(a)).progress; end if;
    -- a second reaction type on the same nickname, and toggling, still count once per assignment
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (nid, m1, 'savage');
    delete from public.nickname_votes where nickname_id = nid and user_id = m1 and vote_type = 'savage';
    insert into public.nickname_votes (nickname_id, user_id, vote_type) values (nid, m1, 'savage');
    if (pg_temp.cur(a)).progress <> 1 then raise exception 'FAIL A: reacting twice on one nickname counted % times', (pg_temp.cur(a)).progress; end if;
    if (select count(*) from public.challenge_events where user_id = m1 and event_type = 'nickname_rated' and source_key = 'nickname_votes:' || (select id from public.nickname_votes where nickname_id = nid and user_id = m1 and vote_type = 'funny')) <> 1 then
      raise exception 'FAIL A: the same row produced two events'; end if;
    v_report := v_report || 'PASS idempotency: a replayed event and repeated/toggled reactions on one nickname count exactly once' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== B. beer safety: nothing counts drinking =====
  begin
    if exists (select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid where p.proname like '\_ch\_t\_%' and t.tgrelid::regclass::text in ('beer_consumption', 'public.beer_consumption')) then
      raise exception 'FAIL B: a challenge trigger listens to beer_consumption'; end if;
    if exists (select 1 from public.challenge_definitions d where d.is_active and (d.event_type ~* '(consum|drink|quantity|chug|pint)' or array_to_string(coalesce(d.event_types, '{}'), ',') ~* '(consum|drink|quantity)'
          or d.parts::text ~* '(consum|drink|quantity)' or d.group_rule::text ~* '(consum|drink|quantity)')) then raise exception 'FAIL B: a definition listens to a drinking event'; end if;
    if exists (select 1 from public.challenge_event_categories where event_type ~* '(consum|drink|pour)') then raise exception 'FAIL B: a drinking-adjacent event counts as an activity'; end if;
    select string_agg(distinct e, ', ' order by e) into v_err from (
      select d.event_type e from public.challenge_definitions d where d.is_active and d.category = 'beer'
      union select unnest(d.event_types) from public.challenge_definitions d where d.is_active and d.category = 'beer' and d.event_types is not null
      union select jsonb_array_elements_text(p->'events') from public.challenge_definitions d, jsonb_array_elements(d.parts) p where d.is_active and d.category = 'beer') x;
    v_report := v_report || 'PASS beer safety: no trigger on beer_consumption, no drinking events in any definition, no pour-based activity. Beer challenges listen to: ' || coalesce(v_err, '-') || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== C. Beer Explorer: two DIFFERENT discovery kinds; a re-rating is no discovery =====
  begin
    a := pg_temp.givew('pw_beer_explorer', m1);
    perform pg_temp.ev(m1, 'beer_rated', 'beer:1', '{"first": 0}');
    perform pg_temp.ev(m1, 'beer_rated', 'beer:2', '{"first": 1}'); perform pg_temp.ev(m1, 'beer_rated', 'beer:3', '{"first": 1}');
    if (pg_temp.cur(a)).progress <> 1 or (pg_temp.cur(a)).status <> 'active' then raise exception 'FAIL C: rating beers is one kind, not two (progress %)', (pg_temp.cur(a)).progress; end if;
    perform pg_temp.ev(m1, 'beer_session_participated', 'session:1', '{"session_id": "1"}');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL C: rating + a session should complete it'; end if;
    v_report := v_report || 'PASS Beer Explorer: re-rating an old beer does not count, three first ratings are one kind, a session is the second' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== D. reward speed: the weekly fragment cap =====
  begin
    v_tot := 0;
    for i in 1..12 loop r := public._add_fragments(m1, 1); v_tot := v_tot + (r->>'stored')::int; end loop;
    if v_tot <> 6 then raise exception 'FAIL D: 12 single fragments stored % in one week (cap 6)', v_tot; end if;
    if (select coalesce(sum(amount), 0) from public.gauntlet_fragment_log where user_id = m1) <> 6 then raise exception 'FAIL D: the log does not match'; end if;
    if (public._add_fragments(m1, 3)->>'week_capped')::boolean is not true then raise exception 'FAIL D: the cap was not reported'; end if;
    -- the fixed Long Reign milestones are outside the cap
    r := public._add_fragments(m1, 2, 'rebellion');
    if (r->>'stored')::int < 1 then raise exception 'FAIL D: a Long Reign milestone was blocked by the weekly cap: %', r; end if;
    -- a new week starts fresh
    update public.gauntlet_fragment_log set created_at = now() - interval '8 days' where user_id = m1;
    update public.gauntlet_fragments set fragments = 0 where user_id = m1;
    if (public._add_fragments(m1, 2)->>'stored')::int <> 2 then raise exception 'FAIL D: the cap did not reset with the week'; end if;
    v_report := v_report || 'PASS reward speed: at most 6 fragments stored per ISO week (about 1 Gauntlet per 5 days at the very most), milestones outside the cap, resets with the week' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== E. the Nickname Factory can not be finished by one member =====
  begin
    a := pg_temp.givew('gw_nickname_factory', m1);
    for i in 1..6 loop perform pg_temp.ev(m1, 'nickname_created'); end loop;
    if (pg_temp.cur(a)).progress <> 3 or (pg_temp.cur(a)).status <> 'active' then raise exception 'FAIL E: one member took the pool to % / 5', (pg_temp.cur(a)).progress; end if;
    perform pg_temp.ev(m2, 'nickname_created'); perform pg_temp.ev(m2, 'quote_added');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL E: with a second member it should complete'; end if;
    v_report := v_report || 'PASS Nickname Factory: one member stops at 3 of 5, a second member completes it' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== F. a deactivated member does not block a group quest =====
  begin
    a := pg_temp.givew('gw_fellowship', m1);
    if (select count(*) from public.challenge_member_progress where assignment_id = a) < 3 then raise exception 'ABORTED: needs 3 members'; end if;
    update public.app_memberships set is_active = false where user_id = m3 and app_id = 'officelore';
    perform pg_temp.ev(m1, 'daily_completed', 'x1'); perform pg_temp.ev(m2, 'daily_completed', 'x2');
    if (pg_temp.cur(a)).status <> 'completed' then raise exception 'FAIL F: the quest waits for a deactivated member (%/%)', (pg_temp.cur(a)).progress, (pg_temp.cur(a)).target; end if;
    perform pg_temp.imp(m3);
    v_err := null; begin perform public.claim_challenge(a); exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'FAIL F: a deactivated member could claim'; end if;
    v_report := v_report || 'PASS group quest: a deactivated member is no longer awaited and can not claim; the others finish and claim' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== G. the Abt Lord =====
  begin
    if v_lord is null then raise exception 'ABORTED: no Abt Lord'; end if;
    insert into public.royal_gauntlet_balances (user_id, balance) values (v_lord, 2) on conflict (user_id) do update set balance = 2;
    perform pg_temp.imp(v_lord);
    v_err := null; begin perform public.create_throne_challenge(false, null); exception when others then v_err := sqlerrm; end;
    if v_err is null or v_err not like '%cannot challenge themselves%' then raise exception 'FAIL G: the Lord challenged himself (%)', coalesce(v_err, 'accepted'); end if;
    if (select balance from public.royal_gauntlet_balances where user_id = v_lord) <> 2 then raise exception 'FAIL G: a Gauntlet was spent'; end if;
    -- earns, stores, does not forge
    delete from public.royal_gauntlet_balances where user_id = v_lord;
    r := public._add_fragments(v_lord, 5);
    if (r->>'forged')::int <> 0 or (r->>'fragments')::int <> 5 then raise exception 'FAIL G: the Lord forged or lost fragments: %', r; end if;
    v_report := v_report || 'PASS Abt Lord: can not challenge himself (nothing spent), earns fragments, 5 fragments stay 5 fragments' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  -- ===== H. only executable challenges are assigned (30 days, every member) =====
  begin
    update public.challenge_features set enabled = false;
    delete from public.challenge_assignments;
    for i in 0..29 loop
      perform public._ensure_challenge_assignments_for(m1, now() + make_interval(days => i));
      perform public._ensure_challenge_assignments_for(m2, now() + make_interval(days => i));
    end loop;
    select count(*) into v_n from public.challenge_assignments a join public.challenge_definitions d on d.id = a.definition_id where d.requires in ('quiz', 'prediction');
    if v_n > 0 then raise exception 'FAIL H: % assignments need a switched-off feature', v_n; end if;
    select count(*) into v_n from public.challenge_assignments a where a.definition_id = 'pw_keeper_knowledge';
    if v_n > 0 then raise exception 'FAIL H: the quiz weekly was assigned'; end if;
    update public.nickname_battles set status = 'draw' where status = 'open';
    delete from public.challenge_assignments;
    for i in 0..13 loop perform public._ensure_challenge_assignments_for(m1, now() + make_interval(days => i)); end loop;
    if exists (select 1 from public.challenge_assignments where definition_id = 'pd_pick_a_side') then raise exception 'FAIL H: Pick a Side without a battle'; end if;
    v_report := v_report || 'PASS feasibility: 30 days x 2 members never assigned a quiz / prediction challenge while those switches are off, nor Pick a Side without an open battle' || E'\n';
    raise exception 'ROLLBACK_OK';
  exception when others then if sqlerrm <> 'ROLLBACK_OK' then v_report := v_report || sqlerrm || E'\n'; end if; end;

  raise exception E'AUDIT REPORT (nothing was saved)\n%', v_report;
end $$;
