-- SELF-TEST for 0080_quest_guide.sql (read-only)
do $$
declare
  v_report text := ''; m uuid; r jsonb; v_n int;
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  perform set_config('request.jwt.claim.sub', m::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  r := public.get_quest_guide();
  select count(*) into v_n from jsonb_array_elements(r->'quests');
  if v_n <> (select count(*) from public.challenge_definitions d where d.is_active and (d.requires is null or d.requires in ('open_battle','unrated_beer','anecdote_target','old_content','nicknames_3','poems_2','group_quiz_data','poetry_prompt_data', 'battle_activity') or coalesce((select f.enabled from public.challenge_features f where f.key = d.requires), false))) then
    raise exception 'FAIL 1: quest count %', v_n; end if;
  if exists (select 1 from jsonb_array_elements(r->'quests') q where q->>'id' in ('pd_quote_hunter', 'pw_lorekeeper')) then raise exception 'FAIL 2: a hidden quest is listed'; end if;
  if jsonb_array_length((select q->'reward' from jsonb_array_elements(r->'quests') q where q->>'id' = 'pd_royal_decree')) = 0 then raise exception 'FAIL 3: a Chaos Daily has no reward lines'; end if;
  if jsonb_array_length(r->'group_daily'->'winner') = 0 or jsonb_array_length(r->'sweep') = 0 then raise exception 'FAIL 4: group daily / sweep rewards missing'; end if;
  if exists (select 1 from jsonb_array_elements(r->'quests') q where coalesce(q->>'description', '') = '' or q->>'type' not in ('personal_daily','group_daily','personal_weekly','group_weekly','rebellion')) then raise exception 'FAIL 5: a quest without text or with a strange type'; end if;
  v_report := format('PASS get_quest_guide: %s active quests with rewards, hidden quests and the group daily / sweep / slots included correctly', v_n);
  raise exception E'\n%', v_report;
end $$;
