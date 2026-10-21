import sys, threading, json
sys.path.insert(0,'/tmp/s')
import harness, psycopg2
srv = harness.server()
URI = srv.get_uri()
ELIEN='b064ee54-08c8-4d80-863a-b75d6a46b523'; NICK='3a5ad158-62db-4852-90b4-e1034adf894d'; ATTI='809714bc-e4c4-4628-b624-94a2803d16de'
def conn():
    c = psycopg2.connect(URI); c.autocommit = True; return c
def as_user(c, uid):
    cur = c.cursor(); cur.execute("select set_config('request.jwt.claim.sub', %s, false)", (uid,)); return cur
admin = conn().cursor()
def q(sql, args=None):
    admin.execute(sql, args); 
    try: return admin.fetchall()
    except Exception: return None
def race(n, uid, sql, args=None):
    out=[None]*n; errs=[None]*n; bar=threading.Barrier(n)
    def work(i):
        c=conn(); cur=as_user(c, uid)
        try:
            bar.wait(); cur.execute(sql, args); r=cur.fetchall(); out[i]=r[0][0] if r else None
        except Exception as e: errs[i]=(e.pgerror or str(e)).strip().split('\n')[0]
        finally: c.close()
    ts=[threading.Thread(target=work,args=(i,)) for i in range(n)]
    [t.start() for t in ts]; [t.join() for t in ts]
    return out, errs
report=[]
def check(name, ok, detail=''):
    report.append(('PASS' if ok else 'FAIL', name, detail)); print(report[-1])

# clean slate (committed fixtures only; this DB is a throwaway copy)
q("delete from public.challenge_assignments"); q("delete from public.gauntlet_fragments"); q("delete from public.royal_gauntlet_balances"); q("delete from public.mystery_boxes"); q("delete from public.gauntlet_fragment_log")
q("delete from public.challenge_sweeps"); q("delete from public.group_daily_rounds")
q("update public.challenge_config set value = value || '{\"weekly_fragment_cap\": 1000}'::jsonb where key='gauntlet_rules'")

# 1. parallel claims of ONE completed assignment (double click / two tabs / realtime echo)
q("""insert into public.challenge_assignments (app_id, definition_id, user_id, type, category, title, description, difficulty, event_type, reward, target, progress, period_key, starts_at, expires_at, status, completed_at)
     values ('officelore','pd_quote_hunter',%s,'personal_daily','lore','T','d','easy','quote_added','{"lines":[{"kind":"player_xp","amount":10},{"kind":"gauntlet_fragments","amount":2},{"kind":"mystery","amount":1}]}',1,1,'RACE1',now()-interval '1 hour',now()+interval '5 hours','completed',now())""",(ATTI,))
aid=q("select id from public.challenge_assignments where period_key='RACE1'")[0][0]
out,errs=race(12, ATTI, "select public.claim_challenge(%s)::text", (str(aid),))
st=[json.loads(o)['status'] for o in out if o]
check('12 parallel claims of one reward: exactly one pays', st.count('claimed')==1 and st.count('already_claimed')==11 and not any(errs), f'{st.count("claimed")} claimed, {st.count("already_claimed")} already, errors={[e for e in errs if e]}')
check('  fragments paid once', q("select fragments from public.gauntlet_fragments where user_id=%s",(ATTI,))[0][0]==2)
check('  XP grant once, one Mystery box', q("select count(*) from public.challenge_reward_grants where assignment_id=%s and kind='player_xp'",(aid,))[0][0]==1 and q("select count(*) from public.mystery_boxes where user_id=%s",(ATTI,))[0][0]==1)

# 2. parallel opening of one box
bid=q("select id from public.mystery_boxes where user_id=%s",(ATTI,))[0][0]
out,errs=race(10, ATTI, "select public.open_mystery_box(%s)::text", (str(bid),))
prizes={json.dumps(json.loads(o)['prize'],sort_keys=True) for o in out if o}
sts=[json.loads(o)['status'] for o in out if o]
check('10 parallel opens of one box: one prize, one payment', len(prizes)==1 and sts.count('opened')==1 and not any(errs), f'{sts.count("opened")} opened, {len(prizes)} distinct prizes, errs={[e for e in errs if e]}')

# 3. parallel ensure (reload / second tab / two users at once) -> no duplicates, no errors
q("delete from public.challenge_assignments")
errs_all=[]
for uid in (ELIEN,NICK,ATTI):
    o,e=race(6, uid, "select public.ensure_challenge_assignments()::text"); errs_all+= [x for x in e if x]
check('parallel ensure from 3 users x 6 tabs: no errors', not errs_all, str(errs_all[:3]))
dups=q("select count(*) from (select definition_id, coalesce(user_id::text,'g'), period_key, count(*) from public.challenge_assignments group by 1,2,3 having count(*)>1) x")[0][0]
check('  no duplicate assignments', dups==0)
check('  exactly 3 dailies per member, 1 shared Group Daily', all(q("select count(*) from public.challenge_assignments where user_id=%s and type='personal_daily'",(u,))[0][0]==3 for u in (ELIEN,NICK,ATTI)) and q("select count(*) from public.challenge_assignments where type='group_daily'")[0][0]==1)
check('  one participant set per Group Weekly quest, full', all(c==3 for (c,) in q("select (select count(*) from public.challenge_member_progress mp where mp.assignment_id=a.id) from public.challenge_assignments a where a.type='group_weekly'")))

# 4. group daily: parallel entries by the same user, parallel votes
o,e=race(1, ELIEN, "select public.get_group_daily()::text")
gd=json.loads(o[0])['current']; rid=gd['id']; kind=gd['kind']; print('group daily kind:', kind)
if kind in ('nickname','poetry','emoji'):
    payload={'nickname':{'text':'Racecar Rex'},'poetry':{'text':'Roses are red the coffee is cold the stapler is lost and the meeting is old'},'emoji':{'emoji':'🍺👑'}}[kind]
    o,e=race(8, ELIEN, "select public.submit_group_entry(%s, %s::jsonb, null)::text", (rid, json.dumps(payload)))
    check('8 parallel entries by one member: exactly one entry', q("select count(*) from public.group_daily_entries where round_id=%s and user_id=%s",(rid,ELIEN))[0][0]==1 and sum(1 for x in o if x)==1, f'ok={sum(1 for x in o if x)} errs={len([x for x in e if x])}')
    o,e=race(1, NICK, "select public.submit_group_entry(%s, %s::jsonb, null)::text", (rid, json.dumps({'nickname':{'text':'Other Name'},'poetry':{'text':'Another poem about the printer that jams on every single Monday morning'},'emoji':{'emoji':'🎉🔥'}}[kind])))
    eid=q("select id from public.group_daily_entries where round_id=%s and user_id=%s",(rid,NICK))[0][0]
    o,e=race(8, ELIEN, "select public.vote_group_entry(%s, %s)::text", (rid, str(eid)))
    check('8 parallel votes by one member: exactly one counts', q("select count(*) from public.group_daily_votes where round_id=%s and voter_id=%s",(rid,ELIEN))[0][0]==1 and q("select vote_count from public.group_daily_rounds where id=%s",(rid,))[0][0]==1, f'ok={sum(1 for x in o if x)}')
    # participation claim race
    aid=q("select assignment_id from public.group_daily_rounds where id=%s",(rid,))[0][0]
    o,e=race(8, ELIEN, "select public.claim_challenge(%s)::text", (str(aid),))
    st=[json.loads(x)['status'] for x in o if x]
    check('8 parallel participation claims: one pays', st.count('claimed')==1)
    # winner claim race after the day ends
    q("update public.group_daily_rounds set ends_at=now()-interval '1 minute' where id=%s",(rid,)); q("update public.challenge_assignments set expires_at=now()-interval '1 minute' where id=%s",(aid,))
    race(1, NICK, "select public.get_group_daily()::text")
    w=q("select user_id from public.group_daily_winners where round_id=%s",(rid,))
    if w:
        wu=str(w[0][0]); o,e=race(8, wu, "select public.claim_group_winner(%s)::text", (rid,))
        st=[json.loads(x)['status'] for x in o if x]
        check('8 parallel winner claims: one pays', st.count('claimed')==1 and not any(e), str(st))
    else: check('winner exists after the end (1 vote)', False)

if kind == 'quiz':
    race(1, ELIEN, "select public.start_group_quiz(%s)::text", (rid,))
    ans=json.dumps(q("select answers from public.group_daily_secrets where round_id=%s",(rid,))[0][0])
    o,e=race(8, ELIEN, "select public.submit_group_quiz(%s, %s::jsonb)::text", (rid, ans))
    check('8 parallel quiz hand-ins by one member: exactly one entry and one participation', q("select count(*) from public.group_daily_entries where round_id=%s and user_id=%s",(rid,ELIEN))[0][0]==1 and sum(1 for x in o if x)==1, f'ok={sum(1 for x in o if x)}')
    aid=q("select assignment_id from public.group_daily_rounds where id=%s",(rid,))[0][0]
    o,e=race(8, ELIEN, "select public.claim_challenge(%s)::text", (str(aid),))
    st=[json.loads(x)['status'] for x in o if x]
    check('8 parallel participation claims (quiz round): one pays', st.count('claimed')==1, str(st))

# 5. parallel fragment grants: 20 distinct reward lines at once -> weekly cap holds, no lost update
q("delete from public.gauntlet_fragments"); q("delete from public.royal_gauntlet_balances"); q("delete from public.gauntlet_fragment_log"); q("delete from public.royal_gauntlet_ledger where reason='fragment_convert'")
q("update public.challenge_config set value = value || '{\"weekly_fragment_cap\": 6}'::jsonb where key='gauntlet_rules'")
out,errs=race(20, NICK, "select public._add_fragments(%s, 1)::text", (NICK,)) if False else (None,None)
# _add_fragments is internal (not callable by clients): drive it as the owner role in threads
def add_frag(i, bar, res):
    c=conn(); cur=c.cursor()
    try:
        bar.wait(); cur.execute("select (public._add_fragments(%s, 1)->>'stored')::int", (NICK,)); res[i]=cur.fetchone()[0]
    except Exception as ex: res[i]=str(ex)[:80]
    finally: c.close()
res=[None]*20; bar=threading.Barrier(20); ts=[threading.Thread(target=add_frag,args=(i,bar,res)) for i in range(20)]
[t.start() for t in ts]; [t.join() for t in ts]
stored=sum(r for r in res if isinstance(r,int))
f=q("select fragments from public.gauntlet_fragments where user_id=%s",(NICK,))[0][0]; b=q("select balance from public.royal_gauntlet_balances where user_id=%s",(NICK,))[0][0]
check('20 parallel fragment grants: weekly cap 6 holds exactly', stored==6 and f+5*b==6 and b<=2, f'stored={stored} fragments={f} gauntlets={b} errs={[r for r in res if not isinstance(r,int)][:2]}')
print(); print(sum(1 for r in report if r[0]=='PASS'), 'PASS', sum(1 for r in report if r[0]=='FAIL'), 'FAIL')
