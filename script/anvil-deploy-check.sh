#!/usr/bin/env bash
# Runs DeployFactory against a local anvil (chain id 31337) and checks what the mainnet deploy must guarantee:
#  - the script makes no bytecode-derived RPC reads (counts account / code fetches in anvil's log),
#  - every linked library address in deployments/local-31337.json has code,
#  - the implementation's link references point at those libraries (forge test does the byte level check).
# Usage: cd contracts && bash script/anvil-deploy-check.sh      (needs anvil, forge, cast, python)
set -euo pipefail
cd "$(dirname "$0")/.."
PORT=${PORT:-8547}
LOG=$(mktemp)
anvil --chain-id 31337 --port "$PORT" > "$LOG" 2>&1 &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true; rm -f "$LOG"' EXIT
sleep 3

export OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266   # anvil account 0, unlocked
export PROTOCOL_FEE_RECIPIENT=${PROTOCOL_FEE_RECIPIENT:-0x18483B23B326c30dd80E59C617A1483842B7e797}
export PLATFORM_GUARDIAN=${PLATFORM_GUARDIAN:-0x1A7acB7966e6E3632694484dE261B70230eCD7ff}
export PLATFORM_SENTINEL=${PLATFORM_SENTINEL:-0x8fEe38402cA8BB788b144af1ab7023e7B46F95F1}
export AGENT_REGISTRAR=${AGENT_REGISTRAR:-0x6702656173C413EAeda0CCD9d2c034051Ae0d198}

forge script script/Deploy.s.sol:DeployFactory --rpc-url "http://127.0.0.1:$PORT" --sender "$OWNER" --unlocked --broadcast --slow -vv

REC=deployments/local-31337.json
test -f "$REC" || { echo "missing $REC"; exit 1; }
# anvil answers forge's account fetches as eth_getAccountInfo (newer) or eth_getCode (older); either counts.
fetches=$(grep -cE "eth_getAccountInfo|eth_getCode" "$LOG" || true)
echo "account / code fetches during the run: $fetches (the bytecode scanner made ~3,400)"
if [ "$fetches" -gt 100 ]; then echo "FAIL: the script scans bytecode-derived addresses"; exit 1; fi

for key in vaultLogicLibrary vaultGovernanceLibrary vaultImplementation policyImplementation lens factory; do
  addr=$(python -c "import json;print(json.load(open('$REC'))['$key'])")
  size=$(cast code "$addr" --rpc-url "http://127.0.0.1:$PORT" | wc -c)
  if [ "$size" -le 4 ]; then echo "FAIL: $key $addr has no code"; exit 1; fi
  echo "ok   $key $addr ($(( (size - 3) / 2 )) bytes)"
done
echo "ok   owner $(cast call "$(python -c "import json;print(json.load(open('$REC'))['factory'])")" "owner()(address)" --rpc-url "http://127.0.0.1:$PORT")"
echo "ok   pendingOwner $(cast call "$(python -c "import json;print(json.load(open('$REC'))['factory'])")" "pendingOwner()(address)" --rpc-url "http://127.0.0.1:$PORT")"
rm -f "$REC"
echo "PASS"
