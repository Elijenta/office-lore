-- =================================================================
-- OFFICE LORE — POETRY CHALLENGES (extends Poetry Wall)
-- =================================================================
-- New table: poetry_prompts (seeded with ~41 prompts below). Extends
-- poems with prompt_id + denormalized snapshot fields (same "freeze
-- historical display data" pattern as nickname_battles) + a
-- is_challenge_poem flag. Challenge XP (+3) is added to the EXISTING
-- xp_on_poem_insert() trigger from 0009 rather than a new trigger --
-- since it only fires on INSERT (never UPDATE), editing a poem can
-- never re-grant it, with no extra idempotency bookkeeping needed.
-- =================================================================

-- ---- 1. poetry_prompts ----
create table public.poetry_prompts (
  id uuid primary key default gen_random_uuid(),
  prompt_text text not null,
  category text not null check (category in (
    'romantic', 'tragic', 'office_nonsense', 'beer_inspired', 'absolute_nonsense', 'dramatic', 'abt_dynasty'
  )),
  is_daily_eligible boolean not null default true,
  is_surprise_eligible boolean not null default false,
  is_active boolean not null default true,
  created_by_user_id uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

alter table public.poetry_prompts enable row level security;
create policy "Poetry prompts: read" on public.poetry_prompts for select to authenticated using (true);
create policy "Poetry prompts: insert own" on public.poetry_prompts for insert to authenticated
  with check (created_by_user_id = auth.uid());
create policy "Poetry prompts: update own" on public.poetry_prompts for update to authenticated
  using (created_by_user_id = auth.uid());
create policy "Poetry prompts: delete own" on public.poetry_prompts for delete to authenticated
  using (created_by_user_id = auth.uid());

-- ---- 2. seed prompts ----
insert into public.poetry_prompts (prompt_text, category) values
  ('Write a romantic poem about the office printer.', 'romantic'),
  ('Write a love letter to the coffee machine.', 'romantic'),
  ('Write a sonnet about someone finally replying to your Teams message.', 'romantic'),
  ('Write about Excel as if it were your forbidden lover.', 'romantic'),
  ('Write a passionate poem about Friday afternoon.', 'romantic'),

  ('Write a tragic poem about a meeting that could have been an email.', 'tragic'),
  ('Mourn the death of your weekend on Monday morning.', 'tragic'),
  ('Write about the coffee machine being empty.', 'tragic'),
  ('Write a funeral poem for a crashed spreadsheet.', 'tragic'),
  ('Describe the pain of seeing "Meeting extended by 30 minutes."', 'tragic'),

  ('Write an epic poem about someone stealing your chair.', 'office_nonsense'),
  ('Turn a printer jam into a heroic battle.', 'office_nonsense'),
  ('Write about a mysterious smell in the office kitchen.', 'office_nonsense'),
  ('Describe a Teams notification as a supernatural event.', 'office_nonsense'),
  ('Write about the person who never replaces the toilet roll as an ancient villain.', 'office_nonsense'),

  ('Write an ode to your favourite beer.', 'beer_inspired'),
  ('Describe The Abt Lord as an ancient ruler.', 'beer_inspired'),
  ('Write about opening the first beer after work.', 'beer_inspired'),
  ('Write a medieval prophecy about the next Abt Lord.', 'beer_inspired'),
  ('Write a tragic poem about the last beer being gone.', 'beer_inspired'),

  ('Write a poem from the perspective of a stapler.', 'absolute_nonsense'),
  ('Write about a PowerPoint presentation becoming self-aware.', 'absolute_nonsense'),
  ('Describe a keyboard plotting revenge.', 'absolute_nonsense'),
  ('Write a poem about a pigeon becoming CEO.', 'absolute_nonsense'),
  ('Write an emotional goodbye between two Post-it notes.', 'absolute_nonsense'),

  ('Turn a minor office inconvenience into a Shakespearean tragedy.', 'dramatic'),
  ('Write about someone taking the last cookie as an act of betrayal.', 'dramatic'),
  ('Describe losing Wi-Fi as the fall of civilization.', 'dramatic'),
  ('Write an epic battle between coffee and tea.', 'dramatic'),
  ('Write about a 4:59 PM Teams message as the beginning of the apocalypse.', 'dramatic'),

  ('Write a coronation poem for The Abt Lord.', 'abt_dynasty'),
  ('Write a lament from The Fallen Abt.', 'abt_dynasty'),
  ('Write a prophecy predicting who will next take the throne.', 'abt_dynasty'),
  ('Describe an Abt Lord dethronement as a medieval coup.', 'abt_dynasty'),
  ('Write an anthem for the Beer Kingdom.', 'abt_dynasty');

-- "Give Me Something Stupid" -- a distinct curated pool, not just
-- "whatever's tagged absolute_nonsense", so that category can grow
-- later without silently changing what Surprise Me serves.
insert into public.poetry_prompts (prompt_text, category, is_daily_eligible, is_surprise_eligible) values
  ('Write a breakup poem addressed to Microsoft Excel.', 'absolute_nonsense', false, true),
  ('Write a medieval ballad about someone microwaving fish at work.', 'absolute_nonsense', false, true),
  ('Write a seductive poem about a Power BI refresh.', 'absolute_nonsense', false, true),
  ('Write from the perspective of a forgotten yoghurt in the office fridge.', 'absolute_nonsense', false, true),
  ('Write a eulogy for a pen that has run out of ink.', 'absolute_nonsense', false, true),
  ('Write about The Abt Lord discovering that the fridge is empty.', 'absolute_nonsense', false, true);

-- ---- 3. extend poems ----
alter table public.poems add column prompt_id uuid references public.poetry_prompts(id) on delete set null;
alter table public.poems add column prompt_text_snapshot text;
alter table public.poems add column prompt_category_snapshot text;
alter table public.poems add column is_challenge_poem boolean not null default false;

-- ---- 4. challenge XP: extend the existing publish trigger ----
create or replace function public.xp_on_poem_insert()
returns trigger as $$
begin
  insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
  values (new.author_user_id, 'poetry', 'poem_published', new.id, 5, 'Gedicht gepubliceerd: "' || new.title || '"');

  if new.is_challenge_poem then
    insert into public.xp_events (user_id, xp_type, source_type, source_id, points, description)
    values (new.author_user_id, 'poetry', 'challenge_completed', new.id, 3, 'Poetry Challenge voltooid: "' || new.title || '"');
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

-- extend the existing poem-delete cleanup with the new source_type
create or replace function public.trg_fn_xp_cleanup_poem()
returns trigger as $$
begin
  perform public.xp_cleanup_by_source('poem_published', old.id);
  perform public.xp_cleanup_by_source('actually_good_bonus', old.id);
  perform public.xp_cleanup_by_source('challenge_completed', old.id);
  return old;
end;
$$ language plpgsql security definer set search_path = public;

-- ---- 5. Realtime ----
alter publication supabase_realtime add table public.poetry_prompts;
