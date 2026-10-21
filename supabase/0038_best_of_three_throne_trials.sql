-- =================================================================
-- OFFICE LORE — CHALLENGE FOR THE THRONE: BEST OF 3 TRIALS
-- =================================================================
-- Replaces the passive 7-day Beer XP duel from 0037 with a real
-- best-of-3 series of Trials. First to 2 Trial wins takes the throne.
--
--   Trial 1  challenger picks a Trial School
--   Trial 2  the Abt Lord picks a Trial School (the Lord's advantage)
--   Trial 3  only at 1-1: the FINAL TRIAL -- the throne chooses (a
--            random Trial from a random allowed school). 2-0 ends it.
--
-- A school choice draws a random Trial inside that school. Trials are
-- pure DATA (throne_trial_catalog) resolved by a small number of
-- resolution types (roll / answer / judge) -- adding a Trial = adding a
-- catalog row; adding a brand-new minigame type = one new resolution
-- value + one client renderer. The Throne Challenge itself never needs
-- rewriting.
--
-- State machine (throne_challenges.status):
--   pending         challenger created it, hasn't picked Trial 1's school yet
--   active          a Trial is being played / a school pick is due
--   awaiting_judge  the current Trial needs an independent judge
--   completed       someone reached 2 points (winner_user_id)
--   cancelled       challenger withdrew before Trial 1 / pending timed out
--
-- Asynchronous play: every step has a 48h deadline (step_deadline).
-- Lazy resolution, same as everything else here (no pg_cron): deadlines
-- are enforced from check_abt_throne(), resolve_throne_challenges() and
-- at the start of every challenge RPC. On expiry: unpicked school =
-- random school, unplayed Trial = lost by the non-responder (nobody
-- played = coin flip), unjudged Trial = coin flip, a never-started
-- pending challenge = cancelled.
--
-- Secrecy: the catalog (with answer keys) and the per-player
-- submissions have RLS enabled and NO client policy at all -- clients
-- can never read answers or the opponent's guess/roll early. The trial
-- row exposes only *_submitted booleans until the Trial resolves, plus
-- a snapshot of title/description/config.
--
-- Additive: nothing dropped. The 0037 XP-duel columns (ends_at,
-- *_xp_gained, resolved_at) stay but are retired. Same app-scoping
-- pattern as every table since 0015.
--
-- Run this once in the Supabase SQL Editor, after 0037.
-- =================================================================

-- =================================================================
-- SECTION 1 — throne_challenges: new state-machine columns
-- =================================================================
do $$
declare
  v_constraint_name text;
begin
  select conname into v_constraint_name
  from pg_constraint
  where conrelid = 'public.throne_challenges'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%status%';
  if v_constraint_name is not null then
    execute format('alter table public.throne_challenges drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.throne_challenges
  add column if not exists allow_real_life boolean not null default false,
  add column if not exists challenger_score int not null default 0,
  add column if not exists defender_score int not null default 0,
  add column if not exists winner_user_id uuid references public.profiles(id),
  add column if not exists started_at timestamptz,
  add column if not exists completed_at timestamptz,
  add column if not exists awaiting_pick_by uuid references public.profiles(id),
  add column if not exists step_deadline timestamptz;

alter table public.throne_challenges alter column ends_at drop not null;

-- any pre-existing XP-duel rows: keep them, in the new vocabulary
update public.throne_challenges
  set winner_user_id = case status
        when 'challenger_won' then challenger_user_id
        when 'defender_won' then defender_user_id
      end,
      completed_at = coalesce(resolved_at, now())
  where status in ('challenger_won', 'defender_won');
update public.throne_challenges set status = 'completed' where status in ('challenger_won', 'defender_won');

alter table public.throne_challenges add constraint throne_challenges_status_check
  check (status in ('pending', 'active', 'awaiting_judge', 'completed', 'cancelled'));

drop index if exists public.one_active_throne_challenge;
create unique index one_open_throne_challenge on public.throne_challenges ((1))
  where status in ('pending', 'active', 'awaiting_judge');

-- =================================================================
-- SECTION 2 — Trial catalog (private) + trials + submissions
-- =================================================================
create table public.throne_trial_catalog (
  id text primary key,
  school text not null check (school in ('pint', 'wisdom', 'lore', 'chaos', 'reflex', 'real_life')),
  title text not null,
  description text not null,
  resolution text not null check (resolution in ('roll', 'answer', 'judge')),
  public_config jsonb not null default '{}',
  answer_key jsonb, -- {"value": n} or {"source": "beers_count"|...}; never sent to clients
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.throne_trial_catalog enable row level security; -- deliberately NO policy

create table public.throne_challenge_trials (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references public.throne_challenges(id) on delete cascade,
  trial_no int not null check (trial_no between 1 and 3),
  picker_user_id uuid references public.profiles(id), -- null = the Final Trial (the throne chose)
  school text not null,
  catalog_id text not null references public.throne_trial_catalog(id),
  title text not null,
  description text not null,
  resolution text not null,
  public_config jsonb not null default '{}',
  status text not null default 'active' check (status in ('active', 'awaiting_judge', 'completed')),
  challenger_submitted boolean not null default false,
  defender_submitted boolean not null default false,
  challenger_result jsonb,
  defender_result jsonb,
  reveal jsonb,
  judge_user_id uuid references public.profiles(id),
  winner_user_id uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (challenge_id, trial_no)
);
alter table public.throne_challenge_trials enable row level security;
create policy "Throne challenge trials: read" on public.throne_challenge_trials for select to authenticated
  using (public.is_app_member('officelore'));

create table public.throne_trial_submissions (
  id uuid primary key default gen_random_uuid(),
  trial_id uuid not null references public.throne_challenge_trials(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  payload jsonb not null,
  created_at timestamptz not null default now(),
  unique (trial_id, user_id)
);
alter table public.throne_trial_submissions enable row level security; -- deliberately NO policy

alter publication supabase_realtime add table public.throne_challenge_trials;

-- placeholder Trials (real minigames come in later phases). REFLEX ones
-- are plain rolls until real-time minigames exist.
insert into public.throne_trial_catalog (id, school, title, description, resolution, public_config, answer_key) values
  ('pint_foam_fortune', 'pint', 'Foam Fortune', 'Roll the dice of the brewery gods. The highest roll takes the Trial.', 'roll', '{}', null),
  ('pint_beer_count', 'pint', 'The Great Beer Census', 'How many different beers has the Office registered in total? The closest guess wins.', 'answer', '{"unit":"beers"}', '{"source":"beers_count"}'),
  ('wisdom_eiffel', 'wisdom', 'Iron Lady', 'In which year was the Eiffel Tower completed? The closest guess wins.', 'answer', '{"unit":"year"}', '{"value":1889}'),
  ('wisdom_bones', 'wisdom', 'Skeleton Crew', 'How many bones does an adult human have? The closest guess wins.', 'answer', '{"unit":"bones"}', '{"value":206}'),
  ('lore_nickname_count', 'lore', 'Keepers of Names', 'How many nicknames exist on the Nickname Wall right now? The closest guess wins.', 'answer', '{"unit":"nicknames"}', '{"source":"nicknames_count"}'),
  ('lore_poem_count', 'lore', 'Verses of the Wall', 'How many poems are on the Poetry Wall right now? The closest guess wins.', 'answer', '{"unit":"poems"}', '{"source":"poems_count"}'),
  ('chaos_nickname_sprint', 'chaos', 'Nickname Sprint', 'Both players invent the best nickname for the judge, in 30 seconds. The judge decides.', 'judge', '{}', null),
  ('chaos_fake_holiday', 'chaos', 'Holiday Pitch', 'Both players pitch a brand-new fake Office Lore holiday. The judge decides.', 'judge', '{}', null),
  ('reflex_quick_draw', 'reflex', 'Quick Draw (placeholder)', 'The gunslingers of the taproom draw. For now the draw is a roll: highest wins.', 'roll', '{}', null),
  ('reflex_cap_flip', 'reflex', 'Bottle Cap Flip (placeholder)', 'A flick of the wrist, a roll of fate. Highest wins.', 'roll', '{}', null),
  ('real_bottle_flip', 'real_life', 'Bottle Flip Showdown', 'In real life: three bottle-flip attempts each. Most clean landings wins. The judge decides.', 'judge', '{}', null),
  ('real_arm_wrestle', 'real_life', 'Arm Wrestle', 'In real life: an arm-wrestling match at the nearest table. The judge decides.', 'judge', '{}', null);

-- =================================================================
-- SECTION 3 — internal helpers (revoked from client roles below)
-- =================================================================
create or replace function public._throne_answer_value(p_key jsonb)
returns numeric as $$
begin
  if p_key ? 'value' then
    return (p_key->>'value')::numeric;
  end if;
  return case p_key->>'source'
    when 'beers_count' then (select count(*) from public.beers)
    when 'nicknames_count' then (select count(*) from public.nicknames)
    when 'poems_count' then (select count(*) from public.poems)
    else 0
  end;
end;
$$ language plpgsql security definer set search_path = public;

-- draws a random unused, allowed catalog Trial. p_school null = random
-- school (the Final Trial / auto-pick). Falls back to any allowed Trial
-- when the chosen school has nothing usable left.
create or replace function public._pick_catalog_trial(p_challenge_id uuid, p_school text)
returns public.throne_trial_catalog as $$
declare
  c public.throne_challenges;
  v_judge_exists boolean;
  v_school text := p_school;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id;

  select exists (
    select 1 from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active = true
      and m.user_id not in (c.challenger_user_id, c.defender_user_id)
  ) into v_judge_exists;

  if v_school is not null then
    select t.* into v_cat from public.throne_trial_catalog t
      where t.is_active and t.school = v_school
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution <> 'judge' or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
      order by random() limit 1;
    if v_cat.id is not null then
      return v_cat;
    end if;
  end if;

  -- random school (or fallback): pick a school first so every school is
  -- equally likely regardless of how many Trials it has
  select s.school into v_school from (
    select distinct t.school from public.throne_trial_catalog t
      where t.is_active
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution <> 'judge' or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
  ) s order by random() limit 1;

  if v_school is null then
    raise exception 'No Trials available for this Throne Challenge';
  end if;

  select t.* into v_cat from public.throne_trial_catalog t
    where t.is_active and t.school = v_school
      and (c.allow_real_life or t.school <> 'real_life')
      and (t.resolution <> 'judge' or v_judge_exists)
      and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
    order by random() limit 1;
  return v_cat;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._start_throne_trial(p_challenge_id uuid, p_cat public.throne_trial_catalog, p_picker uuid)
returns uuid as $$
declare
  v_no int;
  v_id uuid;
  v_status text;
begin
  select count(*) + 1 into v_no from public.throne_challenge_trials where challenge_id = p_challenge_id;
  v_status := case when p_cat.resolution = 'judge' then 'awaiting_judge' else 'active' end;

  insert into public.throne_challenge_trials
    (challenge_id, trial_no, picker_user_id, school, catalog_id, title, description, resolution, public_config, status)
  values
    (p_challenge_id, v_no, p_picker, p_cat.school, p_cat.id, p_cat.title, p_cat.description, p_cat.resolution, p_cat.public_config, v_status)
  returning id into v_id;

  update public.throne_challenges
    set status = v_status,
        awaiting_pick_by = null,
        started_at = coalesce(started_at, now()),
        step_deadline = now() + interval '48 hours'
    where id = p_challenge_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- the throne changes hands (or not). Same reign swap as 0037.
create or replace function public._complete_throne_challenge(p_challenge_id uuid, p_winner uuid)
returns void as $$
declare
  c public.throne_challenges;
  v_reign record;
  v_def_total int;
  v_chal_total int;
  v_snapshot jsonb;
begin
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.status in ('completed', 'cancelled') then
    return;
  end if;

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;

  if p_winner = c.challenger_user_id then
    if v_reign is null or v_reign.id <> c.reign_id then
      -- the challenged reign is no longer the open one: nothing to take
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;
      return;
    end if;

    select coalesce(beer_xp, 0) into v_def_total from public.user_xp_totals where user_id = c.defender_user_id;
    select coalesce(beer_xp, 0) into v_chal_total from public.user_xp_totals where user_id = c.challenger_user_id;
    select to_jsonb(l) into v_snapshot from public.abt_avatar_loadouts l where l.user_id = c.defender_user_id;

    update public.abt_reigns
      set ended_at = now(), ending_beer_xp = v_def_total, dethroned_by_user_id = c.challenger_user_id,
          ending_loadout_snapshot = v_snapshot
      where id = v_reign.id;

    insert into public.abt_reigns (user_id, started_at, starting_beer_xp)
    values (c.challenger_user_id, now(), v_chal_total);
  end if;

  update public.throne_challenges
    set status = 'completed', winner_user_id = p_winner, completed_at = now(), resolved_at = now(),
        awaiting_pick_by = null, step_deadline = null
    where id = c.id;

  perform public._sync_absolute_abt();
end;
$$ language plpgsql security definer set search_path = public;

-- scores a finished Trial and moves the series forward
create or replace function public._finish_throne_trial(p_trial_id uuid, p_winner uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
  v_chal int;
  v_def int;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.status = 'completed' then
    return;
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id for update;
  if p_winner not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Trial winner must be a participant';
  end if;

  update public.throne_challenge_trials
    set status = 'completed', winner_user_id = p_winner, completed_at = now()
    where id = t.id;

  v_chal := c.challenger_score + case when p_winner = c.challenger_user_id then 1 else 0 end;
  v_def := c.defender_score + case when p_winner = c.defender_user_id then 1 else 0 end;
  update public.throne_challenges set challenger_score = v_chal, defender_score = v_def where id = c.id;

  if v_chal >= 2 or v_def >= 2 then
    perform public._complete_throne_challenge(c.id, p_winner);
  elsif t.trial_no = 1 then
    -- Trial 2: the Abt Lord picks the school
    update public.throne_challenges
      set status = 'active', awaiting_pick_by = c.defender_user_id, step_deadline = now() + interval '48 hours'
      where id = c.id;
  else
    -- 1-1 after Trial 2: THE FINAL TRIAL, the throne chooses
    v_cat := public._pick_catalog_trial(c.id, null);
    perform public._start_throne_trial(c.id, v_cat, null);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- resolves a roll/answer Trial once both players have submitted
create or replace function public._resolve_submission_trial(p_trial_id uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  cat public.throne_trial_catalog;
  v_chal jsonb;
  v_def jsonb;
  v_target numeric;
  v_chal_score numeric;
  v_def_score numeric;
  v_winner uuid;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  select * into c from public.throne_challenges where id = t.challenge_id;
  select payload into v_chal from public.throne_trial_submissions where trial_id = t.id and user_id = c.challenger_user_id;
  select payload into v_def from public.throne_trial_submissions where trial_id = t.id and user_id = c.defender_user_id;

  if t.resolution = 'roll' then
    v_chal_score := (v_chal->>'roll')::numeric;
    v_def_score := (v_def->>'roll')::numeric;
    update public.throne_challenge_trials set challenger_result = v_chal, defender_result = v_def where id = t.id;
  else
    select * into cat from public.throne_trial_catalog where id = t.catalog_id;
    v_target := public._throne_answer_value(cat.answer_key);
    -- lower distance is better: compare negated distances
    v_chal_score := -abs((v_chal->>'guess')::numeric - v_target);
    v_def_score := -abs((v_def->>'guess')::numeric - v_target);
    update public.throne_challenge_trials
      set challenger_result = v_chal || jsonb_build_object('distance', abs((v_chal->>'guess')::numeric - v_target)),
          defender_result = v_def || jsonb_build_object('distance', abs((v_def->>'guess')::numeric - v_target)),
          reveal = jsonb_build_object('answer', v_target)
      where id = t.id;
  end if;

  if v_chal_score > v_def_score then
    v_winner := c.challenger_user_id;
  elsif v_def_score > v_chal_score then
    v_winner := c.defender_user_id;
  else
    v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
  end if;

  perform public._finish_throne_trial(t.id, v_winner);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — deadline enforcement (name kept: check_abt_throne() and
-- resolve_throne_challenges() already call it)
-- =================================================================
create or replace function public._resolve_expired_throne_challenge()
returns boolean as $$
declare
  c public.throne_challenges;
  t public.throne_challenge_trials;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_changed boolean := false;
  v_guard int := 0;
begin
  perform pg_advisory_xact_lock(918273645);

  loop
    v_guard := v_guard + 1;
    exit when v_guard > 10;

    select * into c from public.throne_challenges
      where status in ('pending', 'active', 'awaiting_judge')
        and step_deadline is not null and step_deadline <= now()
      limit 1;
    exit when c.id is null;
    v_changed := true;

    if c.status = 'pending' then
      -- the challenger never picked Trial 1's school: nothing was played, nobody lost
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;

    elsif c.awaiting_pick_by is not null then
      -- the picker didn't choose a school in time: a random school is drawn
      v_cat := public._pick_catalog_trial(c.id, null);
      perform public._start_throne_trial(c.id, v_cat, c.awaiting_pick_by);

    else
      select * into t from public.throne_challenge_trials
        where challenge_id = c.id and status <> 'completed'
        order by trial_no desc limit 1;

      if t.id is null then
        -- inconsistent state: close it safely
        update public.throne_challenges
          set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
          where id = c.id;
      else
        if t.resolution = 'judge' then
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        elsif t.challenger_submitted and not t.defender_submitted then
          v_winner := c.challenger_user_id; -- the non-responder forfeits
        elsif t.defender_submitted and not t.challenger_submitted then
          v_winner := c.defender_user_id;
        else
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        end if;
        update public.throne_challenge_trials
          set reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('timeout', true)
          where id = t.id;
        perform public._finish_throne_trial(t.id, v_winner);
      end if;
    end if;
  end loop;

  return v_changed;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — public RPCs
-- =================================================================
drop function if exists public.get_throne_challenge_progress();
drop function if exists public.create_throne_challenge();

create or replace function public.create_throne_challenge(p_allow_real_life boolean default false)
returns uuid as $$
declare
  v_reign record;
  v_id uuid;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;
  if v_reign is null then
    raise exception 'There is no Abt Lord to challenge yet';
  end if;
  if v_reign.user_id = auth.uid() then
    raise exception 'The Abt Lord cannot challenge themselves';
  end if;
  if exists (select 1 from public.throne_challenges where status in ('pending', 'active', 'awaiting_judge')) then
    raise exception 'A Throne Challenge is already underway';
  end if;

  insert into public.throne_challenges
    (reign_id, defender_user_id, challenger_user_id, allow_real_life, awaiting_pick_by, step_deadline, starts_at)
  values
    (v_reign.id, v_reign.user_id, auth.uid(), coalesce(p_allow_real_life, false), auth.uid(), now() + interval '48 hours', now())
  returning id into v_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.pick_throne_trial_school(p_challenge_id uuid, p_school text)
returns void as $$
declare
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.id is null or c.status not in ('pending', 'active') then
    raise exception 'This Throne Challenge is not waiting for a Trial School';
  end if;
  if c.awaiting_pick_by is distinct from auth.uid() then
    raise exception 'It is not your turn to choose a Trial School';
  end if;
  if p_school not in ('pint', 'wisdom', 'lore', 'chaos', 'reflex', 'real_life') then
    raise exception 'Unknown Trial School';
  end if;
  if p_school = 'real_life' and not c.allow_real_life then
    raise exception 'Real Life Trials are not allowed in this challenge';
  end if;

  v_cat := public._pick_catalog_trial(c.id, p_school);
  perform public._start_throne_trial(c.id, v_cat, auth.uid());
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.submit_throne_trial(p_trial_id uuid, p_payload jsonb default '{}')
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_payload jsonb;
  v_guess numeric;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'active' or t.resolution not in ('roll', 'answer') then
    raise exception 'This Trial is not open for submissions';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can play this Trial';
  end if;
  if exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = auth.uid()) then
    raise exception 'You have already played this Trial';
  end if;

  if t.resolution = 'roll' then
    v_payload := jsonb_build_object('roll', 1 + floor(random() * 100)::int);
  else
    begin
      v_guess := (p_payload->>'guess')::numeric;
    exception when others then
      v_guess := null;
    end;
    if v_guess is null then
      raise exception 'Enter a number as your guess';
    end if;
    v_payload := jsonb_build_object('guess', v_guess);
  end if;

  insert into public.throne_trial_submissions (trial_id, user_id, payload) values (t.id, auth.uid(), v_payload);

  if auth.uid() = c.challenger_user_id then
    update public.throne_challenge_trials set challenger_submitted = true where id = t.id;
  else
    update public.throne_challenge_trials set defender_submitted = true where id = t.id;
  end if;

  if exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = c.challenger_user_id)
     and exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = c.defender_user_id) then
    perform public._resolve_submission_trial(t.id);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.judge_throne_trial(p_trial_id uuid, p_winner uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'awaiting_judge' then
    raise exception 'This Trial is not waiting for a judge';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'A duelist cannot judge their own Trial';
  end if;
  if p_winner not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'The winner must be one of the duelists';
  end if;

  update public.throne_challenge_trials
    set judge_user_id = auth.uid(), reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid())
    where id = t.id;
  perform public._finish_throne_trial(t.id, p_winner);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.cancel_throne_challenge(p_challenge_id uuid)
returns void as $$
declare
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  select * into c from public.throne_challenges where id = p_challenge_id for update;
  if c.id is null or c.challenger_user_id <> auth.uid() then
    raise exception 'Only the challenger can withdraw a challenge';
  end if;
  if c.status <> 'pending' or exists (select 1 from public.throne_challenge_trials where challenge_id = c.id) then
    raise exception 'The challenge has already begun';
  end if;

  update public.throne_challenges
    set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
    where id = c.id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — grants
-- =================================================================
revoke all on function public._throne_answer_value(jsonb) from public, anon, authenticated;
revoke all on function public._pick_catalog_trial(uuid, text) from public, anon, authenticated;
revoke all on function public._start_throne_trial(uuid, public.throne_trial_catalog, uuid) from public, anon, authenticated;
revoke all on function public._complete_throne_challenge(uuid, uuid) from public, anon, authenticated;
revoke all on function public._finish_throne_trial(uuid, uuid) from public, anon, authenticated;
revoke all on function public._resolve_submission_trial(uuid) from public, anon, authenticated;
revoke all on function public._resolve_expired_throne_challenge() from public, anon, authenticated;

revoke all on function public.create_throne_challenge(boolean) from public, anon;
revoke all on function public.pick_throne_trial_school(uuid, text) from public, anon;
revoke all on function public.submit_throne_trial(uuid, jsonb) from public, anon;
revoke all on function public.judge_throne_trial(uuid, uuid) from public, anon;
revoke all on function public.cancel_throne_challenge(uuid) from public, anon;
grant execute on function public.create_throne_challenge(boolean) to authenticated;
grant execute on function public.pick_throne_trial_school(uuid, text) to authenticated;
grant execute on function public.submit_throne_trial(uuid, jsonb) to authenticated;
grant execute on function public.judge_throne_trial(uuid, uuid) to authenticated;
grant execute on function public.cancel_throne_challenge(uuid) to authenticated;
