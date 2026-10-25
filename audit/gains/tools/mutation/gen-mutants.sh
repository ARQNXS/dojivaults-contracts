#!/usr/bin/env bash
# Generates gambit mutants for every src/gains file into $S/gambit/<File>/ (from a pristine copy, gen/).
S=<scratch>/tools-run
G=$S/gen
rm -rf $G && mkdir -p $G/src
cp -r $S/h0/src/* $G/src/
cp -r $S/h0/lib $G/ 2>/dev/null || true
cd $G
mkdir -p $S/gambit
for f in ${FILES:-GainsNav GainsPrice GainsVaultLogic GainsVaultMath GainsVaultGovernance GainsVaultPolicy GainsVaultFactory GainsVault GainsVaultLens GainsTypes IGainsDiamond}; do
  rm -rf $S/gambit/$f
  ~/.cargo/bin/gambit.exe mutate --filename src/gains/$f.sol --sourceroot . \
    --solc ~/AppData/Roaming/svm/0.8.28/solc-0.8.28 --solc_evm_version cancun \
    --solc_remappings "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/" "@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/" "forge-std/=lib/forge-std/src/" \
    ${VALIDATE:---skip_validate} -o $S/gambit/$f > $S/gambit/$f.log 2>&1
  echo "$f exit $? : $(ls $S/gambit/$f/mutants 2>/dev/null | wc -l) mutants"
done
