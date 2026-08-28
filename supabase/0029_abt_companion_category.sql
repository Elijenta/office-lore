-- =================================================================
-- OFFICE LORE — ABT AVATAR: THE ABT COMPANION CATEGORY
-- =================================================================
-- Adds "companion" as a new cosmetic category -- an illustrated pet
-- standing beside the Abt Lord. Takes the Wardrobe slot that 'cape'
-- used to occupy (cape stays in the data model, still excluded from
-- the UI/render composition, untouched by this migration). No RLS/
-- RPC changes needed -- equip_abt_item() already resolves the target
-- column generically via `p_category || '_item_id'`.
--
-- Elien illustrated 8 standard companions (a royal cat, a black cat,
-- a golden retriever, a german shepherd, a baby goat, a lamb, a
-- donkey, and a pony), all available from day one, plus a "No
-- Companion" default matching every other category's none option.
--
-- Run this once in the Supabase SQL Editor, after 0028.
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
  check (category in ('hair','headwear','armor','cape','companion','weapon','accessory','body'));

alter table public.abt_avatar_loadouts add column if not exists companion_item_id uuid references public.abt_cosmetic_items(id);

insert into public.abt_cosmetic_items (name, flavor_text, category, rarity, unlock_type, asset_key) values
  ('No Companion', 'Reigning alone. Bold choice.', 'companion', 'standard', 'standard', 'companion.none'),
  ('Royal Cat', 'Crowned, unbothered, technically outranks you.', 'companion', 'standard', 'standard', 'companion.royal_cat'),
  ('Black Cat', 'Bad luck for everyone except the Abt Lord.', 'companion', 'standard', 'standard', 'companion.black_cat'),
  ('Golden Retriever', 'Guards the throne. Mostly guards the fridge.', 'companion', 'standard', 'standard', 'companion.golden_retriever'),
  ('German Shepherd', 'Official Captain of the Royal Guard.', 'companion', 'standard', 'standard', 'companion.german_shepherd'),
  ('Baby Goat', 'Snacks on the hedge accessory when nobody''s looking.', 'companion', 'standard', 'standard', 'companion.baby_goat'),
  ('Lamb', 'Soft, loyal, occasionally mistaken for foam.', 'companion', 'standard', 'standard', 'companion.lamb'),
  ('Royal Donkey', 'Carries the good beer. Never complains.', 'companion', 'standard', 'standard', 'companion.donkey'),
  ('Royal Pony', 'Saddled up for absolutely no reason.', 'companion', 'standard', 'standard', 'companion.pony');
