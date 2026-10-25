// VERIFY-R2 item 1: every open gTrade trade on Arbitrum One against the GV-01 size bound.
// Reads all traders with open trades (getTraders), their trades (getTrades) at one block, and computes
//   expected = collateral x precisionDelta x leverage x 1e10 / (1e3 x openPrice)   (GainsNav._checkSize, verbatim)
//   ratio    = positionSizeToken / expected                                        (bound: 1/4 <= ratio <= 4)
// Trades opened before v10 (TradeInfo.contractsVersion < 2) carry positionSizeToken 0 and are reported apart:
// a vault opens only v10 trades.
// plus GainsNav._plausible (leverage, openPrice, collateral > 0, tradeType <= STOP) on every open element.
// Read only (eth_call through Multicall3). Usage, from contracts/:
//   ARBITRUM_RPC_URL=... node audit/gains/verify-r2/scan-size-ratio.mjs [block] > audit/gains/verify-r2/data/scan-<block>.json
// viem is taken from the server's node_modules (VIEM env var to override).
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const viemPath = process.env.VIEM ?? path.resolve('../server/node_modules/viem/_esm/index.js');
const { createPublicClient, http, parseAbi } = await import(pathToFileURL(viemPath).href);
const { arbitrum } = await import(pathToFileURL(path.join(path.dirname(viemPath), 'chains/index.js')).href);

const DIAMOND = '0xFF162c694eAA571f685030649814282eA457f169';
const rpc = process.env.ARBITRUM_RPC_URL;
if (!rpc) throw new Error('ARBITRUM_RPC_URL');
const client = createPublicClient({ chain: arbitrum, transport: http(rpc, { timeout: 60_000, retryCount: 5 }), batch: { multicall: { batchSize: 200_000 } } });

const TRADE = 'address user,uint32 index,uint16 pairIndex,uint24 leverage,bool long,bool isOpen,uint8 collateralIndex,uint8 tradeType,uint120 collateralAmount,uint64 openPrice,uint64 tp,uint64 sl,bool isCounterTrade,uint160 positionSizeToken,uint24 __placeholder';
const abi = parseAbi([
  'function getTradersCount() view returns (uint256)',
  'function getTraders(uint32 offset, uint32 limit) view returns (address[])',
  `function getTrades(address trader) view returns ((${TRADE})[])`,
  'function getCollateral(uint8 index) view returns ((address collateral,bool isActive,uint88 __placeholder,uint128 precision,uint128 precisionDelta))',
  'function getCollateralsCount() view returns (uint8)',
  'function getTradeInfo(address trader, uint32 index) view returns ((uint32 createdBlock,uint32 tpLastUpdatedBlock,uint32 slLastUpdatedBlock,uint16 maxSlippageP,uint48 lastOiUpdateTs,uint48 collateralPriceUsd,uint8 contractsVersion,uint32 lastPosIncreaseBlock,uint8 __placeholder))',
]);

const blockNumber = process.argv[2] ? BigInt(process.argv[2]) : await client.getBlockNumber();
const read = (functionName, args = []) => client.readContract({ address: DIAMOND, abi, functionName, args, blockNumber });

const nColl = Number(await read('getCollateralsCount'));
const precisionDelta = {};
for (let i = 1; i <= nColl; i++) precisionDelta[i] = (await read('getCollateral', [i])).precisionDelta;

const count = Number(await read('getTradersCount'));
const traders = new Set();
for (let off = 0; off < count; off += 1000) {
  const list = await read('getTraders', [off, Math.min(off + 999, count - 1)]);
  for (const t of list) if (t !== '0x0000000000000000000000000000000000000000') traders.add(t);
}

const all = [...traders];
const trades = [];
for (let i = 0; i < all.length; i += 300) {
  const chunk = all.slice(i, i + 300);
  const res = await Promise.all(chunk.map((t) => read('getTrades', [t])));
  res.forEach((list) => trades.push(...list));
}

// contractsVersion: 0 / 1 = opened before v10 (positionSizeToken was introduced by v10), 2 = v10
const market = trades.filter((t) => t.isOpen && t.tradeType === 0);
const infos = [];
for (let i = 0; i < market.length; i += 300) {
  infos.push(...(await Promise.all(market.slice(i, i + 300).map((t) => read('getTradeInfo', [t.user, t.index])))));
}
const version = new Map(market.map((t, i) => [`${t.user}-${t.index}`, infos[i].contractsVersion]));
const created = new Map(market.map((t, i) => [`${t.user}-${t.index}`, infos[i].createdBlock]));

// ratio in 1e6 fixed point
const rows = [];
const implausible = [];
for (const t of trades) {
  if (!t.isOpen) continue;
  const plausible = t.leverage > 0 && t.openPrice > 0n && t.collateralAmount > 0n && t.tradeType <= 2;
  if (!plausible) implausible.push(t);
  if (t.tradeType !== 0 || !plausible) continue;
  const pd = precisionDelta[t.collateralIndex];
  const expected = (t.collateralAmount * pd * BigInt(t.leverage) * 10_000_000_000n) / (1000n * t.openPrice);
  const size = t.positionSizeToken;
  const ratio = expected === 0n ? null : Number((size * 1_000_000n) / expected) / 1e6;
  const fails = size === 0n || size * 4n < expected || size > expected * 4n;
  rows.push({ v: version.get(`${t.user}-${t.index}`), created: created.get(`${t.user}-${t.index}`), user: t.user, index: t.index, pair: t.pairIndex, ci: t.collateralIndex, lev: t.leverage, coll: t.collateralAmount.toString(), openPrice: t.openPrice.toString(), size: size.toString(), expected: expected.toString(), ratio, fails });
}

const v10 = rows.filter((r) => r.v >= 2);
const legacy = rows.filter((r) => r.v < 2);
const byCi = {};
for (const r of v10) {
  const b = (byCi[r.ci] ??= { n: 0, min: Infinity, max: 0, minRow: null, maxRow: null, fails: 0 });
  b.n++;
  if (r.fails) b.fails++;
  if (r.ratio !== null && r.ratio < b.min) { b.min = r.ratio; b.minRow = r; }
  if (r.ratio !== null && r.ratio > b.max) { b.max = r.ratio; b.maxRow = r; }
}
// TradeInfo.createdBlock is moved by Gains on a size change, so "open for 30 days" here means untouched for 30 days
const stat = (g) => g.length ? { n: g.length, min: Math.min(...g.map((r) => r.ratio)), max: Math.max(...g.map((r) => r.ratio)), fails: g.filter((r) => r.fails).length } : { n: 0 };
const vaultPairsUsdc = stat(v10.filter((r) => [0, 1, 33].includes(r.pair) && r.ci === 3));
const untouched30d = stat(v10.filter((r) => BigInt(r.created) < blockNumber - 30n * 345_600n));
const untouched7d = stat(v10.filter((r) => BigInt(r.created) < blockNumber - 7n * 345_600n));
const sorted = v10.filter((r) => r.ratio !== null).sort((a, b) => Math.abs(Math.log(b.ratio)) - Math.abs(Math.log(a.ratio)));
console.log(JSON.stringify({
  block: blockNumber.toString(),
  traders: all.length,
  openElements: trades.filter((t) => t.isOpen).length,
  marketTrades: rows.length,
  v10Trades: v10.length,
  legacyTrades: { n: legacy.length, zeroSize: legacy.filter((r) => r.size === '0').length, failBound: legacy.filter((r) => r.fails).length, versions: [...new Set(legacy.map((r) => r.v))] },
  v10FailsBound: v10.filter((r) => r.fails),
  vaultPairsUsdc, untouched7d, untouched30d,
  v10Pairs: [...new Set(v10.map((r) => r.pair))].length,
  implausible: implausible.map((t) => ({ user: t.user, index: t.index, lev: t.leverage, coll: t.collateralAmount.toString(), openPrice: t.openPrice.toString(), type: t.tradeType })),
  byCollateralIndex: byCi,
  furthestFrom1: sorted.slice(0, 25),
}, null, 1));
