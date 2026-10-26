-- =================================================================
-- 0085 — The Taproom wall hangs ONE neon sign (a big one), not two
--
-- The other signs stay in the collection; the group chooses which single sign hangs (set_wall_neons, at most 1). If 0084 already hung two,
-- only the first stays. The starter pack now hangs PROOST! (OPEN is in the collection). Safe to run whether or not 0084 was run before 0085.
-- Additive + idempotent. Run after 0084.
-- =================================================================
create or replace function public.set_wall_neons(p_ids text[])
returns jsonb as $$
declare v_ids text[] := coalesce(p_ids, '{}');
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if cardinality(v_ids) > 1 then raise exception 'Only 1 neon sign fits on the wall'; end if;
  if exists (select 1 from unnest(v_ids) x where not exists (select 1 from public.wall_found_neons f where f.neon_id = x)) then raise exception 'That sign has not been found yet'; end if;
  insert into public.wall_settings (key, value) values ('hung_neons', to_jsonb(v_ids)) on conflict (key) do update set value = excluded.value;
  return to_jsonb(v_ids);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._wall_starter_pack()
returns void as $$
begin
  if exists (select 1 from public.wall_settings where key = 'starter_given') then return; end if;
  insert into public.wall_found_neons (neon_id, found_by) values ('prost', null), ('open', null) on conflict do nothing;
  update public.wall_settings set value = '["prost"]'::jsonb where key = 'hung_neons';
  insert into public.wall_coasters (beer_id, found_by)
    select b.id, null
    from public.beers b
    left join (select beer_id, avg(rating) as a, count(rating) as c from public.beer_ratings where rating is not null group by beer_id) r on r.beer_id = b.id
    order by r.a desc nulls last, r.c desc nulls last, b.created_at asc, b.name asc
    limit 2
  on conflict do nothing;
  insert into public.wall_settings (key, value) values ('starter_given', 'true'::jsonb) on conflict do nothing;
end;
$$ language plpgsql security definer set search_path = public;

-- a wall that already hung two: keep the first one
update public.wall_settings set value = jsonb_build_array(value->0) where key = 'hung_neons' and jsonb_array_length(value) > 1;

revoke all on function public._wall_starter_pack() from public, anon, authenticated;
revoke all on function public.set_wall_neons(text[]) from public, anon;
grant execute on function public.set_wall_neons(text[]) to authenticated;
