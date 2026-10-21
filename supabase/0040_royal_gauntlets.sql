-- =================================================================
-- OFFICE LORE — THE ROYAL GAUNTLET (access + cooldown + anti-spam)
-- =================================================================
-- Starting a Throne Challenge now costs 1 Royal Gauntlet. Gauntlets are
-- NOT a currency: they can't be bought, traded or sent. For now an admin
-- grants them from the SQL editor (see admin_grant_royal_gauntlets at the
-- bottom); later they are earned via Daily / Weekly Challenges.
--
--  1. royal_gauntlet_balances  one row per user, balance >= 0 (CHECK)
--  2. royal_gauntlet_ledger    append-only history. A UNIQUE index on
--                              challenge_id (per reason) makes it
--                              impossible to spend -- or refund -- the same
--                              Gauntlet for the same challenge twice.
--  3. create_throne_challenge  replaced: checks Gauntlet, cooldown, the
--                              expected Abt Lord, and the single open
--                              challenge rule, all inside one transaction
--                              under the throne advisory lock.
--  4. cooldown                 after a LOST challenge (defender won, incl.
--                              forfeits) the same challenger waits
--                              _throne_cooldown() before challenging again.
--                              Derived from throne_challenges, nothing stored.
--  5. refund trigger           a challenge that is cancelled (withdrawn or
--                              never started) gives its Gauntlet back, once.
--  6. get_throne_rules()       single source of truth for the cooldown and
--                              cost; the client reads it instead of
--                              hardcoding.
--
-- Additive, idempotent. Run once in the Supabase SQL Editor, after 0039.
-- =================================================================

-- -----------------------------------------------------------------
-- 1. Config (change here, the client follows via get_throne_rules())
-- -----------------------------------------------------------------
create or replace function public._throne_cooldown() returns interval as $$
  select interval '5 days';
$$ language sql immutable;

create or replace function public._throne_gauntlet_cost() returns int as $$
  select 1;
$$ language sql immutable;

-- -----------------------------------------------------------------
-- 2. Tables
-- -----------------------------------------------------------------
create table if not exists public.royal_gauntlet_balances (
  user_id uuid primary key references public.profiles(id),
  balance int not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.royal_gauntlet_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  delta int not null check (delta <> 0),
  reason text not null check (reason in ('admin_grant', 'throne_challenge', 'throne_refund')),
  challenge_id uuid references public.throne_challenges(id),
  note text,
  created_at timestamptz not null default now()
);

-- one spend and at most one refund per challenge: the same Gauntlet can
-- never be consumed (or given back) twice, whatever the client does
create unique index if not exists royal_gauntlet_one_spend_per_challenge
  on public.royal_gauntlet_ledger (challenge_id) where reason = 'throne_challenge';
create unique index if not exists royal_gauntlet_one_refund_per_challenge
  on public.royal_gauntlet_ledger (challenge_id) where reason = 'throne_refund';
create index if not exists royal_gauntlet_ledger_user on public.royal_gauntlet_ledger (user_id, created_at desc);

alter table public.royal_gauntlet_balances enable row level security;
alter table public.royal_gauntlet_ledger enable row level security;

-- members only ever see their OWN balance / history; no client write policy
-- exists, so every change goes through the SECURITY DEFINER functions below
drop policy if exists "Gauntlet balances: read own" on public.royal_gauntlet_balances;
create policy "Gauntlet balances: read own" on public.royal_gauntlet_balances for select to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

drop policy if exists "Gauntlet ledger: read own" on public.royal_gauntlet_ledger;
create policy "Gauntlet ledger: read own" on public.royal_gauntlet_ledger for select to authenticated
  using (user_id = auth.uid() and public.is_app_member('officelore'));

do $$
begin
  begin
    alter publication supabase_realtime add table public.royal_gauntlet_balances;
  exception when duplicate_object then null;
  end;
end $$;

-- -----------------------------------------------------------------
-- 3. Cooldown after a lost challenge (derived, nothing stored)
-- -----------------------------------------------------------------
create or replace function public._throne_cooldown_until(p_user uuid)
returns timestamptz as $$
  select max(completed_at) + public._throne_cooldown()
  from public.throne_challenges
  where challenger_user_id = p_user
    and status = 'completed'
    and winner_user_id is not null
    and winner_user_id <> challenger_user_id;
$$ language sql stable security definer set search_path = public;

create or replace function public.get_throne_rules()
returns jsonb as $$
  select jsonb_build_object(
    'cooldown_hours', extract(epoch from public._throne_cooldown()) / 3600,
    'gauntlet_cost', public._throne_gauntlet_cost()
  );
$$ language sql stable security definer set search_path = public;

-- -----------------------------------------------------------------
-- 4. create_throne_challenge: replaced (the old 1-arg version would be a
--    bypass of every rule below, so it is dropped, not overloaded)
-- -----------------------------------------------------------------
drop function if exists public.create_throne_challenge(boolean);

create or replace function public.create_throne_challenge(
  p_allow_real_life boolean default false,
  p_expected_defender uuid default null
)
returns uuid as $$
declare
  v_reign record;
  v_id uuid;
  v_until timestamptz;
  v_cost int := public._throne_gauntlet_cost();
  v_left int;
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
  -- the UI showed a specific Lord; if the throne changed hands since, refuse
  if p_expected_defender is not null and v_reign.user_id <> p_expected_defender then
    raise exception 'The throne has changed hands. Refresh and look again.';
  end if;
  -- one open challenge at a time (also covers "no parallel challenges per user")
  if exists (select 1 from public.throne_challenges where status in ('pending', 'active', 'awaiting_judge')) then
    raise exception 'A Throne Challenge is already underway';
  end if;

  v_until := public._throne_cooldown_until(auth.uid());
  if v_until is not null and v_until > now() then
    raise exception 'COOLDOWN: you may challenge the throne again at %', v_until;
  end if;

  -- consume the Gauntlet atomically: the CHECK (balance >= 0) plus the
  -- conditional update means two parallel calls can never spend one twice
  update public.royal_gauntlet_balances
    set balance = balance - v_cost, updated_at = now()
    where user_id = auth.uid() and balance >= v_cost
    returning balance into v_left;
  if not found then
    raise exception 'You need a Royal Gauntlet to challenge the throne';
  end if;

  insert into public.throne_challenges
    (reign_id, defender_user_id, challenger_user_id, status, allow_real_life, awaiting_pick_by, step_deadline, starts_at)
  values
    (v_reign.id, v_reign.user_id, auth.uid(), 'pending', coalesce(p_allow_real_life, false), auth.uid(), now() + interval '48 hours', now())
  returning id into v_id;

  insert into public.royal_gauntlet_ledger (user_id, delta, reason, challenge_id)
    values (auth.uid(), -v_cost, 'throne_challenge', v_id);

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- -----------------------------------------------------------------
-- 5. A cancelled challenge (withdrawn, or never started in time) gives its
--    Gauntlet back -- once. Covers every cancel path, present and future.
-- -----------------------------------------------------------------
create or replace function public._refund_gauntlet_on_cancel()
returns trigger as $$
declare
  v_spent int;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    select -delta into v_spent from public.royal_gauntlet_ledger
      where challenge_id = new.id and reason = 'throne_challenge';
    if v_spent is not null then
      insert into public.royal_gauntlet_ledger (user_id, delta, reason, challenge_id)
        values (new.challenger_user_id, v_spent, 'throne_refund', new.id)
        on conflict do nothing;
      if found then
        insert into public.royal_gauntlet_balances (user_id, balance)
          values (new.challenger_user_id, v_spent)
          on conflict (user_id) do update
            set balance = public.royal_gauntlet_balances.balance + excluded.balance, updated_at = now();
      end if;
    end if;
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_refund_gauntlet_on_cancel on public.throne_challenges;
create trigger trg_refund_gauntlet_on_cancel
  after update of status on public.throne_challenges
  for each row execute procedure public._refund_gauntlet_on_cancel();

-- -----------------------------------------------------------------
-- 6. Admin / development grants -- SQL editor only (postgres role).
--    Not callable from the app by anyone.
--
--    select public.admin_grant_royal_gauntlets('Elien', 3);
--    select public.admin_grant_royal_gauntlets('Elien', -1);   -- take one back
-- -----------------------------------------------------------------
create or replace function public.admin_grant_royal_gauntlets(p_user_name text, p_amount int, p_note text default 'admin grant')
returns int as $$
declare
  v_user uuid;
  v_new int;
begin
  select id into v_user from public.profiles
    where lower(display_name) = lower(p_user_name) or lower(first_name) = lower(p_user_name)
    limit 1;
  if v_user is null then raise exception 'No user called %', p_user_name; end if;
  if p_amount = 0 then raise exception 'Amount must not be 0'; end if;

  insert into public.royal_gauntlet_balances (user_id, balance)
    values (v_user, p_amount)
    on conflict (user_id) do update
      set balance = public.royal_gauntlet_balances.balance + p_amount, updated_at = now()
    returning balance into v_new;

  insert into public.royal_gauntlet_ledger (user_id, delta, reason, note)
    values (v_user, p_amount, 'admin_grant', p_note);
  return v_new;
end;
$$ language plpgsql security definer set search_path = public;

-- -----------------------------------------------------------------
-- 7. grants
-- -----------------------------------------------------------------
revoke all on function public._throne_cooldown() from public, anon, authenticated;
revoke all on function public._throne_gauntlet_cost() from public, anon, authenticated;
revoke all on function public._throne_cooldown_until(uuid) from public, anon, authenticated;
revoke all on function public._refund_gauntlet_on_cancel() from public, anon, authenticated;
revoke all on function public.admin_grant_royal_gauntlets(text, int, text) from public, anon, authenticated;

revoke all on function public.get_throne_rules() from public, anon;
grant execute on function public.get_throne_rules() to authenticated;

revoke all on function public.create_throne_challenge(boolean, uuid) from public, anon;
grant execute on function public.create_throne_challenge(boolean, uuid) to authenticated;
