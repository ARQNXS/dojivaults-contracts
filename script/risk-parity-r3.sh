#!/usr/bin/env bash
# Round-3 / legacy risk parity: runs script/risk-parity-r3/RiskParityR3.t.sol.in against the round-3 contracts
# (git f11359d) in a throwaway worktree.
#   script/risk-parity-r3.sh          check test/fixtures/risk-parity-r3.json against the round-3 checkRisk()
#   script/risk-parity-r3.sh --write  regenerate it
# server/test/risk-parity.test.ts runs the keeper's off-chain mirror on the same file.
set -euo pipefail
REV=f11359d
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d)/r3"
git -C "$here" worktree add --detach "$dir" "$REV" >/dev/null
trap 'git -C "$here" worktree remove --force "$dir" >/dev/null 2>&1 || true' EXIT
c="$dir/contracts"
rm -rf "$c/lib"
cp -r "$here/lib" "$c/lib"
cp "$here/script/risk-parity-r3/RiskParityR3.t.sol.in" "$c/test/RiskParityR3.t.sol"
mkdir -p "$c/test/fixtures"
if [ -f "$here/test/fixtures/risk-parity-r3.json" ]; then cp "$here/test/fixtures/risk-parity-r3.json" "$c/test/fixtures/"; fi
sed -i 's|^fs_permissions = .*|fs_permissions = [{ access = "read-write", path = "./test/fixtures" }]|' "$c/foundry.toml"
if [ "${1:-}" = "--write" ]; then
  (cd "$c" && RISK_PARITY_WRITE=true forge test --match-contract RiskParityR3)
  cp "$c/test/fixtures/risk-parity-r3.json" "$here/test/fixtures/risk-parity-r3.json"
  echo "wrote test/fixtures/risk-parity-r3.json"
else
  (cd "$c" && forge test --match-contract RiskParityR3)
fi
