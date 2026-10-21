-- =================================================================
-- OFFICE LORE — 🤝 GROUP WEEKLY QUESTS
-- =================================================================
-- Shared weekly quests for ALL active members of the workspace.
--
--   🤝 The Fellowship    every participant completes at least one Personal Daily
--   🍻 The Gathering     members attend ONE shared Beer Session (existing attendance, no drinking needed)
--   ✍️ The Poets         every participant writes at least one poem (named after the head count: The Three Poets)
--   🏭 Nickname Factory  the group together makes 5 nickname/lore contributions
--   🏛️ The Council       everyone plays the same Lore Quiz; the group average must reach 75%
--
-- THE PARTICIPANT SET. When the quest is created the active members of the
-- workspace are written to challenge_member_progress, one row each: that IS the
-- participant set and the per-person progress. Nothing counts for anyone outside
-- it, so somebody who joins later cannot corrupt a running quest (they are in
-- from next week), and nothing is hardcoded to three people: every rule counts
-- the rows. A member who is deactivated during the week is no longer awaited.
--
-- RULES (challenge_definitions.group_rule, data-driven):
--   each           every participant needs per_member events          (Fellowship, Poets)
--   pool           all participants together reach target             (Nickname Factory)
--   shared_session min_attendees participants in the SAME session     (Gathering)
--   avg_quiz       everyone plays once, the average pct >= min_avg    (Council)
--
-- REWARDS. Every participant claims their own: Player XP + 1 Gauntlet Fragment +
-- a Mystery chance (2 Fragments for the harder Council). Rewards live in
-- challenge_config.weekly_rewards; the number of group weeklies a week in
-- weekly_slots.group (default 2). Claiming is once per participant.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0052.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
alter table public.challenge_definitions add column if not exists group_rule jsonb;
alter table public.challenge_assignments add column if not exists group_rule jsonb;

create table if not exists public.challenge_member_progress (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  amount int not null default 0,
  extra jsonb not null default '{}',
  primary key (assignment_id, user_id)
);
alter table public.challenge_member_progress enable row level security;
drop policy if exists "Challenge members: read" on public.challenge_member_progress;
create policy "Challenge members: read" on public.challenge_member_progress for select to authenticated using (public.is_app_member('officelore'));
do $$
begin
  begin
    alter publication supabase_realtime add table public.challenge_member_progress;
  exception when duplicate_object then null;
  end;
end $$;

update public.challenge_config set value = value || '{"group": 2}'::jsonb where key = 'weekly_slots' and not (value ? 'group');

-- =================================================================
-- SECTION 2 — snapshots: the participant set is written with the assignment
-- =================================================================
create or replace function public._challenge_slots(p_type text) returns int as $$
  select case p_type
    when 'personal_daily' then 3 when 'group_daily' then 1
    when 'personal_weekly' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'normal')::int, 2) + coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'big')::int, 1)
    when 'group_weekly' then coalesce((public._challenge_config('weekly_slots', '{}'::jsonb)->>'group')::int, 2)
    when 'rebellion' then 1 else 0 end;
$$ language sql stable security definer set search_path = public;

create or replace function public._group_title(d public.challenge_definitions, p_n int)
returns text as $$
  select case when d.id = 'gw_poets' and p_n between 1 and 12
    then 'The ' || (array['One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve'])[p_n] || ' Poets'
    else d.title end;
$$ language sql immutable;

create or replace function public._new_assignment(d public.challenge_definitions, p_owner uuid, p_user uuid, p_key text, p_from timestamptz, p_to timestamptz)
returns uuid as $$
declare
  v_id uuid;
  v_n int := 0;
  v_target int;
begin
  if d.group_rule is not null then
    select count(*) into v_n from public.app_memberships m where m.app_id = 'officelore' and m.is_active;
  end if;
  v_target := case
    when d.parts is not null then (select sum((pt->>'target')::int) from jsonb_array_elements(d.parts) pt)
    when d.group_rule->>'mode' in ('each', 'avg_quiz') then greatest(v_n, 1)
    when d.group_rule->>'mode' = 'shared_session' then (d.group_rule->>'min_attendees')::int
    when d.group_rule->>'mode' = 'pool' then (d.group_rule->>'target')::int
    else d.target end;
  insert into public.challenge_assignments
    (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
     target, period_key, starts_at, expires_at, completion, payload, parts, distinct_by, unit, group_rule)
  values ('officelore', d.id, p_owner, d.type, d.category, public._group_title(d, v_n), d.description, d.difficulty, d.event_type,
          case when d.parts is not null then (select array_agg(distinct ev) from jsonb_array_elements(d.parts) pt, jsonb_array_elements_text(pt->'events') ev)
               when d.group_rule is not null then (select array_agg(ev) from jsonb_array_elements_text(d.group_rule->'events') ev)
               else d.event_types end,
          d.icon, d.requirements, public._assignment_reward(d), v_target,
          p_key, p_from, p_to, d.completion,
          public._chaos_payload(d, p_user, p_key) || public._weekly_payload(d), d.parts, d.distinct_by, d.unit, d.group_rule)
  on conflict do nothing
  returning id into v_id;
  if v_id is not null and d.group_rule is not null then
    insert into public.challenge_member_progress (assignment_id, user_id)
      select v_id, m.user_id from public.app_memberships m where m.app_id = 'officelore' and m.is_active
      on conflict do nothing;
  end if;
  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — the engine: group rules
-- =================================================================
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

-- the engine, with the group rule branch
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
      continue when not public._challenge_requirements_met(a.requirements, v_meta);
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

-- the weekly Council quiz uses the same round machinery as the Group Daily quiz,
-- but never decides a daily winner and never completes the assignment by itself
create or replace function public._ensure_group_round(p_assignment uuid)
returns public.group_daily_rounds as $$
declare
  a public.challenge_assignments;
  r public.group_daily_rounds;
  v_q jsonb; v_ans jsonb; v_kind text;
begin
  select * into r from public.group_daily_rounds where assignment_id = p_assignment;
  if found then return r; end if;
  perform pg_advisory_xact_lock(hashtext('group_round:' || p_assignment::text));
  select * into r from public.group_daily_rounds where assignment_id = p_assignment;
  if found then return r; end if;
  select * into a from public.challenge_assignments where id = p_assignment;
  v_kind := case when a.group_rule->>'mode' = 'avg_quiz' then 'quiz' else split_part(a.completion, ':', 2) end;
  if v_kind = 'quiz' then select g.questions, g.answers into v_q, v_ans from public._group_quiz(a.period_key) g; end if;
  insert into public.group_daily_rounds (app_id, assignment_id, kind, day_key, prompt, questions, winner_lines, min_participants, starts_at, ends_at)
    values (a.app_id, a.id, v_kind, a.period_key, a.payload - 'winner' - 'min_participants', v_q,
            coalesce(a.payload->'winner', '[]'::jsonb), coalesce((a.payload->>'min_participants')::int, 2), a.starts_at, a.expires_at)
    returning * into r;
  if v_ans is not null then insert into public.group_daily_secrets (round_id, answers) values (r.id, v_ans); end if;
  return r;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._group_participated(p_round uuid, p_user uuid)
returns void as $$
declare
  r public.group_daily_rounds;
  e public.group_daily_entries;
  v_type text;
begin
  select * into r from public.group_daily_rounds where id = p_round;
  select type into v_type from public.challenge_assignments where id = r.assignment_id;
  insert into public.group_daily_participants (round_id, user_id) values (p_round, p_user) on conflict do nothing;
  if v_type = 'group_daily' then
    update public.challenge_assignments set progress = target, status = case when status = 'active' then 'completed' else status end,
           completed_at = coalesce(completed_at, now())
      where id = r.assignment_id;
    insert into public.challenge_contributions (assignment_id, user_id, amount) values (r.assignment_id, p_user, 1)
      on conflict (assignment_id, user_id) do nothing;
  end if;
  update public.group_daily_rounds set entry_count = entry_count + 1, updated_at = now() where id = p_round;

  perform public._challenge_event(p_user, 'group_entry', 1, null, jsonb_build_object('kind', r.kind), 'group_entry:' || p_round::text || ':' || p_user::text);
  if r.kind in ('chaos', 'emoji') then
    perform public._challenge_event(p_user, 'chaos_completed', 1, null, jsonb_build_object('kind', 'group'), 'group_chaos:' || p_round::text || ':' || p_user::text);
  elsif r.kind = 'quiz' then
    select * into e from public.group_daily_entries where round_id = p_round and user_id = p_user;
    perform public._challenge_event(p_user, 'quiz_completed', 1, null,
      jsonb_build_object('pct', round(coalesce(e.score, 0) * 100.0 / greatest(coalesce((e.content->>'total')::int, 5), 1)), 'score', e.score, 'round_id', p_round),
      'group_quiz:' || p_round::text || ':' || p_user::text);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._finalize_group_round(p_round uuid)
returns void as $$
declare
  r public.group_daily_rounds;
  v_top int; v_top_ms int;
begin
  select * into r from public.group_daily_rounds where id = p_round for update;
  if r.id is null or r.status <> 'open' or r.ends_at > now() then return; end if;
  -- the weekly Council round has no winner
  if (select type from public.challenge_assignments where id = r.assignment_id) <> 'group_daily' then
    update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now() where id = r.id;
    return;
  end if;

  if r.entry_count < r.min_participants then
    update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now(),
      no_winner_reason = 'Not enough entries: at least ' || r.min_participants || ' are needed for a winner.' where id = r.id;
    return;
  end if;

  if r.kind = 'quiz' then
    select max(e.score) into v_top from public.group_daily_entries e where e.round_id = r.id;
    if coalesce(v_top, 0) <= 0 then
      update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now(), no_winner_reason = 'Nobody scored a point.' where id = r.id;
      return;
    end if;
    select min(e.duration_ms) into v_top_ms from public.group_daily_entries e where e.round_id = r.id and e.score = v_top;
    insert into public.group_daily_winners (round_id, user_id, entry_id)
      select r.id, e.user_id, e.id from public.group_daily_entries e where e.round_id = r.id and e.score = v_top and e.duration_ms = v_top_ms;
  else
    select max(c) into v_top from (select count(*) as c from public.group_daily_votes v where v.round_id = r.id group by v.entry_id) q;
    if coalesce(v_top, 0) < 1 then
      update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now(), no_winner_reason = 'Nobody voted.' where id = r.id;
      return;
    end if;
    insert into public.group_daily_winners (round_id, user_id, entry_id)
      select r.id, e.user_id, e.id from public.group_daily_entries e
      where e.round_id = r.id and (select count(*) from public.group_daily_votes v where v.entry_id = e.id) = v_top;
  end if;
  update public.group_daily_rounds set status = 'finalized', finalized_at = now(), updated_at = now() where id = r.id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.get_group_daily()
returns jsonb as $$
declare
  a public.challenge_assignments;
  r public.group_daily_rounds;
  p public.group_daily_rounds;
  v_cur jsonb := null; v_prev jsonb := null;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform public._finalize_due_group_rounds();
  select * into a from public.challenge_assignments
    where app_id = 'officelore' and type = 'group_daily' and user_id is null and completion like 'group:%'
      and starts_at <= now() and expires_at > now() order by starts_at desc limit 1;
  if a.id is not null then
    r := public._ensure_group_round(a.id);
    v_cur := public._group_round_json(r, auth.uid());
  end if;
  select * into p from public.group_daily_rounds
    where app_id = 'officelore' and status = 'finalized' and id is distinct from r.id and ends_at > now() - interval '3 days'
      and exists (select 1 from public.challenge_assignments x where x.id = public.group_daily_rounds.assignment_id and x.type = 'group_daily')
    order by ends_at desc limit 1;
  if p.id is not null then v_prev := public._group_round_json(p, auth.uid()); end if;
  return jsonb_build_object('current', v_cur, 'previous', v_prev);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.get_group_weekly_round(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  r public.group_daily_rounds;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id and app_id = 'officelore' and type = 'group_weekly' and group_rule->>'mode' = 'avg_quiz';
  if a.id is null then raise exception 'Unknown quest'; end if;
  r := public._ensure_group_round(a.id);
  return public._group_round_json(r, auth.uid());
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — claiming: every participant, once
-- =================================================================
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
-- SECTION 5 — the pool
-- =================================================================
update public.challenge_definitions set is_active = false where type = 'group_weekly' and group_rule is null;
delete from public.challenge_assignments a
  where a.type = 'group_weekly' and a.group_rule is null and a.status = 'active' and a.progress = 0
    and not exists (select 1 from public.challenge_contributions c where c.assignment_id = a.id)
    and not exists (select 1 from public.challenge_claims c where c.assignment_id = a.id);

insert into public.challenge_config (key, value)
select 'weekly_rewards', '{}'::jsonb where not exists (select 1 from public.challenge_config where key = 'weekly_rewards');
update public.challenge_config set value = value || '{
      "gw_fellowship":       [ {"kind":"player_xp","amount":30}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.25} ],
      "gw_gathering":        [ {"kind":"player_xp","amount":30}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "gw_poets":            [ {"kind":"player_xp","amount":35}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.25} ],
      "gw_nickname_factory": [ {"kind":"player_xp","amount":30}, {"kind":"gauntlet_fragments","amount":1}, {"kind":"mystery","amount":1,"chance":0.25} ],
      "gw_council":          [ {"kind":"player_xp","amount":45}, {"kind":"gauntlet_fragments","amount":2}, {"kind":"mystery","amount":1,"chance":0.35} ]
   }'::jsonb
 where key = 'weekly_rewards' and not (value ? 'gw_fellowship');

insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, target, requirements, reward_from_difficulty, reward_key, completion, icon, requires, audience, group_rule) values
  ('gw_fellowship', 'group_weekly', 'social', 'The Fellowship', 'Every member completes at least one Personal Daily this week. Nobody is left behind.', 'normal', 'daily_completed', 1, '{}', false, 'weekly_rewards', 'auto', '🤝', null, 'everyone',
     '{"mode":"each","events":["daily_completed"],"per_member":1}'::jsonb),
  ('gw_gathering', 'group_weekly', 'beer', 'The Gathering', 'Meet at one shared Beer Session this week. Showing up is enough: nobody has to drink anything.', 'normal', 'beer_session_participated', 2, '{}', false, 'weekly_rewards', 'auto', '🍻', null, 'everyone',
     '{"mode":"shared_session","events":["beer_session_participated"],"min_attendees":2}'::jsonb),
  ('gw_poets', 'group_weekly', 'poetry', 'The Poets', 'Every member writes at least one poem this week.', 'normal', 'poem_created', 1, '{}', false, 'weekly_rewards', 'auto', '✍️', null, 'everyone',
     '{"mode":"each","events":["poem_created"],"per_member":1}'::jsonb),
  ('gw_nickname_factory', 'group_weekly', 'nickname', 'Nickname Factory', 'Together: 5 nickname or lore contributions (new nicknames, anecdotes, quotes).', 'normal', 'nickname_created', 5, '{}', false, 'weekly_rewards', 'auto', '🏭', null, 'everyone',
     '{"mode":"pool","events":["nickname_created","nickname_anecdote_added","anecdote_added","quote_added"],"target":5}'::jsonb),
  ('gw_council', 'group_weekly', 'quiz', 'The Council', 'Everyone plays the same Lore Quiz. The group average has to reach 75%.', 'hard', 'quiz_completed', 1, '{}', false, 'weekly_rewards', 'auto', '🏛️', 'group_quiz_data', 'everyone',
     '{"mode":"avg_quiz","events":["quiz_completed"],"min_avg":75}'::jsonb)
on conflict (id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description, difficulty = excluded.difficulty, event_type = excluded.event_type,
  target = excluded.target, reward_key = excluded.reward_key, icon = excluded.icon, requires = excluded.requires, group_rule = excluded.group_rule, is_active = true;

-- =================================================================
-- SECTION 6 — grants
-- =================================================================
do $$
declare f text;
begin
  foreach f in array array[
    '_challenge_slots(text)', '_group_title(public.challenge_definitions, int)',
    '_new_assignment(public.challenge_definitions, uuid, uuid, text, timestamptz, timestamptz)',
    '_group_rule_apply(uuid, jsonb, uuid, text, int, text, jsonb)', '_challenge_event(uuid, text, int, text, jsonb, text)',
    '_ensure_group_round(uuid)', '_group_participated(uuid, uuid)', '_finalize_group_round(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  revoke all on function public.get_group_weekly_round(uuid) from public, anon;
  grant execute on function public.get_group_weekly_round(uuid) to authenticated;
end $$;
