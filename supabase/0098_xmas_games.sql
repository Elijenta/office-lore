-- =================================================================
-- 0098 — Kerstspelletjes en de kerstboom
--
-- Spelletjes: altijd speelbaar. Kerstballen verzamel je
--   * maximaal 1 keer per dag per spel, en
--   * bij maximaal 3 verschillende spellen per dag (Brusselse tijd).
-- De server rekent zelf uit hoeveel een ronde waard is en weigert buiten
-- de kerstperiode (1 december 2026 t/m 6 januari 2027).
--   snowball : 8 punten = 1, 14 = 2, 20 = 3
--   beer     : aantal glazen van 95% of beter in een ronde (max 3)
--   order    : aantal juiste bestellingen in een ronde (max 3)
--   sleigh   : 8 punten = 1, 15 = 2, 25 = 3
--   catch    : 15 punten = 1, 25 = 2, 35 = 3
--   find     : aantal gehaalde rondes (max 3)
--
-- Kerstboom: iedereen versiert een eigen boom (staat in het Hoekje).
-- De eerste keer bewaren in de kerstperiode = 5 kerstballen. Iedereen heeft
-- 1 ster om aan de boom van iemand anders te geven (verplaatsbaar t/m 24 dec).
--
-- Kamerlichtjes: iedereen kiest zelf waar in zijn Hoekje lichtjes hangen,
-- in welke kleuren en hoe ze branden. De anderen zien dat bij een bezoek.
--
-- Vereist 0097. Additief + idempotent: mag opnieuw gedraaid worden.
-- =================================================================

create table if not exists public.xmas_trees (
  user_id uuid primary key references public.profiles(id),
  config jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.xmas_tree_votes (
  voter_id uuid primary key references public.profiles(id),
  target_user_id uuid not null references public.profiles(id),
  updated_at timestamptz not null default now(),
  check (voter_id <> target_user_id)
);
alter table public.xmas_trees enable row level security;
alter table public.xmas_tree_votes enable row level security;
drop policy if exists "Xmas trees: read" on public.xmas_trees;
create policy "Xmas trees: read" on public.xmas_trees for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "Xmas tree votes: read" on public.xmas_tree_votes;
create policy "Xmas tree votes: read" on public.xmas_tree_votes for select to authenticated using (public.is_app_member('officelore'));
-- geen schrijf-policies: alleen de functies hieronder schrijven

create or replace function public.claim_xmas_game(p_game text, p_score numeric)
returns jsonb as $$
declare
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Europe/Brussels')::date;
  v_amount int;
  v_games int;
begin
  if v_user is null or not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if v_day < date '2026-12-01' or v_day >= date '2027-01-07' then
    return jsonb_build_object('ok', false, 'reason', 'closed');
  end if;

  v_amount := case p_game
    when 'snowball' then case when p_score >= 20 then 3 when p_score >= 14 then 2 when p_score >= 8 then 1 else 0 end
    when 'beer'   then least(greatest(floor(p_score), 0), 3)::int
    when 'order'  then least(greatest(floor(p_score), 0), 3)::int
    when 'sleigh' then case when p_score >= 25 then 3 when p_score >= 15 then 2 when p_score >= 8 then 1 else 0 end
    when 'catch'  then case when p_score >= 35 then 3 when p_score >= 25 then 2 when p_score >= 15 then 1 else 0 end
    when 'find'   then least(greatest(floor(p_score), 0), 3)::int
    else null
  end;
  if v_amount is null then raise exception 'Unknown game %', p_game; end if;
  if v_amount = 0 then return jsonb_build_object('ok', false, 'reason', 'none'); end if;

  perform pg_advisory_xact_lock(hashtext('xmas_game:' || v_user::text));  -- twee tegelijk mag de limiet niet omzeilen
  if exists (select 1 from public.xmas_baubles where user_id = v_user and source = 'game:' || p_game and ref = v_day::text) then
    return jsonb_build_object('ok', false, 'reason', 'already');
  end if;
  select count(*) into v_games from public.xmas_baubles where user_id = v_user and source like 'game:%' and ref = v_day::text;
  if v_games >= 3 then return jsonb_build_object('ok', false, 'reason', 'limit'); end if;

  insert into public.xmas_baubles (user_id, amount, source, ref) values (v_user, v_amount, 'game:' || p_game, v_day::text);
  return jsonb_build_object('ok', true, 'amount', v_amount);
end;
$$ language plpgsql security definer set search_path = public;
revoke all on function public.claim_xmas_game(text, numeric) from public, anon;
grant execute on function public.claim_xmas_game(text, numeric) to authenticated;

create or replace function public.save_xmas_tree(p_config jsonb)
returns jsonb as $$
declare
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Europe/Brussels')::date;
  v_rows int := 0;
begin
  if v_user is null or not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_config is null or jsonb_typeof(p_config) <> 'object' or octet_length(p_config::text) > 1000 then raise exception 'Invalid tree'; end if;
  insert into public.xmas_trees (user_id, config) values (v_user, p_config)
    on conflict (user_id) do update set config = excluded.config, updated_at = now();
  if v_day >= date '2026-12-01' and v_day < date '2027-01-07' then
    insert into public.xmas_baubles (user_id, amount, source, ref) values (v_user, 5, 'tree', 'first')
      on conflict (user_id, source, ref) do nothing;
    get diagnostics v_rows = row_count;
  end if;
  return jsonb_build_object('ok', true, 'reward', case when v_rows > 0 then 5 else 0 end);
end;
$$ language plpgsql security definer set search_path = public;
revoke all on function public.save_xmas_tree(jsonb) from public, anon;
grant execute on function public.save_xmas_tree(jsonb) to authenticated;

create or replace function public.vote_xmas_tree(p_user uuid)
returns jsonb as $$
declare v_day date := (now() at time zone 'Europe/Brussels')::date;
begin
  if auth.uid() is null or not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if v_day < date '2026-12-01' or v_day > date '2026-12-24' then return jsonb_build_object('ok', false, 'reason', 'closed'); end if;
  if p_user = auth.uid() or not exists (select 1 from public.xmas_trees where user_id = p_user) then raise exception 'Invalid vote'; end if;
  insert into public.xmas_tree_votes (voter_id, target_user_id) values (auth.uid(), p_user)
    on conflict (voter_id) do update set target_user_id = excluded.target_user_id, updated_at = now();
  return jsonb_build_object('ok', true);
end;
$$ language plpgsql security definer set search_path = public;
revoke all on function public.vote_xmas_tree(uuid) from public, anon;
grant execute on function public.vote_xmas_tree(uuid) to authenticated;

create table if not exists public.xmas_rooms (
  user_id uuid primary key references public.profiles(id),
  config jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.xmas_rooms enable row level security;
drop policy if exists "Xmas rooms: read" on public.xmas_rooms;
create policy "Xmas rooms: read" on public.xmas_rooms for select to authenticated using (public.is_app_member('officelore'));

create or replace function public.save_xmas_room(p_config jsonb)
returns jsonb as $$
begin
  if auth.uid() is null or not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if p_config is null or jsonb_typeof(p_config) <> 'object' or octet_length(p_config::text) > 1000 then raise exception 'Invalid room'; end if;
  insert into public.xmas_rooms (user_id, config) values (auth.uid(), p_config)
    on conflict (user_id) do update set config = excluded.config, updated_at = now();
  return jsonb_build_object('ok', true);
end;
$$ language plpgsql security definer set search_path = public;
revoke all on function public.save_xmas_room(jsonb) from public, anon;
grant execute on function public.save_xmas_room(jsonb) to authenticated;

-- de stand van de markt: kerstballen, wat jij vandaag al verzamelde, de bomen en de sterren
create or replace function public.get_xmas_state()
returns jsonb as $$
declare v_day text := ((now() at time zone 'Europe/Brussels')::date)::text;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  return jsonb_build_object(
    'total', coalesce((select sum(amount) from public.xmas_baubles), 0),
    'users', coalesce((select jsonb_agg(jsonb_build_object('user_id', t.user_id, 'baubles', t.n) order by t.n desc)
                       from (select user_id, sum(amount)::int as n from public.xmas_baubles group by user_id) t), '[]'::jsonb),
    'day', v_day,
    'mine', coalesce((select jsonb_object_agg(substr(source, 6), amount) from public.xmas_baubles
                      where user_id = auth.uid() and source like 'game:%' and ref = v_day), '{}'::jsonb),
    'trees', coalesce((select jsonb_object_agg(user_id, config) from public.xmas_trees), '{}'::jsonb),
    'rooms', coalesce((select jsonb_object_agg(user_id, config) from public.xmas_rooms), '{}'::jsonb),
    'stars', coalesce((select jsonb_object_agg(t.target_user_id, t.n)
                       from (select target_user_id, count(*)::int as n from public.xmas_tree_votes group by target_user_id) t), '{}'::jsonb),
    'my_vote', (select target_user_id from public.xmas_tree_votes where voter_id = auth.uid())
  );
end;
$$ language plpgsql stable security definer set search_path = public;
revoke all on function public.get_xmas_state() from public, anon;
grant execute on function public.get_xmas_state() to authenticated;
