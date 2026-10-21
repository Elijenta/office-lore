-- =================================================================
-- 0080 — Quest Guide: one overview of every quest, what to do, and what it pays
--
-- get_quest_guide() returns the ACTIVE quest definitions (hidden ones and switched-off features are left out) with the reward
-- lines they really pay (the same resolution the engine uses when an assignment is created), plus the Group Daily winner reward
-- and the Daily Sweep. Read-only, members only; nothing about drop odds of outfits / pets / titles is exposed.
-- The Quest Board reads it for its "Guide" page, so a new or changed quest shows up there without a code change. Idempotent.
-- =================================================================
create or replace function public.get_quest_guide()
returns jsonb as $$
declare
  v_quests jsonb;
  v_gd jsonb := public._challenge_config('group_daily_rewards', '{}'::jsonb);
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select coalesce(jsonb_agg(t.q order by t.ord), '[]'::jsonb) into v_quests from (
    select jsonb_build_object(
             'id', d.id, 'type', d.type, 'category', d.category, 'title', d.title, 'description', d.description,
             'difficulty', d.difficulty, 'icon', d.icon, 'weekly_tier', d.weekly_tier, 'audience', d.audience,
             'target', case when d.parts is not null then (select sum((pt->>'target')::int) from jsonb_array_elements(d.parts) pt) else d.target end,
             'group_mode', d.group_rule->>'mode',
             'parts', (select jsonb_agg(jsonb_build_object('label', pt->>'label', 'target', (pt->>'target')::int)) from jsonb_array_elements(d.parts) pt),
             'reward', coalesce(public._assignment_reward(d)->'lines', '[]'::jsonb)) as q,
           row_number() over (order by
             case d.type when 'personal_daily' then 1 when 'group_daily' then 2 when 'personal_weekly' then 3 when 'group_weekly' then 4 else 5 end,
             d.category,
             case d.difficulty when 'easy' then 1 when 'normal' then 2 when 'hard' then 3 else 4 end, d.title) as ord
    from public.challenge_definitions d
    where d.app_id = 'officelore' and d.is_active
      and (d.requires is null
           or d.requires in ('open_battle', 'unrated_beer', 'anecdote_target', 'old_content', 'nicknames_3', 'poems_2', 'group_quiz_data', 'poetry_prompt_data', 'battle_activity')
           or coalesce((select f.enabled from public.challenge_features f where f.key = d.requires), false))
  ) t;
  return jsonb_build_object(
    'quests', v_quests,
    'group_daily', jsonb_build_object('participation', coalesce(v_gd->'participation', '[]'::jsonb), 'winner', coalesce(v_gd->'winner', '[]'::jsonb), 'min_participants', coalesce((v_gd->>'min_participants')::int, 2)),
    'sweep', coalesce(public._challenge_config('daily_sweep', '{}'::jsonb)->'lines', '[]'::jsonb),
    'weekly_slots', public._challenge_config('weekly_slots', '{"normal":2,"big":1}'::jsonb));
end;
$$ language plpgsql stable security definer set search_path = public;
revoke all on function public.get_quest_guide() from public, anon;
grant execute on function public.get_quest_guide() to authenticated;
