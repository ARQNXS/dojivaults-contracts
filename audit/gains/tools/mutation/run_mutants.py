"""Mutant driver.

usage: python -I run_mutants.py <selection.csv> <results.csv> <nworkers>
selection.csv: rows of gambit/index.csv to run. Workers use harness copies w0..w{n-1} (created by mk-harness.sh).
Each mutant: copy mutant file over w/src/gains/<File>.sol, `forge test --fail-fast`, classify, restore.
Results are appended (resumable: ids already in results.csv are skipped).
"""
import csv, os, sys, shutil, subprocess, threading, queue, time, re

S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FORGE = r'~\.foundry\bin\forge.exe'
TIMEOUT = int(os.environ.get('MUT_TIMEOUT', '1200'))
sel_path, res_path, nw = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = list(csv.DictReader(open(sel_path, encoding='utf-8')))
done = set()
if os.path.exists(res_path):
    for r in csv.DictReader(open(res_path, encoding='utf-8')):
        done.add((r['file'], r['id']))
todo = [r for r in rows if (r['file'], r['id']) not in done]
print(f'{len(rows)} selected, {len(todo)} to run', flush=True)
q = queue.Queue()
for r in todo:
    q.put(r)
lock = threading.Lock()
fields = ['file', 'id', 'op', 'line', 'func', 'status', 'secs', 'failed_test', 'orig', 'mut']
new = not os.path.exists(res_path)
out = open(res_path, 'a', newline='', encoding='utf-8')
w = csv.DictWriter(out, fieldnames=fields)
if new:
    w.writeheader()
    out.flush()
count = [0]


def classify(rc, text):
    if 'Compiler run failed' in text or re.search(r'^Error \(\d+\)', text, re.M) or 'Stack too deep' in text:
        return 'compile-fail', ''
    if rc == 0:
        return 'survived', ''
    m = re.search(r'\[FAIL[^\]]*\]\s*(\S+)', text)
    if m:
        return 'killed', m.group(1)
    if 'failing test' in text or 'Suite result: FAILED' in text:
        return 'killed', ''
    return 'error', text.strip().splitlines()[-1][:200] if text.strip() else ''


def worker(k):
    h = os.path.join(S, f'w{k}')
    while True:
        try:
            r = q.get_nowait()
        except queue.Empty:
            return
        target = os.path.join(h, 'src', 'gains', r['file'] + '.sol')
        pristine = os.path.join(S, 'gen', 'src', 'gains', r['file'] + '.sol')
        shutil.copyfile(os.path.join(S, r['path']), target)
        t0 = time.time()
        try:
            p = subprocess.run([FORGE, 'test', '--fail-fast', '--no-match-test', 'test_ImplementationFitsEip170', '--color', 'never'],
                               cwd=h, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=TIMEOUT)
            st, ft = classify(p.returncode, p.stdout + '\n' + p.stderr)
            if st == 'error':
                open(os.path.join(S, 'logs', f"{r['file']}-{r['id']}.log"), 'w', encoding='utf-8').write(p.stdout + '\n' + p.stderr)
        except subprocess.TimeoutExpired:
            st, ft = 'timeout', ''
            subprocess.run(['taskkill', '/F', '/T', '/IM', 'nothing.exe'], capture_output=True)
        finally:
            shutil.copyfile(pristine, target)
        secs = int(time.time() - t0)
        with lock:
            w.writerow({'file': r['file'], 'id': r['id'], 'op': r['op'], 'line': r['line'], 'func': r['func'], 'status': st,
                        'secs': secs, 'failed_test': ft, 'orig': r['orig'], 'mut': r['mut']})
            out.flush()
            count[0] += 1
            print(f"[{count[0]}/{len(todo)}] w{k} {r['file']}#{r['id']} L{r['line']} {st} {secs}s {ft}", flush=True)


os.makedirs(os.path.join(S, 'logs'), exist_ok=True)
ts = [threading.Thread(target=worker, args=(k,)) for k in range(nw)]
for t in ts:
    t.start()
for t in ts:
    t.join()
print('done', flush=True)
