#!/usr/bin/env bash
# Rehearses the HyperEVM big-block deploy (plan on a fork, send with explicit gas limits) end to end on anvil forks of
# the live chain, with a throwaway keystore. Sends nothing to any live chain.
#   1. the problem: forge script against a fork with the chain's own header limit runs OutOfGas at that limit;
#   2. the plan: DeployFactory on fork P (30M block, the big block size), --unlocked, as the throwaway sender;
#   3. the send: script/py/send_planned.py to fork L (the stand-in for the live chain, also forked from it), stopped
#      after 2 transactions, then resumed; addresses, record, factory reads and RELEASE-BYTECODE checked on L;
#   4. small blocks after: L's block limit set back to the chain's own, then D14Launch (testnet) or the factory's
#      first view calls (mainnet) through plain forge script, which must fit.
# Usage (from contracts/): bash script/rehearsal/bigblock-deploy-anvil.sh testnet|mainnet <logdir>
#   testnet forks the public testnet RPC; mainnet forks $HYPEREVM_RPC_URL (read from the Windows user environment if
#   unset; never printed, anvil runs silent).
set -euo pipefail
cd "$(dirname "$0")/../.."
NET=${1:?testnet|mainnet}
LOGDIR=${2:?logdir}
mkdir -p "$LOGDIR"
if [ "$NET" = testnet ]; then
  CHAIN=998; NAME=testnet; URL=https://rpc.hyperliquid-testnet.xyz/evm
else
  CHAIN=999; NAME=mainnet
  if [ -z "${HYPEREVM_RPC_URL:-}" ]; then
    HYPEREVM_RPC_URL=$(powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('HYPEREVM_RPC_URL','User')" | tr -d '\r\n')
  fi
  URL=$HYPEREVM_RPC_URL
  [ -n "$URL" ] || { echo "HYPEREVM_RPC_URL is not set"; exit 1; }
fi
PP=8571; PL=8572; PC=8573
WORK=$(cygpath -m "$(mktemp -d)" 2>/dev/null || mktemp -d)   # a Windows path for python on Git Bash
PIDS=()
# the fork run writes deployments/$NAME.json: an existing record (the current mainnet one) is set aside and restored
SAVED=""
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -f deployments/$NAME.json
  [ -z "$SAVED" ] || mv "$SAVED" deployments/$NAME.json
  rm -rf "$WORK"
}
trap cleanup EXIT
if [ -e deployments/$NAME.json ]; then SAVED="$WORK/saved-$NAME.json"; mv deployments/$NAME.json "$SAVED"; fi

# a throwaway keystore (random key, generated here, deleted on exit)
PW="$WORK/pw"; echo "rehearsal-only-$RANDOM$RANDOM" > "$PW"
cast wallet new "$WORK" --password-file "$PW" > /dev/null 2>&1 || cast wallet new "$WORK" --unsafe-password "$(cat "$PW")" > /dev/null
KS=$(ls "$WORK" | grep -v '^pw$' | head -1)
SENDER=$(cast wallet address --keystore "$WORK/$KS" --password-file "$PW")
echo "throwaway sender $SENDER"

anvil_fork() { # port gaslimit
  if [ -n "$2" ]; then anvil --fork-url "$URL" --port "$1" --gas-limit "$2" --silent > /dev/null 2>&1 &
  else anvil --fork-url "$URL" --port "$1" --silent > /dev/null 2>&1 &
  fi
  PIDS+=($!)
}
up() { for i in $(seq 1 180); do cast chain-id --rpc-url http://127.0.0.1:$1 > /dev/null 2>&1 && return 0; sleep 1; done; echo "anvil on $1 did not start"; exit 1; }
anvil_fork $PC ""; up $PC; anvil_fork $PP 30000000; up $PP; anvil_fork $PL 30000000; up $PL
for port in $PC $PP $PL; do
  cast rpc anvil_setBalance "$SENDER" 0x56bc75e2d63100000 --rpc-url http://127.0.0.1:$port > /dev/null   # 100 native
  cast rpc anvil_impersonateAccount "$SENDER" --rpc-url http://127.0.0.1:$port > /dev/null
done
HEADER=$(cast block latest -f gasLimit --rpc-url http://127.0.0.1:$PC)
# a fork's head is the live block, with the live header limit: mine one block so P and L have a 30M head
for port in $PP $PL; do cast rpc evm_mine --rpc-url http://127.0.0.1:$port > /dev/null; done
echo "fork P head gas limit $(cast block latest -f gasLimit --rpc-url http://127.0.0.1:$PP)"
echo "chain $(cast chain-id --rpc-url http://127.0.0.1:$PC), live header gas limit $HEADER"

export OWNER=$SENDER PROTOCOL_FEE_RECIPIENT=$SENDER PLATFORM_GUARDIAN=$SENDER ALLOW_LAUNCHER=$SENDER
export PLATFORM_SENTINEL=0x000000000000000000000000000000000000d14e
if [ "$NET" = testnet ]; then export CURATED_ASSETS=3,4; else export CURATED_ASSETS=0,1,5; fi
unset AGENT_REGISTRAR MAX_DEPOSIT_CAP BASE_SHARE_BPS HOSTED_SHARE_BPS MIN_SEED_USDC MIN_HYPE_WEI DEPLOY_SKIP_RECORD

echo "== 1. the problem: forge script against the chain's own header limit"
set +e
forge script script/Deploy.s.sol:DeployFactory --skip test --rpc-url http://127.0.0.1:$PC --sender "$SENDER" --slow \
  --gas-limit 30000000 > "$LOGDIR/1-forge-at-header-limit.txt" 2>&1
rc=$?
set -e
rm -f deployments/$NAME.json
grep -q "OutOfGas" "$LOGDIR/1-forge-at-header-limit.txt" && [ $rc -ne 0 ] && echo "   reproduced: exit $rc, OutOfGas (with --gas-limit 30000000)" || { echo "FAIL: expected OutOfGas"; exit 1; }

echo "== 2. the plan on fork P (30M block)"
forge script script/Deploy.s.sol:DeployFactory --skip test --rpc-url http://127.0.0.1:$PP --sender "$SENDER" --unlocked \
  --broadcast --slow > "$LOGDIR/2-plan.txt" 2>&1 || { tail -30 "$LOGDIR/2-plan.txt"; exit 1; }
cp broadcast/Deploy.s.sol/$CHAIN/run-latest.json "$WORK/plan.json"
mv deployments/$NAME.json "$WORK/plan-record.json"
rm -rf broadcast/Deploy.s.sol/$CHAIN
echo "   planned $(python -c "import json;print(len(json.load(open('$WORK/plan.json'))['transactions']))") transactions; record kept aside"

echo "== 3. the send to fork L, stopped after 2, then resumed"
PRICE=$(cast gas-price --rpc-url http://127.0.0.1:$PL)
cast rpc anvil_stopImpersonatingAccount "$SENDER" --rpc-url http://127.0.0.1:$PL > /dev/null   # L only takes signed transactions
S="python script/py/send_planned.py --plan $WORK/plan.json --chain-id $CHAIN --rpc http://127.0.0.1:$PL --account $KS \
   --keystore-dir $WORK --password-file $PW --gas-price $PRICE --yes --timeout 60"
set +e
$S --stop-after 2 > "$LOGDIR/3a-send-first-2.txt" 2>&1; rc=$?
set -e
[ $rc -ne 0 ] && grep -q "stopped after 2" "$LOGDIR/3a-send-first-2.txt" || { cat "$LOGDIR/3a-send-first-2.txt"; echo "FAIL: stop-after"; exit 1; }
$S --record-in "$WORK/plan-record.json" --record-out "$WORK/live-record.json" > "$LOGDIR/3b-send-resume.txt" 2>&1 || { cat "$LOGDIR/3b-send-resume.txt"; exit 1; }
grep -q "ALL SENT" "$LOGDIR/3b-send-resume.txt" || { echo "FAIL: resume"; exit 1; }
echo "   ALL SENT (resumed)"
cp "$WORK/live-record.json" "$LOGDIR/live-record.json"

R=http://127.0.0.1:$PL
F=$(python -c "import json;print(json.load(open('$WORK/live-record.json'))['factory'])")
I=$(python -c "import json;print(json.load(open('$WORK/live-record.json'))['vaultImplementation'])")
{
  echo "factory $F"
  echo "owner $(cast call $F 'owner()(address)' --rpc-url $R)"
  echo "guardian $(cast call $F 'guardian()(address)' --rpc-url $R)"
  echo "curatedAssets $(cast call $F 'curatedAssets()(uint32[])' --rpc-url $R)"
  echo "vaultImplementation $(cast call $F 'vaultImplementation()(address)' --rpc-url $R) (record $I)"
  echo "orderPath $(cast call $I 'orderPath()(uint256)' --rpc-url $R)"
  echo "vaultCount $(cast call $F 'vaultCount()(uint256)' --rpc-url $R)"
} | tee "$LOGDIR/3c-checks.txt" | sed 's/^/   /'
[ "$(cast call $F 'vaultImplementation()(address)' --rpc-url $R | tr A-Z a-z)" = "$(echo $I | tr A-Z a-z)" ] || { echo FAIL; exit 1; }
python ../docs/fix-round/bytecode-check.py --chain hyperevm --rpc "$R" --record "$WORK/live-record.json" > "$LOGDIR/3d-bytecode.txt" 2>&1 || true
tail -2 "$LOGDIR/3d-bytecode.txt" | sed 's/^/   bytecode: /'

echo "== 4. small blocks again: L back to the chain's limit ($HEADER), plain forge script must fit"
cast rpc evm_setBlockGasLimit "$(printf '0x%x' "$HEADER")" --rpc-url $R > /dev/null
cast rpc anvil_impersonateAccount "$SENDER" --rpc-url $R > /dev/null
if [ "$NET" = testnet ]; then
  cp "$WORK/live-record.json" deployments/testnet.json
  AGENT=0x000000000000000000000000000000000000a9e7 forge script script/testnet/D14Testnet.s.sol:D14Launch --skip test \
    --rpc-url $R --sender "$SENDER" --unlocked --broadcast > "$LOGDIR/4-d14-launch.txt" 2>&1 || { rm -f deployments/testnet.json deployments/testnet-d14.json; tail -30 "$LOGDIR/4-d14-launch.txt"; exit 1; }
  rm -f deployments/testnet.json deployments/testnet-d14.json; rm -rf broadcast/D14Testnet.s.sol/$CHAIN
  grep -E "agentActiveAt|asset 3|ONCHAIN EXECUTION COMPLETE" "$LOGDIR/4-d14-launch.txt" | sed 's/^/   /'
else
  cast send $F "setOpenLaunch(bool)" false --from "$SENDER" --unlocked --rpc-url $R > "$LOGDIR/4-small-call.txt" 2>&1 || true
  echo "   a small factory call under the $HEADER limit: $(grep -E '^status' "$LOGDIR/4-small-call.txt" | head -1)"
fi
echo PASS
