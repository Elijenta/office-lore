-- =================================================================
-- OFFICE LORE — DAILY POETRY CHALLENGE (subject = nickname or user)
-- =================================================================
-- New table: daily_poetry_challenges, one row per calendar date,
-- written exactly once by get_or_create_daily_challenge() (the only
-- thing that ever writes here -- same read-only-for-clients pattern
-- as abt_reigns/poet_laureate_reigns). Extends poems with a link +
-- flag; no new XP trigger needed since a daily-challenge poem is
-- submitted with is_challenge_poem = true, so the EXISTING publish
-- trigger (0009/0012) already grants the normal +5/+3.
-- =================================================================

-- ---- 1. daily_poetry_challenges ----
create table public.daily_poetry_challenges (
  id uuid primary key default gen_random_uuid(),
  challenge_date date not null unique,
  subject_type text not null check (subject_type in ('nickname', 'user')),
  nickname_id uuid references public.nicknames(id) on delete set null,
  user_id uuid references public.profiles(id) on delete set null,
  subject_text text not null,
  category text not null check (category in (
    'romantic', 'tragic', 'office_nonsense', 'beer_inspired', 'absolute_nonsense',
    'dramatic', 'abt_dynasty', 'deep_thoughts', 'wholesome'
  )),
  prompt_text text not null,
  created_at timestamptz not null default now()
);

alter table public.daily_poetry_challenges enable row level security;
create policy "Daily poetry challenges: read" on public.daily_poetry_challenges for select to authenticated using (true);
-- no insert/update/delete policy: only get_or_create_daily_challenge() (security definer) writes here

-- ---- 2. get-or-create, race-safe via a per-date advisory lock ----
create or replace function public.get_or_create_daily_challenge()
returns public.daily_poetry_challenges as $$
declare
  v_today date := current_date;
  v_row public.daily_poetry_challenges;
  v_subject_type text;
  v_nickname_id uuid;
  v_user_id uuid;
  v_subject_text text;
  v_category text;
  v_template text;
  v_prompt_text text;
  v_nickname_count int;
  v_user_count int;
  v_subject_seed bigint := abs(hashtext('daily-challenge-subject:' || v_today::text));
  v_category_seed bigint := abs(hashtext('daily-challenge-category:' || v_today::text));
  v_template_seed bigint := abs(hashtext('daily-challenge-template:' || v_today::text));
begin
  perform pg_advisory_xact_lock(hashtext('daily_poetry_challenge:' || v_today::text));

  select * into v_row from public.daily_poetry_challenges where challenge_date = v_today;
  if found then
    return v_row;
  end if;

  select count(*) into v_nickname_count from public.nicknames;
  -- "user" subjects komen uitsluitend uit de 3 OUDSTE profiles (Elien/
  -- Nick/Atti, de originele 3 vaste accounts) -- niet zomaar "alle
  -- profiles", want self-service signup betekent dat er in de praktijk
  -- ook losse test-/QA-accounts kunnen bestaan, en die horen nooit als
  -- subject van een Daily Challenge te verschijnen.
  select count(*) into v_user_count from (select id from public.profiles order by created_at asc limit 3) t;

  -- flat 50/50 tussen nickname en user als subject (niet naar pool-
  -- grootte gewogen, anders komt "user" met maar 3 kandidaten tegen
  -- ~22 nicknames zelden aan bod)
  if v_nickname_count > 0 and (v_user_count = 0 or v_subject_seed % 2 = 0) then
    v_subject_type := 'nickname';
    select id, nickname into v_nickname_id, v_subject_text
      from public.nicknames order by id offset (v_subject_seed % v_nickname_count) limit 1;
  else
    v_subject_type := 'user';
    select id, display_name into v_user_id, v_subject_text
      from (select id, display_name from public.profiles order by created_at asc limit 3) t
      order by id offset (v_subject_seed % greatest(v_user_count, 1)) limit 1;
  end if;

  v_category := (array[
    'romantic', 'tragic', 'office_nonsense', 'beer_inspired', 'absolute_nonsense',
    'dramatic', 'abt_dynasty', 'deep_thoughts', 'wholesome'
  ])[1 + (v_category_seed % 9)];

  v_template := case v_category
    when 'romantic' then (array[
      'Write a romantic poem about %s as if they were the love of your life.',
      'Write a love poem describing an unexpected office encounter with %s.',
      'Write a sonnet about someone hopelessly falling for %s.'
    ])[1 + (v_template_seed % 3)]
    when 'tragic' then (array[
      'Write a tragic poem about the day %s lost everything.',
      'Write a tragic poem mourning %s''s greatest defeat.',
      'Write a eulogy-style poem for %s''s fallen dignity.'
    ])[1 + (v_template_seed % 3)]
    when 'office_nonsense' then (array[
      'Write an absurd office poem starring %s in an epic printer battle.',
      'Write about %s discovering a mysterious smell in the office kitchen.',
      'Write a poem about %s becoming an office legend for all the wrong reasons.'
    ])[1 + (v_template_seed % 3)]
    when 'beer_inspired' then (array[
      'Write an ode to %s discovering the perfect beer.',
      'Write a tragic poem about %s finding the beer fridge empty.',
      'Write a medieval poem about %s and the Abt Lord''s throne.'
    ])[1 + (v_template_seed % 3)]
    when 'absolute_nonsense' then (array[
      'Write a poem about %s being elected Supreme Leader by the office printer.',
      'Write about %s slowly turning into a sentient stapler.',
      'Write an absurd poem about %s versus a rogue PowerPoint presentation.'
    ])[1 + (v_template_seed % 3)]
    when 'dramatic' then (array[
      'Describe %s losing Wi-Fi as if civilization itself has collapsed.',
      'Turn %s''s minor office inconvenience into a Shakespearean tragedy.',
      'Write an epic battle poem starring %s against a broken coffee machine.'
    ])[1 + (v_template_seed % 3)]
    when 'abt_dynasty' then (array[
      'Write a medieval prophecy about %s attempting to seize the Abt throne.',
      'Turn %s into a legendary knight serving the Abt Lord.',
      'Write a coronation poem imagining %s as the next Abt Lord.'
    ])[1 + (v_template_seed % 3)]
    when 'deep_thoughts' then (array[
      'Write a philosophical poem about %s contemplating the meaning of a Monday.',
      'Write a deep, reflective poem about %s staring at a spreadsheet.',
      'Write an existential poem from %s''s perspective at 4:59 PM.'
    ])[1 + (v_template_seed % 3)]
    when 'wholesome' then (array[
      'Write a wholesome poem about %s making everyone''s day a little better.',
      'Write a heartwarming poem about %s sharing their lunch.',
      'Write a sweet poem about %s remembering everyone''s birthday.'
    ])[1 + (v_template_seed % 3)]
  end;

  v_prompt_text := format(v_template, v_subject_text);

  insert into public.daily_poetry_challenges (challenge_date, subject_type, nickname_id, user_id, subject_text, category, prompt_text)
  values (v_today, v_subject_type, v_nickname_id, v_user_id, v_subject_text, v_category, v_prompt_text)
  on conflict (challenge_date) do nothing
  returning * into v_row;

  if v_row.id is null then
    -- een gelijktijdige transactie won de race (defensief, de
    -- advisory lock hierboven maakt dit in de praktijk onmogelijk) --
    -- gewoon de bestaande rij ophalen
    select * into v_row from public.daily_poetry_challenges where challenge_date = v_today;
  end if;

  return v_row;
end;
$$ language plpgsql security definer set search_path = public;

-- ---- 3. extend poems ----
alter table public.poems add column daily_challenge_id uuid references public.daily_poetry_challenges(id) on delete set null;
alter table public.poems add column is_daily_challenge boolean not null default false;

-- max 1 daily-challenge gedicht per user per daily challenge
create unique index one_daily_challenge_poem_per_user
  on public.poems (daily_challenge_id, author_user_id) where is_daily_challenge = true;

-- ---- 4. Realtime ----
alter publication supabase_realtime add table public.daily_poetry_challenges;
