"""Builds gambit/index.csv: file,id,op,line,func,orig,mut  (line-level diff vs the pristine source)."""
import json, os, csv, re, difflib
S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
G = os.path.join(S, 'gen')
rows = []
for f in sorted(os.listdir(os.path.join(S, 'gambit'))):
    d = os.path.join(S, 'gambit', f)
    if not os.path.isdir(d):
        continue
    orig = open(os.path.join(G, 'src', 'gains', f + '.sol'), encoding='utf-8', newline='').read().replace('\r\n', '\n').split('\n')
    # function containing each line
    func = []
    cur = ''
    for l in orig:
        m = re.match(r'\s*(function|constructor|modifier)\s*(\w*)', l)
        if m:
            cur = m.group(2) or m.group(1)
        func.append(cur)
    res = json.load(open(os.path.join(d, 'gambit_results.json'), encoding='utf-8'))
    for r in res:
        mp = os.path.join(d, r['name'])
        mut = open(mp, encoding='utf-8', newline='').read().replace('\r\n', '\n').split('\n')
        sm = difflib.SequenceMatcher(a=orig, b=mut, autojunk=False)
        ln, o, n = None, [], []
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag != 'equal':
                ln = ln or i1 + 1
                o += orig[i1:i2]
                n += mut[j1:j2]
        # gambit adds a "/// XxxMutation(...) of: ..." comment line; drop it from the new side
        n = [x for x in n if not x.strip().startswith('/// ') or 'Mutation(' not in x]
        rows.append({'file': f, 'id': r['id'], 'op': r['description'], 'line': ln or 0, 'func': func[(ln or 1) - 1],
                     'orig': ' | '.join(x.strip() for x in o)[:300], 'mut': ' | '.join(x.strip() for x in n)[:300],
                     'path': os.path.relpath(mp, S).replace('\\', '/')})
with open(os.path.join(S, 'gambit', 'index.csv'), 'w', newline='', encoding='utf-8') as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)
print(len(rows))
import collections
print(collections.Counter(r['op'] for r in rows))
