-- =================================================================
-- OFFICE LORE — THE ROYAL JUDGE + CREATIVE (HUMAN-JUDGED) TRIALS
-- =================================================================
-- Trials a computer cannot score. Both duelists write something, a human
-- Royal Judge decides.
--
--   ✍️ POETRY DUEL     same absurd prompt (from the Poetry Wall prompts), a short poem
--   🏷️ NICKNAME DUEL   the app picks a person from the Office Lore, both invent a nickname
--   🎭 CAPTION BATTLE  same absurd situation, one caption each
--   😂 MAKE ME LAUGH   same subject, one sentence to make the Judge laugh
--   👑 ROYAL SPEECH    "explain in 30 seconds why you are the rightful ruler of The Taproom"
--
-- ROYAL JUDGE
--   Chosen automatically when a human-judged Trial starts: a random active
--   Office Lore member who is neither the challenger nor the defender (with
--   three users: simply the third one). Stored on the Trial
--   (throne_challenge_trials.judge_user_id) so it is stable and visible. Only
--   THAT member can judge. Verdicts:
--     the defender wins / the challenger wins / BOTH WERE TERRIBLE
--   "Both were terrible" scores NO point: the Trial is voided and a
--   replacement Trial (same Trial number, same school when possible, a
--   different Trial) takes its place.
--
-- ANONYMOUS VOTING
--   Creative entries are shown to the Judge as "Submission A" / "Submission B"
--   (random order, fixed when the second entry arrives). The Judge never
--   sees names. Only after the verdict does the Trial record who wrote what.
--   Entries live in throne_trial_submissions (no client policy): a duelist
--   only ever reads their OWN entry (via get_throne_creative), the Judge
--   reads the anonymous pair only while judging, and everybody reads the
--   revealed entries once the Trial is over (trial.reveal).
--
-- STATE (per Trial)
--   active          duelists are writing        (flags: *_submitted)
--   awaiting_judge  both entries in, Judge decides   (fresh 48h for the Judge)
--   completed       a winner was named
--   voided          "both were terrible": no point, replaced
--   Deadlines (48h per step, lazy like everything else): a duelist who never
--   writes forfeits (nobody wrote = coin flip); a Judge who never decides =
--   coin flip.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0041.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.throne_trial_catalog'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%resolution%';
  if v_name is not null then execute format('alter table public.throne_trial_catalog drop constraint %I', v_name); end if;

  select conname into v_name from pg_constraint
    where conrelid = 'public.throne_challenge_trials'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%status%';
  if v_name is not null then execute format('alter table public.throne_challenge_trials drop constraint %I', v_name); end if;
end $$;

alter table public.throne_trial_catalog add constraint throne_trial_catalog_resolution_check
  check (resolution in ('roll', 'answer', 'judge', 'quiz', 'timed', 'streak', 'creative'));
alter table public.throne_challenge_trials add constraint throne_challenge_trials_status_check
  check (status in ('active', 'awaiting_judge', 'completed', 'voided'));

-- a voided Trial is replaced by another attempt at the SAME Trial number
alter table public.throne_challenge_trials add column if not exists attempt int not null default 1;
alter table public.throne_challenge_trials drop constraint if exists throne_challenge_trials_challenge_id_trial_no_key;
create unique index if not exists throne_challenge_trials_no_attempt
  on public.throne_challenge_trials (challenge_id, trial_no, attempt);

alter table public.throne_trial_submissions add column if not exists slot text check (slot in ('A', 'B'));

-- prompts for the creative Trials (private: the chosen prompt is copied onto the Trial)
create table if not exists public.throne_creative_prompts (
  id serial primary key,
  kind text not null check (kind in ('caption', 'laugh', 'speech', 'poem')),
  prompt text not null unique
);
alter table public.throne_creative_prompts enable row level security; -- deliberately NO policy

insert into public.throne_creative_prompts (kind, prompt) values
  ('caption', 'The office printer has just been elected team leader. Caption the moment.'),
  ('caption', 'A lone banana sits in the CEO''s chair. Caption the photo.'),
  ('caption', 'Someone just replied-all to 400 people. Caption the second after.'),
  ('caption', 'The coffee machine, seconds after being told it is "out of order". Caption it.'),
  ('caption', 'A tiny dragon is guarding the last biscuit. Caption the scene.'),
  ('caption', 'The Abt Lord arrives at the Monday stand-up. Caption the entrance.'),
  ('caption', 'Two colleagues stare at the same spreadsheet in complete silence. Caption it.'),
  ('caption', 'A single sock was found on the printer. Caption the evidence.'),
  ('laugh', 'Mondays'),
  ('laugh', 'The office fridge'),
  ('laugh', 'Meetings that could have been an email'),
  ('laugh', 'Parking spots'),
  ('laugh', 'The last beer'),
  ('laugh', 'A reply-all chain that will not die'),
  ('laugh', 'Open-plan offices'),
  ('laugh', 'The company outing'),
  ('speech', 'Explain in 30 seconds why you are the rightful ruler of The Taproom.'),
  ('speech', 'Defend, in 30 seconds, why your taste in beer should be law.'),
  ('speech', 'Give a 30-second victory speech for the throne you have not won yet.'),
  ('speech', 'In 30 seconds: why does the Abt Lord''s crown fit YOUR head?'),
  ('speech', 'Convince the Royal Judge in 30 seconds that you are the true heir of the Taproom.'),
  ('poem', 'Write a short poem about a flying beer mat.'),
  ('poem', 'Write a short ode to the last biscuit in the tin.'),
  ('poem', 'Write a short poem about a stapler that dreams of the sea.')
on conflict (prompt) do nothing;

-- =================================================================
-- SECTION 2 — helpers
-- =================================================================
-- the Royal Judge: a random active Office Lore member, not a duelist
create or replace function public._pick_judge(p_challenge_id uuid)
returns uuid as $$
  select m.user_id
  from public.app_memberships m, public.throne_challenges c
  where c.id = p_challenge_id
    and m.app_id = 'officelore' and m.is_active = true
    and m.user_id not in (c.challenger_user_id, c.defender_user_id)
  order by random() limit 1;
$$ language sql volatile security definer set search_path = public;

-- both entries, with who wrote what (only ever written into trial.reveal AFTER judging)
create or replace function public._throne_creative_reveal(p_trial_id uuid)
returns jsonb as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'slot', slot, 'text', payload->>'text') order by slot), '[]'::jsonb)
  from public.throne_trial_submissions where trial_id = p_trial_id;
$$ language sql stable security definer set search_path = public;

-- draws the shared prompt of a creative Trial and stores it on the Trial
create or replace function public._prepare_creative_trial(p_trial_id uuid, p_cat public.throne_trial_catalog)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_kind text := p_cat.public_config->>'kind';
  v_prompt text;
  v_facts jsonb := '{}'::jsonb;
  r record;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  select * into c from public.throne_challenges where id = t.challenge_id;

  if v_kind = 'poem' then
    -- the Poetry Wall's own absurd prompts
    select prompt_text into v_prompt from public.poetry_prompts
      where is_active and category in ('absolute_nonsense', 'office_nonsense', 'beer_inspired', 'tragic', 'dramatic')
      order by random() limit 1;
    if v_prompt is null then
      select prompt into v_prompt from public.throne_creative_prompts where kind = 'poem' order by random() limit 1;
    end if;

  elsif v_kind = 'nickname' then
    -- a person already in the Office Lore, never one of the people in this duel
    select btrim(n.person_real_name) as person, max(nullif(btrim(n.business_unit), '')) as bu into r
    from public.nicknames n
    where btrim(n.person_real_name) <> ''
      and not exists (
        select 1 from public.profiles pr
        where pr.id in (c.challenger_user_id, c.defender_user_id, t.judge_user_id)
          and lower(split_part(btrim(pr.display_name), ' ', 1)) = lower(split_part(btrim(n.person_real_name), ' ', 1)))
    group by btrim(n.person_real_name)
    order by random() limit 1;
    if r.person is not null then
      v_prompt := format('Invent the best nickname for %s.', r.person);
      v_facts := jsonb_build_object('person', r.person, 'business_unit', r.bu);
    else
      v_prompt := 'Invent the best nickname for the colleague who always takes the last biscuit.';
    end if;

  else
    select prompt into v_prompt from public.throne_creative_prompts where kind = v_kind order by random() limit 1;
  end if;

  update public.throne_challenge_trials
    set public_config = public_config || jsonb_build_object('prompt', coalesce(v_prompt, p_cat.description), 'facts', v_facts)
    where id = p_trial_id;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- eligibility: human-judged Trials need a member who is not a duelist
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
        and (t.resolution not in ('judge', 'creative') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
      order by random() limit 1;
    if v_cat.id is not null then
      return v_cat;
    end if;
  end if;

  select s.school into v_school from (
    select distinct t.school from public.throne_trial_catalog t
      where t.is_active
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution not in ('judge', 'creative') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
  ) s order by random() limit 1;

  if v_school is null then
    raise exception 'No Trials available for this Throne Challenge';
  end if;

  select t.* into v_cat from public.throne_trial_catalog t
    where t.is_active and t.school = v_school
      and (c.allow_real_life or t.school <> 'real_life')
      and (t.resolution not in ('judge', 'creative') or v_judge_exists)
      and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
    order by random() limit 1;
  return v_cat;
end;
$$ language plpgsql security definer set search_path = public;

-- starting a Trial: a replacement for a voided one reuses its number
create or replace function public._start_throne_trial(p_challenge_id uuid, p_cat public.throne_trial_catalog, p_picker uuid)
returns uuid as $$
declare
  v_no int;
  v_attempt int;
  v_id uuid;
  v_status text;
  v_judge uuid;
begin
  select count(*) + 1 into v_no from public.throne_challenge_trials where challenge_id = p_challenge_id and status <> 'voided';
  select count(*) + 1 into v_attempt from public.throne_challenge_trials where challenge_id = p_challenge_id and trial_no = v_no;
  v_status := case when p_cat.resolution = 'judge' then 'awaiting_judge' else 'active' end;
  v_judge := case when p_cat.resolution in ('judge', 'creative') then public._pick_judge(p_challenge_id) end;

  insert into public.throne_challenge_trials
    (challenge_id, trial_no, attempt, picker_user_id, school, catalog_id, title, description, resolution, public_config, status, judge_user_id)
  values
    (p_challenge_id, v_no, v_attempt, p_picker, p_cat.school, p_cat.id, p_cat.title, p_cat.description, p_cat.resolution, p_cat.public_config, v_status, v_judge)
  returning id into v_id;

  if p_cat.resolution in ('quiz', 'timed', 'streak') then
    perform public._prepare_throne_trial(v_id, p_cat);
  elsif p_cat.resolution = 'creative' then
    perform public._prepare_creative_trial(v_id, p_cat);
  end if;

  update public.throne_challenges
    set status = v_status,
        awaiting_pick_by = null,
        started_at = coalesce(started_at, now()),
        step_deadline = now() + interval '48 hours'
    where id = p_challenge_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 3 — creative entries
-- =================================================================
create or replace function public.submit_throne_creative(p_trial_id uuid, p_text text)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_text text := btrim(coalesce(p_text, ''));
  v_max int;
  v_a_first boolean;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.resolution <> 'creative' or t.status <> 'active' then
    raise exception 'This Trial is not open for entries';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can enter this Trial';
  end if;
  if exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = auth.uid()) then
    raise exception 'You have already sealed your entry';
  end if;

  v_max := coalesce((t.public_config->>'max_chars')::int, 600);
  if length(v_text) < 1 then raise exception 'Write something first'; end if;
  if length(v_text) > v_max then raise exception 'Too long: at most % characters', v_max; end if;

  insert into public.throne_trial_submissions (trial_id, user_id, payload) values (t.id, auth.uid(), jsonb_build_object('text', v_text));
  if auth.uid() = c.challenger_user_id then
    update public.throne_challenge_trials set challenger_submitted = true where id = t.id;
  else
    update public.throne_challenge_trials set defender_submitted = true where id = t.id;
  end if;

  -- both entries in: fix the anonymous order and hand over to the Royal Judge
  if exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = c.challenger_user_id)
     and exists (select 1 from public.throne_trial_submissions where trial_id = t.id and user_id = c.defender_user_id) then
    v_a_first := random() < 0.5;
    update public.throne_trial_submissions set slot = case when (user_id = c.challenger_user_id) = v_a_first then 'A' else 'B' end
      where trial_id = t.id;
    update public.throne_challenge_trials set status = 'awaiting_judge' where id = t.id;
    update public.throne_challenges set status = 'awaiting_judge', step_deadline = now() + interval '48 hours' where id = c.id;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- what the caller may see of a creative Trial: their own entry, or (the Judge) the anonymous pair
create or replace function public.get_throne_creative(p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_role text;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  if t.id is null or t.resolution <> 'creative' then raise exception 'Not a creative Trial'; end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  v_role := case when auth.uid() = t.judge_user_id then 'judge'
                 when auth.uid() in (c.challenger_user_id, c.defender_user_id) then 'duelist' else 'spectator' end;
  return jsonb_build_object(
    'role', v_role,
    'mine', case when v_role = 'duelist' then
              (select payload->>'text' from public.throne_trial_submissions where trial_id = t.id and user_id = auth.uid()) end,
    'submissions', case when v_role = 'judge' and t.status = 'awaiting_judge' then
              (select coalesce(jsonb_agg(jsonb_build_object('slot', slot, 'text', payload->>'text') order by slot), '[]'::jsonb)
               from public.throne_trial_submissions where trial_id = t.id and slot is not null) end
  );
end;
$$ language plpgsql stable security definer set search_path = public;

-- =================================================================
-- SECTION 4 — the Royal Judge's verdict
-- =================================================================
--   creative Trials (anonymous):  'A' | 'B' | 'both_terrible'
--   other human-judged Trials:    'challenger' | 'defender' | 'both_terrible'
create or replace function public.judge_throne_verdict(p_trial_id uuid, p_verdict text)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_entries jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'awaiting_judge' or t.resolution not in ('judge', 'creative') then
    raise exception 'This Trial is not waiting for the Royal Judge';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'A duelist cannot judge their own Trial';
  end if;
  if t.judge_user_id is not null and t.judge_user_id <> auth.uid() then
    raise exception 'You are not the Royal Judge of this Trial';
  end if;

  if p_verdict = 'both_terrible' then
    v_winner := null;
  elsif t.resolution = 'creative' and p_verdict in ('A', 'B') then
    select user_id into v_winner from public.throne_trial_submissions where trial_id = t.id and slot = p_verdict;
  elsif t.resolution = 'judge' and p_verdict = 'challenger' then
    v_winner := c.challenger_user_id;
  elsif t.resolution = 'judge' and p_verdict = 'defender' then
    v_winner := c.defender_user_id;
  else
    raise exception 'Unknown verdict';
  end if;
  if p_verdict <> 'both_terrible' and v_winner is null then
    raise exception 'Unknown verdict';
  end if;

  v_entries := case when t.resolution = 'creative' then public._throne_creative_reveal(t.id) else null end;

  if v_winner is not null then
    update public.throne_challenge_trials
      set judge_user_id = auth.uid(),
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', p_verdict)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    perform public._finish_throne_trial(t.id, v_winner);
    return;
  end if;

  -- BOTH WERE TERRIBLE: no point. Void it and play a replacement Trial.
  begin
    update public.throne_challenge_trials
      set status = 'voided', completed_at = now(), judge_user_id = auth.uid(),
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', 'both_terrible', 'voided', true)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    v_cat := public._pick_catalog_trial(c.id, t.school);
    perform public._start_throne_trial(c.id, v_cat, t.picker_user_id);
  exception when raise_exception then
    -- no replacement Trial left: the throne decides by coin flip, openly
    v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
    update public.throne_challenge_trials
      set status = 'awaiting_judge', completed_at = null,
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', 'both_terrible', 'coin_flip', true)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    perform public._finish_throne_trial(t.id, v_winner);
  end;
end;
$$ language plpgsql security definer set search_path = public;

-- the 0038 entry point now goes through the same checks (and Judge identity)
create or replace function public.judge_throne_trial(p_trial_id uuid, p_winner uuid)
returns void as $$
declare
  c public.throne_challenges;
begin
  select ch.* into c from public.throne_challenges ch
    join public.throne_challenge_trials t on t.challenge_id = ch.id where t.id = p_trial_id;
  if c.id is null then raise exception 'This Trial is not waiting for the Royal Judge'; end if;
  perform public.judge_throne_verdict(p_trial_id,
    case when p_winner = c.challenger_user_id then 'challenger' when p_winner = c.defender_user_id then 'defender' else 'invalid' end);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — deadline resolver (replaces 0041's)
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

  if public._finalize_expired_runs() then
    v_changed := true;
  end if;

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
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;

    elsif c.awaiting_pick_by is not null then
      v_cat := public._pick_catalog_trial(c.id, null);
      perform public._start_throne_trial(c.id, v_cat, c.awaiting_pick_by);

    else
      select * into t from public.throne_challenge_trials
        where challenge_id = c.id and status in ('active', 'awaiting_judge')
        order by trial_no desc, attempt desc limit 1;

      if t.id is null then
        update public.throne_challenges
          set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
          where id = c.id;
      else
        if t.resolution in ('quiz', 'timed', 'streak') then
          perform public._finalize_throne_run(t.id, c.challenger_user_id, 'deadline');
          perform public._finalize_throne_run(t.id, c.defender_user_id, 'deadline');
          select * into t from public.throne_challenge_trials where id = t.id;
          continue when t.status = 'completed';
        end if;

        if t.status = 'awaiting_judge' then
          -- the Royal Judge never decided: the throne flips a coin
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
                       || case when t.resolution = 'creative' then jsonb_build_object('entries', public._throne_creative_reveal(t.id)) else '{}'::jsonb end
          where id = t.id;
        perform public._finish_throne_trial(t.id, v_winner);
      end if;
    end if;
  end loop;

  return v_changed;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — the creative Trials
-- =================================================================
-- the placeholder CHAOS judge Trials are replaced by the real ones
update public.throne_trial_catalog set is_active = false where id in ('chaos_nickname_sprint', 'chaos_fake_holiday');

insert into public.throne_trial_catalog (id, school, title, description, resolution, public_config) values
  ('lore_poetry_duel', 'lore', 'Poetry Duel',
   'Both duelists get the same absurd prompt and write a short poem. The Royal Judge reads them anonymously and chooses.',
   'creative', '{"kind":"poem","max_chars":700,"anonymous":true,"input":"Write your poem…"}'),
  ('lore_nickname_duel', 'lore', 'Nickname Duel',
   'The app picks a person from the Office Lore. Both duelists invent a nickname. The Royal Judge picks the better one, blind.',
   'creative', '{"kind":"nickname","max_chars":40,"anonymous":true,"single_line":true,"input":"Their new nickname…"}'),
  ('chaos_caption_battle', 'chaos', 'Caption Battle',
   'The same absurd situation, one caption each. The Royal Judge chooses the funniest, blind.',
   'creative', '{"kind":"caption","max_chars":160,"anonymous":true,"input":"Your caption…"}'),
  ('chaos_make_me_laugh', 'chaos', 'Make Me Laugh',
   'The same subject, ONE sentence each. Make the Royal Judge laugh.',
   'creative', '{"kind":"laugh","max_chars":200,"anonymous":true,"input":"One sentence…"}'),
  ('chaos_royal_speech', 'chaos', 'Royal Speech',
   'A short royal speech: convince the Royal Judge you are the rightful ruler. Keep it to what fits in 30 seconds.',
   'creative', '{"kind":"speech","max_chars":600,"anonymous":true,"input":"Your royal speech…"}')
on conflict (id) do update set
  school = excluded.school, title = excluded.title, description = excluded.description,
  resolution = excluded.resolution, public_config = excluded.public_config, is_active = true;

-- =================================================================
-- SECTION 7 — grants
-- =================================================================
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('_pick_judge', '_throne_creative_reveal', '_prepare_creative_trial', '_pick_catalog_trial',
                        '_start_throne_trial', '_resolve_expired_throne_challenge')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

revoke all on function public.submit_throne_creative(uuid, text) from public, anon;
revoke all on function public.get_throne_creative(uuid) from public, anon;
revoke all on function public.judge_throne_verdict(uuid, text) from public, anon;
revoke all on function public.judge_throne_trial(uuid, uuid) from public, anon;
grant execute on function public.submit_throne_creative(uuid, text) to authenticated;
grant execute on function public.get_throne_creative(uuid) to authenticated;
grant execute on function public.judge_throne_verdict(uuid, text) to authenticated;
grant execute on function public.judge_throne_trial(uuid, uuid) to authenticated;
