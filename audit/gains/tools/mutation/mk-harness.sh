#!/usr/bin/env bash
# usage: mk-harness.sh <name>   creates $S/<name>
set -e
S=<scratch>/tools-run
W=<worktree>/contracts
T=$S/${1:-h0}
rm -rf $T; mkdir -p $T/src/hypercore $T/src/libraries $T/test/mocks $T/test/audit/gains $T/deployments
cd $T
cp -r $W/lib .
cp -r $W/src/gains src/
cp $W/src/VaultTypes.sol $W/src/VaultPolicy.sol src/
cp $W/src/hypercore/HyperCore.sol src/hypercore/
cp $W/src/libraries/PxMath.sol src/libraries/
cp $W/test/mocks/Mocks.sol test/mocks/
cp -r $W/test/gains test/
rm -rf test/gains/fork test/gains/spike
cp $W/test/audit/gains/R1Base.t.sol $W/test/audit/gains/R1PoC.t.sol $W/test/audit/gains/R1NavBias.t.sol $W/test/audit/gains/AccessMatrix.t.sol test/audit/gains/
cp -r $W/test/audit/gains/gov $W/test/audit/gains/xreview test/audit/gains/
mkdir -p test/audit/gains/nav
cp $W/test/audit/gains/nav/NavUnit.t.sol test/audit/gains/nav/
if [ -d $W/test/audit/gains/static ]; then cp -r $W/test/audit/gains/static test/audit/gains/; fi
cp $S/scripts/foundry.toml foundry.toml
echo "harness $T ready"
