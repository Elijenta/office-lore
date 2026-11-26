-- =================================================================
-- 0097 — Kerstmarkt: de kerstballen van het hele gezelschap
--
-- Elke kerstbal die iemand verdient komt als rij in xmas_baubles. De som
-- van iedereen bepaalt het Kerst-level van de kerstmarkt op de homepagina
-- (een gezamenlijk iets). Clients kunnen niet schrijven: kerstballen komen
-- later uit kerstquests en de kerstboom-minigame (aparte migratie).
--
-- Voor testen kun je er zelf kerstballen bijzetten in de SQL editor:
--   select public.admin_grant_baubles('Elien', 12);
--
-- Additief + idempotent. Draai 1x in de Supabase SQL editor.
-- =================================================================

create table if not exists public.xmas_baubles (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id),
  amount int not null check (amount <> 0),
  source text not null,              -- 'quest', 'tree', 'admin', ...
  ref text,                          -- dedupe: bv. de assignment-id
  created_at timestamptz not null default now(),
  unique (user_id, source, ref)
);
alter table public.xmas_baubles enable row level security;
drop policy if exists "Xmas baubles: read" on public.xmas_baubles;
create policy "Xmas baubles: read" on public.xmas_baubles for select to authenticated using (public.is_app_member('officelore'));
-- geen insert/update/delete-policy: alleen SECURITY DEFINER-functies schrijven hier

create or replace function public.get_xmas_state()
returns jsonb as $$
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  return jsonb_build_object(
    'total', coalesce((select sum(amount) from public.xmas_baubles), 0),
    'users', coalesce((select jsonb_agg(jsonb_build_object('user_id', t.user_id, 'baubles', t.n) order by t.n desc)
                       from (select user_id, sum(amount)::int as n from public.xmas_baubles group by user_id) t), '[]'::jsonb)
  );
end;
$$ language plpgsql stable security definer set search_path = public;

revoke all on function public.get_xmas_state() from public, anon;
grant execute on function public.get_xmas_state() to authenticated;

-- alleen via de SQL editor (postgres): kerstballen bijzetten of wegnemen
create or replace function public.admin_grant_baubles(p_user_name text, p_amount int, p_note text default 'admin')
returns int as $$
declare v_user uuid; v_total int;
begin
  select id into v_user from public.profiles
    where lower(display_name) = lower(p_user_name) or lower(first_name) = lower(p_user_name) limit 1;
  if v_user is null then raise exception 'No user called %', p_user_name; end if;
  insert into public.xmas_baubles (user_id, amount, source, ref) values (v_user, p_amount, 'admin', p_note || ':' || clock_timestamp()::text);
  select coalesce(sum(amount), 0) into v_total from public.xmas_baubles;
  return v_total;
end;
$$ language plpgsql security definer set search_path = public;
revoke all on function public.admin_grant_baubles(text, int, text) from public, anon, authenticated;
