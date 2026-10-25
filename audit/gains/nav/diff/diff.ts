/**
 * Round 1 Gains review, sub-reviewer 3.1: differential NAV.
 *
 * Recomputes the close value of each recorded trade independently of GainsNav.sol, from the pieces the
 * @gainsnetwork/sdk 1.8.10 exports (getPnlPercent, getTradeValue, getFixedSpreadP, getPriceAfterImpact,
 * getTradeSkewPriceImpact, getTotalTradeFeesCollateral, getTradeRealizedPnlCollateral, getLiqPnlThresholdP,
 * convertLiquidationParams) composed as the verified gTrade v10 facet source does it
 * (TradingCommonUtils.getTradeClosingPriceImpact / getTradeValueCollateral, BorrowingFeesUtils.getTradeLiquidationPrice).
 *
 * Inputs: the JSON the forge fork tests write (test/audit/gains/nav/NavDiffFork.t.sol, NavReplayFork.t.sol):
 * raw diamond state per trade (trade, tradeInfo, liquidation params, fee params, OI tokens and skew depth, the two
 * cumulative-volume impact passes, pending holding fees at the price, TradeFeesData), Chainlink, band, GainsNav's
 * value, and the USDC Gains paid. Taken from the diamond as inputs (not recomputed): pending holding fees (funding +
 * borrowing accumulators) and the cumulative-volume impact of each pass (OI windows); everything else is recomputed.
 *
 * Usage: npx tsx diff.ts <json files...>   (prints a report; --md writes DIFF tables to stdout as markdown)
 */
import * as fs from "node:fs";
import {
  getPnlPercent,
  getTradeValue,
  getFixedSpreadP,
  getPriceAfterImpact,
  getTradeSkewPriceImpact,
  getTotalTradeFeesCollateral,
  getTradeRealizedPnlCollateral,
  getLiqPnlThresholdP,
  convertLiquidationParams,
} from "@gainsnetwork/sdk";

type Raw = Record<string, string | boolean | number>;
interface Row {
  rec: Raw;
  paidAmount: string;
}

const n = (r: Raw, k: string): number => {
  const v = r[k];
  if (v === undefined) throw new Error(`missing ${k} in ${r.tag}`);
  return Number(v as string);
};
const b = (r: Raw, k: string): boolean => r[k] === true;

export interface Result {
  tag: string;
  pair: number;
  long: boolean;
  lev: number;
  coll: number;
  price: number;
  exact: number; // TS: what Gains pays at `price`
  navModel: number; // TS: the documented NAV rule (no fee tier, 0 within the band of liquidation)
  gainsNav: number; // GainsNav.tradeValue at `price`
  gainsNavNoBand: number; // GainsNav with band 0 (Gains' own liquidation rule)
  paid: number; // USDC Gains paid (fork fill or real tx), -1 if none
  liqTs: number;
  liqDiamond: number;
  skewTs: number;
  skewDiamond: number;
  realizedTs: number;
  realizedDiamond: number;
  pnlPositivePass: boolean;
  liquidatedExact: boolean;
  nearLiq: boolean;
}

export function compute(r: Raw, paid: number): Result {
  const coll = n(r, "collateralAmount") / 1e6;
  const lev = n(r, "leverage") / 1e3;
  const open = n(r, "openPrice") / 1e10;
  const P = n(r, "price") / 1e10;
  const long = b(r, "long");
  const pair = n(r, "pairIndex");
  const cv = n(r, "contractsVersion");
  const band = n(r, "bandBps") / 1e4;

  // ---- fees: SDK getTotalTradeFeesCollateral (min-position basis), fee tier applied as calculateFeeAmount does
  const feeCtx = {
    fee: {
      totalPositionSizeFeeP: n(r, "totalPositionSizeFeeP") / 1e12, // 1e10 percent -> fraction
      minPositionSizeUsd: n(r, "minPositionSizeUsd") / 1e18,
    },
    collateralPriceUsd: n(r, "collateralPriceUsd") / 1e8,
    globalTradeFeeParams: undefined as any,
    traderFeeMultiplier: undefined,
  } as any;
  const feeRaw = getTotalTradeFeesCollateral(3, "", pair, coll * lev, false, feeCtx);
  const tier = b(r, "skipFeeTier") ? 1 : n(r, "feeTierOf1e12") / 1e12;
  const feeTiered = feeRaw * tier;

  // ---- realized pnl: SDK getTradeRealizedPnlCollateral over TradeFeesData
  const realized = getTradeRealizedPnlCollateral({
    realizedPnlCollateral: n(r, "fd_realizedPnlCollateral") / 1e6,
    realizedTradingFeesCollateral: n(r, "fd_realizedTradingFeesCollateral") / 1e6,
  } as any).totalRealizedPnlCollateral;

  // ---- holding fees at P: diamond input
  const holding = n(r, "h_total") / 1e6;

  // ---- impact: fixed spread (SDK), skew (SDK, from OI tokens and depth), cumulative volume (diamond, both passes)
  const spreadPct = n(r, "pairSpreadP") / 1e10;
  let fixed = 0,
    skew = 0,
    cumulNeg = 0,
    cumulPos = 0;
  if (cv >= 1) {
    fixed = getFixedSpreadP(spreadPct, long, false);
    if (cv >= 2) {
      skew = getTradeSkewPriceImpact(
        { collateralIndex: 3, pairIndex: pair, long, open: false, positionSizeToken: n(r, "positionSizeToken") / 1e18 } as any,
        {
          skewDepth: n(r, "skewDepth") / 1e18,
          pairOiToken: { oiLongToken: n(r, "oiLongToken") / 1e18, oiShortToken: n(r, "oiShortToken") / 1e18 },
        } as any
      ).totalPriceImpactP;
    }
    cumulNeg = n(r, "cumulNeg") / 1e10;
    cumulPos = n(r, "cumulPos") / 1e10;
  }
  // pass 1 (TradingCommonUtils.getTradeClosingPriceImpact): net value with fee tier, holding and realized pnl, no
  // protection factor; the protection factor applies when that net value is above the collateral.
  let cumul = 0;
  let pnlPositivePass = false;
  if (cv >= 1) {
    const p1 = getPriceAfterImpact(P, fixed + cumulNeg + skew);
    const v1 = getTradeValue(coll, getPnlPercent(open, p1, long, lev), feeTiered + holding - realized);
    pnlPositivePass = v1 > coll;
    cumul = pnlPositivePass ? cumulPos : cumulNeg;
  }
  const pai = cv >= 1 ? getPriceAfterImpact(P, fixed + cumul + skew) : P;
  const pnl = getPnlPercent(open, pai, long, lev);
  const valueTiered = getTradeValue(coll, pnl, feeTiered + holding - realized);
  const valueRaw = getTradeValue(coll, pnl, feeRaw + holding - realized);

  // ---- liquidation price (BorrowingFeesUtils._getTradeLiquidationPrice) with SDK threshold and params converter
  const lp = convertLiquidationParams({
    maxLiqSpreadP: n(r, "maxLiqSpreadP"),
    startLiqThresholdP: n(r, "startLiqThresholdP"),
    endLiqThresholdP: n(r, "endLiqThresholdP"),
    startLeverage: n(r, "startLeverage"),
    endLeverage: n(r, "endLeverage"),
  } as any);
  const thr = n(r, "maxLiqSpreadP") === 0 ? 0.9 : getLiqPnlThresholdP(lp, lev);
  const liqFees = feeRaw + (holding - realized); // closing fee never with fee tier
  let dist = (open * (coll * thr - liqFees)) / coll / lev;
  if (cv >= 1) {
    const s = Math.min(spreadPct / 100 / 2, lp.maxLiqSpreadP);
    dist -= open * s;
  }
  const liq = Math.max(long ? open - dist : open + dist, 0);
  const liquidatedExact = long ? P <= liq : P >= liq;
  const nearLiq = long ? P <= liq * (1 + band) : P >= liq * (1 - band);

  return {
    tag: String(r.tag),
    pair,
    long,
    lev,
    coll,
    price: P,
    exact: liquidatedExact ? 0 : valueTiered,
    navModel: nearLiq ? 0 : valueRaw,
    gainsNav: n(r, "gainsNavAtPrice") / 1e6,
    gainsNavNoBand: n(r, "gainsNavAtPriceNoBand") / 1e6,
    paid,
    liqTs: liq,
    liqDiamond: n(r, "diamondLiqAtPrice") / 1e10,
    skewTs: skew,
    skewDiamond: n(r, "diamondSkewP") / 1e10,
    realizedTs: realized,
    realizedDiamond: n(r, "rp_total") / 1e6,
    pnlPositivePass,
    liquidatedExact,
    nearLiq,
  };
}

/** divergence in bps of the trade value (base = the larger of the two, floor 1 USDC so dust rows don't explode) */
export const bps = (a: number, x: number): number => {
  const base = Math.max(Math.abs(a), Math.abs(x), 1);
  return (Math.abs(a - x) / base) * 1e4;
};

function bucket(lev: number): string {
  return lev < 10 ? "2-10x" : lev < 50 ? "10-50x" : "50-150x";
}

interface Agg {
  n: number;
  max: number;
  sum: number;
  maxAbs: number;
}
const agg = (): Agg => ({ n: 0, max: 0, sum: 0, maxAbs: 0 });
function add(a: Agg, d: number, abs: number) {
  a.n++;
  a.sum += d;
  a.max = Math.max(a.max, d);
  a.maxAbs = Math.max(a.maxAbs, abs);
}

function main() {
  const files = process.argv.slice(2).filter((f) => !f.startsWith("--"));
  const md = process.argv.includes("--md");
  const rows: Result[] = [];
  for (const f of files) {
    const arr: Row[] = JSON.parse(fs.readFileSync(f, "utf8"));
    for (const x of arr) rows.push(compute(x.rec, x.paidAmount === undefined ? -1 : Number(x.paidAmount) / 1e6));
  }
  const byPair: Record<string, Agg> = {};
  const byLev: Record<string, Agg> = {};
  const all = agg();
  const exactVsPaid = agg();
  const navVsPaid = agg();
  const findings: string[] = [];
  const lines: string[] = [];
  for (const r of rows) {
    // the comparison that matters: an independent implementation of the documented NAV rule vs GainsNav
    const d = bps(r.navModel, r.gainsNav);
    const abs = Math.abs(r.navModel - r.gainsNav);
    add(all, d, abs);
    add((byPair[String(r.pair)] ??= agg()), d, abs);
    add((byLev[bucket(r.lev)] ??= agg()), d, abs);
    if (r.paid >= 0) {
      add(exactVsPaid, bps(r.exact, r.paid), Math.abs(r.exact - r.paid));
      add(navVsPaid, bps(r.gainsNav, r.paid), r.paid - r.gainsNav);
    }
    if (d > 1) findings.push(`${r.tag} pair ${r.pair} lev ${r.lev}: TS ${r.navModel} vs GainsNav ${r.gainsNav} (${d.toFixed(3)} bp)`);
    lines.push(
      [
        r.tag,
        r.pair,
        r.long ? "L" : "S",
        r.lev.toFixed(2),
        r.coll.toFixed(2),
        r.exact.toFixed(6),
        r.navModel.toFixed(6),
        r.gainsNav.toFixed(6),
        r.paid >= 0 ? r.paid.toFixed(6) : "-",
        d.toFixed(4),
        r.paid >= 0 ? bps(r.exact, r.paid).toFixed(4) : "-",
        r.nearLiq ? "nearLiq" : "",
        r.liquidatedExact ? "liq" : "",
        `liqΔ=${(Math.abs(r.liqTs - r.liqDiamond) / Math.max(r.liqDiamond, 1e-12) * 1e4).toFixed(4)}bp`,
        `skewΔ=${Math.abs(r.skewTs - r.skewDiamond).toExponential(2)}%`,
        `realΔ=${Math.abs(r.realizedTs - r.realizedDiamond).toExponential(2)}`,
        r.pnlPositivePass ? "pass2:+" : "",
      ].join(" | ")
    );
  }
  const f = (a: Agg) => `n=${a.n} max=${a.max.toFixed(4)}bp mean=${(a.sum / Math.max(a.n, 1)).toFixed(4)}bp maxAbs=${a.maxAbs.toFixed(6)} USDC`;
  console.log("rows:", rows.length);
  console.log("TS (documented NAV rule) vs GainsNav, all:", f(all));
  for (const [k, a] of Object.entries(byPair)) console.log("  pair", k, f(a));
  for (const [k, a] of Object.entries(byLev)) console.log("  lev", k, f(a));
  console.log("TS exact (Gains close rule, fee tier) vs USDC paid:", f(exactVsPaid));
  console.log("GainsNav vs USDC paid (paid - nav >= 0 is conservative):", f(navVsPaid));
  console.log(findings.length ? "DIVERGENCES > 1 bp:\n" + findings.join("\n") : "no divergence above 1 bp");
  if (md) {
    console.log(
      "\n| tag | pair | side | lev | coll | TS exact | TS NAV rule | GainsNav | paid | TS NAV vs GainsNav bp | TS exact vs paid bp | near liq | liquidated | liq TS vs diamond | skew TS vs diamond | realized TS vs diamond | pass 2 |"
    );
    console.log("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|");
    for (const l of lines) console.log("| " + l + " |");
  } else {
    for (const l of lines) console.log(l);
  }
}

main();
