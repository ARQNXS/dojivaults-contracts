"""Limited sample (lead's rule, run capped at ~3 h) -> gambit/selection3.csv.
Files: GainsNav, GainsPrice, GainsVaultPolicy, GainsVaultLogic (settle, fees, reduce, exits), GainsVaultFactory (roles,
curation). Only mutants inside the listed functions; seeded (7) round-robin over distinct lines up to the budget.
Mutants of these functions already run (earlier runs) are kept and count toward the budget."""
import csv, os, random, collections, re
S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEC = {
    'GainsNav': ({'snapshot', 'tradeValue', '_nearLiquidation', '_closingPrice', 'minGovFee', 'totalTradeFeesRaw', 'pnlPercent',
                  'priceAfterImpact', 'tradeValuePure', '_price', 'fixedSpreadP'}, 25),
    'GainsPrice': ({'read', 'checkSequencer', 'adverse', '_latest'}, 20),
    'GainsVaultPolicy': ({'checkOrder', 'nextCheckpoint', 'proposeConfig', 'applyPendingConfig', 'queueAllowAsset', 'allowAsset',
                          'setPairFeed', 'proposeTimelockDelay', 'applyTimelockDelay', '_checkEta', '_allow', '_checkNavBound',
                          '_validate', '_isTighter', 'navBoundLeverageBps', 'flattenSlippage'}, 20),
    'GainsVaultLogic': ({'settle', '_accrueFees', 'reduceTrade', 'requestRedeem', 'cancelRedeemRequest', 'claim', '_claimIfSettled',
                         '_mayExit', 'flatten'}, 30),
    'GainsVaultFactory': ({'create', 'registerPlatformAgent', 'unregisterPlatformAgent', '_checkRoles', 'setGuardian', 'setSentinel',
                           'setAgentRegistrar', 'transferOwnership', 'setAssetCurated'}, 15),
}
rows = list(csv.DictReader(open(os.path.join(S, 'gambit', 'index.csv'), encoding='utf-8')))
done = {(r['file'], r['id']) for r in csv.DictReader(open(os.path.join(S, 'gambit', 'results.csv'), encoding='utf-8'))}
# function line ranges for the report
ranges = {}
for f in SEC:
    src = open(os.path.join(S, 'gen', 'src', 'gains', f + '.sol'), encoding='utf-8').read().replace('\r\n', '\n').split('\n')
    cur, start = None, 0
    for i, l in enumerate(src, 1):
        m = re.match(r'\s*(function|constructor)\s*(\w*)', l)
        if m:
            if cur:
                ranges.setdefault(f, []).append((cur, start, i - 1))
            cur, start = m.group(2) or 'constructor', i
    ranges.setdefault(f, []).append((cur, start, len(src)))
rng = random.Random(7)
sel = []
report = []
for f, (funcs, budget) in SEC.items():
    rs = [r for r in rows if r['file'] == f and r['func'] in funcs]
    pre = [r for r in rs if (r['file'], r['id']) in done]
    rest = [r for r in rs if (r['file'], r['id']) not in done]
    lines = collections.OrderedDict()
    for r in rest:
        lines.setdefault(r['line'], []).append(r)
    for v in lines.values():
        rng.shuffle(v)
    order = list(lines)
    rng.shuffle(order)
    picked = list(pre[:budget])
    b = min(budget, len(rs))
    rnd = 0
    while len(picked) < b:
        for ln in order:
            if rnd < len(lines[ln]) and len(picked) < b:
                picked.append(lines[ln][rnd])
        rnd += 1
    fr = ', '.join(f'{n} ({a}-{z})' for n, a, z in ranges[f] if n in funcs)
    report.append(f'| {f} | {sum(1 for r in rows if r["file"] == f)} | {len(rs)} | {len(picked)} | {fr} |')
    print(f, 'eligible', len(rs), 'picked', len(picked), 'pre', len(pre))
    sel += picked
rng.shuffle(sel)
with open(os.path.join(S, 'gambit', 'selection3.csv'), 'w', newline='', encoding='utf-8') as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(sel)
open(os.path.join(S, 'gambit', 'sample3.md'), 'w', encoding='utf-8').write('\n'.join(report))
print('total', len(sel), 'to run', sum(1 for r in sel if (r['file'], r['id']) not in done))
