-- =================================================================
-- OFFICE LORE — Nicknames: correct edit rights for creator vs. others
-- =================================================================
-- Bugfix: the UPDATE RLS policy on nicknames has always been
-- creator-only, but the frontend used one plain full-field update
-- for everyone -- a non-creator's update silently matched zero rows
-- (Supabase doesn't error on an RLS-filtered update with no matching
-- rows), so nothing ever saved for them, with no error surfaced.
--
-- Fix: keep the existing owner-only UPDATE policy exactly as-is (the
-- creator's full edit keeps working through it unchanged), and add a
-- narrow SECURITY DEFINER RPC that any authenticated user can call to
-- update ONLY description/anecdote -- its own SQL statement is
-- structurally incapable of touching any other column, so this is
-- safe against a manipulated API call, not just a UI convention.
-- =================================================================

-- ---- 1. updated_by_user_id: who last touched this row, via either path ----
alter table public.nicknames add column updated_by_user_id uuid references public.profiles(id);

create or replace function public.set_nickname_updated_by()
returns trigger as $$
begin
  new.updated_by_user_id = auth.uid();
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_nicknames_updated_by
  before update on public.nicknames
  for each row execute procedure public.set_nickname_updated_by();

-- ---- 2. collaborative-fields RPC (description + anecdote only) ----
create or replace function public.update_nickname_collaborative_fields(
  p_nickname_id uuid,
  p_description text,
  p_anecdote text
)
returns void as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update public.nicknames
    set description = p_description, anecdote = p_anecdote
    where id = p_nickname_id;
end;
$$ language plpgsql security definer set search_path = public;

-- Note: no XP trigger changes needed -- trg_xp_nickname_insert (0001)
-- is `after insert` only, so editing (by anyone, any number of
-- times, through either path) has never been able to re-grant the
-- +10 creation XP.
