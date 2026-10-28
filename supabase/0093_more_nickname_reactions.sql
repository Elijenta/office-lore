-- =================================================================
-- OFFICE LORE / TRIPEL TALES — MORE NICKNAME REACTIONS
-- =================================================================
-- A nickname could only get 5 fixed reactions: nickname_votes had a CHECK with that exact list (funny, accurate, savage,
-- legendary, doubt), so every new reaction needed a migration. The list now lives in the app (NICKNAME_REACTIONS in
-- index.html): the database only checks that the key looks sane (lowercase letters and underscores), like poem_reactions
-- since 0089. New in the app: genius, inside_joke, hall_of_fame. Everything else stays as it was: one vote per person per
-- reaction per nickname, own vote only, open read, and votes never give XP.
-- Additive + idempotent. Run after 0092.
-- =================================================================
do $$
declare c text;
begin
  for c in
    select con.conname from pg_constraint con
    where con.conrelid = 'public.nickname_votes'::regclass and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%vote_type%' and pg_get_constraintdef(con.oid) ilike '%legendary%'
  loop
    execute format('alter table public.nickname_votes drop constraint %I', c);
  end loop;
end $$;
alter table public.nickname_votes drop constraint if exists nickname_votes_type_format;
alter table public.nickname_votes add constraint nickname_votes_type_format check (vote_type ~ '^[a-z][a-z_]{1,29}$');
