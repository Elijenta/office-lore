"""Builds the DEV bundle: every migration in order, cut into a few files that fit in the Supabase SQL editor.
  python3 build_dev_bundle.py      ->  supabase/dev/dev_1_*.sql ... (paste them in order into a NEW, EMPTY Supabase dev project)
0002 (demo seed) is not part of it: use dev_seed.sql after you have created the 3 dev accounts."""
import glob, os
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
OUT = os.path.join(ROOT, 'dev')
os.makedirs(OUT, exist_ok=True)
for old in glob.glob(os.path.join(OUT, 'dev_[0-9]_*.sql')): os.remove(old)
files = sorted(f for f in glob.glob(os.path.join(ROOT, '0[0-9][0-9][0-9]_*.sql')) if not os.path.basename(f).startswith('0002'))
LIMIT = 230_000
parts, cur, size = [], [], 0
for f in files:
    n = os.path.getsize(f)
    if cur and size + n > LIMIT: parts.append(cur); cur, size = [], 0
    cur.append(f); size += n
if cur: parts.append(cur)
for i, part in enumerate(parts, 1):
    first, last = os.path.basename(part[0])[:4], os.path.basename(part[-1])[:4]
    name = f'dev_{i}_{first}-{last}.sql'
    with open(os.path.join(OUT, name), 'w', encoding='utf-8') as out:
        out.write(f'-- DEV bundle part {i}/{len(parts)}: migrations {first} to {last}. Run the parts in order, each once, in a NEW empty Supabase project (never in production).\n')
        for f in part:
            out.write(f'\n-- =========== {os.path.basename(f)} ===========\n')
            sql = open(f, encoding='utf-8').read().rstrip()
            if os.path.basename(f).startswith('0015'):
                # production backfills 3 fixed user ids; a fresh dev project does not have those users, so only insert the ones that exist
                old = sql[sql.index("insert into public.app_memberships (app_id, user_id) values"):sql.index("on conflict (app_id, user_id) do nothing;") + len("on conflict (app_id, user_id) do nothing;")]
                new = "insert into public.app_memberships (app_id, user_id) select 'officelore', u.id from auth.users u where u.id in ('b064ee54-08c8-4d80-863a-b75d6a46b523', '3a5ad158-62db-4852-90b4-e1034adf894d', '809714bc-e4c4-4628-b624-94a2803d16de') on conflict (app_id, user_id) do nothing;"
                sql = sql.replace(old, new, 1)
            out.write(sql + '\n')
    print(name, sum(os.path.getsize(f) for f in part) // 1024, 'KB')
