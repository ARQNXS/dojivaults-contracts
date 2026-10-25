#!/usr/bin/env bash
# Coverage for src/gains (Stage 1 gate).
#
# forge coverage builds without the optimizer (--ir-minimum), and some round 4 code does not compile that way
# ("stack too deep"). Round 4 must stay byte-identical, so coverage runs on a Gains-only copy of the project: the
# Gains sources, the round 4 type files they import (VaultTypes, VaultPolicy, HyperCore, PxMath), test/mocks and
# test/gains (minus the deploy rehearsal, which imports the round 4 deploy script). Fork tests run when
# ARBITRUM_RPC_URL is set and are skipped otherwise.
#
# Usage: bash script/gains-coverage.sh [out_dir]   (default: a temp dir; lcov at <out_dir>/gains-lcov.info)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$(mktemp -d)}"
rm -rf "$out/tree" && mkdir -p "$out/tree/src/hypercore" "$out/tree/src/libraries" "$out/tree/test/mocks" "$out/tree/deployments"
cd "$out/tree"
cp "$here/foundry.toml" .
cp -r "$here/lib" .
cp -r "$here/src/gains" src/
cp "$here/src/VaultTypes.sol" "$here/src/VaultPolicy.sol" src/
cp "$here/src/hypercore/HyperCore.sol" src/hypercore/
cp "$here/src/libraries/PxMath.sol" src/libraries/
cp "$here/test/mocks/Mocks.sol" test/mocks/
cp -r "$here/test/gains" test/
rm -f test/gains/fork/DeployGains.t.sol
# The EIP-170 size test measures an unoptimized build here; the optimized check runs in the normal suite.
forge coverage --ir-minimum --no-match-test "test_ImplementationFitsEip170" \
  --report summary --report lcov --report-file "$out/gains-lcov.info" | grep -E "src/gains|Ran [0-9]+ test suites|FAIL" || true
echo "lcov: $out/gains-lcov.info"
