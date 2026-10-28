-- =================================================================
-- OFFICE LORE / TRIPEL TALES — PUBLIC PLAYER XP + "WHO IS DONE TODAY"
-- =================================================================
-- Quest XP (the challenge reward ledger) is private: everybody can only read their OWN rows. That is right for the ledger, but it means
-- the app could not know how much XP the others have earned from quests, so every other person's level and any ranking was too low.
-- Two small read-only functions fix that without opening the ledger:
--   player_challenge_xp()  -> per active member: the Player XP they earned from quests (+ XP from opened Mystery Rewards)
--   sweep_done_today()     -> per active member: has this member completed today's Daily Sweep (Europe/Brussels day)?
-- Used by the Home terrace: the group's growth, the VIP seats (most XP), level auras and the "everybody is done" party.
-- Additive + idempotent. Run after 0089.
-- =================================================================
create or replace function public.player_challenge_xp()
returns table (user_id uuid, challenge_xp int) as $$
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  return query
    select m.user_id,
           (coalesce((select sum(g.amount) from public.challenge_reward_grants g where g.user_id = m.user_id and g.kind = 'player_xp'), 0)
          + coalesce((select sum((b.prize->>'amount')::int) from public.mystery_boxes b
                      where b.user_id = m.user_id and b.status = 'opened' and b.prize->>'type' = 'xp'), 0))::int
    from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active
    order by m.user_id;
end;
$$ language plpgsql stable security definer set search_path = public;

create or replace function public.sweep_done_today()
returns table (user_id uuid, done boolean) as $$
declare v_today text := to_char(now() at time zone 'Europe/Brussels', 'YYYY-MM-DD');
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  return query
    select m.user_id, exists (select 1 from public.challenge_sweeps s where s.user_id = m.user_id and s.period_key = v_today)
    from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active
    order by m.user_id;
end;
$$ language plpgsql stable security definer set search_path = public;

revoke all on function public.player_challenge_xp() from public, anon;
grant execute on function public.player_challenge_xp() to authenticated;
revoke all on function public.sweep_done_today() from public, anon;
grant execute on function public.sweep_done_today() to authenticated;
