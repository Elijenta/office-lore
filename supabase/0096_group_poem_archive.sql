-- =================================================================
-- 0096 — Poetry Showdown: de gedichten blijven leesbaar
--
-- Een gedicht dat je schrijft voor de Daily Poetry Showdown (Group
-- Challenge) staat in group_daily_entries. Die tabel is per speler
-- afgeschermd, en get_group_daily() toont alleen de LAATSTE afgeronde
-- ronde. Een nieuwe ronde later was het gedicht dus voor iedereen
-- (behalve de schrijver) onvindbaar.
--
-- get_group_poems(): alle gedichten van AFGERONDE poetry-rondes, zodat
-- de Poetry Wall ze als aparte sectie kan tonen. Rondes die nog open
-- staan blijven anoniem (er wordt nog gestemd).
--
-- Alleen lezen. Additief + idempotent. Draai 1x in de Supabase SQL editor.
-- =================================================================

create or replace function public.get_group_poems(p_limit int default 100)
returns jsonb as $$
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform public._finalize_due_group_rounds();
  return coalesce((
    select jsonb_agg(x.j order by x.ends_at desc, x.created_at)
    from (
      select r.ends_at, e.created_at,
        jsonb_build_object(
          'id', e.id,
          'round_id', r.id,
          'day_key', r.day_key,
          'prompt', r.prompt->>'text',
          'user_id', e.user_id,
          'text', e.content->>'text',
          'votes', (select count(*) from public.group_daily_votes v where v.entry_id = e.id),
          'winner', exists (select 1 from public.group_daily_winners w where w.round_id = r.id and w.user_id = e.user_id)
        ) as j
      from public.group_daily_rounds r
      join public.group_daily_entries e on e.round_id = r.id
      where r.app_id = 'officelore' and r.kind = 'poetry' and r.status = 'finalized'
        and coalesce(e.content->>'text', '') <> ''
      order by r.ends_at desc, e.created_at
      limit greatest(least(coalesce(p_limit, 100), 300), 1)
    ) x
  ), '[]'::jsonb);
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.get_group_poems(int) from public, anon;
grant execute on function public.get_group_poems(int) to authenticated;
