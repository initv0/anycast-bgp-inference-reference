#!/usr/bin/env bash
# Restore region1 to a healthy, announcing state and set BFD on/off for the arm.
# A3 needs BFD up on the transit<->region1 session; A1/A2 must not have it.
set -euo pipefail
ARM="${1:?usage: reset-arm.sh A1|A2|A3}"

# Re-announce the VIP in case a previous A1 trial withdrew it.
docker exec region1 vtysh -c 'conf t' -c 'router bgp 65001' \
  -c 'address-family ipv4 unicast' -c 'network 10.0.0.1/32' >/dev/null 2>&1 || true

if [ "$ARM" = "A3" ]; then
  # ~100ms x3 detection. Configure both ends, then let it come up.
  docker exec transit vtysh -c 'conf t' -c 'bfd' -c 'peer 10.1.1.3' \
    -c 'transmit-interval 100' -c 'receive-interval 100' -c 'detect-multiplier 3' >/dev/null 2>&1 || true
  docker exec transit vtysh -c 'conf t' -c 'router bgp 65000' -c 'neighbor 10.1.1.3 bfd' >/dev/null 2>&1 || true
  docker exec region1 vtysh -c 'conf t' -c 'bfd' -c 'peer 10.1.1.2' \
    -c 'transmit-interval 100' -c 'receive-interval 100' -c 'detect-multiplier 3' >/dev/null 2>&1 || true
  docker exec region1 vtysh -c 'conf t' -c 'router bgp 65001' -c 'neighbor 10.1.1.2 bfd' >/dev/null 2>&1 || true
else
  docker exec transit vtysh -c 'conf t' -c 'router bgp 65000' -c 'no neighbor 10.1.1.3 bfd' >/dev/null 2>&1 || true
  docker exec region1 vtysh -c 'conf t' -c 'router bgp 65001' -c 'no neighbor 10.1.1.2 bfd' >/dev/null 2>&1 || true
fi
