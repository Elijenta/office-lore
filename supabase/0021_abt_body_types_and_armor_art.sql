-- =================================================================
-- OFFICE LORE — ABT AVATAR: BODY TYPES + ILLUSTRATED ARMOR ART
-- =================================================================
-- Two additive changes, run together:
--
-- 1. Adds "body" as a 7th cosmetic category (female / male / male
--    muscle / male thin), all Standard (available from day one, same
--    as every other Standard item). Widens the category check
--    constraint, adds one nullable column to abt_avatar_loadouts.
--    No RLS/RPC changes needed -- equip_abt_item() already resolves
--    the target column generically via `p_category || '_item_id'`.
--
-- 2. Elien illustrated a full matching outfit set for all 4 body
--    types (abtlord-images/base-armors.png) plus a Tiger-Stripe
--    milestone variant (tiger-armor.png). This UPDATEs the 5
--    existing standard armor rows' asset_key (and names, to match
--    her labels) to point at the new art instead of the old flat SVG
--    shapes -- no new rows needed, no existing unlocks/ownership
--    touched (standard items were never tracked per-user anyway).
--    'Tiger-Stripe Armor' already used asset_key='armor.tiger', so it
--    needs no change here. Every other armor item (the 5 daily-pick
--    'armor.plate' tints, and the lion/bear/eternal_tap/eternal_abt
--    milestones) has no illustrated art yet -- the client filters
--    those out of the Wardrobe grid rather than rendering a
--    mismatched/missing image, exactly as it already does for 'cape'.
--
-- Run this once in the Supabase SQL Editor, after 0020.
-- =================================================================

do $$
declare
  v_constraint_name text;
begin
  select conname into v_constraint_name
  from pg_constraint
  where conrelid = 'public.abt_cosmetic_items'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%category%';
  if v_constraint_name is not null then
    execute format('alter table public.abt_cosmetic_items drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.abt_cosmetic_items add constraint abt_cosmetic_items_category_check
  check (category in ('hair','headwear','armor','cape','weapon','accessory','body'));

alter table public.abt_avatar_loadouts add column if not exists body_item_id uuid references public.abt_cosmetic_items(id);

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key)
select v.name, v.flavor_text, 'body', 'standard', 'standard', v.asset_key
from (values
  ('Female', 'The default look for a lord who has earned it.', 'body.female'),
  ('Male', 'Standard issue. Perfectly respectable.', 'body.male'),
  ('Male (Muscle)', 'Definitely earned through beer alone.', 'body.male_muscle'),
  ('Male (Thin)', 'Lean, mean, questionable-decision-making machine.', 'body.male_thin')
) as v(name, flavor_text, asset_key)
where not exists (
  select 1 from public.abt_cosmetic_items existing where existing.asset_key = v.asset_key
);

-- ---- illustrated armor: repoint the 5 existing standard rows ----
update public.abt_cosmetic_items set asset_key = 'armor.monk_robes'
  where category = 'armor' and unlock_type = 'standard' and name = 'Monk Robes';

update public.abt_cosmetic_items set name = 'Leather Ranger', asset_key = 'armor.leather_ranger'
  where category = 'armor' and unlock_type = 'standard' and name = 'Leather Armor';

update public.abt_cosmetic_items set name = 'Knight Armor', asset_key = 'armor.knight_armor'
  where category = 'armor' and unlock_type = 'standard' and name = 'Basic Knight Armor';

update public.abt_cosmetic_items set asset_key = 'armor.tavern_outfit'
  where category = 'armor' and unlock_type = 'standard' and name = 'Tavern Outfit';

update public.abt_cosmetic_items set name = 'Royal Guard', asset_key = 'armor.royal_guard'
  where category = 'armor' and unlock_type = 'standard' and name = 'Royal Tunic';
