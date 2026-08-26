-- =================================================================
-- OFFICE LORE — POETRY WALL: WRITTEN COMMENTS
-- =================================================================
-- Adds real written comments on poems, alongside (not replacing) the
-- existing emoji reactions in poem_reactions. Deliberately no XP
-- trigger -- comments are for conversation, not a new XP source (the
-- spec explicitly wants to avoid cheap XP-farming via short comments).
-- Same app-scoping pattern as every table since 0015: RLS gates on
-- public.is_app_member('officelore'), reusing the existing helper.
-- =================================================================

create table public.poem_comments (
  id uuid primary key default gen_random_uuid(),
  poem_id uuid not null references public.poems(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  content text not null check (char_length(content) <= 1000 and char_length(trim(content)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_poem_comments_updated_at
  before update on public.poem_comments
  for each row execute procedure public.set_updated_at();
-- "edited" is derived client-side (updated_at !== created_at), same
-- philosophy as every other derived-not-stored flag in this app --
-- no separate is_edited column needed.

create index poem_comments_poem_id_idx on public.poem_comments (poem_id);

alter table public.poem_comments enable row level security;

create policy "Poem comments: read" on public.poem_comments for select to authenticated
  using (public.is_app_member('officelore'));

-- anyone (including the poem's own author -- unlike reactions, there's
-- no self-comment restriction in the spec) may comment
create policy "Poem comments: authenticated may add own" on public.poem_comments for insert to authenticated
  with check (user_id = auth.uid() and public.is_app_member('officelore'));

create policy "Poem comments: only own comment may be edited" on public.poem_comments for update to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'))
  with check (user_id = auth.uid() and public.is_app_member('officelore'));

create policy "Poem comments: only own comment may be deleted" on public.poem_comments for delete to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

alter publication supabase_realtime add table public.poem_comments;
