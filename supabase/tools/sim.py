import sys, random, json, statistics
sys.path.insert(0,'/tmp/s')
import harness, psycopg2
srv = harness.server()
URI = srv.get_uri()
ELIEN='b064ee54-08c8-4d80-863a-b75d6a46b523'; NICK='3a5ad158-62db-4852-90b4-e1034adf894d'; ATTI='809714bc-e4c4-4628-b624-94a2803d16de'
USERS=[ATTI, NICK]            # Elien holds the throne in the fixtures
PROFILES={
 'normal':      dict(d={'easy':.8,'normal':.6,'hard':.3,'special':.25}, w_normal=.5, w_big=.25, group=.35, reb=.45, days_active=.8),
 'very active': dict(d={'easy':.98,'normal':.9,'hard':.7,'special':.6}, w_normal=.9, w_big=.6, group=.75, reb=.85, days_active=1.0),
}
WEEKS=int(sys.argv[1]) if len(sys.argv)>1 else 8
RUNS=int(sys.argv[2]) if len(sys.argv)>2 else 5
cap_override = sys.argv[3] if len(sys.argv)>3 else None

def run(profile, seed):
    rnd=random.Random(seed); P=PROFILES[profile]
    c=psycopg2.connect(URI); c.autocommit=False; cur=c.cursor()
    def q(sql,args=None):
        cur.execute(sql,args)
        try: return cur.fetchall()
        except Exception: return None
    def as_user(u): cur.execute("select set_config('request.jwt.claim.sub', %s, true)", (u,))
    q("update public.challenge_features set enabled=false")
    for t in ['challenge_assignments','gauntlet_fragments','royal_gauntlet_balances','mystery_boxes','challenge_sweeps','gauntlet_fragment_log','group_daily_rounds','rebellion_rewards']:
        q(f"delete from public.{t}")
    q("delete from public.royal_gauntlet_ledger where reason='fragment_convert'")
    if cap_override: q("update public.challenge_config set value = value || %s::jsonb where key='gauntlet_rules'", (json.dumps({'weekly_fragment_cap': int(cap_override)}),))
    forged={u:0 for u in USERS}; frag_src={'dailies':0,'weeklies':0,'group':0,'rebellion':0,'mystery_box':0,'sweep/other':0}
    seen_forges=0
    for day in range(WEEKS*7):
        t=f"now() + interval '{day} days'"
        for u in USERS:
            q(f"select public._ensure_challenge_assignments_for(%s, {t})", (u,))
        dkey=q(f"select to_char(({t}) at time zone 'Europe/Brussels','YYYY-MM-DD'), extract(isodow from ({t}) at time zone 'Europe/Brussels')::int, to_char(({t}) at time zone 'Europe/Brussels','IYYY-\"W\"IW')")[0]
        dayk, isodow, wkey = dkey
        for u in USERS:
            as_user(u)
            if rnd.random() <= P['days_active']:
                for aid,diff in q("select id, difficulty from public.challenge_assignments where user_id=%s and type='personal_daily' and period_key=%s and status='active'",(u,dayk)):
                    if rnd.random() < P['d'][diff]:
                        q("update public.challenge_assignments set progress=target, status='completed', completed_at=now() where id=%s",(aid,))
                        q("select public._after_personal_daily_completed(%s,%s,%s)",(u,aid,dayk))
                        q("select public.claim_challenge(%s)",(aid,))
                for (sid,) in q("select id from public.challenge_sweeps where user_id=%s and claimed_at is null",(u,)):
                    q("select public.claim_daily_sweep(%s)",(sid,))
            for (bid,) in q("select id from public.mystery_boxes where user_id=%s and status='unopened'",(u,)):
                q("select public.open_mystery_box(%s)",(bid,))
        if isodow==7:   # the week ends: weeklies, group quests, rebellion
            for u in USERS:
                as_user(u)
                for aid,typ,tier in q("select a.id, a.type, coalesce(a.payload->>'tier','normal') from public.challenge_assignments a where a.user_id=%s and a.type in ('personal_weekly','rebellion') and a.period_key=%s and a.status='active'",(u,wkey)):
                    p = P['reb'] if typ=='rebellion' else (P['w_big'] if tier=='big' else P['w_normal'])
                    if rnd.random()<p:
                        q("update public.challenge_assignments set progress=target, status='completed', completed_at=now() where id=%s",(aid,))
                        q("select public.claim_challenge(%s)",(aid,))
            for aid, in q("select id from public.challenge_assignments where user_id is null and type='group_weekly' and period_key=%s and status='active'",(wkey,)):
                if rnd.random()<P['group']:
                    q("update public.challenge_assignments set progress=target, status='completed', completed_at=now() where id=%s",(aid,))
                    for u in USERS:
                        as_user(u); q("select public.claim_challenge(%s)",(aid,))
        # a Gauntlet is spent as soon as it exists (we measure the earning speed)
        for u in USERS:
            n=q("select count(*) from public.royal_gauntlet_ledger where user_id=%s and reason='fragment_convert'",(u,))[0][0]
            forged[u]=n
        q("delete from public.royal_gauntlet_balances")
        if isodow==7:   # next simulated week: the weekly allowance starts fresh
            q("update public.gauntlet_fragment_log set created_at = created_at - interval '8 days'")
            q("update public.mystery_boxes set opened_at = opened_at - interval '8 days' where opened_at is not null")
    # fragments by source (grants) + mystery
    for typ,key in [('personal_daily','dailies'),('personal_weekly','weeklies'),('group_weekly','group'),('rebellion','rebellion')]:
        frag_src[key]=q("select coalesce(sum(g.amount),0) from public.challenge_reward_grants g join public.challenge_assignments a on a.id=g.assignment_id where g.kind='gauntlet_fragments' and g.status='applied' and a.type=%s",(typ,))[0][0]
    frag_src['mystery_box']=q("select count(*) from public.mystery_boxes where prize->>'type'='fragment'")[0][0]
    stored=q("select coalesce(sum(amount),0) from public.gauntlet_fragment_log")[0][0]
    c.rollback(); c.close()
    wk=WEEKS
    return dict(gauntlets_per_user_week=sum(forged.values())/len(USERS)/wk, stored_per_user_week=stored/len(USERS)/wk,
                src={k:v/len(USERS)/wk for k,v in frag_src.items()})
for prof in PROFILES:
    res=[run(prof, s) for s in range(RUNS)]
    g=[r['gauntlets_per_user_week'] for r in res]; f=[r['stored_per_user_week'] for r in res]
    src={k:statistics.mean(r['src'][k] for r in res) for k in res[0]['src']}
    print(f"{prof:12s} gauntlets/week {statistics.mean(g):.2f} (1 per {1/max(statistics.mean(g),0.01):.1f} wk)  fragments stored/week {statistics.mean(f):.1f}  offered by source/week: " + ', '.join(f'{k} {v:.1f}' for k,v in src.items()))
