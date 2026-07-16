#!/usr/bin/env bash
# Fail region1 according to the arm. Called at the injection instant by run-trial.sh.
set -euo pipefail
ARM="${1:?usage: inject.sh A1|A2|A3}"
case "$ARM" in
  A1)  # health-triggered withdraw: region1 explicitly stops announcing the VIP
    docker exec region1 vtysh -c 'conf t' -c 'router bgp 65001' \
      -c 'address-family ipv4 unicast' -c 'no network 10.0.0.1/32' >/dev/null ;;
  A2)  # silent death of the whole region (router + backend): transit only notices at hold-timer expiry
    docker pause region1 backend1 >/dev/null ;;
  A3)  # silent death of the whole region, but BFD (configured by reset-arm.sh) detects it fast
    docker pause region1 backend1 >/dev/null ;;
  *) echo "unknown arm $ARM" >&2; exit 1 ;;
esac
