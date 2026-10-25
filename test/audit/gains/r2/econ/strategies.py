"""Adversarial strategies for the ECON review. Each runs at least `cfg.epochs` settled epochs on top of the honest
background of scenario.Sim (victims depositing / redeeming / cancelling / claiming, the manager trading, prices
moving, crashes into loss breaches) and returns the finished Sim."""
from __future__ import annotations

from model import DAY, LEVERAGE, Revert
from scenario import (ACCRUE, CANDEP, CANRED, CHECK, CHECKRISK, CLEARLEV, CLOSE, DEP, DONATE, EMERG, ETH, EXITEMERG,
                      CLEARBREACH, FEE, GUARDIAN, MANAGER, OWNER, QFEEREC, QFEES, RED, SETTLE, TIMELOCK, USDC,
                      XFEEREC, XFEES, Cfg, Sim)


class Strategy:
    background = True  # the manager trades randomly
    honest = True

    def __init__(self, s: Sim):
        self.s = s
        self.A = s.attackers[0] if s.attackers else None

    def init(self):
        pass

    def epoch(self, k):
        """One epoch: prices move, breach handling, trading, flows, settle."""
        s = self.s
        s.epoch_prices()
        s.manage_breach()
        self.emergency_round(k)
        self.before_trading(k)
        if self.background and not s.v.emergency:
            s.background_trading()
        if self.honest:
            s.honest_epoch(k)
        self.before_settle(k)
        self.do_settle(k)
        self.after_settle(k)

    def emergency_round(self, k):
        s, v = self.s, self.s.v
        if not v.emergency and s.cfg.emergency_p > 0 and s.rng.random() < s.cfg.emergency_p:
            s.ev(EMERG, OWNER)
        if v.emergency:
            # unwind one trade per epoch; leave once every redeemer is paid in full
            ts = s.d.open_trades()
            if ts:
                s.ev(CLOSE, GUARDIAN, ts[0].index)
            last = v.epochs.get(v.current - 1)
            if v.pending_red == 0 and last is not None and last.red_burned == last.red_shares and not ts:
                s.claim_all()
                r = s.ev(EXITEMERG, GUARDIAN)
                if not isinstance(r, Revert):
                    s.ev(CLEARBREACH, GUARDIAN)

    def do_settle(self, k):
        self.s.settle()

    def before_trading(self, k):
        pass

    def before_settle(self, k):
        pass

    def after_settle(self, k):
        pass


class Passive(Strategy):
    """Control: the attacker deposits once at epoch 0 and holds."""

    def before_settle(self, k):
        if k == 0:
            self.s.fund(self.A, int(self.s.cfg.size * self.s.cfg.attacker_ratio))


class OpenInFlatOut(Strategy):
    """GR1-02 residual: the confederate deposits while trades are open at high leverage and redeems when the manager
    has made the vault flat (the manager cooperates). Every two epochs."""
    background = False

    def before_settle(self, k):
        s = self.s
        if k % 2 == 0:
            s.open_to(s.cfg.max_lev / 10_000 * 0.95, per_trade_lev=10_000)
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))
        else:
            s.close_all()
            s.claim_all([self.A])
            s.redeem_frac(self.A, 1.0)


class FlatInOpenOut(Strategy):
    """Inverse leg: in when flat, out while open (should cost the attacker the adverse band)."""
    background = False

    def before_settle(self, k):
        s = self.s
        if k % 2 == 0:
            s.close_all()
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))
        else:
            s.open_to(s.cfg.max_lev / 10_000 * 0.95, per_trade_lev=10_000)
            s.claim_all([self.A])
            s.redeem_frac(self.A, 1.0)


class SpreadFarm(Strategy):
    """GR2-ECON-01: the confederate holds a large stake bought while flat; before every settle that prices victim
    flows the manager opens a delta-neutral ETH long + short book at the policy's leverage, and closes it right after.
    Every victim deposit pays the favourable band edge and every victim redemption the adverse one on that book."""
    background = False
    big_flow = False

    def before_settle(self, k):
        s, v = self.s, self.s.v
        if k == 0:
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))
            return
        if self.big_flow and k % 5 == 2:
            # one victim makes a deposit as large as the vault, another redeems half
            s.fund(s.victims[0], int(s.cfg.size))
        if v.breached or v.emergency or (v.pending_dep == 0 and v.pending_red == 0):
            return
        # open the book only when the band it charges the flows beats its Gains fees (2 x fee x notional)
        nav = v.total_assets()
        lev = s.cfg.max_lev / 10_000 * 0.97
        red_value = v.to_assets(v.pending_red, nav, v.supply)
        dep = v.pending_dep
        gain = s.cfg.band / 10_000 * lev * (dep * nav / (nav + dep) + red_value * nav / max(nav - red_value, 1))
        cost = 2 * (s.cfg.fee_p / 1e12) * lev * nav
        if gain > cost:
            s.open_to(lev, hedged=True, per_trade_lev=10_000)

    def after_settle(self, k):
        self.s.close_all()


class SpreadFarmBig(SpreadFarm):
    big_flow = True


class LagOption(Strategy):
    """Deposit-before-favourable / redeem-before-adverse with a Chainlink lag (cfg.lag_bps): the attacker sees the
    oracle's (true) price, the vault prices at Chainlink. Out: request a deposit, keep it at the last moment only when
    the vault's book is worth more at the true price than at Chainlink; in: request a redemption, keep it only when the
    book is worth less. Every other request is cancelled just before the settle (free option, GR1-15)."""

    def gap_value(self):
        s = self.s
        return sum(s.d.value_at(t, s.true[t.pair]) - s.d.value_at(t, s.cl[t.pair]) for t in s.d.open_trades())

    def before_settle(self, k):
        s, v, A = self.s, self.s.v, self.A
        s.claim_all([A])
        holding = s.balance(A) > 0
        g = self.gap_value()
        if not holding:
            r = s.fund(A, int(s.cfg.size * s.cfg.attacker_ratio))
            if r is not None and not isinstance(r, Revert) and g <= 0:
                s.ev(CANDEP, A)
        else:
            r = s.redeem_frac(A, 1.0)
            if r is not None and not isinstance(r, Revert) and g >= 0:
                s.ev(CANRED, A)


class Split(Strategy):
    """The same capital as Passive, but split across all attacker addresses and over five epochs."""

    def before_settle(self, k):
        s = self.s
        if k < 5:
            for a in s.attackers:
                s.fund(a, int(s.cfg.size * s.cfg.attacker_ratio / 5 / len(s.attackers)))
        if 30 <= k < 35:
            for a in s.attackers:
                s.redeem_frac(a, 1.0 / (35 - k))


class CarryOption(Strategy):
    """Carried deposits across redemption-only epochs: the attacker keeps a deposit request queued at every
    opportunity; while it is carried by a loss breach it cancels at the last moment whenever the true price is below
    Chainlink for a long book (no edge without a lag) and re-requests once deposits reopen."""

    def before_settle(self, k):
        s, v, A = self.s, self.s.v, self.A
        r = v.req.get(A)
        if r is not None and r.dep > 0 and r.epoch < v.current and v.claimable_with_carry(A)[2]:
            g = sum(s.d.value_at(t, s.true[t.pair]) - s.d.value_at(t, s.cl[t.pair]) for t in s.d.open_trades())
            if g < 0:
                s.ev(CANDEP, A)
            return
        if s.balance(A) == 0:
            s.fund(A, int(s.cfg.size * s.cfg.attacker_ratio))
        elif k % 7 == 6:
            s.redeem_frac(A, 1.0)


class MgmtTiming(Strategy):
    """The fee recipient calls accrueFees (permissionless) whenever the NAV is at a new high since its last call, so
    the management fee is charged on high NAV marks rather than evenly."""

    def init(self):
        self.last = 0

    def epoch(self, k):
        s = self.s
        n = s.cfg.substeps
        for _ in range(n):
            s.warp(s.prng.randint(600, 4 * 3600 // n))
            s.move_prices()
            nav = s.v.total_assets()
            if nav > self.last:
                s.ev(ACCRUE, FEE)
                self.last = nav
        s.manage_breach()
        self.emergency_round(k)
        if not s.v.emergency:
            s.background_trading()
        s.honest_epoch(k)
        if k == 0:
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))
        s.settle()


class MgmtControl(MgmtTiming):
    def epoch(self, k):
        s = self.s
        n = s.cfg.substeps
        for _ in range(n):
            s.warp(s.prng.randint(600, 4 * 3600 // n))
            s.move_prices()
            nav = s.v.total_assets()  # same rng draws as MgmtTiming
            if nav > self.last:
                self.last = nav
        s.manage_breach()
        self.emergency_round(k)
        if not s.v.emergency:
            s.background_trading()
        s.honest_epoch(k)
        if k == 0:
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))
        s.settle()


class PerfTiming(Strategy):
    """The manager settles at the first NAV high of the epoch (an hour or more in), crystallising the performance
    fee on transient highs; the control settles at the end of the same price path."""
    timing = True

    def epoch(self, k):
        s, v = self.s, self.s.v
        n = s.cfg.substeps
        settled = False
        for i in range(n):
            s.warp(s.prng.randint(600, 4 * 3600 // n))
            s.move_prices()
            if self.timing and not settled and s.now >= v.epoch_started + 3600 and not v.breached:
                price = v.price_at(v.total_assets(), v.supply)
                if price > v.hwm:
                    self._flows(k)
                    s.settle()
                    settled = True
        s.manage_breach()
        self.emergency_round(k)
        if not settled:
            self._flows(k)
            s.settle()

    def _flows(self, k):
        s = self.s
        if not s.v.emergency:
            s.background_trading()
        s.honest_epoch(k)
        if k == 0:
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))


class PerfControl(PerfTiming):
    timing = False


class OverdueOwner(Strategy):
    """GR2-ECON-02: the owner (with the confederate as a stayer) stops settling; once the epoch is overdue it settles
    exit-only whenever the NAV is above the checkpoint, so the queued redemptions are paid at the stale checkpoint
    (min(NAV, checkpoint)). The confederate never redeems."""

    def before_settle(self, k):
        if k == 0:
            self.s.fund(self.A, int(self.s.cfg.size * self.s.cfg.attacker_ratio))

    def do_settle(self, k):
        s, v = self.s, self.s.v
        if k == 0:
            s.settle()
            return
        # let the epoch run overdue; the keeper's checkRisk ratchets the checkpoint at most hourly
        dt = v.epoch_started + s.cfg.risk.max_epoch - s.now
        if dt > 0:
            s.warp(dt)
        for _ in range(8):
            s.move_prices()
            nav = v.total_assets()
            if 0 < v.cp_nav < nav and not v.breached:
                r = s.ev(SETTLE, OWNER)
                if not isinstance(r, Revert):
                    s.ev(CHECK)
                    return
            if s.now >= v.cp_at + 3600:
                s.ev(CHECKRISK)
            s.warp(900)
        s.settle()


class OverdueControl(OverdueOwner):
    """Same timing, but the manager settles normally (redemptions at the live NAV)."""

    def do_settle(self, k):
        s, v = self.s, self.s.v
        if k == 0:
            s.settle()
            return
        dt = v.epoch_started + s.cfg.risk.max_epoch - s.now
        if dt > 0:
            s.warp(dt)
        for _ in range(8):
            s.move_prices()
            nav = v.total_assets()
            if 0 < v.cp_nav < nav and not v.breached:
                s.settle(check=False)
                return
            if s.now >= v.cp_at + 3600:
                s.ev(CHECKRISK)
            s.warp(900)
        s.settle()


class LevBreachPerf(Strategy):
    """GR2-ECON-03: when the share price is above the high water mark and victim deposits are queued, the manager
    opens to the policy's leverage limit; the open's own cost puts leverage over the limit, checkRisk sets a LEVERAGE
    breach, and the settle mints the deposits without crystallising the performance fee. The breach is cleared and
    the next settle charges the fee on the whole supply, the new shares included."""
    induce = True

    def before_settle(self, k):
        s, v = self.s, self.s.v
        if k == 0:
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))
            return
        if k % 4 == 1:
            s.close_all()
            s.open_to(4.5 * s.cfg.max_lev / 50_000, per_trade_lev=10_000)
        if k % 4 == 2:
            # a large victim deposit arrives
            s.fund(s.victims[0], int(s.cfg.size))
            price = v.price_at(v.total_assets(), v.supply)
            if self.induce and price > v.hwm and not v.breached:
                s.open_to(s.cfg.max_lev / 10_000, per_trade_lev=10_000)
                s.ev(CHECKRISK)

    def after_settle(self, k):
        s, v = self.s, self.s.v
        if v.breached and v.reason == LEVERAGE:
            s.close_some(0.5)
            s.warp(901)
            s.ev(CLEARLEV)


class LevBreachControl(LevBreachPerf):
    induce = False


class InsiderEdges(Strategy):
    """Insider deferral edges: the manager deposits for the confederate's controller (deferred one epoch), the fee
    recipient is changed to the confederate mid-run (its next deposit is deferred), and the old fee recipient deposits
    as an outsider. Everything else as Passive."""

    def before_settle(self, k):
        s, A = self.s, self.A
        if k == 1:
            s.ev(DEP, MANAGER, int(s.cfg.size * s.cfg.attacker_ratio / 2), A)
        if k == 5:
            s.ev(QFEEREC, OWNER, A)
        if k == 8 and s.now >= 0:
            s.warp(TIMELOCK)
            s.ev(XFEEREC, 0, A)
        if k == 10:
            s.fund(A, int(s.cfg.size * s.cfg.attacker_ratio / 2))
            s.fund(FEE, int(s.cfg.size * 0.1))
        if k == 20:
            s.redeem_frac(A, 0.5)
            s.redeem_frac(FEE, 1.0)


class Dust(Strategy):
    """Rounding: 10 USDC requests and 1-unit redemptions every epoch by every attacker address, a donation, a full
    exit and the first depositor after it."""

    def before_settle(self, k):
        s, v = self.s, self.s.v
        for a in s.attackers:
            if s.balance(a) > 0 and k % 3 == 1:
                s.ev(RED, a, 1)
            elif k % 3 != 1:
                s.fund(a, 10 * USDC)
        if k == 3:
            s.ev(DONATE, s.attackers[0], 1)


class FullExit(Strategy):
    """First depositor after a full exit: every holder redeems at epoch 10 (exit-only, the owner settles when the NAV
    is above the checkpoint), then the attacker is the first depositor."""

    def before_settle(self, k):
        s, v = self.s, self.s.v
        if k == 10:
            for a in s.actors:
                s.claim_all([a])
                if s.balance(a) > 0:
                    s.ev(RED, a, s.balance(a))
        if k == 12:
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))


class EmergencyPartial(Strategy):
    """Emergency with trades open at epoch 6; partial fills and returned shares while the guardian unwinds one trade
    per epoch. The attacker redeems in the first emergency epoch (first in line); victims redeem randomly."""

    def before_settle(self, k):
        s, v = self.s, self.s.v
        if k == 0:
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))
        if k == 5:
            s.close_all()
            s.open_to(4.0 * s.cfg.max_lev / 50_000, per_trade_lev=5_000)
        if k == 6:
            s.ev(EMERG, OWNER)
            s.claim_all([self.A])
            s.redeem_frac(self.A, 1.0)
        if v.emergency and k > 6:
            s.claim_all([self.A])
            if s.balance(self.A) > 0:
                s.redeem_frac(self.A, 1.0)


class EmergencyStay(EmergencyPartial):
    def before_settle(self, k):
        s, v = self.s, self.s.v
        if k == 0:
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))
        if k == 5:
            s.close_all()
            s.open_to(4.0 * s.cfg.max_lev / 50_000, per_trade_lev=5_000)
        if k == 6:
            s.ev(EMERG, OWNER)


class FeeRaise(Strategy):
    """Scheduled performance fee raise (20 % -> 30 %) and management raise (2 % -> 5 %) queued at epoch 5, executed
    during a leverage breach; the manager then crystallises old gains at the first normal settle."""

    def before_settle(self, k):
        s, v = self.s, self.s.v
        if k == 0:
            s.fund(self.A, int(s.cfg.size * s.cfg.attacker_ratio))
        if k == 5:
            s.ev(QFEES, OWNER, 500, 3000)
        if k == 7:
            s.warp(TIMELOCK)
            s.open_to(s.cfg.max_lev / 10_000, per_trade_lev=10_000)
            s.ev(CHECKRISK)
            s.ev(XFEES, 0, 500, 3000)


STRATS = {
    "passive": Passive,
    "openin_flatout": OpenInFlatOut,
    "flatin_openout": FlatInOpenOut,
    "spread_farm": SpreadFarm,
    "spread_farm_big": SpreadFarmBig,
    "lag_option": LagOption,
    "split": Split,
    "carry_option": CarryOption,
    "mgmt_timing": MgmtTiming,
    "mgmt_control": MgmtControl,
    "perf_timing": PerfTiming,
    "perf_control": PerfControl,
    "overdue_owner": OverdueOwner,
    "overdue_control": OverdueControl,
    "levbreach_perf": LevBreachPerf,
    "levbreach_control": LevBreachControl,
    "insider_edges": InsiderEdges,
    "dust": Dust,
    "full_exit": FullExit,
    "emergency_partial": EmergencyPartial,
    "emergency_stay": EmergencyStay,
    "fee_raise": FeeRaise,
}


def run(cfg: Cfg) -> Sim:
    s = Sim(cfg)
    st = STRATS[cfg.strategy](s)
    s.start()
    st.init()
    for k in range(cfg.epochs):
        st.epoch(k)
    s.finish()
    return s
