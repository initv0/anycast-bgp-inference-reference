#!/usr/bin/env bash
# Run N trials of each arm. Default 20 trials per arm at 50 req/s (see trial-matrix.md).
# Usage: run-matrix.sh [N=20] [rate=50]
set -euo pipefail
cd "$(dirname "$0")/.."
N="${1:-20}"; RATE="${2:-50}"
for arm in A1 A2 A3; do
  for t in $(seq 1 "$N"); do
    echo "=== $arm trial $t/$N ==="
    ./harness/run-trial.sh "$arm" "$RATE" || echo "  (trial failed, continuing)"
    sleep 3
  done
done
echo "matrix complete -> python3 harness/analyze.py results/"
