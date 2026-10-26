# Furniture for Mijn Hoekje

A new desk (or later another piece of furniture) takes two steps:

1. **The picture.** Put a PNG in `furniture-images/desk/` named after the id of the new look, e.g. `desk-pirate.png`.
   - Make it 1120 x 880 px (the room's desk box is 28:22). It is NOT cropped: the whole image fills the box, anchored bottom-centre.
   - Keep the top ~15% of the image free of important detail: the gold nameplate (name + title) floats there.
   - Then run: `python3 supabase/tools/build_furniture_images.py`
2. **The row.** In the Supabase SQL editor (the desk only shows up once its row AND its picture exist):

```sql
insert into public.room_furniture_items (id, slot, name, tag, rarity, sources, pity_after, hint, sort_order, is_starter) values
  ('desk-pirate', 'desk', 'Piratenbureau', '🏴‍☠️ Schatkaart', 'rare',
   '[{"def":"pw_adventurer","chance":0.10},{"def":"rb_storm","chance":0.08}]'::jsonb, 20,
   'Drops from the adventure quests and Rebellions.', 50, false)
on conflict (id) do update set name = excluded.name, tag = excluded.tag, rarity = excluded.rarity, sources = excluded.sources,
  pity_after = excluded.pity_after, hint = excluded.hint, sort_order = excluded.sort_order;
```

- `sources` = which quest definitions can drop it, with a chance per claim; `pity_after` = guaranteed after that many claims of those quests (null = no guarantee).
- Mystery Rewards can also contain any look that is not a starter.
- Better to keep it in a migration file (e.g. `0089_more_desks.sql`) so the dev bundle stays complete.
