"""Compile-time speedup for the mutation harness (test files only; src untouched).

Under via-IR every `new C(...)` embeds C's full Yul object in the creating contract and re-runs codegen for it, so the
~25 test contracts that inherit GainsBase each recompile GainsVault, GainsVaultPolicy, GainsVaultLens and
GainsVaultFactory. Replacing `new C(args)` by `C(deployCode("C.sol:C", abi.encode(args)))` deploys the same artifact
(same CREATE from the same test contract, same constructor args, same address) without embedding it.

usage: python -I fast_tests.py <harness dir>
"""
import os, re, sys
root = sys.argv[1]
NAMES = ['GainsVaultFactory', 'GainsVaultPolicy', 'GainsVaultLens', 'GainsVault', 'MockGainsDiamond']
ART = {'MockGainsDiamond': 'GainsMocks.sol:MockGainsDiamond'}


def rewrite(src):
    out, i, n = [], 0, 0
    pat = re.compile(r'\bnew\s+(' + '|'.join(NAMES) + r')\s*\(')
    while True:
        m = pat.search(src, i)
        if not m:
            out.append(src[i:])
            break
        name = m.group(1)
        j = m.end()  # after '('
        depth = 1
        k = j
        while depth:
            c = src[k]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            k += 1
        args = src[j:k - 1]
        art = ART.get(name, f'{name}.sol:{name}')
        if args.strip():
            rep = f'{name}(payable(deployCode("{art}", abi.encode({args}))))' if name == 'GainsVault' else f'{name}(deployCode("{art}", abi.encode({args})))'
        else:
            rep = f'{name}(payable(deployCode("{art}")))' if name == 'GainsVault' else f'{name}(deployCode("{art}"))'
        out.append(src[i:m.start()])
        out.append(rep)
        i = k
        n += 1
    return ''.join(out), n


tot = 0
for dp, _, fs in os.walk(os.path.join(root, 'test')):
    for f in fs:
        if not f.endswith('.sol') or f == 'GainsMocks.sol':
            continue
        p = os.path.join(dp, f)
        s = open(p, encoding='utf-8', newline='').read()
        s2, n = rewrite(s)
        if n:
            open(p, 'w', encoding='utf-8', newline='').write(s2)
            print(f, n)
            tot += n
print('rewritten', tot)
