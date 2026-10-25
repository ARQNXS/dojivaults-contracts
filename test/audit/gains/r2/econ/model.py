"""Independent model of a Gains vault for the round 2 multi-epoch economics review (domain ECON).

Two ledgers run side by side over the same event sequence:

* ``SpecVault`` re-implements the vault's accounting from contracts/audit/gains/SPEC.md (sections 2-4, 8) and the
  ERC-4626 virtual-offset share formulas the spec names, in exact integer arithmetic. It predicts every settle mode,
  every revert the sequence provokes, every minted / burned share and every USDC claim. The Foundry differential test
  (EconDiff.t.sol) replays the same sequence on the real vault and requires agreement to the wei.
* ``FairLedger`` says what each participant SHOULD own: every flow at the mid NAV (open trades at the TRUE price
  through Gains' close path, i.e. collateral + pnl - closing fee - holding fees + realized pnl), the same fee rules
  evaluated at mid, the same settle modes and fill fractions as the real vault. See ECONOMICS.md section 2.

The venue (``Diamond``) is the economic world: it is the mock gTrade diamond of test/gains/mocks/GainsMocks.sol
(Gains' close formula without impact, opening fee booked as realized, liquidation at -90 %). It is shared by both
ledgers: trades are absolute (collateral, leverage) and pay the same in both worlds.

Python 3.13, stdlib only. Run with ``python -I``.
"""
from __future__ import annotations

from dataclasses import dataclass, field

YEAR = 365 * 86400
DAY = 86400
BPS = 10_000
ONE_SHARE = 10**12
OFF = 10**6  # 10 ** DECIMALS_OFFSET: virtual shares
MIN_DEPOSIT = 10 * 10**6
MIN_RISK_NAV = 10**6
P10 = 10**10
PD = 10**12  # USDC precision delta
INSIDER_MIN_EPOCH_AGE = 3600
CHECKPOINT_INTERVAL = 3600
CHECKPOINT_MAX_AGE = DAY
RESUME_COOLDOWN = DAY
LEVERAGE_CLEAR_COOLDOWN = 15 * 60
MAX_POSITIONS = 20
U64 = 2**64 - 1

# BreachReason
NONE, LEVERAGE, DAILY_LOSS, DRAWDOWN, GUARDIAN, EMERGENCY = range(6)

# Revert codes shared with EconDiff.t.sol (mapped there to the vault's custom error selectors)
ERR = {
    "EpochTooYoung": 1,
    "InsufficientLiquidity": 2,
    "NavMoved": 3,
    "StaleCheckpoint": 4,
    "Unauthorized": 5,
    "ReduceOnlyMode": 6,
    "RequestPending": 7,
    "DepositsClosed": 8,
    "NothingToCancel": 9,
    "RequestNotSettled": 10,
    "RedemptionsPending": 11,
    "NotClearable": 12,
    "NotReady": 13,
    "InEmergency": 14,
    "DepositTooSmall": 15,
    "EpochOverdue": 16,
    "OrderRejected": 17,
    "InsufficientIdle": 18,
    "InvalidFee": 19,
    "TooManyPositions": 20,
}


class Revert(Exception):
    def __init__(self, name: str):
        super().__init__(name)
        self.name = name
        self.code = ERR[name]


def mul_div(a: int, b: int, c: int) -> int:
    assert a >= 0 and b >= 0 and c > 0
    return a * b // c


def mul_div_up(a: int, b: int, c: int) -> int:
    assert a >= 0 and b >= 0 and c > 0
    return -((-a * b) // c)


def sdiv(a: int, b: int) -> int:
    """Solidity signed division (truncates toward zero)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


# ======================================================================================================================
# Venue: the mock gTrade diamond (Gains' close formula, no impact)
# ======================================================================================================================
@dataclass
class Pair:
    fee_p: int = 0  # pairTotalPositionSizeFeeP, 1e10 percent (0.05 % = 5e8)
    min_pos: int = 285_700_000  # pairMinPositionSizeUsd in USDC units (285.7e18 / 1e12)
    min_fee: int = 100_000  # pairMinFeeUsd in USDC units (0.1e18 / 1e12)
    spread_p: int = 0  # 1e10 percent
    band: int = 20  # Chainlink NAV band of the curated feed, bps


@dataclass
class Trade:
    index: int
    pair: int
    long: bool
    coll: int
    lev: int  # 1e3
    open_price: int
    size_tok: int
    realized_fees: int
    holding: int = 0
    is_open: bool = True


class Diamond:
    def __init__(self, pairs: dict[int, Pair]):
        self.pairs = pairs
        self.trades: list[Trade] = []
        self.usdc = 100_000_000 * 10**6  # the gToken vault that pays profits (mock pre-funded)

    def fee_of(self, pair: int, size: int) -> int:
        p = self.pairs[pair]
        basis = max(size, p.min_pos)
        return basis * p.fee_p // P10 // 100

    def min_gov_fee(self, pair: int) -> int:
        return (self.fee_of(pair, 0) // 2) * 85_000 // 1000 // 100

    @staticmethod
    def size_tok(coll: int, lev: int, price: int) -> int:
        return (coll * lev // 1000) * PD * P10 // price

    def open(self, pair: int, long: bool, coll: int, lev: int, price: int) -> Trade:
        p = self.pairs[pair]
        assert coll >= 5 * p.min_fee, "InsufficientCollateral"
        assert 0 < lev <= 200_000, "WrongLeverage"
        t = Trade(
            index=len(self.trades),
            pair=pair,
            long=long,
            coll=coll,
            lev=lev,
            open_price=price,
            size_tok=self.size_tok(coll, lev, price),
            realized_fees=self.fee_of(pair, coll * lev // 1000),
        )
        self.trades.append(t)
        self.usdc += coll
        return t

    def liq_price(self, t: Trade) -> int:
        dist = t.open_price * 90 * 1000 // (100 * t.lev)
        if t.long:
            return 0 if dist >= t.open_price else t.open_price - dist
        return t.open_price + dist

    def close_price(self, t: Trade, price: int) -> int:
        spread = (self.pairs[t.pair].spread_p // 2) * (-1 if t.long else 1)
        raw = price + sdiv(sdiv(price * spread, P10), 100)
        if raw <= 0:
            return 0
        return min(raw, U64)

    @staticmethod
    def pnl_p(open_price: int, cur: int, long: bool, lev: int) -> int:
        if open_price == 0:
            return 0
        d = (cur - open_price) if long else (open_price - cur)
        p = sdiv(sdiv(d * 100 * P10 * lev, open_price), 1000)
        return max(p, -100 * P10)

    @staticmethod
    def value_pure(coll: int, pnl_p: int, fees: int) -> int:
        v = sdiv(coll * PD + sdiv(sdiv(coll * PD * pnl_p, P10), 100), PD) - fees
        return v if v > 0 else 0

    def value_at(self, t: Trade, price: int) -> int:
        """What a full market close at oracle price `price` pays (0 at or past liquidation)."""
        liq = self.liq_price(t)
        if (price <= liq) if t.long else (price >= liq):
            return 0
        size = t.coll * t.lev // 1000
        fees = self.fee_of(t.pair, size) + t.holding + t.realized_fees  # realized pnl = -realized fees
        return self.value_pure(t.coll, self.pnl_p(t.open_price, self.close_price(t, price), t.long, t.lev), fees)

    def close(self, t: Trade, price: int) -> int:
        paid = self.value_at(t, price)
        t.is_open = False
        self.usdc -= paid
        return paid

    def open_trades(self) -> list[Trade]:
        return [t for t in self.trades if t.is_open]


def adverse(mid: int, band: int, long: bool) -> int:
    if long:
        return min(mid * (BPS - band) // BPS, U64)
    return min(mid * (BPS + band) // BPS, U64)


# ======================================================================================================================
# Spec vault
# ======================================================================================================================
@dataclass
class Risk:
    max_lev: int = 50_000
    max_daily: int = 1_500
    max_dd: int = 5_000
    max_slip: int = 100
    max_notional: int = 10_000_000 * 10**6
    max_epoch: int = DAY
    max_nav_move: int = 2_000


@dataclass
class EpochResult:
    dep_assets: int = 0
    dep_shares: int = 0
    red_shares: int = 0
    red_assets: int = 0
    red_burned: int = 0
    nav: int = 0
    price: int = 0
    settled_at: int = 0
    carried_from: int = 0
    mode: str = ""


@dataclass
class Req:
    epoch: int = 0
    dep: int = 0
    red: int = 0


VAULT = "vault"


class SpecVault:
    """Accounting of SPEC.md sections 2-4 and 8, exact integers. Roles are actor ids (ints)."""

    def __init__(self, diamond: Diamond, risk: Risk, mgmt: int, perf: int, now: int,
                 owner: int, manager: int, guardian: int, fee_recipient: int, cl: dict[int, int]):
        self.d = diamond
        self.risk = risk
        self.mgmt = mgmt
        self.perf = perf
        self.pending_perf = 0
        self.owner, self.manager, self.guardian, self.fee_recipient = owner, manager, guardian, fee_recipient
        self.operator = None
        self.cl = cl  # Chainlink price per pair (1e10), shared with the scenario
        self.now = now
        self.usdc = 0
        self.bal: dict = {}
        self.supply = 0
        self.pending_dep = 0
        self.deferred_dep = 0
        self.claimable = 0
        self.pending_red = 0
        self.current = 0
        self.epoch_started = now
        self.last_fee = now
        self.epochs: dict[int, EpochResult] = {}
        self.req: dict[int, Req] = {}
        self.carry_origin = 0
        self.carry_priced_in: dict[int, int] = {}
        self.insider_in_queue = False
        self.hwm = 10**6
        self.peak = 10**6
        self.day_start = 0
        self.risk_day = now // DAY
        self.breached = False
        self.reason = NONE
        self.breached_at = 0
        self.emergency = False
        self.emergency_at = 0
        self.cp_nav = 0
        self.cp_at = 0
        self.deposits_paused = False
        self.trading_paused = False
        self.hooks = None  # FairLedger

    # ------------------------------------------------------------------ shares
    def mint(self, to, n):
        self.supply += n
        self.bal[to] = self.bal.get(to, 0) + n

    def burn(self, frm, n):
        assert self.bal.get(frm, 0) >= n, "burn exceeds balance"
        self.bal[frm] -= n
        self.supply -= n

    def transfer(self, frm, to, n):
        if self.bal.get(frm, 0) < n:
            raise Revert("Unauthorized")  # ERC20InsufficientBalance; never generated on purpose
        self.bal[frm] -= n
        self.bal[to] = self.bal.get(to, 0) + n

    @staticmethod
    def to_shares(assets, nav, supply):
        if supply == 0:
            return assets * OFF
        return mul_div(assets, supply + OFF, nav + 1)

    @staticmethod
    def to_assets(shares, nav, supply):
        if supply == 0:
            return shares // OFF
        return mul_div(shares, nav + 1, supply + OFF)

    @staticmethod
    def price_at(nav, supply):
        if supply == 0:
            return 0
        return mul_div(nav + 1, ONE_SHARE, supply + OFF)

    # ------------------------------------------------------------------ NAV (SPEC N1-N3, N8)
    def idle(self) -> int:
        reserved = self.pending_dep + self.deferred_dep + self.claimable
        return self.usdc - reserved if self.usdc > reserved else 0

    def venue(self, high=False):
        value = notional = vh = 0
        for t in self.d.open_trades():
            mid = self.cl[t.pair]
            band = self.d.pairs[t.pair].band
            value += self.d.value_at(t, adverse(mid, band, t.long))
            if high:
                vh += self.d.value_at(t, adverse(mid, band, not t.long))
            notional += t.size_tok * mid // 10**22
        return value, notional, vh

    def total_assets(self) -> int:
        return self.idle() + self.venue()[0]

    def share_price(self) -> int:
        return self.to_assets(ONE_SHARE, self.total_assets(), self.supply)

    def hard_stop(self) -> bool:
        return self.emergency or (self.breached and self.reason >= GUARDIAN)

    def overdue(self) -> bool:
        return self.now >= self.epoch_started + self.risk.max_epoch

    def loss_breach(self) -> bool:
        return (not self.emergency) and self.breached and self.reason in (DAILY_LOSS, DRAWDOWN)

    def insider(self, a) -> bool:
        return a in (self.manager, self.owner, self.fee_recipient)

    # ------------------------------------------------------------------ checkpoint (GainsVaultPolicy.nextCheckpoint)
    def next_checkpoint(self, prev, at, nav, settling):
        if at == 0 or prev == 0:
            if settling and at == 0:
                raise Revert("StaleCheckpoint")
            return nav, True
        if prev < MIN_RISK_NAV:
            return nav, True
        cap = prev * self.risk.max_nav_move // BPS
        if settling:
            if self.now > at + CHECKPOINT_MAX_AGE:
                raise Revert("StaleCheckpoint")
            if abs(nav - prev) > cap:
                raise Revert("NavMoved")
        else:
            if self.now < at + CHECKPOINT_INTERVAL:
                return prev, False
            if nav > prev + cap:
                nav = prev + cap
            elif nav + cap < prev:
                nav = prev - cap
        return nav, True

    def checkpoint(self, nav, settling):
        nxt, upd = self.next_checkpoint(self.cp_nav, self.cp_at, nav, settling)
        if upd:
            self.cp_nav, self.cp_at = nxt, self.now

    # ------------------------------------------------------------------ risk (SPEC K1)
    def check_risk(self):
        value, notional, _ = self.venue()
        equity = self.idle() + value
        price = self.price_at(equity, self.supply)
        day = self.now // DAY
        if day != self.risk_day:
            self.risk_day = day
            self.day_start = price
            if self.breached and self.reason == DAILY_LOSS and not self.emergency:
                self._clear()
        if price > self.peak:
            self.peak = price
        lev = daily = dd = 0
        if notional > 0:
            lev = mul_div(notional, BPS, equity) if equity > 0 else 2**256 - 1
        if self.supply > 0 and equity >= MIN_RISK_NAV:
            if self.day_start > price:
                daily = mul_div(self.day_start - price, BPS, self.day_start)
            if self.peak > price:
                dd = mul_div(self.peak - price, BPS, self.peak)
        self.checkpoint(equity, False)
        r = NONE
        if dd > self.risk.max_dd:
            r = DRAWDOWN
        elif daily > self.risk.max_daily:
            r = DAILY_LOSS
        elif lev > self.risk.max_lev:
            r = LEVERAGE
        if r != NONE and ((not self.breached) or self.reason < r):
            self.breached, self.reason, self.breached_at = True, r, self.now
        return lev, daily, dd

    def _clear(self):
        self.breached, self.reason = False, NONE

    def clear_leverage_breach(self):
        if (not self.breached) or self.reason != LEVERAGE:
            raise Revert("NotClearable")
        if self.emergency:
            raise Revert("InEmergency")
        if self.now < self.breached_at + LEVERAGE_CLEAR_COOLDOWN:
            raise Revert("NotReady")
        lev, daily, dd = self.check_risk()
        if self.reason != LEVERAGE or lev > self.risk.max_lev or daily > self.risk.max_daily or dd > self.risk.max_dd:
            raise Revert("NotClearable")
        self._clear()

    def resume(self, caller):
        if caller != self.owner:
            raise Revert("Unauthorized")
        if (not self.breached) or self.reason != DRAWDOWN:
            raise Revert("NotClearable")
        if self.emergency:
            raise Revert("InEmergency")
        if self.now < self.breached_at + RESUME_COOLDOWN:
            raise Revert("NotReady")
        lev, daily, _ = self.check_risk()
        if self.reason != DRAWDOWN or lev > self.risk.max_lev or daily > self.risk.max_daily:
            raise Revert("NotClearable")
        self.peak = self.share_price()
        self._clear()

    def trigger_emergency(self, caller):
        privileged = caller in (self.guardian, self.owner)
        if not privileged and not (self.overdue() and self.pending_red > 0):
            raise Revert("Unauthorized")  # NotOverdue; never generated
        if not self.emergency:
            self.emergency, self.emergency_at = True, self.now
        self.breached, self.reason, self.breached_at = True, EMERGENCY, self.now

    def exit_emergency(self, caller):
        if caller != self.guardian:
            raise Revert("Unauthorized")
        if self.pending_red > 0:
            raise Revert("RedemptionsPending")
        e = self.current
        if e > 0:
            last = self.epochs[e - 1]
            if last.settled_at >= self.emergency_at and last.red_burned < last.red_shares:
                raise Revert("RedemptionsPending")
        self.emergency = False

    def clear_breach(self, caller):
        if caller != self.guardian:
            raise Revert("Unauthorized")
        if self.emergency:
            raise Revert("InEmergency")
        self.day_start = self.share_price()
        self.risk_day = self.now // DAY
        self._clear()

    # ------------------------------------------------------------------ fees (SPEC F1-F5)
    def accrue_fees_ext(self):
        self._accrue(False, self.venue()[0])

    def _accrue(self, with_perf, venue):
        supply = self.supply
        assets = self.idle() + venue
        elapsed = self.now - self.last_fee
        self.last_fee = self.now
        if supply == 0 or assets == 0:
            return
        fee_assets = mul_div(assets, self.mgmt * elapsed, BPS * YEAR)
        mgmt_assets = fee_assets
        price = self.price_at(assets, supply)
        if with_perf and price > self.hwm and self.perf > 0:
            gain = mul_div(price - self.hwm, supply, ONE_SHARE)
            fee_assets += mul_div(gain, self.perf, BPS)
        fee_shares = 0
        if self.hooks:
            self.hooks.on_accrue_pre(self)
        if 0 < fee_assets < assets:
            fee_shares = mul_div(fee_assets, supply + OFF, assets - fee_assets)
            if fee_shares > 0:
                self.mint(self.fee_recipient, fee_shares)
        new_price = self.price_at(assets, self.supply)
        if self.hooks:
            self.hooks.on_accrue_post(self, fee_shares, mgmt_assets, fee_assets - mgmt_assets, price, new_price, with_perf)
        if with_perf and new_price > self.hwm:
            self.hwm = new_price
        if fee_shares > 0 and new_price < price:
            self.peak = mul_div(self.peak, new_price, price)
            self.day_start = mul_div(self.day_start, new_price, price)

    def set_fees(self, mgmt, perf):
        if mgmt > 500 or perf > 3000:
            raise Revert("InvalidFee")
        self.accrue_fees_ext()
        self.mgmt = mgmt
        if perf > self.perf:
            self.pending_perf = perf
        else:
            self.perf = perf
            self.pending_perf = 0

    def lower_fees(self, caller, mgmt, perf):
        if caller != self.owner:
            raise Revert("Unauthorized")
        if mgmt > self.mgmt or perf > self.perf:
            raise Revert("InvalidFee")
        if mgmt == self.mgmt and perf == self.perf and self.pending_perf == 0:
            raise Revert("InvalidFee")
        self.set_fees(mgmt, perf)

    # ------------------------------------------------------------------ depositor flow (SPEC D1-D6)
    def _r(self, a) -> Req:
        return self.req.setdefault(a, Req())

    def claimable_with_carry(self, a):
        r = self._r(a)
        shares = assets = 0
        carried = False
        if r.epoch >= self.current:
            return 0, 0, False
        e = self.epochs.get(r.epoch, EpochResult())
        if r.dep > 0:
            pe = e
            if e.carried_from != 0:
                p = self.carry_priced_in.get(e.carried_from - 1, 0)
                if p == 0:
                    carried = True
                else:
                    pe = self.epochs[p - 1]
            if not carried and pe.dep_assets > 0:
                if pe.dep_shares == 0:
                    assets = r.dep
                else:
                    shares = mul_div(r.dep, pe.dep_shares, pe.dep_assets)
        s = r.red
        if s > 0 and e.red_shares > 0:
            assets += mul_div(s, e.red_assets, e.red_shares)
            burned_for_me = mul_div_up(s, e.red_burned, e.red_shares)
            if burned_for_me < s:
                shares += s - burned_for_me
        return shares, assets, carried

    def _claim_if_settled(self, a, wallet):
        r = self._r(a)
        if r.epoch >= self.current:
            return
        if r.dep == 0 and r.red == 0:
            return
        shares, assets, carried = self.claimable_with_carry(a)
        if not carried:
            r.dep = 0
        r.red = 0
        if shares > 0:
            self.transfer(VAULT, a, shares)
        if assets > 0:
            assets = min(assets, self.claimable)
            self.claimable -= assets
            self.usdc -= assets
            wallet[a] += assets

    def _rejoin_carry(self, a):
        r = self._r(a)
        if r.dep == 0 or r.epoch >= self.current:
            return
        _, _, carried = self.claimable_with_carry(a)
        if carried:
            r.epoch = self.current

    def request_deposit(self, sender, assets, controller, wallet):
        if assets < MIN_DEPOSIT:
            raise Revert("DepositTooSmall")
        if self.deposits_paused or self.breached or self.emergency:
            raise Revert("DepositsClosed")
        self._claim_if_settled(controller, wallet)
        self._rejoin_carry(controller)
        ins = self.insider(sender) or self.insider(controller)
        epoch = self.current + 1 if ins else self.current
        r = self._r(controller)
        if (r.dep > 0 or r.red > 0) and r.epoch != epoch:
            raise Revert("RequestPending")
        assert wallet[sender] >= assets
        wallet[sender] -= assets
        self.usdc += assets
        r.epoch = epoch
        r.dep += assets
        if ins:
            self.deferred_dep += assets
        else:
            self.pending_dep += assets
        if self.hooks:
            self.hooks.on_deposit(sender, controller, assets, ins)

    def request_redeem(self, sender, shares, controller, owner, wallet):
        if sender != owner:
            raise Revert("Unauthorized")  # the generator never uses allowances
        self._claim_if_settled(controller, wallet)
        self._rejoin_carry(controller)
        r = self._r(controller)
        if r.epoch > self.current:
            raise Revert("RequestPending")
        if self.hooks:
            self.hooks.on_redeem(controller, shares, self.bal.get(owner, 0))
        self.transfer(owner, VAULT, shares)
        r.epoch = self.current
        r.red += shares
        self.pending_red += shares

    def cancel_deposit(self, a, wallet):
        r = self._r(a)
        if r.dep == 0:
            raise Revert("NothingToCancel")
        if r.epoch < self.current:
            _, _, carried = self.claimable_with_carry(a)
            if not carried:
                raise Revert("NothingToCancel")
        assets = r.dep
        r.dep = 0
        if r.epoch > self.current:
            self.deferred_dep -= assets
            r.epoch = self.current
        else:
            self.pending_dep -= assets
        self.usdc -= assets
        wallet[a] += assets
        if self.hooks:
            self.hooks.on_cancel_deposit(a, assets)

    def cancel_redeem(self, a, wallet):
        self._claim_if_settled(a, wallet)
        r = self._r(a)
        if r.epoch != self.current or r.red == 0:
            raise Revert("NothingToCancel")
        shares = r.red
        r.red = 0
        self.pending_red -= shares
        self.transfer(VAULT, a, shares)
        if self.hooks:
            self.hooks.on_cancel_redeem(a)

    def claim(self, a, wallet):
        r = self._r(a)
        if r.epoch >= self.current:
            raise Revert("RequestNotSettled")
        _, _, carried = self.claimable_with_carry(a)
        if carried and r.red == 0:
            raise Revert("RequestNotSettled")
        self._claim_if_settled(a, wallet)

    # ------------------------------------------------------------------ settle (SPEC S1-S9)
    def settle(self, caller):
        if self.cp_at == 0:
            self.check_risk()
        treasury = caller == self.manager or (self.operator is not None and caller == self.operator)
        platform = caller in (self.owner, self.guardian)
        if not treasury and not platform:
            raise Revert("Unauthorized")
        if self.hard_stop() and not self.emergency:
            raise Revert("ReduceOnlyMode")
        red_only = self.loss_breach()
        exit_only = self.emergency or ((not treasury) and not red_only)
        if exit_only and not self.emergency and not self.overdue():
            raise Revert("Unauthorized")
        if (not exit_only and not red_only and (self.insider_in_queue or self.pending_dep > 0)
                and self.now < self.epoch_started + INSIDER_MIN_EPOCH_AGE):
            raise Revert("EpochTooYoung")
        # the whole settle is atomic: work on a snapshot and roll back on revert
        snap = self._snapshot()
        try:
            return self._settle(red_only, exit_only)
        except Revert:
            self._restore(snap)
            raise

    def _settle(self, red_only, exit_only):
        venue, _, vh = self.venue(high=(not exit_only and not red_only and self.pending_dep > 0))
        mode = "exit" if exit_only else ("redonly" if red_only else "normal")
        self._accrue((not self.breached) and not self.emergency, venue)
        if self.pending_perf != 0 and not self.breached and not self.emergency:
            self.perf = self.pending_perf
            self.pending_perf = 0
        if self.hooks:
            self.hooks.on_settle_pre(self)
        idle0 = self.idle()
        nav = idle0 + venue
        price_nav = nav
        if exit_only:
            if 0 < self.cp_nav < nav:
                price_nav = self.cp_nav
        else:
            cp = self.cp_nav
            self.checkpoint(nav, True)
            if red_only and 0 < cp < nav:
                price_nav = cp
        dep_assets = 0 if red_only else self.pending_dep
        dep_in = 0 if exit_only else dep_assets
        red_shares = self.pending_red
        supply = self.supply
        red_assets = self.to_assets(red_shares, price_nav, supply)
        buy_nav = max(nav, idle0 + vh)
        dep_shares = self.to_shares(dep_in, buy_nav, supply)
        if dep_shares == 0:
            dep_in = 0
        available = idle0 + dep_in
        paid, burned = red_assets, red_shares
        if available < red_assets:
            if not self.emergency:
                raise Revert("InsufficientLiquidity")
            paid = available
            burned = mul_div(red_shares, paid, red_assets)
        if burned > 0:
            self.burn(VAULT, burned)
        if dep_shares > 0:
            self.mint(VAULT, dep_shares)
        self.claimable += paid + dep_assets - dep_in
        epoch = self.current
        carried_from = 0
        if red_only:
            if self.pending_dep > 0:
                if self.carry_origin == 0:
                    self.carry_origin = epoch + 1
                carried_from = self.carry_origin
            if self.deferred_dep > 0:
                self.insider_in_queue = True
            self.pending_dep += self.deferred_dep
        else:
            if self.carry_origin != 0:
                self.carry_priced_in[self.carry_origin - 1] = epoch + 1
                self.carry_origin = 0
            self.pending_dep = self.deferred_dep
            self.insider_in_queue = self.deferred_dep > 0
        self.deferred_dep = 0
        self.pending_red = 0
        nav_after = self.idle() + venue
        price = self.to_assets(ONE_SHARE, nav_after, self.supply)
        if supply == 0 and dep_shares > 0:
            self.hwm = self.peak = self.day_start = price
        if price > self.peak:
            self.peak = price
        er = EpochResult(dep_assets, dep_shares, red_shares, paid, burned, nav_after, price, self.now, carried_from, mode)
        self.epochs[epoch] = er
        self.current = epoch + 1
        self.epoch_started = self.now
        self.cp_nav, self.cp_at = nav_after, self.now
        if self.hooks:
            self.hooks.on_settle(self, er, red_only, exit_only, dep_in > 0 or dep_assets == 0, red_assets)
        return er

    # ------------------------------------------------------------------ trading (SPEC T1-T3, R2)
    def can_open(self, caller, pair, long, coll, lev):
        if caller != self.manager:
            return "Unauthorized"
        if self.breached or self.emergency:
            return "ReduceOnlyMode"
        if self.trading_paused:
            return "ReduceOnlyMode"
        if self.overdue():
            return "EpochOverdue"
        value, notional, _ = self.venue()
        if len(self.d.open_trades()) >= MAX_POSITIONS:
            return "TooManyPositions"
        idle = self.idle()
        if coll > idle:
            return "InsufficientIdle"
        size = coll * lev // 1000
        p = self.d.pairs[pair]
        if size > self.risk.max_notional:
            return "OrderRejected"
        if coll < 5 * p.min_fee:
            return "OrderRejected"
        if (notional + size) * BPS > self.risk.max_lev * (idle + value):
            return "OrderRejected"
        return None

    def open_trade(self, caller, pair, long, coll, lev, fill_price):
        why = self.can_open(caller, pair, long, coll, lev)
        if why:
            raise Revert(why)
        self.usdc -= coll
        t = self.d.open(pair, long, coll, lev, fill_price)
        if self.hooks:
            self.hooks.on_trade_cash(-coll)
        return t

    def close_trade(self, caller, idx, fill_price):
        if caller not in (self.manager, self.guardian) and not (
                caller in (self.owner,) and (self.breached or self.emergency)):
            raise Revert("Unauthorized")
        t = self.d.trades[idx]
        assert t.is_open
        paid = self.d.close(t, fill_price)
        self.usdc += paid
        if self.hooks:
            self.hooks.on_trade_cash(paid)
        return paid

    def donate(self, amount):
        self.usdc += amount
        if self.hooks:
            self.hooks.on_trade_cash(amount)

    # ------------------------------------------------------------------ atomicity helper
    def _snapshot(self):
        import copy
        return copy.deepcopy({k: v for k, v in self.__dict__.items() if k not in ("d", "cl", "hooks", "risk")}), \
            (self.hooks.snapshot() if self.hooks else None)

    def _restore(self, snap):
        state, hs = snap
        self.__dict__.update(state)
        if self.hooks and hs is not None:
            self.hooks.restore(hs)


