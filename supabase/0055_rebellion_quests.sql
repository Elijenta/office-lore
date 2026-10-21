-- =================================================================
-- OFFICE LORE — ⚔️ REBELLION QUESTS + LONG REIGN BONUSES
-- =================================================================
-- Only for members who do NOT currently hold the throne.
--
-- 1. REBELLION QUESTS (weekly, type 'rebellion', audience 'non_lord')
--      ⚔️ Seeds of Rebellion   2 Personal Dailies + 1 Lore activity + 1 Battle   -> XP + 2 Gauntlet Fragments
--      📜 The Pamphlet War      1 poem + 3 nickname ratings
--      ⛈️ The Gathering Storm   3 Battles
--    They use the same parts engine as the Personal Weeklies. The Abt Lord is not
--    assigned one, and cannot claim one that was assigned before he took the throne.
--
-- 2. LONG REIGN BONUSES. The longer the same Abt Lord rules WITHOUT interruption
--    (one abt_reigns row), the more the people support a rebellion. Milestones are
--    configuration (challenge_config.rebellion_milestones):
--        14 days  +1 Gauntlet Fragment      30 days  +2 Gauntlet Fragments
--        60 days  a full Royal Gauntlet (only while the inventory cap has room; otherwise it
--                 is DEFERRED and handed over as soon as a Gauntlet has been used)
--    Every eligible member (active, not the ruling Lord) gets each milestone ONCE per
--    reign: rebellion_rewards has UNIQUE (reign_id, user_id, milestone_id) and the
--    reward is only paid when that row was inserted. Nothing is repeated on login.
--    Milestones are awarded lazily (get_rebellion_state, any member's visit) and also
--    when a reign ends, for the days it did reach.
--
-- 3. THE LORD sees REIGN PRESSURE (day count + mood). Informational only: no penalty.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0054.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema and config
-- =================================================================
do $$
declare v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.royal_gauntlet_ledger'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%reason%';
  if v_name is not null then execute format('alter table public.royal_gauntlet_ledger drop constraint %I', v_name); end if;
end $$;
alter table public.royal_gauntlet_ledger add constraint royal_gauntlet_ledger_reason_check
  check (reason in ('admin_grant', 'throne_challenge', 'throne_refund', 'throne_coup', 'coup_refund', 'fragment_convert', 'rebellion_gauntlet'));

create table if not exists public.rebellion_rewards (
  reign_id uuid not null references public.abt_reigns(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  milestone_id text not null,
  status text not null check (status in ('granted', 'deferred')),
  fragments int not null default 0,
  gauntlets int not null default 0,
  created_at timestamptz not null default now(),
  granted_at timestamptz,
  notified_at timestamptz,
  primary key (reign_id, user_id, milestone_id)          -- ONE milestone per reign and member, enforced by the database
);
alter table public.rebellion_rewards enable row level security;
drop policy if exists "Rebellion rewards: read own" on public.rebellion_rewards;
create policy "Rebellion rewards: read own" on public.rebellion_rewards for select to authenticated using (user_id = auth.uid());

insert into public.challenge_config (key, value) values
  ('rebellion_milestones', '[
      {"id":"restless","days":14,"icon":"⚠️","title":"THE PEOPLE ARE RESTLESS","text":"The Abt has ruled for 14 days.","lord_text":"The people are growing restless.","fragments":1},
      {"id":"grows","days":30,"icon":"🔥","title":"REBELLION GROWS","text":"The throne has stood too long.","lord_text":"Rebellion is growing.","fragments":2},
      {"id":"demand","days":60,"icon":"⚔️","title":"THE PEOPLE DEMAND CHANGE","text":"A Royal Gauntlet has been placed in your hands.","lord_text":"The people demand change.","gauntlets":1}
   ]'::jsonb)
on conflict (key) do nothing;
update public.challenge_config set value = value || '{"rebellion": 1}'::jsonb where key = 'weekly_slots' and not (value ? 'rebellion');

create or replace function public._challenge_slots(p_type text) returns int as $$
  select case p_type
    when 'personal_daily' then 3 when 'group_daily' then 1
    when 'personal_weekly' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'normal')::int, 2) + coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'big')::int, 1)
    when 'group_weekly' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'group')::int, 2)
    when 'rebellion' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'rebellion')::int, 1)
    else 0 end;
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 2 — awarding the milestones
-- =================================================================
create or replace function public._grant_rebellion_gauntlet(p_user uuid, p_reign uuid)
returns boolean as $$
declare
  v_cap int := public._max_gauntlets();
  v_bal int;
begin
  perform pg_advisory_xact_lock(hashtext('gauntlet_forge:' || p_user::text));
  insert into public.royal_gauntlet_balances (user_id) values (p_user) on conflict do nothing;
  select balance into v_bal from public.royal_gauntlet_balances where user_id = p_user for update;
  if v_bal >= v_cap then return false; end if;               -- the inventory cap holds for the people too
  update public.royal_gauntlet_balances set balance = balance + 1, updated_at = now() where user_id = p_user;
  insert into public.royal_gauntlet_ledger (user_id, delta, reason, note) values (p_user, 1, 'rebellion_gauntlet', 'reign ' || p_reign::text);
  return true;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._award_rebellion_milestones(p_reign uuid, p_as_of timestamptz)
returns void as $$
declare
  r public.abt_reigns;
  m jsonb; u record; x record;
  v_frags int; v_gaunt int; v_ok boolean;
begin
  select * into r from public.abt_reigns where id = p_reign;
  if r.id is null then return; end if;
  perform pg_advisory_xact_lock(hashtext('rebellion:' || p_reign::text));

  for m in select * from jsonb_array_elements(public._challenge_config('rebellion_milestones', '[]'::jsonb)) loop
    continue when p_as_of < r.started_at + make_interval(days => (m->>'days')::int);
    v_frags := coalesce((m->>'fragments')::int, 0); v_gaunt := coalesce((m->>'gauntlets')::int, 0);
    for u in select mm.user_id from public.app_memberships mm
             where mm.app_id = 'officelore' and mm.is_active and mm.user_id <> r.user_id loop
      -- the unique key makes this a once-only reward: only the insert that wins pays
      insert into public.rebellion_rewards (reign_id, user_id, milestone_id, status, fragments, gauntlets)
        values (p_reign, u.user_id, m->>'id', case when v_gaunt > 0 then 'deferred' else 'granted' end, v_frags, v_gaunt)
        on conflict do nothing;
      if found then
        if v_gaunt = 0 then
          if v_frags > 0 then perform public._add_fragments(u.user_id, v_frags); end if;
          update public.rebellion_rewards set granted_at = now() where reign_id = p_reign and user_id = u.user_id and milestone_id = m->>'id';
        end if;
      end if;
    end loop;
  end loop;

  -- a full Gauntlet that did not fit the inventory is handed over as soon as there is room
  for x in select * from public.rebellion_rewards where reign_id = p_reign and status = 'deferred' order by created_at loop
    v_ok := public._grant_rebellion_gauntlet(x.user_id, p_reign);
    if v_ok then
      update public.rebellion_rewards set status = 'granted', granted_at = now(), notified_at = null
        where reign_id = x.reign_id and user_id = x.user_id and milestone_id = x.milestone_id and status = 'deferred';
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._t_rebellion_on_reign_end() returns trigger as $$
begin
  if old.ended_at is null and new.ended_at is not null then
    perform public._award_rebellion_milestones(new.id, new.ended_at);      -- what the reign reached, even if nobody opened the app
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
drop trigger if exists trg_rebellion_on_reign_end on public.abt_reigns;
create trigger trg_rebellion_on_reign_end after update of ended_at on public.abt_reigns
  for each row execute procedure public._t_rebellion_on_reign_end();

-- =================================================================
-- SECTION 3 — reading, and the ceremony acknowledgement
-- =================================================================
create or replace function public.get_rebellion_state()
returns jsonb as $$
declare
  r public.abt_reigns;
  v_day int; v_ms jsonb; v_out jsonb := '[]'::jsonb; v_unseen jsonb := '[]'::jsonb; v_last jsonb := null;
  m jsonb; x public.rebellion_rewards; v_reached boolean;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into r from public.abt_reigns where ended_at is null limit 1;
  if r.id is null then return jsonb_build_object('reign', null); end if;
  perform public._award_rebellion_milestones(r.id, now());
  v_day := floor(extract(epoch from (now() - r.started_at)) / 86400)::int + 1;
  for m in select * from jsonb_array_elements(public._challenge_config('rebellion_milestones', '[]'::jsonb)) order by (value->>'days')::int loop
    v_reached := now() >= r.started_at + make_interval(days => (m->>'days')::int);
    select * into x from public.rebellion_rewards where reign_id = r.id and user_id = auth.uid() and milestone_id = m->>'id';
    if v_reached then v_last := m; end if;
    v_out := v_out || (m || jsonb_build_object('reached', v_reached, 'my_status', x.status,
                        'reach_at', r.started_at + make_interval(days => (m->>'days')::int)));
    if x.status = 'granted' and x.notified_at is null then v_unseen := v_unseen || m; end if;
  end loop;
  return jsonb_build_object(
    'reign', jsonb_build_object('id', r.id, 'user_id', r.user_id, 'started_at', r.started_at, 'day', v_day),
    'i_am_lord', r.user_id = auth.uid(),
    'milestones', v_out,
    'unseen', v_unseen,
    'pressure', coalesce(v_last->>'lord_text', 'The people are content, for now.'),
    'pressure_icon', coalesce(v_last->>'icon', '👑'));
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.ack_rebellion_notice()
returns void as $$
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  update public.rebellion_rewards set notified_at = now() where user_id = auth.uid() and status = 'granted' and notified_at is null;
end;
$$ language plpgsql security definer set search_path = public;

-- claiming: the Abt Lord can not take a Rebellion reward
create or replace function public.claim_challenge(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_line jsonb;
  v_no int := 0;
  v_results jsonb := '[]'::jsonb;
  v_min numeric;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.app_id <> 'officelore' then raise exception 'Unknown challenge'; end if;
  if a.user_id is not null and a.user_id <> auth.uid() then raise exception 'This is not your challenge'; end if;
  -- a Rebellion is for those who do not hold the throne
  if a.type = 'rebellion' and auth.uid() is not distinct from public._current_abt_lord() then raise exception 'The Abt Lord cannot claim a Rebellion reward'; end if;

  if a.status not in ('completed', 'claimed') then
    -- an unfinished Weekly offers a small consolation once the week is over, and only above the threshold
    v_min := coalesce((a.payload->>'consolation_min_pct')::numeric, 0.5);
    if a.type = 'personal_weekly' and (a.status = 'expired' or a.expires_at <= now()) and a.target > 0
       and a.progress::numeric / a.target > v_min and jsonb_array_length(coalesce(a.payload->'consolation', '[]'::jsonb)) > 0 then
      insert into public.challenge_claims (assignment_id, user_id) values (a.id, auth.uid()) on conflict do nothing;
      if not found then return jsonb_build_object('status', 'already_claimed'); end if;
      for v_line in select * from jsonb_array_elements(a.payload->'consolation') loop
        v_no := v_no + 1;
        -- consolation lines are plain Player XP: never a Fragment, never a chance roll
        if v_line->>'kind' = 'player_xp' then
          v_results := v_results || public._grant_challenge_reward2(auth.uid(), a.id, null, v_line, 200 + v_no);
        end if;
      end loop;
      return jsonb_build_object('status', 'consolation', 'results', v_results);
    end if;
    raise exception 'This challenge is not complete yet';
  end if;

  if a.user_id is null and not (
       case when a.group_rule is not null
            then exists (select 1 from public.challenge_member_progress mp where mp.assignment_id = a.id and mp.user_id = auth.uid())
            else exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id and c.user_id = auth.uid() and c.amount > 0) end) then
    raise exception 'Only members who took part in this quest can claim its reward';
  end if;

  insert into public.challenge_claims (assignment_id, user_id) values (a.id, auth.uid()) on conflict do nothing;
  if not found then
    return jsonb_build_object('status', 'already_claimed');
  end if;

  for v_line in select * from jsonb_array_elements(coalesce(a.reward->'lines', '[]'::jsonb)) loop
    v_no := v_no + 1;
    v_results := v_results || public._grant_challenge_reward2(auth.uid(), a.id, null, v_line, v_no);
  end loop;

  if a.user_id is not null then
    update public.challenge_assignments set status = 'claimed', claimed_at = now() where id = a.id;
  end if;
  return jsonb_build_object('status', 'claimed', 'results', v_results);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — the Rebellion quests
-- =================================================================
update public.challenge_definitions set is_active = false where type = 'rebellion' and parts is null;
delete from public.challenge_assignments a
  where a.type = 'rebellion' and a.parts is null and a.status = 'active' and a.progress = 0
    and not exists (select 1 from public.challenge_claims c where c.assignment_id = a.id);

update public.challenge_config set value = value || '{
      "rb_seeds":    [ {"kind":"player_xp","amount":35}, {"kind":"gauntlet_fragments","amount":2} ],
      "rb_pamphlet": [ {"kind":"player_xp","amount":35}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "rb_storm":    [ {"kind":"player_xp","amount":40}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.30} ]
   }'::jsonb
 where key = 'weekly_rewards' and not (value ? 'rb_seeds');

insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, target, requirements, reward_from_difficulty, reward_key, completion, icon, requires, audience, parts, unit) values
  ('rb_seeds', 'rebellion', 'battle', 'Seeds of Rebellion', 'Sow the doubt: finish 2 Personal Dailies, do 1 Lore activity and take part in 1 Battle.', 'special', 'daily_completed', 4, '{}', false, 'weekly_rewards', 'auto', '⚔️', 'battle_activity', 'non_lord',
     '[{"key":"dailies","label":"Personal Dailies","events":["daily_completed"],"target":2},
       {"key":"lore","label":"Lore activity","events":["nickname_created","nickname_anecdote_added","anecdote_added","quote_added","nickname_rated"],"target":1},
       {"key":"battle","label":"Battle joined","events":["battle_participated"],"target":1}]'::jsonb, 'steps'),
  ('rb_pamphlet', 'rebellion', 'social', 'The Pamphlet War', 'Spread the word: write 1 poem and rate 3 nicknames.', 'special', 'poem_created', 4, '{}', false, 'weekly_rewards', 'auto', '📜', 'nicknames_3', 'non_lord',
     '[{"key":"poem","label":"Poems written","events":["poem_created"],"target":1},
       {"key":"ratings","label":"Nickname ratings","events":["nickname_rated"],"target":3}]'::jsonb, 'steps'),
  ('rb_storm', 'rebellion', 'battle', 'The Gathering Storm', 'Stir the realm: take part in 3 Nickname Battles.', 'special', 'battle_participated', 3, '{}', false, 'weekly_rewards', 'auto', '⛈️', 'battle_activity', 'non_lord',
     '[{"key":"battles","label":"Battles joined","events":["battle_participated"],"target":3}]'::jsonb, 'battles')
on conflict (id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description, difficulty = excluded.difficulty, event_type = excluded.event_type,
  target = excluded.target, reward_key = excluded.reward_key, icon = excluded.icon, requires = excluded.requires, audience = excluded.audience,
  parts = excluded.parts, unit = excluded.unit, is_active = true;

-- =================================================================
-- SECTION 5 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array['_challenge_slots(text)', '_grant_rebellion_gauntlet(uuid, uuid)', '_award_rebellion_milestones(uuid, timestamptz)', '_t_rebellion_on_reign_end()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  revoke all on function public.get_rebellion_state() from public, anon;
  grant execute on function public.get_rebellion_state() to authenticated;
  revoke all on function public.ack_rebellion_notice() from public, anon;
  grant execute on function public.ack_rebellion_notice() to authenticated;
end $$;
