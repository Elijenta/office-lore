-- =================================================================
-- OFFICE LORE — AUDIT FIXES (reward speed, farming, assignments)
-- =================================================================
-- Found by running every migration and self-test on a real Postgres:
--
--  1. BEER EXPLORER never counted a rating or a session: its assignment only listened
--     to 'beer_added'. It now listens to the three discovery events (new beer,
--     FIRST rating of a beer, session attendance) and still needs two DIFFERENT kinds.
--     New: a definition may set requirements.by_event = {"beer_rated": {"min_first": 1}},
--     the rule applies to that event only.
--  2. REWARD SPEED. challenge_config.gauntlet_rules.weekly_fragment_cap (default 6):
--     at most 6 Gauntlet Fragments a member can STORE per ISO week from challenges,
--     Mystery boxes and the Group quests together. That is at most ~1 Royal
--     Gauntlet every 5 days for a very active member; a normal member lands at
--     about one per 1 to 2 weeks (see the balance report). The once-per-reign Long
--     Reign milestones are outside the cap (they are rare and fixed). Every stored
--     fragment is written to gauntlet_fragment_log, which is also the audit trail.
--  3. NICKNAME FACTORY could be finished by one member spamming nicknames: a single
--     member may now contribute at most per_member_max (3 of the 5).
--  4. PERFECT POURS no longer count as an 'activity' for Social Creature /
--     Completionist: pouring is part of drinking, and challenges reward discovery,
--     ratings, sessions, knowledge and social play, never drinking.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0056.
-- =================================================================

-- ---- 1. Beer Explorer ----
update public.challenge_definitions
  set event_types = array['beer_added', 'beer_rated', 'beer_session_participated'],
      requirements = '{"by_event": {"beer_rated": {"min_first": 1}}}'::jsonb
  where id = 'pw_beer_explorer';
update public.challenge_assignments
  set event_types = array['beer_added', 'beer_rated', 'beer_session_participated'],
      requirements = '{"by_event": {"beer_rated": {"min_first": 1}}}'::jsonb
  where definition_id = 'pw_beer_explorer' and status = 'active';

-- the engine: per-event requirements for distinct counts
create or replace function public._challenge_event(
  p_user uuid, p_event text, p_amount int default 1, p_dedupe text default null,
  p_meta jsonb default '{}'::jsonb, p_source text default null)
returns void as $$
declare
  a record;
  prt jsonb;
  v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
  v_pp jsonb; v_changed boolean; v_key text; v_cap int; v_n int; v_ev_n int; v_prog int; v_all boolean;
  v_val text; v_add int; v_done boolean; v_cat text;
begin
  if p_user is null or p_amount is null or p_amount <= 0 then return; end if;
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return;
  end if;

  if p_event <> 'activity' then
    insert into public.challenge_events (app_id, user_id, event_type, amount, dedupe_key, source_key, meta)
      values ('officelore', p_user, p_event, p_amount, p_dedupe, p_source, v_meta)
      on conflict (source_key) where source_key is not null do nothing;
    if not found then return; end if;
  end if;

  for a in
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements, asg.period_key, asg.parts, asg.part_progress, asg.distinct_by, asg.group_rule
    from public.challenge_assignments asg
    where asg.app_id = 'officelore' and asg.status = 'active' and asg.completion = 'auto'
      and p_event = any (coalesce(asg.event_types, array[asg.event_type]))
      and asg.starts_at <= now() and asg.expires_at > now()
      and (asg.user_id = p_user or asg.user_id is null)
    order by asg.id
    for update
  loop
    if a.parts is not null then
      -- a challenge made of several counters
      v_pp := a.part_progress; v_changed := false;
      for prt in select * from jsonb_array_elements(a.parts) loop
        continue when not ((prt->'events') ? p_event);
        continue when not public._challenge_requirements_met(coalesce(prt->'requirements', '{}'::jsonb), v_meta);
        v_key := prt->>'key'; v_cap := (prt->>'target')::int;
        v_n := coalesce((v_pp->>v_key)::int, 0);
        continue when not (prt ? 'avg_key') and v_n >= v_cap;
        if p_dedupe is not null then
          insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, v_key || ':' || p_dedupe) on conflict do nothing;
          continue when not found;
        end if;
        if (prt->'per_event_max') ? p_event then                       -- e.g. a battle win counts as a bonus step only once
          v_ev_n := coalesce((v_pp->>(v_key || ':' || p_event))::int, 0);
          continue when v_ev_n >= (prt->'per_event_max'->>p_event)::int;
          v_pp := v_pp || jsonb_build_object(v_key || ':' || p_event, v_ev_n + 1);
        end if;
        if prt ? 'avg_key' then                                        -- count + running sum, for "average at least X"
          v_pp := v_pp || jsonb_build_object(v_key, v_n + p_amount,
                    v_key || '_sum', coalesce((v_pp->>(v_key || '_sum'))::numeric, 0) + coalesce((v_meta->>(prt->>'avg_key'))::numeric, 0));
        else
          v_pp := v_pp || jsonb_build_object(v_key, least(v_n + p_amount, v_cap));
        end if;
        v_changed := true;
      end loop;
      continue when not v_changed;
      v_prog := 0; v_all := true;
      for prt in select * from jsonb_array_elements(a.parts) loop
        v_n := coalesce((v_pp->>(prt->>'key'))::int, 0);
        v_prog := v_prog + least(v_n, (prt->>'target')::int);
        if v_n < (prt->>'target')::int then v_all := false;
        elsif prt ? 'avg_key' and coalesce((v_pp->>((prt->>'key') || '_sum'))::numeric, 0) / greatest(v_n, 1) < (prt->>'min_avg')::numeric then v_all := false;
        end if;
      end loop;
      update public.challenge_assignments
        set part_progress = v_pp, progress = least(v_prog, target),
            status = case when v_all then 'completed' else status end,
            completed_at = case when v_all then now() else completed_at end
        where id = a.id;

    elsif a.distinct_by is not null then
      -- a challenge that counts DIFFERENT values (Dailies, categories, beer activity types)
      v_val := case when a.distinct_by = '$event' then p_event else v_meta->>a.distinct_by end;
      continue when v_val is null;
      -- requirements may differ per event kind: {"by_event": {"beer_rated": {"min_first": 1}}}
      continue when not public._challenge_requirements_met((a.requirements - 'by_event') || coalesce(a.requirements->'by_event'->p_event, '{}'::jsonb), v_meta);
      insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, 'v:' || v_val) on conflict do nothing;
      continue when not found;
      v_add := least(1, a.target - a.progress);
      continue when v_add <= 0;
      v_done := a.progress + v_add >= a.target;
      update public.challenge_assignments
        set progress = progress + v_add, status = case when v_done then 'completed' else status end,
            completed_at = case when v_done then now() else completed_at end
        where id = a.id;

    elsif a.group_rule is not null then
      -- a shared quest: per-person rows, one participant set, counted by rule
      perform public._group_rule_apply(a.id, a.group_rule, p_user, p_event, p_amount, p_dedupe, v_meta);

    else
      continue when not public._challenge_requirements_met(a.requirements, v_meta);
      if p_dedupe is not null then
        insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, p_dedupe) on conflict do nothing;
        continue when not found;
      end if;
      v_add := least(p_amount, a.target - a.progress);
      continue when v_add <= 0;
      v_done := a.progress + v_add >= a.target;
      update public.challenge_assignments
        set progress = progress + v_add,
            status = case when v_done then 'completed' else status end,
            completed_at = case when v_done then now() else completed_at end
        where id = a.id;
      if a.user_id is null then
        insert into public.challenge_contributions (assignment_id, user_id, amount) values (a.id, p_user, v_add)
          on conflict (assignment_id, user_id) do update set amount = public.challenge_contributions.amount + excluded.amount;
      end if;
      if v_done and a.type = 'personal_daily' then
        perform public._after_personal_daily_completed(p_user, a.id, a.period_key);
      end if;
    end if;
  end loop;

  -- every real event that belongs to an app category is also one 'activity' in that category
  if p_event <> 'activity' then
    select category into v_cat from public.challenge_event_categories where event_type = p_event;
    if found then perform public._challenge_event(p_user, 'activity', 1, null, jsonb_build_object('category', v_cat), null); end if;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- ---- 2. the weekly fragment cap ----
update public.challenge_config set value = value || '{"weekly_fragment_cap": 6}'::jsonb
  where key = 'gauntlet_rules' and not (value ? 'weekly_fragment_cap');

create table if not exists public.gauntlet_fragment_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  amount int not null check (amount > 0),
  source text not null default 'challenge',
  created_at timestamptz not null default now()
);
create index if not exists gauntlet_fragment_log_user on public.gauntlet_fragment_log (user_id, created_at desc);
alter table public.gauntlet_fragment_log enable row level security;
drop policy if exists "Fragment log: read own" on public.gauntlet_fragment_log;
create policy "Fragment log: read own" on public.gauntlet_fragment_log for select to authenticated using (user_id = auth.uid());

drop function if exists public._add_fragments(uuid, int);
create or replace function public._add_fragments(p_user uuid, p_n int, p_source text default 'challenge')
returns jsonb as $$
declare
  v_rules jsonb := public._challenge_config('gauntlet_rules', '{}'::jsonb);
  v_per int := public._fragments_per_gauntlet();
  v_cap int := public._max_gauntlets();
  v_weekly int := coalesce((v_rules->>'weekly_fragment_cap')::int, 6);
  v_lord boolean := p_user is not distinct from public._current_abt_lord();
  v_week_start timestamptz := date_trunc('week', now() at time zone 'Europe/Brussels') at time zone 'Europe/Brussels';
  v_used int := 0; v_n int := p_n;
  v_before int; v_after int; v_bal int; v_forged int; v_new int; v_stored int;
begin
  perform pg_advisory_xact_lock(hashtext('gauntlet_forge:' || p_user::text));
  insert into public.gauntlet_fragments (user_id, fragments) values (p_user, 0) on conflict do nothing;
  select fragments into v_before from public.gauntlet_fragments where user_id = p_user for update;

  -- the weekly allowance (the fixed once-per-reign milestones are outside it)
  if p_source <> 'rebellion' then
    select coalesce(sum(amount), 0) into v_used from public.gauntlet_fragment_log
      where user_id = p_user and created_at >= v_week_start and source <> 'rebellion';
    v_n := least(p_n, greatest(v_weekly - v_used, 0));
  end if;
  if v_n <= 0 then
    select coalesce(balance, 0) into v_bal from public.royal_gauntlet_balances where user_id = p_user;
    return jsonb_build_object('stored', 0, 'wasted', p_n, 'forged', 0, 'lord', v_lord, 'fragments', v_before, 'balance', coalesce(v_bal, 0),
                              'full', coalesce(v_bal, 0) >= v_cap, 'week_capped', true);
  end if;

  update public.gauntlet_fragments set fragments = fragments + v_n, updated_at = now() where user_id = p_user;
  v_forged := public._forge_gauntlets(p_user);
  select fragments into v_after from public.gauntlet_fragments where user_id = p_user;
  select coalesce(balance, 0) into v_bal from public.royal_gauntlet_balances where user_id = p_user;
  v_new := v_after;
  if not v_lord and coalesce(v_bal, 0) >= v_cap then
    v_new := greatest(least(v_after, v_per - 1), least(v_before, v_after));
    if v_new <> v_after then update public.gauntlet_fragments set fragments = v_new, updated_at = now() where user_id = p_user; end if;
  end if;
  v_stored := least(v_n, greatest(v_new - (v_before - v_per * v_forged), 0));
  if v_stored > 0 then
    insert into public.gauntlet_fragment_log (user_id, amount, source) values (p_user, v_stored, p_source);
  end if;
  return jsonb_build_object('stored', v_stored, 'wasted', p_n - v_stored, 'forged', v_forged, 'lord', v_lord,
                            'fragments', v_new, 'balance', coalesce(v_bal, 0), 'full', coalesce(v_bal, 0) >= v_cap, 'week_capped', v_n < p_n);
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
          if v_frags > 0 then perform public._add_fragments(u.user_id, v_frags, 'rebellion'); end if;
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

-- ---- 3. Nickname Factory ----
create or replace function public._group_rule_apply(p_assignment uuid, p_rule jsonb, p_user uuid, p_event text, p_amount int, p_dedupe text, p_meta jsonb)
returns void as $$
declare
  v_mode text := p_rule->>'mode';
  mp public.challenge_member_progress;
  v_sid text; v_total int; v_done int; v_prog int; v_target int; v_complete boolean := false; v_avg numeric;
begin
  select * into mp from public.challenge_member_progress where assignment_id = p_assignment and user_id = p_user;
  if mp.assignment_id is null then return; end if;                 -- not in this quest's participant set
  if not exists (select 1 from jsonb_array_elements_text(p_rule->'events') e where e = p_event) then return; end if;
  -- one member can not finish a shared pool alone
  if v_mode = 'pool' and (p_rule ? 'per_member_max') and mp.amount >= (p_rule->>'per_member_max')::int then return; end if;
  if p_dedupe is not null then
    insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (p_assignment, p_user, p_dedupe) on conflict do nothing;
    if not found then return; end if;
  end if;

  if v_mode in ('each', 'pool') then
    update public.challenge_member_progress set amount = amount + p_amount where assignment_id = p_assignment and user_id = p_user;
  elsif v_mode = 'shared_session' then
    v_sid := p_meta->>'session_id';
    if v_sid is null then return; end if;
    if coalesce(mp.extra->'sessions', '[]'::jsonb) ? v_sid then return; end if;
    update public.challenge_member_progress
      set extra = jsonb_set(extra, '{sessions}', coalesce(extra->'sessions', '[]'::jsonb) || to_jsonb(v_sid), true), amount = amount + 1
      where assignment_id = p_assignment and user_id = p_user;
  elsif v_mode = 'avg_quiz' then
    if mp.amount >= 1 then return; end if;                          -- one play counts
    update public.challenge_member_progress set amount = 1, extra = extra || jsonb_build_object('pct', coalesce((p_meta->>'pct')::numeric, 0))
      where assignment_id = p_assignment and user_id = p_user;
  else
    return;
  end if;

  -- the state is always recomputed from the rows: only members who are still active are awaited
  select count(*) into v_total from public.challenge_member_progress x
    join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active
    where x.assignment_id = p_assignment;
  if v_mode = 'each' then
    select count(*) into v_done from public.challenge_member_progress x
      join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active
      where x.assignment_id = p_assignment and x.amount >= coalesce((p_rule->>'per_member')::int, 1);
    v_prog := v_done; v_target := greatest(v_total, 1); v_complete := v_total > 0 and v_done = v_total;
  elsif v_mode = 'pool' then
    select coalesce(sum(x.amount), 0) into v_done from public.challenge_member_progress x where x.assignment_id = p_assignment;
    v_target := (p_rule->>'target')::int; v_prog := least(v_done, v_target); v_complete := v_done >= v_target;
  elsif v_mode = 'shared_session' then
    select coalesce(max(c), 0) into v_done from (
      select s, count(*) as c from public.challenge_member_progress x
        join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active,
        jsonb_array_elements_text(x.extra->'sessions') s
      where x.assignment_id = p_assignment group by s) q;
    v_target := (p_rule->>'min_attendees')::int; v_prog := least(v_done, v_target); v_complete := v_done >= v_target;
  else
    select count(*) filter (where x.amount >= 1), avg((x.extra->>'pct')::numeric) filter (where x.amount >= 1) into v_done, v_avg
      from public.challenge_member_progress x
      join public.app_memberships m on m.user_id = x.user_id and m.app_id = 'officelore' and m.is_active
      where x.assignment_id = p_assignment;
    v_prog := v_done; v_target := greatest(v_total, 1);
    v_complete := v_total > 0 and v_done = v_total and coalesce(v_avg, 0) >= (p_rule->>'min_avg')::numeric;
  end if;
  update public.challenge_assignments
    set progress = least(v_prog, v_target), target = v_target,
        status = case when v_complete and status = 'active' then 'completed' else status end,
        completed_at = case when v_complete then coalesce(completed_at, now()) else completed_at end
    where id = p_assignment;
end;
$$ language plpgsql security definer set search_path = public;
update public.challenge_definitions set group_rule = group_rule || '{"per_member_max": 3}'::jsonb where id = 'gw_nickname_factory';
update public.challenge_assignments set group_rule = group_rule || '{"per_member_max": 3}'::jsonb where definition_id = 'gw_nickname_factory' and status = 'active';

-- ---- 4. no drinking-adjacent 'activity' ----
delete from public.challenge_event_categories where event_type in ('perfect_pour', 'perfect_pour_given');

-- ---- grants ----
do $$
declare f text;
begin
  foreach f in array array['_add_fragments(uuid, int, text)', '_challenge_event(uuid, text, int, text, jsonb, text)', '_group_rule_apply(uuid, jsonb, uuid, text, int, text, jsonb)',
                           '_award_rebellion_milestones(uuid, timestamptz)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- ---- 5. the challenge trigger functions are not meant to be callable at all ----
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like '\_ch\_t\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
