"""ECON model entry point (python -I econ.py ...).

  ffi <strategy> <seed> <sizeUsdc> [key=value ...]   ABI-encoded uint256[] for EconDiff.t.sol (hex on stdout)
  show <strategy> <seed> <sizeUsdc> [key=value ...]  per-actor result table
  table [out.json]                                   the strategy table of ECONOMICS.md (all strategies, seeds, sizes)

Layout of the ffi words: [nEvents, 8 words per event..., nActors, per actor: finalUsdc, ..., cfg words (see EconDiff)]
"""
from __future__ import annotations

import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from scenario import Cfg, FEE, MANAGER, OWNER, GUARDIAN, INIT_WALLET, USDC  # noqa: E402
from strategies import run  # noqa: E402

PRESETS = {
    # strategy -> cfg overrides (fees, lag) used by the table and the differential
    "passive": {},
    "openin_flatout": {},
    "flatin_openout": {},
    "spread_farm": {},
    "spread_farm_big": {},
    "lag_option": {"lag_bps": 5},
    "split": {"attackers": 4},
    "carry_option": {"crash_p": 0.12},
    "mgmt_timing": {"mgmt": 200},
    "mgmt_control": {"mgmt": 200},
    "perf_timing": {"perf": 2000},
    "perf_control": {"perf": 2000},
    "overdue_owner": {},
    "overdue_control": {},
    "levbreach_perf": {"perf": 2000, "crash_p": 0.0, "sigma_bps": 30, "drift_bps": 8.0},
    "levbreach_control": {"perf": 2000, "crash_p": 0.0, "sigma_bps": 30, "drift_bps": 8.0},
    "insider_edges": {"mgmt": 200, "perf": 2000},
    "dust": {"attackers": 3},
    "full_exit": {},
    "emergency_partial": {"crash_p": 0.0},
    "emergency_stay": {"crash_p": 0.0},
    "fee_raise": {"mgmt": 200, "perf": 2000, "crash_p": 0.0},
}


def make_cfg(strategy: str, seed: int, size_usdc: int, extra: list[str]) -> Cfg:
    kw = dict(PRESETS.get(strategy, {}))
    for e in extra:
        k, v = e.split("=")
        kw[k] = float(v) if "." in v else int(v)
    return Cfg(seed=seed, strategy=strategy, size=size_usdc * USDC, **kw)


def encode(words: list[int]) -> str:
    out = [32, len(words)] + words
    for w in out:
        assert 0 <= w < 2**256, w
    return "0x" + "".join(f"{w:064x}" for w in out)


def ffi_words(s) -> list[int]:
    cfg = s.cfg
    words = [len(s.events)]
    for row in s.events:
        words.extend(row)
    words.append(len(s.actors))
    for a in s.actors:
        words.append(s.wallet[a])
    words.extend([s.v.usdc, s.v.supply])
    # configuration the test must build the same vault with
    words.extend([cfg.mgmt, cfg.perf, cfg.fee_p, cfg.band, cfg.max_lev, cfg.risk.max_daily, cfg.risk.max_dd,
                  cfg.risk.max_epoch, cfg.risk.max_nav_move, cfg.risk.max_notional, INIT_WALLET])
    return words


def result(s):
    """Per actor (USDC): real P&L, flow transfer, fee transfer, performance overcharge vs per-lot."""
    rows = {}
    for a in s.actors:
        rows[a] = ((s.wallet[a] - INIT_WALLET) / USDC, s.x.flow[a] / USDC, s.x.fee[a] / USDC, s.x.perf_over[a] / USDC)
    return rows


def per_epoch_extraction(s, actors, k=0):
    """Largest one-settle increase of the cumulative transfer (component k) summed over `actors`, in USDC."""
    best = 0.0
    prev = 0.0
    for m in s.marks:
        x = sum(m[a][k] for a in actors)
        best = max(best, x - prev)
        prev = x
    return best / USDC


def show(s):
    names = {OWNER: "owner", MANAGER: "manager", GUARDIAN: "guardian", FEE: "feeRecipient"}
    for a in s.victims:
        names[a] = f"victim{a}"
    for a in s.attackers:
        names[a] = f"attacker{a}"
    print(f"strategy {s.cfg.strategy} seed {s.cfg.seed} size {s.cfg.size // USDC} events {len(s.events)} "
          f"epochs settled {s.v.current} reverts {s.reverts}")
    print(f"{'actor':>14} {'real P&L':>14} {'flow xfer':>12} {'fee xfer':>12} {'perf over':>12}")
    for a, (r, fl, fe, po) in result(s).items():
        print(f"{names[a]:>14} {r:14.6f} {fl:12.6f} {fe:12.6f} {po:12.6f}")
    print(f"vault left: usdc {s.v.usdc / USDC:.6f} supply {s.v.supply} unassigned {s.x.unassigned / USDC:.6f}")
    modes = {}
    for e in s.v.epochs.values():
        modes[e.mode] = modes.get(e.mode, 0) + 1
    print("settle modes", modes, "partial fills", sum(1 for e in s.v.epochs.values() if e.red_burned < e.red_shares))


CONTROL = {
    # strategy -> the control run on the same seed (same price path, same honest behaviour draws)
    "mgmt_timing": "mgmt_control",
    "perf_timing": "perf_control",
    "overdue_owner": "overdue_control",
    "levbreach_perf": "levbreach_control",
    "emergency_partial": "emergency_stay",
    "openin_flatout": "passive",
    "flatin_openout": "passive",
    "lag_option": "passive",
    "split": "passive",
    "carry_option": "passive",
    "insider_edges": "passive",
    "full_exit": "passive",
}


def _one(s):
    res = result(s)
    att, vic = s.attackers, s.victims
    return {
        "att_real": sum(res[a][0] for a in att),
        "att_flow": sum(res[a][1] for a in att),
        "att_fee": sum(res[a][2] for a in att),
        "vic_flow": sum(res[a][1] for a in vic),
        "vic_fee": sum(res[a][2] for a in vic),
        "vic_perf_over": sum(res[a][3] for a in vic),
        "att_perf_over": sum(res[a][3] for a in att),
        "fee_real": res[FEE][0],
        "fee_total": res[FEE][1] + res[FEE][2],
        "insiders_flow": sum(res[a][1] for a in (OWNER, MANAGER, GUARDIAN)),
        "att_epoch_max": per_epoch_extraction(s, att, 0),
        "fee_epoch_max": per_epoch_extraction(s, [FEE], 1),
        "unassigned": s.x.unassigned / USDC,
        "stranded": s.v.usdc / USDC,
        "settles": s.v.current,
        "events": len(s.events),
        "modes": {m: sum(1 for e in s.v.epochs.values() if e.mode == m) for m in ("normal", "redonly", "exit")},
        "partial": sum(1 for e in s.v.epochs.values() if e.red_burned < e.red_shares),
    }


def summarize(strategy, seeds, sizes, extra=()):
    import dataclasses
    out = {}
    for size in sizes:
        rows = []
        for seed in seeds:
            cfg = make_cfg(strategy, seed, size, list(extra))
            r = _one(run(cfg))
            r["seed"] = seed
            if strategy in CONTROL:
                r["ctl"] = _one(run(dataclasses.replace(cfg, strategy=CONTROL[strategy])))
            rows.append(r)
        out[size] = rows
    return out


TABLE = [
    # (label, strategy, extra cfg)
    ("passive holder (control)", "passive", ()),
    ("GR1-02 residual: in while open, out when flat", "openin_flatout", ()),
    ("in when flat, out while open", "flatin_openout", ()),
    ("manufactured spread, per-settle hedged book, Gains fee 0", "spread_farm", ()),
    ("manufactured spread, Gains fee 3.6 bp/side", "spread_farm", ("fee_p=360000000",)),
    ("manufactured spread, large victim flows, fee 0", "spread_farm_big", ()),
    ("manufactured spread, large victim flows, fee 3.6 bp", "spread_farm_big", ("fee_p=360000000",)),
    ("Chainlink lag 5 bp: deposit/redeem/cancel option", "lag_option", ()),
    ("Chainlink lag 50 bp (fast market) option", "lag_option", ("lag_bps=50",)),
    ("split requests over 4 addresses and 5 epochs", "split", ()),
    ("carried deposits as a free option", "carry_option", ()),
    ("management fee accrual timing (fee recipient)", "mgmt_timing", ()),
    ("performance fee at transient highs (manager)", "perf_timing", ()),
    ("overdue exit-only settle at the checkpoint (owner)", "overdue_owner", ()),
    ("leverage-breach settle skips crystallisation", "levbreach_perf", ()),
    ("insider deferral edges (manager for controller, fee recipient change)", "insider_edges", ()),
    ("dust: 10 USDC requests, 1-unit redemptions, donation", "dust", ()),
    ("first depositor after a full exit", "full_exit", ()),
    ("emergency partial fill: first in line", "emergency_partial", ()),
    ("scheduled fee raise during a leverage breach", "fee_raise", ()),
]


def table(seeds, sizes, path):
    import json
    import statistics as st
    rows = []
    for label, strat, extra in TABLE:
        summ = summarize(strat, seeds, sizes, extra)
        for size, rs in summ.items():
            v = size
            row = {"label": label, "strategy": strat, "extra": list(extra), "size": size, "seeds": len(rs),
                   "settles_min": min(r["settles"] for r in rs), "events_max": max(r["events"] for r in rs),
                   "modes": {m: sum(r["modes"][m] for r in rs) for m in ("normal", "redonly", "exit")},
                   "partial": sum(r["partial"] for r in rs),
                   "unassigned_max": max(abs(r["unassigned"]) for r in rs),
                   "stranded_max": max(r["stranded"] for r in rs)}
            for k in ("att_flow", "att_fee", "vic_flow", "fee_total", "vic_perf_over", "att_real", "fee_real"):
                xs = [r[k] for r in rs]
                row[k + "_mean"] = st.mean(xs)
                row[k + "_max"] = max(xs)
                row[k + "_min"] = min(xs)
            row["att_flow_max_bps"] = row["att_flow_max"] / v * 1e4
            row["att_epoch_max"] = max(r["att_epoch_max"] for r in rs)
            row["att_epoch_max_bps"] = row["att_epoch_max"] / v * 1e4
            row["fee_epoch_max"] = max(r["fee_epoch_max"] for r in rs)
            if "ctl" in rs[0]:
                for k in ("att_flow", "att_real", "fee_total", "fee_real", "vic_flow"):
                    d = [r[k] - r["ctl"][k] for r in rs]
                    row["d_" + k + "_mean"] = st.mean(d)
                    row["d_" + k + "_max"] = max(d)
                    row["d_" + k + "_min"] = min(d)
            rows.append(row)
            print(json.dumps(row), flush=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=1)


def main(argv):
    cmd = argv[1]
    if cmd == "table":
        seeds = range(int(argv[2]), int(argv[3]))
        sizes = [int(x) for x in argv[4].split(",")]
        table(seeds, sizes, argv[5])
        return
    if cmd == "summary":
        import json
        strategy = argv[2]
        seeds = range(int(argv[3]), int(argv[4]))
        sizes = [int(x) for x in argv[5].split(",")]
        print(json.dumps(summarize(strategy, seeds, sizes, argv[6:]), indent=1, default=str))
        return
    if cmd in ("ffi", "show"):
        cfg = make_cfg(argv[2], int(argv[3]), int(argv[4]), argv[5:])
        s = run(cfg)
        if cmd == "ffi":
            sys.stdout.write(encode(ffi_words(s)))
        else:
            show(s)
        return
    raise SystemExit("unknown command")


if __name__ == "__main__":
    main(sys.argv)
