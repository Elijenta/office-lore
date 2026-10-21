-- =================================================================
-- OFFICE LORE — 🎭 CHAOS DAILIES (human-input Personal Dailies + the Chaos Feed)
-- =================================================================
-- Playful Dailies the database cannot watch happen. They live in the same
-- engine (a definition, a personal_daily assignment, the same rewards and the
-- Daily Sweep) but complete through a SUBMISSION instead of a trigger.
--
--   👑 Royal Decree      one useless royal decree (text)               -> shown in the feed
--   🎨 Draw This         draw the app-picked nickname                  -> others GUESS which
--   📸 Office Safari     photo of a curated, object-only prompt        -> feed
--   🎲 The Impostor      3 statements, 2 true, 1 false                 -> others GUESS the lie
--   😀 Emoji Lore        a nickname in at most 5 emoji                 -> others GUESS which
--   🧠 Five Second       3 answers to a safe category in 5 seconds     -> server-timed
--   📸 The Photographer  a creative / composition photo prompt         -> feed
--   🧭 Tiny Quest        find and photograph something simple          -> feed
--   (not built, by request: Royal Portrait, Meme Lord, Corporate Bullshit,
--    The Salesman, Worst Advice, Voice Actor)
--
-- NO FARMING. There is no "Done" button. A Daily completes only when the
-- SERVER accepts a valid submission for THAT assignment:
--   * one submission per assignment (unique), one assignment per definition per
--     day, and the daily variety rule keeps Chaos to about one a day
--   * submissions are validated (length, 3 distinct statements, emoji only,
--     a real image), a user cannot resubmit the same text twice (content hash)
--   * Five Second is TIMED ON THE SERVER: start_five_seconds records the clock,
--     submit_five_seconds refuses a late answer; max 2 attempts; categories
--     marked "verify" (nicknames, our beers) check the answers against the data
--
-- GUESSING. The right answer of Draw This / Impostor / Emoji Lore sits in a
-- private table (chaos_secrets, no client policy). Others see the submission and
-- guess through guess_chaos(): one guess each, never your own, and the answer
-- is only revealed to you after you guessed.
--
-- IMAGES are a separate, swappable component: for now a client-resized JPEG/PNG
-- data URL in chaos_submissions.media (the same approach the app already uses
-- for beer photos), validated and size-capped here, with media_kind recording
-- how it is stored so Supabase Storage can replace it later without touching
-- the challenges.
--
-- Photo prompts come from a CURATED list and are about objects only: never
-- people, screens, papers or whiteboards.
--
-- REWARDS: configurable in challenge_config.chaos_rewards (XP + a raised Mystery
-- Reward chance; harder Chaos Dailies also a Gauntlet Fragment chance).
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0049.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
alter table public.challenge_definitions
  add column if not exists completion text not null default 'auto',   -- 'auto' (events) or 'chaos:<kind>' (a submission)
  add column if not exists reward_key text,                           -- challenge_config key holding this definition's reward table
  add column if not exists prompt_kind text;                          -- which curated prompt list to draw from
alter table public.challenge_assignments
  add column if not exists completion text not null default 'auto',
  add column if not exists payload jsonb not null default '{}';       -- what the app picked for THIS assignment (prompt, nickname ...)

create table if not exists public.chaos_prompts (
  id serial primary key,
  kind text not null,
  text text not null,
  verify text,                              -- 'nicknames' | 'beers': Five Second answers must exist in our data
  is_active boolean not null default true,
  unique (kind, text)
);
alter table public.chaos_prompts enable row level security;   -- server-side only: the pick is copied onto the assignment

create table if not exists public.chaos_submissions (
  id uuid primary key default gen_random_uuid(),
  app_id text not null default 'officelore',
  user_id uuid not null references public.profiles(id),
  assignment_id uuid not null unique references public.challenge_assignments(id) on delete cascade,   -- ONE submission per assignment
  definition_id text not null,
  kind text not null check (kind in ('decree', 'draw', 'safari', 'photographer', 'tiny', 'impostor', 'emoji', 'five')),
  prompt text,
  content jsonb not null default '{}',
  options jsonb,                            -- the choices others pick from (draw / emoji)
  media text,                               -- data URL for now
  media_kind text default 'data_url' check (media_kind in ('data_url')),
  content_hash text,
  created_at timestamptz not null default now()
);
create unique index if not exists chaos_submissions_no_repeat on public.chaos_submissions (user_id, content_hash) where content_hash is not null;
create index if not exists chaos_submissions_recent on public.chaos_submissions (app_id, created_at desc);

create table if not exists public.chaos_secrets (
  submission_id uuid primary key references public.chaos_submissions(id) on delete cascade,
  answer jsonb not null
);
alter table public.chaos_secrets enable row level security;     -- deliberately NO policy

create table if not exists public.chaos_guesses (
  submission_id uuid not null references public.chaos_submissions(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  guess jsonb not null,
  correct boolean not null,
  created_at timestamptz not null default now(),
  primary key (submission_id, user_id)
);

create table if not exists public.chaos_reactions (
  submission_id uuid not null references public.chaos_submissions(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  emoji text not null check (emoji in ('😂', '🔥', '👑', '🤯', '❤️')),
  created_at timestamptz not null default now(),
  primary key (submission_id, user_id, emoji)
);

create table if not exists public.chaos_attempts (
  assignment_id uuid not null references public.challenge_assignments(id) on delete cascade,
  attempt_no int not null,
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  ok boolean,
  primary key (assignment_id, attempt_no)
);
alter table public.chaos_attempts enable row level security;    -- deliberately NO policy

alter table public.chaos_submissions enable row level security;
alter table public.chaos_guesses enable row level security;
alter table public.chaos_reactions enable row level security;
drop policy if exists "Chaos submissions: read" on public.chaos_submissions;
create policy "Chaos submissions: read" on public.chaos_submissions for select to authenticated using (public.is_app_member(app_id));
drop policy if exists "Chaos guesses: read own" on public.chaos_guesses;
create policy "Chaos guesses: read own" on public.chaos_guesses for select to authenticated using (user_id = auth.uid());
drop policy if exists "Chaos reactions: read" on public.chaos_reactions;
create policy "Chaos reactions: read" on public.chaos_reactions for select to authenticated using (public.is_app_member('officelore'));

do $$
declare t text;
begin
  foreach t in array array['chaos_submissions', 'chaos_reactions', 'chaos_guesses'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- =================================================================
-- SECTION 2 — rewards and the curated prompts
-- =================================================================
insert into public.challenge_config (key, value) values
  ('chaos_rewards', '{
      "easy":   [ {"kind":"player_xp","amount":12}, {"kind":"mystery","amount":1,"chance":0.20} ],
      "normal": [ {"kind":"player_xp","amount":20}, {"kind":"mystery","amount":1,"chance":0.30} ],
      "hard":   [ {"kind":"player_xp","amount":30}, {"kind":"mystery","amount":1,"chance":0.35}, {"kind":"gauntlet_fragments","amount":1,"chance":0.6} ]
   }'::jsonb),
  ('chaos_rules', '{"five_seconds":5, "five_seconds_grace":3, "five_attempts":2, "media_max_chars":900000}'::jsonb)
on conflict (key) do nothing;

insert into public.chaos_prompts (kind, text, verify) values
  ('decree_topic', 'Decree about: coffee', null), ('decree_topic', 'Decree about: meetings', null), ('decree_topic', 'Decree about: the printer', null),
  ('decree_topic', 'Decree about: Fridays', null), ('decree_topic', 'Decree about: the last biscuit', null), ('decree_topic', 'Decree about: reply-all', null),
  ('decree_topic', 'Decree about: chairs', null), ('decree_topic', 'Decree about: the fridge', null),
  ('safari', 'Photograph the most mysterious object in the office.', null),
  ('safari', 'Photograph something absurdly everyday as if it were a work of art.', null),
  ('safari', 'Photograph something blue.', null), ('safari', 'Photograph something yellow.', null), ('safari', 'Photograph something green.', null),
  ('safari', 'Make a dramatic photo of a perfectly normal object.', null),
  ('safari', 'Photograph the most suspicious-looking cable, plant or chair.', null),
  ('photographer', 'Shoot an everyday object from a hero angle: low, looking up.', null),
  ('photographer', 'Take a photo with a strong, interesting shadow.', null),
  ('photographer', 'Take a perfectly symmetrical photo.', null),
  ('photographer', 'Make a photo that looks like a movie poster, using only objects.', null),
  ('photographer', 'Compose a still life of three items that should never be together.', null),
  ('photographer', 'Find a leading line and make it the whole photo.', null),
  ('tiny_quest', 'Find something red.', null), ('tiny_quest', 'Find something round.', null), ('tiny_quest', 'Find something tiny.', null),
  ('tiny_quest', 'Find something unnecessarily complicated.', null), ('tiny_quest', 'Find something that looks older than it should.', null),
  ('five_seconds', 'Name 3 Belgian beers', null),
  ('five_seconds', 'Name 3 beers from our Beer Fridge', 'beers'),
  ('five_seconds', 'Name 3 nicknames from the Nickname Wall', 'nicknames'),
  ('five_seconds', 'Name 3 things found in an office', null),
  ('five_seconds', 'Name 3 things that are round', null),
  ('five_seconds', 'Name 3 types of cheese', null),
  ('five_seconds', 'Name 3 things you take to a terrace', null)
on conflict (kind, text) do nothing;

-- =================================================================
-- SECTION 3 — engine hooks (replace 0048/0049's)
-- =================================================================
create or replace function public._assignment_reward(d public.challenge_definitions)
returns jsonb as $$
  select case
    when d.reward_key is not null then jsonb_build_object('lines', coalesce(public._challenge_config(d.reward_key, '{}'::jsonb) -> d.difficulty, '[]'::jsonb))
    when d.reward_from_difficulty then public._difficulty_reward(d.difficulty)
    else d.reward end;
$$ language sql stable security definer set search_path = public;

-- the app's own pick for this assignment: a curated prompt, or a nickname
create or replace function public._chaos_payload(d public.challenge_definitions, p_user uuid, p_key text)
returns jsonb as $$
declare
  v_kind text := split_part(d.completion, ':', 2);
  v_row jsonb;
begin
  if d.completion = 'auto' then return '{}'::jsonb; end if;
  if v_kind in ('draw', 'emoji') then
    select jsonb_build_object('nickname_id', n.id, 'text', n.nickname) into v_row
      from public.nicknames n where n.status = 'Actief' order by md5(n.id::text || p_user::text || p_key) limit 1;
  elsif d.prompt_kind is not null then
    select jsonb_build_object('text', p.text, 'verify', p.verify) into v_row
      from public.chaos_prompts p where p.kind = d.prompt_kind and p.is_active
        and (p.verify is null
             or (p.verify = 'nicknames' and (select count(*) from public.nicknames where status = 'Actief') >= 3)
             or (p.verify = 'beers' and (select count(*) from public.beers) >= 3))
      order by md5(p.id::text || p_user::text || p_key) limit 1;
  end if;
  return coalesce(v_row, '{}'::jsonb);
end;
$$ language plpgsql stable security definer set search_path = public;

-- when a Personal Daily completes (by any route): feed the weekly chain, and the Daily Sweep
create or replace function public._after_personal_daily_completed(p_user uuid, p_assignment uuid, p_period text)
returns void as $$
declare
  v_complete int;
begin
  perform public._challenge_event(p_user, 'daily_completed', 1, p_assignment::text, '{}'::jsonb, 'daily_completed:' || p_assignment::text);
  select count(*) into v_complete from public.challenge_assignments x
    where x.app_id = 'officelore' and x.user_id = p_user and x.type = 'personal_daily'
      and x.period_key = p_period and x.status in ('completed', 'claimed');
  if v_complete >= public._challenge_slots('personal_daily') then
    insert into public.challenge_sweeps (user_id, period_key, reward)
      values (p_user, p_period, public._challenge_config('daily_sweep', '{"lines":[]}'::jsonb))
      on conflict (user_id, period_key) do nothing;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._challenge_event(
  p_user uuid, p_event text, p_amount int default 1, p_dedupe text default null,
  p_meta jsonb default '{}'::jsonb, p_source text default null)
returns void as $$
declare
  a record;
  v_add int;
  v_done boolean;
begin
  if p_user is null or p_amount is null or p_amount <= 0 then return; end if;
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return;
  end if;

  insert into public.challenge_events (app_id, user_id, event_type, amount, dedupe_key, source_key, meta)
    values ('officelore', p_user, p_event, p_amount, p_dedupe, p_source, coalesce(p_meta, '{}'::jsonb))
    on conflict (source_key) where source_key is not null do nothing;
  if not found then return; end if;

  for a in
    select asg.id, asg.user_id, asg.type, asg.target, asg.progress, asg.requirements, asg.period_key
    from public.challenge_assignments asg
    where asg.app_id = 'officelore' and asg.status = 'active' and asg.completion = 'auto'      -- a Chaos Daily only completes by submission
      and p_event = any (coalesce(asg.event_types, array[asg.event_type]))
      and asg.starts_at <= now() and asg.expires_at > now()
      and (asg.user_id = p_user or asg.user_id is null)
    order by asg.id
    for update
  loop
    continue when not public._challenge_requirements_met(a.requirements, p_meta);
    if p_dedupe is not null then
      insert into public.challenge_progress_marks (assignment_id, user_id, dedupe_key) values (a.id, p_user, p_dedupe)
        on conflict do nothing;
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
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- generation: now also stores completion kind + the app's pick (0049's, extended)
create or replace function public._ensure_challenge_assignments_for(p_user uuid, p_at timestamptz)
returns int as $$
declare
  v_tz text := public._challenge_tz();
  v_local timestamp := p_at at time zone v_tz;
  v_day_start timestamptz := date_trunc('day', v_local) at time zone v_tz;
  v_day_end timestamptz := (date_trunc('day', v_local) + interval '1 day') at time zone v_tz;
  v_wk_start timestamptz := date_trunc('week', v_local) at time zone v_tz;
  v_wk_end timestamptz := (date_trunc('week', v_local) + interval '7 days') at time zone v_tz;
  v_day_key text := to_char(v_local, 'YYYY-MM-DD');
  v_prev_key text := to_char(v_local - interval '1 day', 'YYYY-MM-DD');
  v_wk_key text := to_char(v_local, 'IYYY-"W"IW');
  v_lord uuid := (select user_id from public.abt_reigns where ended_at is null limit 1);
  v_type text;
  v_key text; v_from timestamptz; v_to timestamptz;
  v_owner uuid;
  v_have int; v_want int; v_created int := 0; v_n int;
  v_ids text[];
begin
  if not exists (select 1 from public.app_memberships m where m.user_id = p_user and m.app_id = 'officelore' and m.is_active) then
    return 0;
  end if;
  perform pg_advisory_xact_lock(hashtext('challenge_gen:' || p_user::text));

  update public.challenge_assignments set status = 'expired'
    where app_id = 'officelore' and status = 'active' and expires_at <= p_at and (user_id = p_user or user_id is null);

  foreach v_type in array array['personal_daily', 'group_daily', 'personal_weekly', 'group_weekly', 'rebellion'] loop
    if v_type in ('personal_daily', 'group_daily') then v_key := v_day_key; v_from := v_day_start; v_to := v_day_end;
    else v_key := v_wk_key; v_from := v_wk_start; v_to := v_wk_end; end if;
    v_owner := case when v_type in ('group_daily', 'group_weekly') then null else p_user end;
    v_want := public._challenge_slots(v_type);
    if v_owner is null then perform pg_advisory_xact_lock(hashtext('challenge_group:' || v_type || ':' || v_key)); end if;

    select count(*) into v_have from public.challenge_assignments
      where app_id = 'officelore' and type = v_type and period_key = v_key and user_id is not distinct from v_owner;
    continue when v_have >= v_want;

    if v_type = 'personal_daily' then
      v_ids := public._pick_personal_dailies(p_user, v_key, v_prev_key, v_lord, v_want - v_have);
    else
      select coalesce(array_agg(x.id), '{}') into v_ids from (
        select d.id from public.challenge_definitions d
        where d.app_id = 'officelore' and d.is_active and d.type = v_type
          and (d.audience = 'everyone'
               or (d.audience = 'non_lord' and p_user is distinct from v_lord)
               or (d.audience = 'lord' and p_user is not distinct from v_lord))
          and public._challenge_available(d, p_user)
          and not exists (select 1 from public.challenge_assignments x2
                          where x2.app_id = 'officelore' and x2.definition_id = d.id and x2.period_key = v_key and x2.user_id is not distinct from v_owner)
        order by md5(d.id || coalesce(v_owner::text, 'group') || v_key)
        limit v_want - v_have) x;
    end if;
    continue when cardinality(v_ids) = 0;

    insert into public.challenge_assignments
      (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, event_types, icon, requirements, reward,
       target, period_key, starts_at, expires_at, completion, payload)
    select 'officelore', d.id, v_owner, d.type, d.category, d.title, d.description, d.difficulty, d.event_type, d.event_types, d.icon, d.requirements,
           public._assignment_reward(d),
           d.target, v_key, v_from, v_to, d.completion, public._chaos_payload(d, p_user, v_key)
    from public.challenge_definitions d
    where d.id = any (v_ids)
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_created := v_created + v_n;
  end loop;
  return v_created;
end;
$$ language plpgsql security definer set search_path = public;

-- finishing a Chaos Daily after its submission was accepted
create or replace function public._complete_chaos_assignment(p_assignment uuid)
returns void as $$
declare
  a public.challenge_assignments;
begin
  select * into a from public.challenge_assignments where id = p_assignment for update;
  update public.challenge_assignments set progress = target, status = 'completed', completed_at = now() where id = a.id;
  perform public._challenge_event(a.user_id, 'chaos_completed', 1, null, jsonb_build_object('kind', split_part(a.completion, ':', 2)), 'chaos_completed:' || a.id::text);
  perform public._after_personal_daily_completed(a.user_id, a.id, a.period_key);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — submitting
-- =================================================================
create or replace function public._chaos_options(p_correct text)
returns jsonb as $$
  select coalesce(jsonb_agg(q.t order by random()), '[]'::jsonb) from (
    select p_correct as t
    union all
    (select x.nickname from (
       select distinct on (lower(btrim(nickname))) nickname from public.nicknames
       where status = 'Actief' and lower(btrim(nickname)) <> lower(btrim(p_correct))
       order by lower(btrim(nickname)), random()) x
     order by random() limit 3)
  ) q;
$$ language sql volatile security definer set search_path = public;

create or replace function public.submit_chaos(p_assignment_id uuid, p_content jsonb, p_media text default null)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_kind text;
  v_text text;
  v_content jsonb := '{}'::jsonb;
  v_options jsonb;
  v_answer jsonb;
  v_media text := null;
  v_hash text;
  v_id uuid;
  v_max int := coalesce((public._challenge_config('chaos_rules', '{}'::jsonb)->>'media_max_chars')::int, 900000);
  v_stmts jsonb; v_fake int; v_i int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.user_id is distinct from auth.uid() then raise exception 'This is not your challenge'; end if;
  if a.completion not like 'chaos:%' then raise exception 'This challenge completes by itself'; end if;
  if a.status <> 'active' or a.expires_at <= now() then raise exception 'This challenge is no longer open'; end if;
  if exists (select 1 from public.chaos_submissions where assignment_id = a.id) then raise exception 'Already submitted'; end if;
  v_kind := split_part(a.completion, ':', 2);

  if v_kind = 'decree' then
    v_text := btrim(coalesce(p_content->>'text', ''));
    if length(v_text) < 15 or length(v_text) > 280 then raise exception 'A decree needs 15 to 280 characters'; end if;
    if array_length(regexp_split_to_array(v_text, '\s+'), 1) < 5 then raise exception 'A decree needs at least 5 words'; end if;
    v_content := jsonb_build_object('text', v_text);
    v_hash := md5(lower(v_text));

  elsif v_kind in ('safari', 'photographer', 'tiny') then
    v_media := p_media;
    v_content := jsonb_build_object('note', left(btrim(coalesce(p_content->>'note', '')), 120));
    v_hash := md5(substr(coalesce(p_media, ''), 1, 4000) || length(coalesce(p_media, '')));

  elsif v_kind = 'draw' then
    v_media := p_media;
    v_answer := jsonb_build_object('text', a.payload->>'text');
    v_options := public._chaos_options(a.payload->>'text');
    v_hash := md5(substr(coalesce(p_media, ''), 1, 4000) || length(coalesce(p_media, '')));

  elsif v_kind = 'emoji' then
    v_text := btrim(coalesce(p_content->>'emoji', ''));
    if v_text ~ '[A-Za-z0-9]' or length(translate(v_text, chr(65039) || chr(8205) || ' ', '')) not between 1 and 5 then raise exception 'Use emoji only, at most 5'; end if;
    v_content := jsonb_build_object('emoji', v_text);
    v_answer := jsonb_build_object('text', a.payload->>'text');
    v_options := public._chaos_options(a.payload->>'text');
    v_hash := md5(v_text || ':' || (a.payload->>'nickname_id'));

  elsif v_kind = 'impostor' then
    v_stmts := p_content->'statements';
    v_fake := (p_content->>'fake')::int;
    if coalesce(jsonb_typeof(v_stmts), '') <> 'array' or jsonb_array_length(v_stmts) <> 3 or coalesce(v_fake, -1) not between 0 and 2 then raise exception 'Write 3 statements and mark the false one'; end if;
    for v_i in 0..2 loop
      if length(btrim(coalesce(v_stmts->>v_i, ''))) < 8 or length(btrim(v_stmts->>v_i)) > 140 then raise exception 'Each statement needs 8 to 140 characters'; end if;
    end loop;
    if (select count(distinct lower(btrim(s))) from jsonb_array_elements_text(v_stmts) s) <> 3 then raise exception 'The 3 statements must be different'; end if;
    v_content := jsonb_build_object('statements', (select jsonb_agg(btrim(s)) from jsonb_array_elements_text(v_stmts) s));
    v_answer := jsonb_build_object('fake', v_fake);
    v_hash := md5(lower(v_content::text));

  else
    raise exception 'This challenge is submitted differently';
  end if;

  if v_kind in ('safari', 'photographer', 'tiny', 'draw') then
    if v_media is null or v_media !~ '^data:image/(jpeg|png);base64,[A-Za-z0-9+/=]+$' then raise exception 'Add a photo or drawing first'; end if;
    if length(v_media) > v_max then raise exception 'That image is too large'; end if;
  end if;

  begin
    insert into public.chaos_submissions (user_id, assignment_id, definition_id, kind, prompt, content, options, media, content_hash)
      values (auth.uid(), a.id, a.definition_id, v_kind, case when v_kind in ('draw', 'emoji') then null else a.payload->>'text' end, v_content, v_options, v_media, v_hash)
      returning id into v_id;
  exception when unique_violation then
    raise exception 'You already sent exactly this before. Make something new';
  end;
  if v_answer is not null then insert into public.chaos_secrets (submission_id, answer) values (v_id, v_answer); end if;

  perform public._complete_chaos_assignment(a.id);
  return jsonb_build_object('status', 'submitted', 'id', v_id);
end;
$$ language plpgsql security definer set search_path = public;

-- 🧠 Five Second: the clock is the server's
create or replace function public.start_five_seconds(p_assignment_id uuid)
returns jsonb as $$
declare
  a public.challenge_assignments;
  v_rules jsonb := public._challenge_config('chaos_rules', '{}'::jsonb);
  v_no int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.user_id is distinct from auth.uid() or a.completion <> 'chaos:five' then raise exception 'This is not your Five Second challenge'; end if;
  if a.status <> 'active' or a.expires_at <= now() then raise exception 'This challenge is no longer open'; end if;
  -- an attempt that was started but never answered counts as used
  update public.chaos_attempts set finished_at = clock_timestamp(), ok = false where assignment_id = a.id and finished_at is null;
  select count(*) into v_no from public.chaos_attempts where assignment_id = a.id;
  if v_no >= coalesce((v_rules->>'five_attempts')::int, 2) then raise exception 'No attempts left'; end if;
  insert into public.chaos_attempts (assignment_id, attempt_no) values (a.id, v_no + 1);
  return jsonb_build_object('attempt', v_no + 1, 'attempts_left', coalesce((v_rules->>'five_attempts')::int, 2) - v_no - 1,
    'category', a.payload->>'text', 'seconds', coalesce((v_rules->>'five_seconds')::int, 5));
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.submit_five_seconds(p_assignment_id uuid, p_answers jsonb)
returns jsonb as $$
declare
  a public.challenge_assignments;
  t public.chaos_attempts;
  v_rules jsonb := public._challenge_config('chaos_rules', '{}'::jsonb);
  v_secs numeric := coalesce((v_rules->>'five_seconds')::numeric, 5) + coalesce((v_rules->>'five_seconds_grace')::numeric, 3);
  v_ans text[];
  v_left int;
  v_ok boolean := true;
  v_why text := null;
  x text;
  v_id uuid;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into a from public.challenge_assignments where id = p_assignment_id for update;
  if a.id is null or a.user_id is distinct from auth.uid() or a.completion <> 'chaos:five' then raise exception 'This is not your Five Second challenge'; end if;
  if a.status <> 'active' then raise exception 'This challenge is no longer open'; end if;
  select * into t from public.chaos_attempts where assignment_id = a.id and finished_at is null order by attempt_no desc limit 1;
  if t.assignment_id is null then raise exception 'Press start first'; end if;

  select array_agg(distinct lower(btrim(e))) into v_ans from jsonb_array_elements_text(coalesce(p_answers, '[]'::jsonb)) e where length(btrim(e)) >= 2;
  if extract(epoch from (clock_timestamp() - t.started_at)) > v_secs then v_ok := false; v_why := 'Too slow';
  elsif coalesce(cardinality(v_ans), 0) < 3 then v_ok := false; v_why := 'Three different answers, please';
  else
    foreach x in array v_ans loop
      if length(x) > 40 then v_ok := false; v_why := 'Answers must be short'; end if;
      if a.payload->>'verify' = 'nicknames' and not exists (select 1 from public.nicknames n where lower(n.nickname) like '%' || x || '%') then v_ok := false; v_why := '"' || x || '" is not on the Wall'; end if;
      if a.payload->>'verify' = 'beers' and not exists (select 1 from public.beers b where lower(b.name) like '%' || x || '%') then v_ok := false; v_why := '"' || x || '" is not in our Beer Fridge'; end if;
    end loop;
  end if;

  update public.chaos_attempts set finished_at = clock_timestamp(), ok = v_ok where assignment_id = a.id and attempt_no = t.attempt_no;
  select coalesce((v_rules->>'five_attempts')::int, 2) - count(*) into v_left from public.chaos_attempts where assignment_id = a.id;
  if not v_ok then
    return jsonb_build_object('status', 'failed', 'reason', v_why, 'attempts_left', greatest(v_left, 0));
  end if;

  insert into public.chaos_submissions (user_id, assignment_id, definition_id, kind, prompt, content)
    values (auth.uid(), a.id, a.definition_id, 'five', a.payload->>'text', jsonb_build_object('answers', to_jsonb(v_ans)))
    returning id into v_id;
  perform public._complete_chaos_assignment(a.id);
  return jsonb_build_object('status', 'submitted', 'id', v_id);
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — the Chaos Feed: guess, react, read
-- =================================================================
create or replace function public.guess_chaos(p_submission_id uuid, p_guess jsonb)
returns jsonb as $$
declare
  s public.chaos_submissions;
  v_answer jsonb;
  v_correct boolean;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into s from public.chaos_submissions where id = p_submission_id;
  if s.id is null or s.app_id <> 'officelore' then raise exception 'Unknown submission'; end if;
  if s.user_id = auth.uid() then raise exception 'You cannot guess your own submission'; end if;
  select answer into v_answer from public.chaos_secrets where submission_id = s.id;
  if v_answer is null then raise exception 'There is nothing to guess here'; end if;
  if exists (select 1 from public.chaos_guesses where submission_id = s.id and user_id = auth.uid()) then raise exception 'You already guessed'; end if;

  v_correct := case s.kind
    when 'impostor' then (p_guess->>'index')::int = (v_answer->>'fake')::int
    else lower(btrim(p_guess->>'option')) = lower(btrim(v_answer->>'text')) end;
  insert into public.chaos_guesses (submission_id, user_id, guess, correct) values (s.id, auth.uid(), p_guess, v_correct);
  perform public._challenge_event(auth.uid(), 'chaos_guess', 1, 'sub:' || s.id, jsonb_build_object('correct', case when v_correct then 1 else 0 end), 'chaos_guess:' || s.id || ':' || auth.uid());
  return jsonb_build_object('correct', v_correct, 'answer', v_answer);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.react_chaos(p_submission_id uuid, p_emoji text)
returns jsonb as $$
declare
  s public.chaos_submissions;
  v_on boolean;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into s from public.chaos_submissions where id = p_submission_id;
  if s.id is null or s.app_id <> 'officelore' then raise exception 'Unknown submission'; end if;
  if s.user_id = auth.uid() then raise exception 'React to somebody else''s chaos'; end if;
  delete from public.chaos_reactions where submission_id = s.id and user_id = auth.uid() and emoji = p_emoji;
  if found then v_on := false;
  else
    insert into public.chaos_reactions (submission_id, user_id, emoji) values (s.id, auth.uid(), p_emoji);
    v_on := true;
    perform public._challenge_event(auth.uid(), 'chaos_reaction', 1, 'sub:' || s.id, '{}'::jsonb, 'chaos_reaction:' || s.id || ':' || auth.uid());
  end if;
  return jsonb_build_object('on', v_on);
end;
$$ language plpgsql security definer set search_path = public;

-- the feed, without the heavy images and without the answers
create or replace function public.get_chaos_feed(p_limit int default 40)
returns jsonb as $$
  select coalesce(jsonb_agg(f order by f->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', s.id, 'user_id', s.user_id, 'kind', s.kind, 'prompt', s.prompt, 'content', s.content,
      'options', s.options, 'has_media', s.media is not null, 'created_at', s.created_at,
      'guessable', exists (select 1 from public.chaos_secrets k where k.submission_id = s.id),
      'my_guess', (select jsonb_build_object('guess', g.guess, 'correct', g.correct) from public.chaos_guesses g where g.submission_id = s.id and g.user_id = auth.uid()),
      -- the answer is only shown to the author and to anyone who has guessed
      'answer', (select k.answer from public.chaos_secrets k where k.submission_id = s.id
                 and (s.user_id = auth.uid() or exists (select 1 from public.chaos_guesses g where g.submission_id = s.id and g.user_id = auth.uid()))),
      'guess_count', (select count(*) from public.chaos_guesses g where g.submission_id = s.id),
      'correct_count', (select count(*) from public.chaos_guesses g where g.submission_id = s.id and g.correct),
      'reactions', coalesce((select jsonb_object_agg(e, n) from (select emoji as e, count(*) as n from public.chaos_reactions r where r.submission_id = s.id group by emoji) q), '{}'::jsonb),
      'my_reactions', coalesce((select jsonb_agg(r.emoji) from public.chaos_reactions r where r.submission_id = s.id and r.user_id = auth.uid()), '[]'::jsonb)
    ) as f
    from public.chaos_submissions s
    where public.is_app_member('officelore') and s.app_id = 'officelore' and s.created_at > now() - interval '14 days'
    order by s.created_at desc limit greatest(least(p_limit, 100), 1)
  ) x;
$$ language sql stable security definer set search_path = public;

create or replace function public.get_chaos_media(p_submission_id uuid)
returns text as $$
  select s.media from public.chaos_submissions s where s.id = p_submission_id and s.app_id = 'officelore' and public.is_app_member('officelore');
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 6 — the Chaos pool
-- =================================================================
insert into public.challenge_definitions
  (id, type, category, title, description, difficulty, event_type, target, requirements, reward_from_difficulty, reward_key, completion, prompt_kind, icon, requires, audience) values
  ('pd_royal_decree', 'personal_daily', 'chaos', 'Royal Decree', 'Write one completely useless royal decree. The court will read it in the Chaos Feed.', 'normal', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:decree', 'decree_topic', '👑', null, 'everyone'),
  ('pd_draw_this', 'personal_daily', 'chaos', 'Draw This', 'Draw the nickname the app picks for you, without writing it. The others will guess which one it is.', 'hard', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:draw', null, '🎨', 'nicknames_3', 'everyone'),
  ('pd_office_safari', 'personal_daily', 'chaos', 'Office Safari', 'A safe photo mission: objects only. No people, screens or papers.', 'normal', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:safari', 'safari', '📸', null, 'everyone'),
  ('pd_the_impostor', 'personal_daily', 'chaos', 'The Impostor', 'Write three statements about yourself or the office: two true, one false. The others hunt the lie.', 'hard', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:impostor', null, '🎲', null, 'everyone'),
  ('pd_emoji_lore', 'personal_daily', 'chaos', 'Emoji Lore', 'Describe the nickname the app picks for you with at most 5 emoji. The others guess which one it is.', 'normal', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:emoji', null, '😀', 'nicknames_3', 'everyone'),
  ('pd_five_seconds', 'personal_daily', 'chaos', 'Five Second Challenge', 'Name 3 answers to a safe category before the clock runs out. The server keeps time.', 'normal', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:five', 'five_seconds', '🧠', null, 'everyone'),
  ('pd_the_photographer', 'personal_daily', 'chaos', 'The Photographer', 'Make a creative photo from a simple, safe prompt. Composition counts. Objects only.', 'hard', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:photographer', 'photographer', '📷', null, 'everyone'),
  ('pd_tiny_quest', 'personal_daily', 'chaos', 'Tiny Quest', 'Find and photograph something that matches one simple property. Objects only.', 'easy', 'chaos_submitted', 1, '{}', false, 'chaos_rewards', 'chaos:tiny', 'tiny_quest', '🧭', null, 'everyone')
on conflict (id) do update set
  title = excluded.title, description = excluded.description, difficulty = excluded.difficulty, event_type = excluded.event_type,
  reward_key = excluded.reward_key, completion = excluded.completion, prompt_kind = excluded.prompt_kind, icon = excluded.icon,
  requires = excluded.requires, is_active = true;

-- =================================================================
-- SECTION 7 — grants
-- =================================================================
revoke all on function public._assignment_reward(public.challenge_definitions) from public, anon, authenticated;
revoke all on function public._chaos_payload(public.challenge_definitions, uuid, text) from public, anon, authenticated;
revoke all on function public._after_personal_daily_completed(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public._challenge_event(uuid, text, int, text, jsonb, text) from public, anon, authenticated;
revoke all on function public._ensure_challenge_assignments_for(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public._complete_chaos_assignment(uuid) from public, anon, authenticated;
revoke all on function public._chaos_options(text) from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array['submit_chaos(uuid, jsonb, text)', 'start_five_seconds(uuid)', 'submit_five_seconds(uuid, jsonb)',
                           'guess_chaos(uuid, jsonb)', 'react_chaos(uuid, text)', 'get_chaos_feed(int)', 'get_chaos_media(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
