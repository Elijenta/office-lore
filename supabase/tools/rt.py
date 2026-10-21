import sys, glob, os
sys.path.insert(0,'/tmp/s')
import harness
srv = harness.server(); c = harness.conn(srv); cur = c.cursor()
def run(path, quiet=False):
    sql = open(path).read().replace('create extension if not exists pgcrypto;','')
    try:
        cur.execute(sql); return 'done (no exception)'
    except Exception as e:
        return (getattr(e,'pgerror',None) or str(e))
if __name__ == '__main__':
    for p in sys.argv[1:]:
        print('=====', os.path.basename(p)); print(run(p)[:7000])
