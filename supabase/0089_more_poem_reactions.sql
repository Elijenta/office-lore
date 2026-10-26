-- =================================================================
-- OFFICE LORE / TRIPEL TALES — MORE POEM REACTIONS
-- =================================================================
-- A poem could only get 9 fixed reactions: the table had a CHECK with that exact list, so every new reaction needed a migration.
-- That list now lives in the app (POEM_REACTION_TYPES in index.html): the database only checks that the key looks sane
-- (lowercase letters and underscores). Everything else stays as it was: a unique reaction per person per poem, at most 3
-- different reactions per person per poem, +1 Poetry XP for the author per reaction, the 'actually_good' bonus.
-- Additive + idempotent. Run after 0088.
-- =================================================================
do $$
declare c text;
begin
  for c in
    select con.conname from pg_constraint con
    where con.conrelid = 'public.poem_reactions'::regclass and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%reaction_type%' and pg_get_constraintdef(con.oid) ilike '%charming%'
  loop
    execute format('alter table public.poem_reactions drop constraint %I', c);
  end loop;
end $$;
alter table public.poem_reactions drop constraint if exists poem_reactions_type_format;
alter table public.poem_reactions add constraint poem_reactions_type_format check (reaction_type ~ '^[a-z][a-z_]{1,29}$');
