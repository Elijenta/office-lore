-- =================================================================
-- SELF-TEST for 0063_personal_character_outfits.sql  (safe: everything is rolled back)
-- =================================================================
create or replace function pg_temp.done_claim(p_user uuid, p_def text) returns jsonb as $$
declare d public.challenge_definitions; a uuid;
begin
  select * into d from public.challenge_definitions where id = p_def;
  a := public._new_assignment(d, case when d.type = 'group_weekly' then null else p_user end, p_user, 'OF' || substr(md5(random()::text), 1, 8), now() - interval '1 day', now() + interval '3 days');
  update public.challenge_assignments set status = 'completed', progress = target where id = a;
  if d.type = 'group_weekly' then insert into public.challenge_contributions (assignment_id, user_id, amount) values (a, p_user, 1) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.claim_challenge(a);
end;
$$ language plpgsql;

create or replace function pg_temp.imp(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$ language plpgsql;

do $$
declare
  v_report text := '';
  m uuid; m2 uuid; v_lord uuid; r jsonb; r2 jsonb; v_err text; v_n int;
begin
  select user_id into v_lord from public.abt_reigns where ended_at is null limit 1;
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id is distinct from v_lord order by p.display_name limit 1;
  select p.id into m2 from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active where p.id <> m order by p.display_name limit 1;
  delete from public.room_profiles where user_id in (m, m2);
  perform pg_temp.imp(m);

  -- a member who is not the Abt Lord makes a character
  r := public.set_room_character('female', 'f3');
  if r->>'body_type' <> 'female' or r->'loadout'->>'outfit' <> 'f3' then raise exception 'FAIL 1: %', r; end if;
  if m = v_lord then raise exception 'ABORTED: the test member must not be the Lord'; end if;
  r := public.set_room_character('male', 'm6');
  if (select body_type from public.room_profiles where user_id = m) <> 'male' then raise exception 'FAIL 2: base not stored'; end if;
  -- the plain base, and Mystery drops stay when the outfit changes
  update public.room_profiles set loadout = loadout || '{"headwear":"00000000-0000-0000-0000-000000000001"}' where user_id = m;
  r := public.set_room_character('male', null);
  if r->'loadout' ? 'outfit' or not (r->'loadout' ? 'headwear') then raise exception 'FAIL 3: plain base / worn items: %', r; end if;
  r := public.set_room_character('male', 'm2');
  if r->'loadout'->>'headwear' is null then raise exception 'FAIL 3b: an outfit change removed a worn item'; end if;

  -- refused: wrong gender, junk, legacy bodies, outsiders
  v_err := null; begin perform public.set_room_character('female', 'm1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 4: a male outfit on a female base'; end if;
  v_err := null; begin perform public.set_room_character('male', 'x9'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 4b: a junk outfit code'; end if;
  v_err := null; begin perform public.set_room_character('male', 'm1; drop table'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 4c: an injected outfit code'; end if;
  v_err := null; begin perform public.set_room_character('muscular', null); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 4d: a legacy body was accepted'; end if;

  -- somebody else's character is untouched
  perform pg_temp.imp(m2); perform public.set_room_character('female', 'f1');
  if (select loadout->>'outfit' from public.room_profiles where user_id = m) <> 'm2' then raise exception 'FAIL 5: another member changed my character'; end if;
  -- and nobody else can write my row directly (RLS)
  select count(*) into v_n from public.room_profiles where user_id = m2;
  v_report := v_report || 'PASS 🧍 character: base female/male + a matching standard outfit (f1.. / m1..), no Abt Lord needed; worn Mystery items survive an outfit change; wrong gender, junk, injected and legacy bodies are refused; nobody can change another member''s character' || E'\n';

  -- ===== special outfit sets =====
  delete from public.user_character_outfits where user_id = m; delete from public.character_outfit_pity where user_id = m;
  update public.character_outfit_sets set sources = '[]' where unlock_kind = 'random_drop';          -- every random set is switched on explicitly below, so no test claim can roll one by accident
  -- locked until earned
  v_err := null; begin perform public.set_room_character('female', 'fbe1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 6: wore a special outfit that was never unlocked'; end if;
  -- be1: the first time Beer Explorer is completed and claimed, exactly once
  r := pg_temp.done_claim(m, 'pd_quote_hunter');
  if jsonb_array_length(r->'outfits') <> 0 then raise exception 'FAIL 7: an unrelated quest gave an outfit'; end if;
  r := pg_temp.done_claim(m, 'pw_beer_explorer');
  if r->'outfits'->0->>'id' is distinct from 'be1' then raise exception 'FAIL 8: Beer Explorer did not unlock Brewfest: %', r; end if;
  delete from public.challenge_assignments where definition_id = 'pw_beer_explorer' and user_id = m;
  r := pg_temp.done_claim(m, 'pw_beer_explorer');
  if jsonb_array_length(r->'outfits') <> 0 then raise exception 'FAIL 9: Brewfest was granted twice'; end if;
  r := public.set_room_character('female', 'fbe1');
  if r->'loadout'->>'outfit' <> 'fbe1' then raise exception 'FAIL 10: could not wear the unlocked outfit'; end if;
  v_err := null; begin perform public.set_room_character('female', 'mbe1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 11: the male version on a female base'; end if;
  r := public.set_room_character('male', 'mbe1');
  -- be2: random with a pity counter
  update public.character_outfit_sets set sources = '[{"def":"pd_beer_scholar","chance":0},{"def":"pd_new_brew","chance":0}]', pity_after = 3 where id = 'be2';
  r := pg_temp.done_claim(m, 'pd_beer_scholar'); r2 := pg_temp.done_claim(m, 'pd_new_brew');
  if exists (select 1 from public.user_character_outfits where user_id = m and set_id = 'be2') then raise exception 'FAIL 12: dropped with chance 0 before the pity'; end if;
  v_err := null; begin perform public.set_room_character('male', 'mbe2'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 12b: wore Beer Trekker while locked'; end if;
  r := pg_temp.done_claim(m, 'pd_beer_scholar');
  if r->'outfits'->0->>'id' is distinct from 'be2' then raise exception 'FAIL 13: the pity did not give Beer Trekker on the 3rd claim: %', r; end if;
  if (select misses from public.character_outfit_pity where user_id = m and set_id = 'be2') <> 0 then raise exception 'FAIL 13b: pity not reset'; end if;
  r := public.set_room_character('male', 'mbe2');
  update public.character_outfit_sets set sources = '[{"def":"pd_beer_scholar","chance":1}]' where id = 'be2';
  delete from public.user_character_outfits where user_id = m and set_id = 'be2';
  r := pg_temp.done_claim(m, 'pd_beer_scholar');
  if r->'outfits'->0->>'id' is distinct from 'be2' then raise exception 'FAIL 14: chance 1 should drop'; end if;
  -- a repeated claim never rolls again
  v_n := jsonb_array_length((public.claim_challenge((select id from public.challenge_assignments where user_id = m and definition_id = 'pd_beer_scholar' order by created_at desc limit 1)))->'outfits');
  if v_n is not null and v_n <> 0 then raise exception 'FAIL 15: a repeated claim granted again'; end if;
  -- lk1: Lorekeeper quests can drop the Scholar's Archive set
  update public.character_outfit_sets set sources = '[{"def":"pd_lore_keeper","chance":1}]' where id = 'lk1';
  v_err := null; begin perform public.set_room_character('female', 'flk1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 16: wore Scholar''s Archive while locked'; end if;
  r := pg_temp.done_claim(m, 'pd_lore_keeper');
  if r->'outfits'->0->>'id' is distinct from 'lk1' then raise exception 'FAIL 17: a Lorekeeper quest did not drop lk1: %', r; end if;
  r := public.set_room_character('female', 'flk1');
  r := public.set_room_character('male', 'mlk1');
  -- bt1: battle quests can drop the Office Gladiator set
  update public.character_outfit_sets set sources = '[{"def":"pd_pick_a_side","chance":1}]' where id = 'bt1';
  v_err := null; begin perform public.set_room_character('male', 'mbt1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 18: wore Office Gladiator while locked'; end if;
  r := pg_temp.done_claim(m, 'pd_pick_a_side');
  if r->'outfits'->0->>'id' is distinct from 'bt1' then raise exception 'FAIL 19: a battle quest did not drop bt1: %', r; end if;
  r := public.set_room_character('male', 'mbt1');
  -- ch1: chaos quests can drop the Court Jester set (also from the group Daily Chaos)
  update public.character_outfit_sets set sources = '[{"def":"pd_royal_decree","chance":1},{"def":"gd_daily_chaos","chance":1}]' where id = 'ch1';
  v_err := null; begin perform public.set_room_character('female', 'fch1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 20: wore Court Jester while locked'; end if;
  r := pg_temp.done_claim(m, 'pd_royal_decree');
  if r->'outfits'->0->>'id' is distinct from 'ch1' then raise exception 'FAIL 21: a Chaos quest did not drop ch1: %', r; end if;
  r := public.set_room_character('female', 'fch1');
  delete from public.user_character_outfits where user_id = m and set_id = 'ch1';
  r := pg_temp.done_claim(m, 'gd_daily_chaos');
  if r->'outfits'->0->>'id' is distinct from 'ch1' then raise exception 'FAIL 22: the group Daily Chaos did not drop ch1: %', r; end if;
  -- cp1: the Completionist always gives Champion's Gala, Adventurer / Social Creature can drop it
  v_err := null; begin perform public.set_room_character('female', 'fcp1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 23: wore Champion''s Gala while locked'; end if;
  update public.character_outfit_sets set sources = '[{"def":"pw_completionist","chance":1}]' where id = 'cp1';
  r := pg_temp.done_claim(m, 'pw_completionist');
  if r->'outfits'->0->>'id' is distinct from 'cp1' then raise exception 'FAIL 24: The Completionist did not give cp1: %', r; end if;
  r := public.set_room_character('female', 'fcp1');
  delete from public.user_character_outfits where user_id = m and set_id = 'cp1';
  update public.character_outfit_sets set sources = '[{"def":"pw_adventurer","chance":0},{"def":"pw_social_creature","chance":0}]', pity_after = 2 where id = 'cp1';
  r := pg_temp.done_claim(m, 'pw_adventurer'); r := pg_temp.done_claim(m, 'pw_social_creature');
  if r->'outfits'->0->>'id' is distinct from 'cp1' then raise exception 'FAIL 25: the pity did not give cp1: %', r; end if;
  -- pt1: poetry quests can drop the Poet's Salon set (also from the Poetry Showdown group Daily)
  update public.character_outfit_sets set sources = '[{"def":"pw_poet_laureate","chance":1},{"def":"gd_poetry_showdown","chance":1}]' where id = 'pt1';
  v_err := null; begin perform public.set_room_character('female', 'fpt1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 26: wore Poet''s Salon while locked'; end if;
  r := pg_temp.done_claim(m, 'pw_poet_laureate');
  if r->'outfits'->0->>'id' is distinct from 'pt1' then raise exception 'FAIL 27: a poetry quest did not drop pt1: %', r; end if;
  r := public.set_room_character('male', 'mpt1');
  delete from public.user_character_outfits where user_id = m and set_id = 'pt1';
  r := pg_temp.done_claim(m, 'gd_poetry_showdown');
  if r->'outfits'->0->>'id' is distinct from 'pt1' then raise exception 'FAIL 28: the Poetry Showdown did not drop pt1: %', r; end if;
  -- qz1: quiz quests can drop the Quiz Master set (also from the Daily Lore Quiz and the Council)
  update public.character_outfit_sets set sources = '[{"def":"gd_lore_quiz","chance":1},{"def":"gw_council","chance":1}]' where id = 'qz1';
  v_err := null; begin perform public.set_room_character('male', 'mqz1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 29: wore Quiz Master while locked'; end if;
  r := pg_temp.done_claim(m, 'gd_lore_quiz');
  if r->'outfits'->0->>'id' is distinct from 'qz1' then raise exception 'FAIL 30: the Daily Lore Quiz did not drop qz1: %', r; end if;
  r := public.set_room_character('female', 'fqz1');
  delete from public.user_character_outfits where user_id = m and set_id = 'qz1';
  r := pg_temp.done_claim(m, 'gw_council');
  if r->'outfits'->0->>'id' is distinct from 'qz1' then raise exception 'FAIL 31: The Council did not drop qz1: %', r; end if;
  -- rb1: Rebellion quests drop the Rebel Banner set; the pity counter works for it too
  update public.character_outfit_sets set sources = '[{"def":"rb_seeds","chance":0},{"def":"rb_storm","chance":0}]', pity_after = 2 where id = 'rb1';
  v_err := null; begin perform public.set_room_character('female', 'frb1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 32: wore Rebel Banner while locked'; end if;
  r := pg_temp.done_claim(m, 'rb_seeds');
  if jsonb_array_length(r->'outfits') <> 0 then raise exception 'FAIL 33: dropped with chance 0 before the pity'; end if;
  r := pg_temp.done_claim(m, 'rb_storm');
  if r->'outfits'->0->>'id' is distinct from 'rb1' then raise exception 'FAIL 34: the pity did not give rb1: %', r; end if;
  r := public.set_room_character('female', 'frb1');
  r := public.set_room_character('male', 'mrb1');
  -- lg1 / lg2: the legendary sets are very rare, weekly quests only, a long pity, and Dailies never roll for them
  if exists (select 1 from public.character_outfit_sets where id in ('lg1', 'lg2') and (select max((e->>'chance')::numeric) from jsonb_array_elements(sources) e) > 0.06) then raise exception 'FAIL 35: a legendary set has a chance above 6%%'; end if;
  if exists (select 1 from public.character_outfit_sets where id in ('lg1', 'lg2') and (pity_after is null or pity_after < 40)) then raise exception 'FAIL 36: the legendary pity is too short'; end if;
  if exists (select 1 from public.character_outfit_sets s, jsonb_array_elements(s.sources) e where s.id in ('lg1', 'lg2') and e->>'def' like 'pd\_%') then raise exception 'FAIL 37: a Daily rolls for a legendary set'; end if;
  update public.character_outfit_sets set sources = '[{"def":"pw_completionist","chance":0}]', pity_after = 2 where id = 'lg1';
  update public.character_outfit_sets set sources = '[{"def":"pw_lorekeeper","chance":1}]' where id = 'lg2';
  v_err := null; begin perform public.set_room_character('female', 'flg1'); exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 38: wore Crimson Court while locked'; end if;
  r := pg_temp.done_claim(m, 'pw_completionist');
  if jsonb_array_length(r->'outfits') <> 0 then raise exception 'FAIL 39: lg1 dropped before the pity'; end if;
  delete from public.challenge_assignments where definition_id = 'pw_completionist' and user_id = m;
  r := pg_temp.done_claim(m, 'pw_completionist');
  if not (r->'outfits' @> '[{"id":"lg1"}]'::jsonb) then raise exception 'FAIL 40: the legendary pity did not give lg1: %', r; end if;
  r := public.set_room_character('female', 'flg1'); r := public.set_room_character('male', 'mlg1');
  r := pg_temp.done_claim(m, 'pw_lorekeeper');
  if not (r->'outfits' @> '[{"id":"lg2"}]'::jsonb) then raise exception 'FAIL 41: lg2 did not drop at chance 1: %', r; end if;
  r := public.set_room_character('male', 'mlg2');
  v_report := v_report || 'PASS 👗 special outfits: Brewfest (be1) comes with the first Beer Explorer claim and never again, Beer Trekker (be2) drops by chance with a pity counter, locked sets can not be worn, only your base''s version fits, repeated claims never grant or roll twice' || E'\n';
  raise exception E'CHARACTER REPORT (nothing was saved)\n%', v_report;
end $$;
