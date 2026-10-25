"""Event sequences for the ECON differential: a deterministic generator (seeded PRNG) of honest background activity
plus one adversarial strategy, applied to the spec vault and the fair ledgers as it is generated.

Every event is recorded as 8 uint256 words ``[op, actor, a, b, c, expectRevert, chk1, chk2]`` for EconDiff.t.sol,
which replays them on the real vault (mock diamond) and checks every expectation.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from model import (DAY, ONE_SHARE, Diamond, Pair, Revert, Risk, SpecVault, VAULT, DAILY_LOSS, DRAWDOWN, EMERGENCY,
                   LEVERAGE, NONE)
from fair import TransferLedger

START = 1_700_000_000
OWNER, MANAGER, GUARDIAN, FEE = 0, 1, 2, 3
FIRST_DEP = 4
BTC, ETH = 0, 1
INIT_WALLET = 50_000_000 * 10**6  # every actor starts with 50M USDC (the test mints the same)
USDC = 10**6

# op codes (EconDiff.t.sol)
WARP, PRICE, DEP, RED, CANDEP, CANRED, CLAIM, OPEN, CLOSE, SETTLE, CHECKRISK, ACCRUE = range(1, 13)
EMERG, EXITEMERG, CLEARBREACH, RESUME, QFEES, XFEES, QFEEREC, XFEEREC, DONATE, CHECK, CLEARLEV, LOWERFEES = range(13, 25)
TIMELOCK = 2 * DAY


class Hooks:
    def __init__(self, *ledgers):
        self.ledgers = ledgers

    def __getattr__(self, name):
        def call(*a):
            for l in self.ledgers:
                getattr(l, name)(*a)
        return call

    def snapshot(self):
        return [l.snapshot() for l in self.ledgers]

    def restore(self, s):
        for l, x in zip(self.ledgers, s):
            l.restore(x)


@dataclass
class Cfg:
    seed: int = 1
    strategy: str = "passive"
    size: int = 100_000 * USDC  # victim capital at the start
    epochs: int = 60
    victims: int = 3
    attackers: int = 1
    mgmt: int = 0
    perf: int = 0
    fee_p: int = 0  # Gains position fee, 1e10 percent per side (5e8 = 0.05 %)
    band: int = 20
    lag_bps: int = 0  # Chainlink deviation threshold (0 = Chainlink equals the oracle)
    sigma_bps: int = 60  # per sub-step volatility of the true price
    substeps: int = 4
    max_lev: int = 50_000
    crash_p: float = 0.04
    emergency_p: float = 0.0
    attacker_ratio: float = 1.0  # attacker capital / victim capital
    drift_bps: float = 0.0  # drift of the true price per sub-step
    risk: Risk = field(default_factory=Risk)


class Sim:
    def __init__(self, cfg: Cfg):
        self.cfg = cfg
        self.rng = random.Random(cfg.seed * 1_000_003)  # behaviour: the same draws for every strategy of a seed
        self.prng = random.Random(cfg.seed)  # price path: identical for every strategy of a seed
        self.now = START
        pairs = {BTC: Pair(fee_p=cfg.fee_p, band=cfg.band), ETH: Pair(fee_p=cfg.fee_p, band=cfg.band)}
        self.cl = {BTC: 100_000 * 10**10, ETH: 3_000 * 10**10}
        self.true = dict(self.cl)
        self.d = Diamond(pairs)
        self.victims = list(range(FIRST_DEP, FIRST_DEP + cfg.victims))
        self.attackers = list(range(FIRST_DEP + cfg.victims, FIRST_DEP + cfg.victims + cfg.attackers))
        self.actors = [OWNER, MANAGER, GUARDIAN, FEE] + self.victims + self.attackers
        self.wallet = {a: INIT_WALLET for a in self.actors}
        risk = Risk(**{**cfg.risk.__dict__, "max_lev": cfg.max_lev})
        self.v = SpecVault(self.d, risk, cfg.mgmt, cfg.perf, self.now, OWNER, MANAGER, GUARDIAN, FEE, self.cl)
        self.x = TransferLedger(self.d, self.true, self.actors)
        self.v.hooks = Hooks(self.x)
        self.events: list[list[int]] = []
        self.queued: dict = {}
        self.marks: list[dict] = []  # per settle: actor -> (real mark - fair mark)
        self.log: list[str] = []
        self.reverts: dict[str, int] = {}

    # ------------------------------------------------------------------ event plumbing
    def ev(self, op, actor=0, a=0, b=0, c=0, quiet=False):
        """Applies one event to the model and records it. Returns the model's result or the Revert."""
        row = [op, actor, a, b, c, 0, 0, 0]
        res = None
        # a call that reverts leaves no trace on chain: ops that can write before they revert run on a snapshot
        snap = None
        if op in (DEP, RED, CANRED, CLEARLEV, RESUME, CLAIM, CANDEP):
            snap = (self.v._snapshot(), dict(self.wallet))
        try:
            res = self._apply(op, actor, a, b, c, row)
        except Revert as r:
            if snap is not None:
                self.v._restore(snap[0])
                self.wallet.clear()
                self.wallet.update(snap[1])
            row[5] = r.code
            res = r
            self.reverts[r.name] = self.reverts.get(r.name, 0) + 1
        self.events.append(row)
        return res

    def _apply(self, op, actor, a, b, c, row):
        v = self.v
        if op == WARP:
            self.now += a
            v.now = self.now
        elif op == PRICE:
            self.cl[a] = b
            self.true[a] = c
        elif op == DEP:
            v.request_deposit(actor, a, b, self.wallet)
        elif op == RED:
            v.request_redeem(actor, a, actor, actor, self.wallet)
        elif op == CANDEP:
            v.cancel_deposit(actor, self.wallet)
        elif op == CANRED:
            v.cancel_redeem(actor, self.wallet)
        elif op == CLAIM:
            v.claim(actor, self.wallet)
        elif op == OPEN:
            pair, long = a // 2, bool(a % 2)
            return v.open_trade(actor, pair, long, b, c, self.true[pair])
        elif op == CLOSE:
            t = self.d.trades[a]
            return v.close_trade(actor, a, self.true[t.pair])
        elif op == SETTLE:
            er = v.settle(actor)
            row[2] = er.red_burned
            row[3] = er.nav
            row[4] = {"normal": 0, "redonly": 1, "exit": 2}[er.mode]
            row[6] = er.dep_shares
            row[7] = er.red_assets
            self._mark()
            return er
        elif op == CHECKRISK:
            return v.check_risk()
        elif op == ACCRUE:
            v.accrue_fees_ext()
        elif op == EMERG:
            v.trigger_emergency(actor)
        elif op == EXITEMERG:
            v.exit_emergency(actor)
        elif op == CLEARBREACH:
            v.clear_breach(actor)
        elif op == RESUME:
            v.resume(actor)
        elif op == QFEES:
            if actor != v.owner:
                raise Revert("Unauthorized")
            self.queued[("fees", a, b)] = self.now + TIMELOCK
        elif op == XFEES:
            eta = self.queued.pop(("fees", a, b))
            assert self.now >= eta
            v.set_fees(a, b)
        elif op == QFEEREC:
            self.queued[("rec", a)] = self.now + TIMELOCK
        elif op == XFEEREC:
            eta = self.queued.pop(("rec", a))
            assert self.now >= eta
            v.fee_recipient = a
        elif op == DONATE:
            assert self.wallet[actor] >= a
            self.wallet[actor] -= a
            v.donate(a)
        elif op == CHECK:
            row[2] = v.supply
            row[3] = v.usdc
            row[4] = v.total_assets()
            row[6] = v.hwm
            row[7] = v.cp_nav
        elif op == CLEARLEV:
            v.clear_leverage_breach()
        elif op == LOWERFEES:
            v.lower_fees(actor, a, b)
        else:
            raise ValueError(op)
        return None

    # ------------------------------------------------------------------ marks
    def mid_nav(self) -> int:
        return self.v.idle() + sum(self.d.value_at(t, self.true[t.pair]) for t in self.d.open_trades())

    def real_mark(self, a) -> float:
        """Actor's real holdings at the mid price: wallet + shares (held, escrowed, claimable) + USDC claimable +
        queued deposits."""
        v = self.v
        nav = self.mid_nav()
        px = nav / (v.supply + 10**6) if v.supply > 0 else 0.0  # per share unit (virtual offset kept)
        r = v.req.get(a)
        shares = v.bal.get(a, 0)
        usdc = self.wallet[a]
        queued = 0
        if r is not None:
            if r.epoch >= v.current:
                shares += r.red
                queued += r.dep
            else:
                s, x, carried = v.claimable_with_carry(a)
                shares += s
                usdc += x
                if carried:
                    queued += r.dep
        return usdc + shares * px + queued

    def _mark(self):
        """Cumulative transfers per actor after each settle: (flow, fee, perf overcharge)."""
        self.marks.append({a: (self.x.flow[a], self.x.fee[a], self.x.perf_over[a]) for a in self.actors})

    # ------------------------------------------------------------------ helpers used by strategies
    def warp(self, dt):
        if dt > 0:
            self.ev(WARP, 0, dt)

    def set_price(self, pair, true_px):
        true_px = max(100, (true_px // 100) * 100)
        cl = self.cl[pair]
        lag = self.cfg.lag_bps
        if lag == 0 or abs(true_px - cl) * 10_000 >= lag * cl:
            cl = true_px
        self.ev(PRICE, 0, pair, cl, true_px)

    def move_prices(self, sigma_bps=None, drift_bps=0.0):
        s = (sigma_bps if sigma_bps is not None else self.cfg.sigma_bps) / 10_000
        for pair in (BTC, ETH):
            r = self.prng.gauss(drift_bps / 10_000, s)
            self.set_price(pair, int(self.true[pair] * math.exp(r)))

    def balance(self, a) -> int:
        return self.v.bal.get(a, 0)

    def claim_all(self, who=None):
        for a in (who if who is not None else self.actors):
            r = self.v.req.get(a)
            if r is None or r.epoch >= self.v.current or (r.dep == 0 and r.red == 0):
                continue
            _, _, carried = self.v.claimable_with_carry(a)
            if carried and r.red == 0:
                continue
            self.ev(CLAIM, a)

    def leverage(self) -> float:
        value, notional, _ = self.v.venue()
        eq = self.v.idle() + value
        return notional / eq if eq > 0 else 0.0

    def open_to(self, target_lev: float, hedged=False, per_trade_lev=10_000, max_trades=8):
        """Manager opens trades until vault leverage reaches about target_lev (x). Returns opened indexes."""
        v = self.v
        opened = []
        for _ in range(max_trades):
            if v.breached or v.emergency or v.overdue():
                break
            value, notional, _ = v.venue()
            nav = v.idle() + value
            room = target_lev * nav - notional
            if room < 600 * USDC or len(self.d.open_trades()) >= 18:
                break
            if hedged:
                size = int(room / 2)
                coll = max(size * 1000 // per_trade_lev, 1)
                if 2 * coll > v.idle():
                    coll = v.idle() // 2
                if coll < 600_000:
                    break
                for long in (True, False):
                    if v.can_open(MANAGER, ETH, long, coll, per_trade_lev) is None:
                        r = self.ev(OPEN, MANAGER, ETH * 2 + int(long), coll, per_trade_lev)
                        if not isinstance(r, Revert):
                            opened.append(r.index)
                if len(opened) >= 2:
                    break
                continue
            lev = per_trade_lev
            coll = int(room * 1000 // lev)
            coll = min(coll, v.idle() * 9 // 10)
            if coll < 600_000:
                break
            pair = self.rng.choice((BTC, ETH))
            long = self.rng.random() < 0.6
            if v.can_open(MANAGER, pair, long, coll, lev) is not None:
                coll = coll * 9 // 10
                if v.can_open(MANAGER, pair, long, coll, lev) is not None:
                    break
            r = self.ev(OPEN, MANAGER, pair * 2 + int(long), coll, lev)
            if isinstance(r, Revert):
                break
            opened.append(r.index)
        return opened

    def close_all(self, who=MANAGER):
        for t in list(self.d.open_trades()):
            self.ev(CLOSE, who, t.index)

    def close_some(self, frac=0.5):
        for t in list(self.d.open_trades()):
            if self.rng.random() < frac:
                self.ev(CLOSE, MANAGER, t.index)

    def settle(self, caller=MANAGER, min_age=3600, check=True):
        """The keeper's settle: age the epoch, checkRisk, settle; on InsufficientLiquidity close trades and retry;
        on NavMoved ratchet the checkpoint an hour later."""
        v = self.v
        age = v.epoch_started + min_age - self.now
        if age > 0:
            self.warp(age)
        for attempt in range(12):
            if check:
                self.ev(CHECKRISK)
            r = self.ev(SETTLE, caller)
            if not isinstance(r, Revert):
                self.ev(CHECK)
                return r
            if r.name == "InsufficientLiquidity":
                # the operator frees margin: close the largest trades until idle covers
                for t in sorted(self.d.open_trades(), key=lambda t: -t.coll):
                    self.ev(CLOSE, MANAGER if caller != GUARDIAN else GUARDIAN, t.index)
                    break
            elif r.name in ("NavMoved", "StaleCheckpoint"):
                self.warp(3600)
                check = True
            elif r.name == "EpochTooYoung":
                self.warp(3600)
            elif r.name == "Unauthorized" and caller != MANAGER:
                caller = MANAGER
            else:
                return r
        return r

    def manage_breach(self):
        v = self.v
        if not v.breached:
            return
        if v.emergency:
            return
        if v.reason == LEVERAGE:
            self.close_some(0.5)
            if self.now >= v.breached_at + 900:
                self.ev(CLEARLEV)
        elif v.reason == DRAWDOWN:
            if self.now >= v.breached_at + DAY:
                self.close_some(0.7)
                self.ev(RESUME, OWNER)

    def fund(self, a, amount):
        """Deposit request for `a` (skipped if the vault refuses deposits now)."""
        v = self.v
        if v.breached or v.emergency or amount < 10 * USDC or self.wallet[a] < amount:
            return None
        r = v.req.get(a)
        if r is not None and (r.dep > 0 or r.red > 0) and r.epoch != v.current:
            self.claim_all([a])
            r = v.req.get(a)
            if r is not None and (r.dep > 0 or r.red > 0) and r.epoch != v.current:
                return None
        return self.ev(DEP, a, amount, a)

    def redeem_frac(self, a, frac):
        r = self.v.req.get(a)
        if r is not None and r.epoch > self.v.current:
            return None
        self.claim_all([a])
        b = self.balance(a)
        s = b if frac >= 1.0 else b * int(frac * 1_000_000) // 1_000_000
        if s <= 0:
            return None
        return self.ev(RED, a, s)

    # ------------------------------------------------------------------ honest background
    def honest_epoch(self, k):
        cfg, rng = self.cfg, self.rng
        for a in self.victims:
            x = rng.random()
            if x < 0.25:
                self.fund(a, int(cfg.size / cfg.victims * rng.uniform(0.02, 0.3)))
            elif x < 0.45:
                self.redeem_frac(a, rng.uniform(0.05, 0.4))
            elif x < 0.5:
                r = self.v.req.get(a)
                if r is not None and r.dep > 0 and r.epoch == self.v.current:
                    self.ev(CANDEP, a)
        if rng.random() < 0.6:
            self.claim_all(self.victims)

    def background_trading(self):
        """Manager: close some, open towards a random leverage target."""
        if self.rng.random() < 0.35:
            self.close_some(0.5)
        target = self.rng.choice((0.0, 0.5, 1.5, 2.5, 3.5, 4.5)) * self.cfg.max_lev / 50_000
        if target > 0:
            self.open_to(target, per_trade_lev=self.rng.choice((2_000, 5_000, 10_000, 25_000)))

    def epoch_prices(self):
        n = self.cfg.substeps
        for _ in range(n):
            self.warp(self.prng.randint(600, 4 * 3600 // n))
            if self.prng.random() < self.cfg.crash_p:
                self.move_prices(sigma_bps=30, drift_bps=-self.prng.choice((300, 500, 900)))
            else:
                self.move_prices(drift_bps=self.cfg.drift_bps)

    # ------------------------------------------------------------------ run
    def start(self):
        cfg = self.cfg
        for a in self.victims:
            self.ev(DEP, a, cfg.size // cfg.victims, a)
        self.settle()
        self.claim_all()

    def finish(self):
        """Unwind: flat, every pending deposit cancelled, every share redeemed, settled and claimed."""
        v = self.v
        if v.emergency or v.breached:
            pass
        self.close_all(MANAGER if not v.emergency else GUARDIAN)
        for _ in range(4):
            for a in self.actors:
                r = v.req.get(a)
                if r is not None and r.dep > 0:
                    if r.epoch >= v.current or v.claimable_with_carry(a)[2]:
                        self.ev(CANDEP, a)
                self.claim_all([a])
                s = self.balance(a)
                if s > 0:
                    r = v.req.get(a)
                    if r is None or r.epoch <= v.current:
                        self.ev(RED, a, s)
            if v.pending_red == 0 and all(self.balance(a) == 0 for a in self.actors):
                break
            self.warp(3600)
            caller = MANAGER
            if v.hard_stop() and not v.emergency:
                self.ev(CLEARBREACH, GUARDIAN)
            self.settle(caller)
            self.claim_all()
            if v.emergency and v.pending_red == 0:
                self.ev(EXITEMERG, GUARDIAN)
                self.ev(CLEARBREACH, GUARDIAN)
        self.claim_all()
        self.ev(CHECK)
        self._mark()


def hash_str(s: str) -> int:
    h = 0
    for ch in s:
        h = (h * 131 + ord(ch)) % 1_000_000_007
    return h
