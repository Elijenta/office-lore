import sys, glob, json, re
import pglast
from pglast import parse_sql, parse_plpgsql
files = sorted(glob.glob('00[45][0-9]_*.sql')) + sorted(glob.glob('tests/*.sql'))
bad = 0
for f in files:
    txt = open(f).read()
    try:
        stmts = parse_sql(txt)
    except Exception as e:
        print('SQL SYNTAX ERROR', f, str(e)[:300]); bad += 1; continue
    # plpgsql bodies
    n = 0
    for st in stmts:
        node = st.stmt
        name = type(node).__name__
        if name == 'CreateFunctionStmt':
            lang = None; body = None
            for o in node.options:
                if o.defname == 'language': lang = o.arg.sval
                if o.defname == 'as': body = o.arg[0].sval
            if lang == 'plpgsql' and body:
                try:
                    parse_plpgsql(txt[st.stmt_location:st.stmt_location + (st.stmt_len or len(txt))])
                    n += 1
                except Exception as e:
                    print('PLPGSQL ERROR', f, [x.sval for x in node.funcname][-1], str(e)[:300]); bad += 1
        if name == 'DoStmt':
            for a in node.args:
                if a.defname == 'as':
                    try:
                        parse_plpgsql('create function _x() returns void as $b$' + a.arg.sval + '$b$ language plpgsql')
                    except Exception as e:
                        print('DO ERROR', f, str(e)[:300]); bad += 1
    print('ok', f, len(stmts), 'stmts', n, 'plpgsql fns')
print('BAD', bad)
