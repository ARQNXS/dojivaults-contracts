"""MUTATION.md + mutation-results.csv for the limited sample (selection3)."""
import csv, os, json, collections
S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = r'<worktree>\contracts\audit\gains\tools'
rd = lambda p: list(csv.DictReader(open(os.path.join(S, 'gambit', p), encoding='utf-8')))
idx = rd('index.csv')
sel = [(r['file'], r['id']) for r in rd('selection3.csv')]
sset = set(sel)
before = {(r['file'], r['id']): r for r in rd('results.csv') if (r['file'], r['id']) in sset}
after_over = {(r['file'], r['id']): r for r in rd('results-after.csv')}
after = dict(before)
after.update({k: v for k, v in after_over.items() if k in sset})
ann = json.load(open(os.path.join(S, 'survivors.json'), encoding='utf-8'))
FILES = ['GainsNav', 'GainsPrice', 'GainsVaultPolicy', 'GainsVaultLogic', 'GainsVaultFactory']
gen = collections.Counter(r['file'] for r in idx)
nsel = collections.Counter(f for f, _ in sel)

def table(res):
    st = collections.defaultdict(collections.Counter)
    for (f, _), r in res.items():
        st[f][r['status']] += 1
    out = ['| file | generated | sampled | compile-fail | killed | survived | timeout | score killed / (killed + survived) |',
           '| --- | --- | --- | --- | --- | --- | --- | --- |']
    t = collections.Counter()
    for f in FILES:
        c = st[f]
        k, s = c['killed'], c['survived']
        out.append(f"| {f} | {gen[f]} | {nsel[f]} | {c['compile-fail']} | {k} | {s} | {c['timeout']} | {k}/{k + s} = {100 * k / max(k + s, 1):.1f}% |")
        for x in ('killed', 'survived', 'timeout', 'compile-fail'):
            t[x] += c[x]
    k, s = t['killed'], t['survived']
    out.append(f"| **total** | **{sum(gen[f] for f in FILES)}** | **{len(sel)}** | **{t['compile-fail']}** | **{k}** | **{s}** | **{t['timeout']}** | **{k}/{k + s} = {100 * k / (k + s):.1f}%** |")
    return '\n'.join(out), t

tb, t0 = table(before)
ta, t1 = table(after)
sample = open(os.path.join(S, 'gambit', 'sample3.md'), encoding='utf-8').read()
rows = []
for key in sorted({k for k, r in before.items() if r['status'] == 'survived'}, key=lambda k: (FILES.index(k[0]), int(before[k]['line']))):
    r = before[key]
    a = ann[f'{key[0]}#{key[1]}']
    fin = after[key]['status']
    rows.append(f"| {r['file']}.sol:{r['line']} `{r['func']}` | {key[0]}#{key[1]} | {r['op']} | `{r['orig'].replace('|', '&#124;')}` | `{r['mut'].replace('|', '&#124;')}` | {fin} | {a['class']} | {a['why'].replace('|', '&#124;')} |")
fields = ['file', 'id', 'op', 'line', 'func', 'status', 'secs', 'failed_test', 'orig', 'mut']
with open(os.path.join(T, 'mutation-results.csv'), 'w', newline='', encoding='utf-8') as fh:
    w = csv.DictWriter(fh, fieldnames=fields + ['status_before_accessmatrix_fix'])
    w.writeheader()
    for key in sorted(sset, key=lambda k: (k[0], int(k[1]))):
        r = dict(after[key])
        r['status_before_accessmatrix_fix'] = before[key]['status']
        w.writerow({k: r[k] for k in fields + ['status_before_accessmatrix_fix']})
md = f"""# Mutation testing, Gains round 1 (limited sample)

Tool: Gambit (Certora, tag v1.0.6), all default operators (binary-op, assignment, if-statement, delete-expression,
swap-arguments, unary-op). Tree: audit/gains-r1 (9f39013). Raw per-mutant results for the sample: `mutation-results.csv`
(next to this file; `status` is final, `status_before_accessmatrix_fix` is the first run). Harness scripts:
`mutation/` (fast_tests.py, run_mutants.py, select3.py, index_mutants.py, gen-mutants.sh, mk-harness.sh,
foundry.mutation.toml) and the test patch `mutation/deploycode.patch`.

**The run is limited** (lead's rule: cap at ~3 h; only security-relevant lines of GainsNav, GainsPrice,
GainsVaultPolicy, GainsVaultLogic (settle, fees, reduce, exits) and GainsVaultFactory (roles, curation)).
Gambit generated **8,493 mutants** over all 11 src/gains files (GainsNav 571, GainsPrice 299, GainsVaultLogic 2,379,
GainsVaultMath 561, GainsVaultGovernance 1,514, GainsVaultPolicy 1,134, GainsVaultFactory 944, GainsVault 163,
GainsVaultLens 870, GainsTypes 27, IGainsDiamond 31); **{len(sel)} were sampled** and run. GainsVaultMath,
GainsVaultGovernance, GainsVault, GainsVaultLens, GainsTypes and IGainsDiamond are NOT in the scored sample.

## Result

Final score on the sample: **{t1['killed']} killed, {t1['survived']} survived, {t1['compile-fail']} compile-fail ->
{t1['killed']}/{t1['killed'] + t1['survived']} = {100 * t1['killed'] / (t1['killed'] + t1['survived']):.1f}%**
(score = killed / (killed + survived), compile-fails excluded). No surviving mutant shows a bug in the contracts.
Mutation testing found one bug **in a test**: test/audit/gains/AccessMatrix.t.sol could never fail (below). It was
fixed by the lead during this run; the score before and after the fix is shown separately.

### Final (with the fixed AccessMatrix.t.sol)

{ta}

### Before the AccessMatrix fix (first run)

{tb}

Differences: GainsVaultLogic#2009 survived -> killed (AccessMatrix fix); GainsVaultLogic#779 was a timeout (> 1,200 s
under the heavily loaded first run, original test harness) and was re-run: killed in 92 s
(test_DUSTCHECKPOINT_oneUsdcDonationFreezesNormalSettle). Before the fix, counting the timeout as killed:
{t0['killed'] + t0['timeout']}/{t0['killed'] + t0['timeout'] + t0['survived']} = {100 * (t0['killed'] + t0['timeout']) / (t0['killed'] + t0['timeout'] + t0['survived']):.1f}%;
excluding it: {t0['killed']}/{t0['killed'] + t0['survived']} = {100 * t0['killed'] / (t0['killed'] + t0['survived']):.1f}%.

The high compile-fail share is expected: Gambit ran with `--skip_validate` (its plain-solc validation hits the
stack-too-deep below on every file importing GainsNav), so type-invalid mutants (e.g. `<` -> `%` on a bool context)
reach forge, which rejects them in a few seconds.

## Test bug found: AccessMatrix.t.sol assertion was vacuous

`_runState` counted mismatches in a storage variable and every cell calls `_enter`, which runs
`vm.revertToState(base)` and rolled the counter back to 0, so `assertEq(mismatches, 0)` only saw the last cell.
Mutant GainsVaultLogic#2009 logged `MISMATCH state/fn/actor <s> 16 7` in 6 states and all 12 test_accessMatrix_*
passed. On the unmutated tree the suite logs 0 mismatches, so ACCESS-MATRIX.md's conclusions held, but nothing
enforced them. Fix (lead, in dv-audit-gains, not yet committed): `mismatches` is a local in `_runState`. With it the
mutant fails all 12 states (1 to 4 mismatches each). Regression PoC: `test/audit/gains/static/RevertToStateCounter.t.sol`
(reproduces the storage-counter-vs-revertToState pattern; passes, i.e. shows the counter is lost).
Other audit tests using vm.revertToState were checked (gov/FactoryMatrix, gov/Governance, gov/PolicyMatrix, R1PoC,
xreview/XReview, and test/gains/fork/GainsRiskParity): all assert inside the snapshot window before reverting, none
accumulates a result in storage across a revert. No other instance of the pattern.

## Sample definition

Only mutants whose line lies inside the listed functions (line ranges of the 9f39013 sources, LF-normalised) were
eligible; from those, a seeded (seed 7) round-robin over distinct source lines (one mutant per line per round) up to
the per-file budget, so the sample spreads over as many security lines as possible. Mutants of these functions run
in an earlier, aborted wider run are counted toward the budget (same semantics).

| file | generated | eligible (in listed functions) | sampled | functions (line range) |
| --- | --- | --- | --- | --- |
{sample}

## Harness

- Gains-only scratch project outside the repo (copy of src/gains, the round 4 type files it imports: VaultTypes,
  VaultPolicy, hypercore/HyperCore, libraries/PxMath; test/mocks; test/gains minus fork/ and spike/; the non-fork audit
  suites R1Base, R1PoC, R1NavBias, AccessMatrix, gov/*, xreview/*, nav/NavUnit), as script/gains-coverage.sh does it.
  29 suites, 295 tests, test_ImplementationFitsEip170 excluded (it measures an unoptimised build, as in
  gains-coverage.sh). contracts/src in the repo was never edited; mutants were only copied over the scratch copy.
- **via_ir was kept** because the tree does not compile without it (stack too deep at GainsNav.sol:96 with the legacy
  pipeline, unmutated tree). Settings: via_ir with the optimizer sequence emptied (`optimizerSteps = ""`, stack
  allocation on), the foundry.toml form of `forge coverage --ir-minimum`. Fuzz runs 64, invariant 16 x 32 (project
  default 512 fuzz runs; speed trade-off).
- **deploycode.patch** (`mutation/deploycode.patch`, applied ONLY in the scratch copies while running the mutants,
  never committed): the 8 `new C(...)` sites for GainsVault / GainsVaultPolicy / GainsVaultLens / GainsVaultFactory /
  MockGainsDiamond in test/gains/GainsBase.t.sol, GainsPolicyAndFactory.t.sol, GainsRound4.t.sol and
  test/audit/gains/gov/FactoryMatrix.t.sol become `C(deployCode("C.sol:C", abi.encode(args)))`. Same artifact, same
  CREATE from the same test contract, same address and arguments; under via-IR it stops every test contract from
  re-generating those contracts, ~43% faster builds. **The reported score is from the patched suite**, which was 295/295
  green on the unmutated tree before mutation (and again with the fixed AccessMatrix: every surviving mutant run
  passes all tests).
- foundry 1.8.4 never reused its compile cache here (`missing cache entry` for every source), so each mutant is a full
  compile; 5 workers; per valid mutant 2.5 to 8 min depending on machine load (shared with four halmos runs).
- Per mutant: copy over scratch `src/gains/<File>.sol`, `forge test --fail-fast`, restore. compile-fail / killed /
  survived / timeout (> 1,200 s).

## Surviving mutants (all on security-relevant lines)

| location | mutant | operator | original | mutant | final status | verdict | explanation |
| --- | --- | --- | --- | --- | --- | --- | --- |
{chr(10).join(rows)}

Test gaps to close (no contract change needed): a two-carry-run settle/claim test (Logic#952), market-order band
boundary tests on both sides (Policy#207), `pendingTimelockEta == 0` after applyTimelockDelay plus a second apply
reverting NothingPending (Policy#753). Logic#2009 is closed by the AccessMatrix fix. Factory#684 is equivalent.
"""
open(os.path.join(T, 'MUTATION.md'), 'w', encoding='utf-8', newline='\n').write(md)
print(ta); print(tb)
