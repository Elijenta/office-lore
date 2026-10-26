-- SELF-TEST for 0086_daily_rewards.sql (read-only)
do $$
declare v_report text := ''; d public.challenge_definitions; r jsonb; v_box numeric;
begin
  select * into d from public.challenge_definitions where id = 'pd_pick_a_side';       -- easy
  r := public._assignment_reward(d);
  select (l->>'chance')::numeric into v_box from jsonb_array_elements(r->'lines') l where l->>'kind' = 'mystery';
  if v_box is distinct from 0.10 then raise exception 'FAIL 1: easy Daily box chance %', v_box; end if;
  select * into d from public.challenge_definitions where id = 'pd_new_brew';          -- normal
  r := public._assignment_reward(d);
  select (l->>'chance')::numeric into v_box from jsonb_array_elements(r->'lines') l where l->>'kind' = 'mystery';
  if v_box is distinct from 0.20 then raise exception 'FAIL 2: normal Daily box chance %', v_box; end if;
  select * into d from public.challenge_definitions where id = 'pd_poet_for_a_day';    -- hard
  r := public._assignment_reward(d);
  if not (r->'lines' @> '[{"kind":"gauntlet_fragments"}]'::jsonb) or not (r->'lines' @> '[{"kind":"mystery"}]'::jsonb) then raise exception 'FAIL 3: hard Daily lines %', r; end if;
  select * into d from public.challenge_definitions where id = 'gd_lore_quiz';         -- Group Daily
  r := public._assignment_reward(d);
  if not (r->'lines' @> '[{"kind":"mystery","chance":0.1}]'::jsonb) then raise exception 'FAIL 4: Group Daily participation %', r; end if;
  v_report := 'PASS 🎁 every Daily now has a Mystery Reward chance (easy 10%, normal 20%, hard 20% next to the fragment, Group Daily 10% for taking part)';
  raise exception E'\n%', v_report;
end $$;
