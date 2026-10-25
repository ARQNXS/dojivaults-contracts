#!/bin/bash
# Round 1 Halmos driver (Git Bash, Windows). Compiles only the symbolic harnesses and what they import (via_ir, ~20 s)
# into a private out dir per run, so several runs can go in parallel without touching ./out.
# usage: audit/gains/tools/halmos-run.sh <Contract> <tag> <solver> [extra halmos args]   (from contracts/)
# logs: $HALMOS_LOG_DIR/<tag>.log (default: ./halmos-logs)
C=$1; TAG=$2; SOLVER=$3; shift 3
LOGDIR=${HALMOS_LOG_DIR:-./halmos-logs}
mkdir -p "$LOGDIR"
export PYTHONUNBUFFERED=1 HALMOS_ALLOW_DOWNLOAD=1 PATH="~/AppData/Roaming/Python/Python313/Scripts:$PATH"
export FOUNDRY_SRC=test/audit/gains/symbolic FOUNDRY_TEST=test/audit/gains/symbolic FOUNDRY_SCRIPT=test/audit/gains/symbolic
export FOUNDRY_OUT=out-halmos-$TAG FOUNDRY_CACHE_PATH=cache-halmos-$TAG
halmos --root . --forge-build-out out-halmos-$TAG --contract "$C" --solver "$SOLVER" "$@" > "$LOGDIR/$TAG.log" 2>&1
echo "exit $?" >> "$LOGDIR/$TAG.log"
