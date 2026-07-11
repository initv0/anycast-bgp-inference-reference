#!/usr/bin/env bash
#
# health-agent.sh — tie the anycast VIP's loopback address to real inference SLOs.
#
# When the region breaches its SLO for BAD_LIMIT consecutive checks, the VIP's
# loopback address is removed, which makes FRR (redistribute connected) withdraw
# the BGP route. It is re-added only after GOOD_LIMIT consecutive healthy checks.
# The hysteresis avoids flapping — a flapping prefix triggers upstream route-flap
# dampening that can suppress you for 30-60 minutes after recovery.
#
# Companion to:
#   https://vkafed.com/blog/bgp-for-the-ai-era-multi-region-routing-for-inference-workloads/
#
set -euo pipefail

# --- Configuration (override via environment) ---------------------------------
VIP="${VIP:-198.51.100.10/32}"
DEV="${DEV:-lo}"
REGION="${REGION:-us-east-1}"
METRICS_URL="${METRICS_URL:-http://localhost:9100}"
P99_THRESHOLD_MS="${P99_THRESHOLD_MS:-250}"
QUEUE_THRESHOLD="${QUEUE_THRESHOLD:-500}"
BAD_LIMIT="${BAD_LIMIT:-3}"          # consecutive bad checks before withdrawal
GOOD_LIMIT="${GOOD_LIMIT:-5}"        # consecutive good checks before re-announce
STATE_FILE="${STATE_FILE:-/run/health-agent.state}"

log() { logger -t health-agent "$*" 2>/dev/null || true; printf '%s %s\n' "$(date -Is)" "$*"; }

# --- Load streak state, or seed it from the interface's actual state ----------
bad=0; good=0
if [[ -r "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
else
  if ip addr show dev "$DEV" 2>/dev/null | grep -qw "${VIP%/*}"; then
    announced=1
  else
    announced=0
  fi
fi
announced="${announced:-1}"

# --- Probe the region's real inference SLO signals ----------------------------
# Fall back to a clearly-unhealthy value if the metrics endpoint is unreachable.
p99="$(curl -fsS --max-time 1 "${METRICS_URL}/metrics/p99_inference_latency_ms" 2>/dev/null || echo 999999)"
queue="$(curl -fsS --max-time 1 "${METRICS_URL}/metrics/gpu_queue_depth" 2>/dev/null || echo 999999)"

# Sanitize (strip anything non-numeric; queue is an integer, p99 may be float).
p99="${p99//[!0-9.]/}"; p99="${p99:-999999}"
queue="${queue//[!0-9]/}"; queue="${queue:-999999}"

# --- Decide health ------------------------------------------------------------
unhealthy=0
if awk "BEGIN{exit !(${p99}+0 > ${P99_THRESHOLD_MS}+0)}"; then unhealthy=1; fi
if (( queue > QUEUE_THRESHOLD )); then unhealthy=1; fi

if (( unhealthy )); then
  bad=$(( bad + 1 )); good=0
else
  good=$(( good + 1 )); bad=0
fi

# --- Act on streaks (with hysteresis) -----------------------------------------
if (( announced )) && (( bad >= BAD_LIMIT )); then
  ip addr del "$VIP" dev "$DEV" 2>/dev/null || true
  announced=0
  log "WITHDRAWN region=${REGION} p99=${p99}ms queue=${queue} bad=${bad}"
elif (( ! announced )) && (( good >= GOOD_LIMIT )); then
  ip addr add "$VIP" dev "$DEV" 2>/dev/null || true
  announced=1
  log "ANNOUNCED region=${REGION} p99=${p99}ms queue=${queue} good=${good}"
fi

# --- Persist state for the next run -------------------------------------------
printf 'bad=%d\ngood=%d\nannounced=%d\n' "$bad" "$good" "$announced" > "$STATE_FILE"
