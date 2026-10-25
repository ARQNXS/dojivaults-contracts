// VERIFY-R2 item 1: real gTrade trades right after a partial close, a partial open or a leverage update, against
// the GV-01 size bound. Collects PositionSizeDecreaseExecuted / PositionSizeIncreaseExecuted / LeverageUpdateExecuted
// (executed, cancelReason NONE) over a block range, then reads the trade (getTrade, getTradeInfo) at the event's
// block (the state after that block) and computes the ratio as GainsNav._checkSize does:
//   expected = collateral x precisionDelta x leverage x 1e10 / (1e3 x openPrice), ratio = positionSizeToken / expected
// Read only. Usage, from contracts/:
//   ARBITRUM_RPC_URL=... node audit/gains/verify-r2/scan-history.mjs <fromBlock> <toBlock> > audit/gains/verify-r2/data/history-<from>-<to>.json
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const viemPath = process.env.VIEM ?? path.resolve('../server/node_modules/viem/_esm/index.js');
const { createPublicClient, http, parseAbi } = await import(pathToFileURL(viemPath).href);
const { arbitrum } = await import(pathToFileURL(path.join(path.dirname(viemPath), 'chains/index.js')).href);

const DIAMOND = '0xFF162c694eAA571f685030649814282eA457f169';
const client = createPublicClient({ chain: arbitrum, transport: http(process.env.ARBITRUM_RPC_URL, { timeout: 120_000, retryCount: 5 }), batch: { multicall: true } });

// topic0 of the v10 events (cast keccak of the canonical signatures; the decrease topic was checked against tx
// 0x8d6d3bfd..., a real partial close)
const TOPICS = {
  DEC: '0x38297f283e8c7319a10c298de767e2b919d8f506a0c15c6579fb7ad1c049cb43',
  INC: '0x3b7323355a4d9442335bf892bd48defd6c1647cb9c7170cb42f41dfba8e95aeb',
  LEV: '0x2fb840f62af77e2ac17f7499425ebdb903a2c05b9d00b29fe2cec3e308f6a99e',
};
const TRADE = 'address user,uint32 index,uint16 pairIndex,uint24 leverage,bool long,bool isOpen,uint8 collateralIndex,uint8 tradeType,uint120 collateralAmount,uint64 openPrice,uint64 tp,uint64 sl,bool isCounterTrade,uint160 positionSizeToken,uint24 __placeholder';
const abi = parseAbi([
  `function getTrade(address trader, uint32 index) view returns ((${TRADE}))`,
  'function getTradeInfo(address trader, uint32 index) view returns ((uint32 createdBlock,uint32 tpLastUpdatedBlock,uint32 slLastUpdatedBlock,uint16 maxSlippageP,uint48 lastOiUpdateTs,uint48 collateralPriceUsd,uint8 contractsVersion,uint32 lastPosIncreaseBlock,uint8 __placeholder))',
]);
const PD = { 1: 1n, 2: 1n, 3: 1_000_000_000_000n, 4: 1n };

const from = BigInt(process.argv[2]);
const to = BigInt(process.argv[3]);
const STEP = BigInt(process.env.STEP ?? 2_000_000);

const events = [];
for (let a = from; a <= to; a += STEP) {
  const b = a + STEP - 1n > to ? to : a + STEP - 1n;
  const logs = await client.request({ method: 'eth_getLogs', params: [{ address: DIAMOND, fromBlock: `0x${a.toString(16)}`, toBlock: `0x${b.toString(16)}`, topics: [Object.values(TOPICS)] }] });
  for (const l of logs) {
    const kind = Object.keys(TOPICS).find((k) => TOPICS[k] === l.topics[0]);
    const w = (i) => BigInt(`0x${l.data.slice(2 + 64 * i, 2 + 64 * (i + 1))}`);
    // DEC / INC: orderId (2 words), cancelReason; LEV: orderId (2 words), isIncrease, cancelReason
    const cancel = kind === 'LEV' ? w(3) : w(2);
    if (cancel !== 0n) continue;
    const isIncrease = kind === 'LEV' ? w(2) === 1n : kind === 'INC';
    // INC: collateralDelta 0 = leverage-only increase. DEC: collateralDelta (word 7) 0 = a leverage-only size decrease
    const collateralDelta = kind === 'LEV' ? null : w(7);
    events.push({ kind, isIncrease, collateralDelta: collateralDelta?.toString() ?? null, trader: `0x${l.topics[2].slice(26)}`, index: Number(BigInt(l.topics[3])), block: BigInt(l.blockNumber), tx: l.transactionHash });
  }
}

// historical reads: the provider answers an occasional "layer stale"; retried, and counted if it persists
const reader = createPublicClient({ chain: arbitrum, transport: http(process.env.ARBITRUM_RPC_URL, { timeout: 120_000, retryCount: 0 }) });
async function at(e) {
  for (let k = 0; k < 4; k++) {
    try {
      const [t, info] = await Promise.all([
        reader.readContract({ address: DIAMOND, abi, functionName: 'getTrade', args: [e.trader, e.index], blockNumber: e.block }),
        reader.readContract({ address: DIAMOND, abi, functionName: 'getTradeInfo', args: [e.trader, e.index], blockNumber: e.block }),
      ]);
      return { e, t, info };
    } catch {
      await new Promise((r) => setTimeout(r, 1000 * (k + 1)));
    }
  }
  return { e, t: null };
}
const rows = [];
let unread = 0;
for (let i = 0; i < events.length; i += 50) {
  const res = await Promise.all(events.slice(i, i + 50).map(at));
  for (const { e, t, info } of res) {
    if (!t) { unread++; continue; }
    if (!t.isOpen || t.tradeType !== 0) continue; // fully closed in that block
    const pd = PD[t.collateralIndex];
    const expected = t.openPrice > 0n ? (t.collateralAmount * pd * BigInt(t.leverage) * 10_000_000_000n) / (1000n * t.openPrice) : 0n;
    const size = t.positionSizeToken;
    const ratio = expected === 0n ? null : Number((size * 1_000_000n) / expected) / 1e6;
    const fails = size === 0n || size * 4n < expected || size > expected * 4n || t.leverage === 0 || t.collateralAmount === 0n || t.openPrice === 0n;
    rows.push({ kind: e.kind, isIncrease: e.isIncrease, collateralDelta: e.collateralDelta, v: info.contractsVersion, block: e.block.toString(), tx: e.tx, user: t.user, index: t.index, pair: t.pairIndex, ci: t.collateralIndex, lev: t.leverage, coll: t.collateralAmount.toString(), openPrice: t.openPrice.toString(), size: size.toString(), expected: expected.toString(), ratio, fails });
  }
}

const v10 = rows.filter((r) => r.v >= 2);
const group = (f) => {
  const g = v10.filter(f).filter((r) => r.ratio !== null);
  if (!g.length) return { n: 0 };
  const min = g.reduce((m, r) => (r.ratio < m.ratio ? r : m));
  const max = g.reduce((m, r) => (r.ratio > m.ratio ? r : m));
  return { n: g.length, fails: g.filter((r) => r.fails).length, min: min.ratio, minAt: { user: min.user, index: min.index, tx: min.tx, block: min.block }, max: max.ratio, maxAt: { user: max.user, index: max.index, tx: max.tx, block: max.block } };
};
console.log(JSON.stringify({
  from: from.toString(), to: to.toString(), events: events.length, unread, openAfter: rows.length, v10: v10.length,
  legacy: { n: rows.length - v10.length, fails: rows.filter((r) => r.v < 2 && r.fails).length },
  v10Fails: v10.filter((r) => r.fails),
  groups: {
    partialClose: group((r) => r.kind === 'DEC' && r.collateralDelta !== '0'),
    sizeDecreaseLeverageOnly: group((r) => r.kind === 'DEC' && r.collateralDelta === '0'),
    partialOpenWithCollateral: group((r) => r.kind === 'INC' && r.collateralDelta !== '0'),
    partialOpenLeverageOnly: group((r) => r.kind === 'INC' && r.collateralDelta === '0'),
    leverageIncrease: group((r) => r.kind === 'LEV' && r.isIncrease),
    leverageDecrease: group((r) => r.kind === 'LEV' && !r.isIncrease),
    // the vault's pairs: BTC 0, ETH 1, SOL 33 on USDC (collateral index 3)
    vaultPairsUsdc: group((r) => [0, 1, 33].includes(r.pair) && r.ci === 3),
  },
  rows: v10.sort((a, b) => Math.abs(Math.log(b.ratio)) - Math.abs(Math.log(a.ratio))).slice(0, 40),
}, null, 1));
