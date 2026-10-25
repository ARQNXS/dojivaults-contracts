"""Reverted checks for FIXES-R1.md. usage: python runcheck.py <lane-dir> <id> [<id> ...]

For each id: reset <lane-dir>/contracts from the worktree's committed contracts (src + test + script + config; lib is a
junction), apply the un-fix, find the test files holding the id's regression tests, run them, and append the forge
result lines to <lane-dir>/results.txt.
"""
import os, re, shutil, subprocess, sys

WT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))  # contracts/
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def reset(lane):
    c = os.path.join(lane, "contracts")
    os.makedirs(c, exist_ok=True)
    for d in ("src", "test", "script"):
        if os.path.exists(os.path.join(c, d)):
            shutil.rmtree(os.path.join(c, d))
        shutil.copytree(os.path.join(WT, d), os.path.join(c, d))
    for f in ("foundry.toml", "remappings.txt"):
        if os.path.exists(os.path.join(WT, f)):
            shutil.copy(os.path.join(WT, f), c)
    os.makedirs(os.path.join(c, "deployments"), exist_ok=True)
    if not os.path.exists(os.path.join(c, "lib")):
        subprocess.run(["cmd", "/c", "mklink", "/J", os.path.join(c, "lib"), os.path.join(WT, "lib")], check=True,
                       capture_output=True)
    return c


def files_for(c, pattern):
    rx = re.compile(r"function (" + pattern + r")")
    out = []
    for root, _, fs in os.walk(os.path.join(c, "test")):
        for f in fs:
            if f.endswith(".sol"):
                p = os.path.join(root, f)
                if rx.search(open(p, encoding="utf-8").read()):
                    out.append(os.path.relpath(p, c).replace("\\", "/"))
    return out


def main():
    lane, ids = os.path.normpath(sys.argv[1]), sys.argv[2:]
    import unfix as U  # noqa: E402  (the table only; main() there is not run on import)
    res = open(os.path.join(lane, "results.txt"), "a", encoding="utf-8")
    env = dict(os.environ)
    for fid in ids:
        c = reset(lane)
        r = subprocess.run([sys.executable, os.path.join(HERE, "unfix.py"), c, fid], capture_output=True, text=True)
        if r.returncode != 0:
            res.write(f"== {fid}: UNFIX FAILED {r.stdout}{r.stderr}\n")
            res.flush()
            continue
        pattern = U.UNFIX[fid][1]
        files = files_for(c, pattern)
        mp = "{" + ",".join(files) + "}" if len(files) > 1 else files[0]
        cmd = ["forge", "test", "--match-path", mp, "--match-test", pattern, "--out", "out-rc", "--cache-path", "cache-rc"]
        p = subprocess.run(cmd, cwd=c, capture_output=True, text=True, env=env)
        out = p.stdout + p.stderr
        keep = [l for l in out.splitlines() if re.search(r"\[(PASS|FAIL)|Suite result|Ran \d+ test|Error \(|error\[", l)]
        res.write(f"== {fid} | files {files} | exit {p.returncode}\n" + "\n".join(keep[:40]) + "\n")
        res.flush()
        print(fid, "exit", p.returncode, flush=True)


if __name__ == "__main__":
    main()
