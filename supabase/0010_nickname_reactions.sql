-- =================================================================
-- OFFICE LORE — Nicknames: Legendary + Doubt reactions
-- =================================================================
-- Single additive change: widen nickname_votes.vote_type to allow
-- two new reaction types. RLS is already fully generic (own vote to
-- insert/delete, open read) so no policy changes are needed, and
-- votes have never granted XP (confirmed against
-- 0003_xp_cleanup_triggers.sql) so no trigger changes are needed
-- either. Existing funny/accurate/savage rows are untouched.
-- =================================================================

alter table public.nickname_votes drop constraint if exists nickname_votes_vote_type_check;
alter table public.nickname_votes add constraint nickname_votes_vote_type_check
  check (vote_type in ('funny', 'accurate', 'savage', 'legendary', 'doubt'));
