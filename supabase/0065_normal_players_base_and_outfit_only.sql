-- =================================================================
-- OFFICE LORE — a normal player's character is only: base + outfit
-- =================================================================
-- Regular players choose female or male and one of the standard outfits (0063), and
-- that is all: no loot is attached to their character. So:
--   * Mystery boxes never contain a cosmetic for anybody but the current Abt Lord
--     (his drops are Royal Wardrobe gear). Everybody else's box pays Player XP, or a
--     Gauntlet Fragment under the existing rules.
--   * the Personal Character Wardrobe only shows the gear tabs to somebody who actually
--     owns such gear (in practice: an Abt Lord who has dropped some).
-- Nothing is deleted. Additive + idempotent. Run after 0064.
-- =================================================================
create or replace function public.open_mystery_box(p_box_id uuid)
returns jsonb as $$
declare
  b public.mystery_boxes;
  v_cfg jsonb := public._challenge_config('mystery_rewards', '{}'::jsonb);
  v_pool jsonb;
  v_order jsonb := coalesce(v_cfg->'rarity_order', '["common","rare","epic","legendary","dynasty"]'::jsonb);
  v_floor_i int; v_rar text; v_rar_i int; v_outcome text; v_outcomes jsonb; v_weights jsonb;
  v_week_start timestamptz := date_trunc('week', now() at time zone 'Europe/Brussels') at time zone 'Europe/Brussels';
  v_frags_week int; v_cap int := coalesce((v_cfg->>'fragment_weekly_cap')::int, 2);
  it public.abt_cosmetic_items;
  v_prize jsonb; v_try int; v_dup boolean := false; v_xp int; v_res jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  select * into b from public.mystery_boxes where id = p_box_id for update;
  if b.id is null or b.user_id is distinct from auth.uid() then raise exception 'This is not your Mystery Reward'; end if;
  if b.status = 'opened' then return jsonb_build_object('status', 'already_opened', 'prize', b.prize); end if;

  v_pool := coalesce(v_cfg->'pools'->b.pool, v_cfg->'pools'->'default');
  v_floor_i := coalesce((select ord - 1 from jsonb_array_elements_text(v_order) with ordinality t(val, ord) where val = coalesce(b.rarity_floor, 'common')), 0);

  -- 1. rarity: the pool's weights, nothing below the floor
  select jsonb_object_agg(e.key, e.value) into v_weights
    from jsonb_each_text(v_pool->'rarity') e
    where coalesce((select ord - 1 from jsonb_array_elements_text(v_order) with ordinality t(val, ord) where val = e.key), -1) >= v_floor_i and e.value::numeric > 0;
  v_rar := public._weighted_pick(coalesce(v_weights, jsonb_build_object(v_order->>v_floor_i, 1)));
  v_rar_i := (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality t(val, ord) where val = v_rar);

  -- 2. outcome: a Fragment only from rare up, and only within the weekly cap
  v_outcomes := v_pool->'outcomes';
  -- cosmetics are Abt Lord gear: for everybody else a box pays XP (or a fragment), nothing is attached to a normal player's character
  if b.user_id is distinct from public._current_abt_lord() then v_outcomes := v_outcomes - 'cosmetic'; end if;
  select count(*) into v_frags_week from public.mystery_boxes x
    where x.user_id = b.user_id and x.status = 'opened' and x.prize->>'type' = 'fragment' and x.opened_at >= v_week_start;
  if v_rar_i < 1 or v_frags_week >= v_cap then v_outcomes := v_outcomes - 'fragment'; end if;
  v_outcome := coalesce(public._weighted_pick(v_outcomes), 'xp');

  if v_outcome = 'cosmetic' then
    -- an unowned item: the rolled rarity first, then the others from the floor upwards (lower ones first)
    for v_try in 0..(jsonb_array_length(v_order) - 1) loop
      select i.* into it from public.abt_cosmetic_items i
        where i.is_active and i.mystery_eligible
          and (not i.lord_only_drop or b.user_id is not distinct from public._current_abt_lord())      -- Abt Lord gear drops for the Abt Lord only
          and i.rarity = (select val from jsonb_array_elements_text(v_order) with ordinality t(val, ord)
                          where ord - 1 = case when v_try = 0 then v_rar_i
                                               else ((v_rar_i - v_try) + jsonb_array_length(v_order) * 2) % jsonb_array_length(v_order) end)
          and not exists (select 1 from public.user_abt_cosmetics u where u.user_id = b.user_id and u.cosmetic_item_id = i.id)
          and (select ord - 1 from jsonb_array_elements_text(v_order) with ordinality t(val, ord) where val = i.rarity) >= v_floor_i
        order by random() limit 1;
      exit when it.id is not null;
    end loop;
    if it.id is null then
      v_outcome := 'xp'; v_dup := true;                       -- nothing new left at this tier: no frustrating duplicate, a bonus instead
    else
      insert into public.user_abt_cosmetics (user_id, cosmetic_item_id, unlock_source) values (b.user_id, it.id, 'mystery') on conflict do nothing;
      v_prize := jsonb_build_object('type', 'cosmetic', 'rarity', it.rarity, 'item_id', it.id, 'name', it.name, 'category', it.category, 'flavor', it.flavor_text);
    end if;
  end if;

  if v_outcome = 'fragment' then
    v_res := public._add_fragments(b.user_id, 1);
    v_prize := jsonb_build_object('type', 'fragment', 'rarity', v_rar, 'amount', 1, 'stored', v_res->'stored', 'forged', v_res->'forged', 'lord', v_res->'lord');
  elsif v_outcome = 'xp' then
    v_xp := coalesce((v_cfg->'xp_by_rarity'->>v_rar)::int, 10);
    v_prize := jsonb_build_object('type', 'xp', 'rarity', v_rar, 'amount', v_xp, 'duplicate_bonus', v_dup);
  end if;

  update public.mystery_boxes set status = 'opened', prize = v_prize, opened_at = now() where id = b.id;
  return jsonb_build_object('status', 'opened', 'prize', v_prize);
end;
$$ language plpgsql security definer set search_path = public;

revoke all on function public.open_mystery_box(uuid) from public, anon;
grant execute on function public.open_mystery_box(uuid) to authenticated;
