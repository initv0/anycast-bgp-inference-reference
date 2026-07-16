#!/usr/bin/env bash
# Run one failover trial for an arm. Warms up, starts the loadgen inside the client,
# injects the region-1 failure at a known instant, records that instant, then lets the
# loadgen run through recovery. Output: results/<arm>/<ts>.csv and .inject (epoch seconds).
#
# Usage: run-trial.sh A1|A2|A3 [rate=50] [duration=40] [warmup=5] [inject_at=20]
set -euo pipefail
cd "$(dirname "$0")/.."
ARM="${1:?usage: run-trial.sh A1|A2|A3 [rate] [duration] [warmup] [inject_at]}"
RATE="${2:-50}"; DUR="${3:-40}"; WARMUP="${4:-5}"; INJECT_AT="${5:-20}"
VIP="10.0.0.1"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="results/$ARM"; mkdir -p "$OUTDIR"
REL="$ARM/$TS.csv"

# Bring the whole region back to life and to the arm's starting state, then wait for convergence.
docker unpause region1 backend1 >/dev/null 2>&1 || true
docker start region1 backend1 >/dev/null 2>&1 || true
./harness/reset-arm.sh "$ARM"
VIP="$VIP" ./harness/wait-converged.sh
sleep "$WARMUP"

# Start the loadgen in the background inside the client (writes to the shared /results volume).
docker exec -d client python3 /loadgen.py --vip "$VIP" --rate "$RATE" --duration "$DUR" --out "/results/$REL"
LOAD_START="$(date +%s.%N)"
echo "[trial $ARM] loadgen started rate=${RATE}/s dur=${DUR}s; injecting at +${INJECT_AT}s"

# Sleep on the same wall clock the loadgen uses, then inject.
python3 - "$LOAD_START" "$INJECT_AT" <<'PY'
import sys, time
start, at = float(sys.argv[1]), float(sys.argv[2])
while time.time() - start < at:
    time.sleep(0.02)
PY
INJECT_TS="$(date +%s.%N)"
echo "$INJECT_TS" > "$OUTDIR/$TS.inject"
./harness/inject.sh "$ARM"
echo "[trial $ARM] injected at $INJECT_TS"

# Wait for the loadgen window (plus a little slack) to finish.
END_SLEEP="$(python3 -c "import sys;print(max(0.0, $DUR-($(date +%s.%N)-$LOAD_START))+3)")"
sleep "$END_SLEEP"
echo "[trial $ARM] done -> results/$REL"
