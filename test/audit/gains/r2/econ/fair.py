"""Fair-value transfer ledger for the ECON model (ECONOMICS.md section 2).

Fair value of a share at any instant = the vault's mid NAV / supply, where the mid NAV is the vault's own idle USDC
plus every open trade valued at the TRUE price (the price Gains' oracle fills at) through Gains' close path
(collateral + pnl - closing fee - holding fees + realized pnl), with no band. (Both use the ERC-4626 virtual offset
of the vault, +1 asset / +1e6 shares, so the conventions match.)

Each actor's economic position = (shares in the wallet + shares escrowed for redemption + settled shares not yet
claimed) x fair share value + USDC claimable + USDC queued as a deposit (at face value). Between settles a position
changes only through the market (pro rata to shares, no transfer) or the actor's own wallet moves (request, cancel,
claim: value preserving). So the only places where value can move BETWEEN actors are the settles (flows priced at
something other than the fair value, refunds, partial fills) and the fee mints. The ledger records, per actor:

* ``flow[a]``: value gained or lost across every settle (minus the fee part of that settle) = the transfer;
* ``fee[a]``: value gained or lost across fee mints (the fee recipient's receipts, everyone's dilution);
* ``perf_over[a]``: performance fee the actor bore minus what a per-lot (equalisation) charge would have been:
  each deposit lot is charged on its own gain above the price it paid (then above its last charge), instead of the
  vault's per-share high water mark. Positive = overcharged.

The sum of ``flow`` over all actors is the rounding left in the vault (unclaimable share dust, virtual offset).
"""
from __future__ import annotations

import copy

from model import ONE_SHARE, OFF


class TransferLedger:
    def __init__(self, diamond, true_px: dict, actors):
        self.d = diamond
        self.true_px = true_px
        self.actors = list(actors)
        self.flow = {a: 0.0 for a in self.actors}
        self.fee = {a: 0.0 for a in self.actors}
        self.perf_over = {a: 0.0 for a in self.actors}
        self.perf_paid = {a: 0.0 for a in self.actors}
        self.lots: dict = {a: [] for a in self.actors}  # [shares, reference price (vault units per ONE_SHARE)]
        self.dep_cur: dict = {}
        self.dep_next: dict = {}
        self._pre = None
        self._fee_pre = None
        self.unassigned = 0.0

    def snapshot(self):
        return copy.deepcopy({k: v for k, v in self.__dict__.items() if k not in ("d", "true_px")})

    def restore(self, s):
        self.__dict__.update(s)

    # ------------------------------------------------------------------ marks on the real vault
    def mid_nav(self, v) -> int:
        return v.idle() + sum(self.d.value_at(t, self.true_px[t.pair]) for t in self.d.open_trades())

    def share_value(self, v) -> float:
        return (self.mid_nav(v) + 1) / (v.supply + OFF)

    def econ(self, v, a):
        """(shares, usdc) of actor a: wallet + escrow + unclaimed settled shares; claimable + queued USDC."""
        shares = v.bal.get(a, 0)
        usdc = 0
        r = v.req.get(a)
        if r is not None:
            if r.epoch >= v.current:
                shares += r.red
                usdc += r.dep
            else:
                s, x, carried = v.claimable_with_carry(a)
                shares += s
                usdc += x
                if carried:
                    usdc += r.dep
        return shares, usdc

    def positions(self, v):
        px = self.share_value(v)
        out = {}
        for a in self.actors:
            s, u = self.econ(v, a)
            out[a] = (s, u, s * px + u)
        return out

    # ------------------------------------------------------------------ shadow requests (for the lots)
    def on_trade_cash(self, delta):
        pass

    def on_deposit(self, sender, controller, assets, insider):
        book = self.dep_next if insider else self.dep_cur
        book[controller] = book.get(controller, 0) + assets

    def on_cancel_deposit(self, a, assets):
        if self.dep_next.get(a, 0) > 0:
            self.dep_next[a] = 0
        else:
            self.dep_cur[a] = 0

    def on_redeem(self, controller, real_shares, real_balance):
        pass

    def on_cancel_redeem(self, a):
        pass

    # ------------------------------------------------------------------ fees
    def on_accrue_pre(self, v):
        self._fee_pre = self.positions(v)

    def on_accrue_post(self, v, fee_shares, mgmt_assets, perf_assets, price, new_price, with_perf):
        pre = self._fee_pre
        post = self.positions(v)
        for a in self.actors:
            self.fee[a] += post[a][2] - pre[a][2]
        if perf_assets > 0:
            supply_pre = sum(pre[a][0] for a in self.actors) or 1
            fr = v.fee_recipient
            perf = v.perf
            for a in self.actors:
                if a == fr:
                    continue
                borne = perf_assets * pre[a][0] / supply_pre
                fair = 0.0
                for lot in self.lots[a]:
                    if price > lot[1]:
                        fair += (price - lot[1]) * lot[0] / ONE_SHARE * perf / 10_000
                self.perf_paid[a] += borne
                self.perf_over[a] += borne - fair
        if with_perf:
            for a in self.actors:
                for lot in self.lots[a]:
                    if new_price > lot[1]:
                        lot[1] = new_price
        if fee_shares > 0:
            self.lots[v.fee_recipient].append([fee_shares, new_price])
        self._fee_pre = None

    # ------------------------------------------------------------------ settles
    def on_settle_pre(self, v):
        self._pre = (self.positions(v), dict(self.dep_cur))

    def on_settle(self, v, er, red_only, exit_only, _priced, _red_assets):
        pre, deps = self._pre
        post = self.positions(v)
        total = 0.0
        for a in self.actors:
            x = post[a][2] - pre[a][2]
            self.flow[a] += x
            total += x
            ds = post[a][0] - pre[a][0]
            if ds > 0:
                paid = deps.get(a, 0)
                ref = paid * ONE_SHARE / ds if paid > 0 else er.price
                self.lots[a].append([ds, ref])
            elif ds < 0:
                have = sum(l[0] for l in self.lots[a])
                k = (have + ds) / have if have > 0 else 0.0
                for lot in self.lots[a]:
                    lot[0] *= max(k, 0.0)
        self.unassigned -= total
        if not red_only:
            self.dep_cur = {}
        for a, x in self.dep_next.items():
            if x > 0:
                self.dep_cur[a] = self.dep_cur.get(a, 0) + x
        self.dep_next = {}
        self._pre = None
