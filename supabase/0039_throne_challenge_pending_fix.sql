-- =================================================================
-- OFFICE LORE — THRONE CHALLENGE: new challenges start as 'pending'
-- =================================================================
-- Fix for 0038: throne_challenges.status still defaulted to 'active'
-- (from 0037), and create_throne_challenge() didn't set a status, so a
-- freshly created challenge skipped 'pending' -- which broke "withdraw
-- before Trial 1" and the pending-timeout (both key off 'pending').
--
--  1. column default becomes 'pending'
--  2. create_throne_challenge() sets status explicitly
--  3. any challenge created by the bug (status 'active', no Trial yet,
--     waiting for the first school pick) is moved back to 'pending'
--
-- Idempotent. Run once in the Supabase SQL Editor, after 0038.
-- =================================================================

alter table public.throne_challenges alter column status set default 'pending';

update public.throne_challenges c
  set status = 'pending'
  where c.status = 'active'
    and c.awaiting_pick_by is not null
    and c.started_at is null
    and not exists (select 1 from public.throne_challenge_trials t where t.challenge_id = c.id);

create or replace function public.create_throne_challenge(p_allow_real_life boolean default false)
returns uuid as $$
declare
  v_reign record;
  v_id uuid;
begin
  if not public.is_app_member('officelore') then
    raise exception 'Access denied';
  end if;

  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into v_reign from public.abt_reigns where ended_at is null limit 1;
  if v_reign is null then
    raise exception 'There is no Abt Lord to challenge yet';
  end if;
  if v_reign.user_id = auth.uid() then
    raise exception 'The Abt Lord cannot challenge themselves';
  end if;
  if exists (select 1 from public.throne_challenges where status in ('pending', 'active', 'awaiting_judge')) then
    raise exception 'A Throne Challenge is already underway';
  end if;

  insert into public.throne_challenges
    (reign_id, defender_user_id, challenger_user_id, status, allow_real_life, awaiting_pick_by, step_deadline, starts_at)
  values
    (v_reign.id, v_reign.user_id, auth.uid(), 'pending', coalesce(p_allow_real_life, false), auth.uid(), now() + interval '48 hours', now())
  returning id into v_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.create_throne_challenge(boolean) from public, anon;
grant execute on function public.create_throne_challenge(boolean) to authenticated;
