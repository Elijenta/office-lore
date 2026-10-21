import sys, glob, os, re, shutil, psycopg2
import pixeltable_pgserver as pgserver
SUPA = "/Users/elijenta/Documents/Office Lore/supabase"
DATA = "/tmp/s/pg/data"
def server(fresh=False):
    if fresh and os.path.exists(DATA): shutil.rmtree(DATA)
    os.makedirs(DATA, exist_ok=True)
    return pgserver.get_server(DATA)
def conn(srv):
    c = psycopg2.connect(srv.get_uri()); c.autocommit = True; return c
STUBS = """
create role anon nologin; create role authenticated nologin; create role service_role nologin;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}', created_at timestamptz default now());
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create or replace function auth.role() returns text language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'authenticated') $$;
create publication supabase_realtime;
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
insert into auth.users (id, email) values
 ('b064ee54-08c8-4d80-863a-b75d6a46b523', 'elien@officelore.app'),
 ('3a5ad158-62db-4852-90b4-e1034adf894d', 'nick@officelore.app'),
 ('809714bc-e4c4-4628-b624-94a2803d16de', 'atti@officelore.app');
"""
def run_file(cur, path):
    sql = open(path).read()
    sql = sql.replace('create extension if not exists pgcrypto;', '')
    cur.execute(sql)
if __name__ == '__main__':
    srv = server(fresh=True); c = conn(srv); cur = c.cursor()
    # stubs before 0001 (profiles refs auth.users); users inserted after the handle_new_user trigger exists -> do in two steps
    cur.execute(STUBS.split("insert into auth.users")[0])
    files = sorted(f for f in glob.glob(SUPA + '/00[0-9][0-9]_*.sql'))
    for f in files:
        name = os.path.basename(f)
        if name.startswith('0001'):
            run_file(cur, f)
            cur.execute("insert into auth.users (id, email) values " + STUBS.split("values")[1])
            continue
        if name.startswith('0002'): continue   # demo seed: fixtures come from fixtures.sql
        try:
            run_file(cur, f); print('applied', name)
        except Exception as e:
            print('FAILED', name, str(e)[:600]); break
    print('URI', srv.get_uri())
