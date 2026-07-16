#!/bin/sh
set -e
ip link add dummy0 type dummy 2>/dev/null || true
ip addr add "${VIP:-10.0.0.1}/32" dev dummy0 2>/dev/null || true
ip link set dummy0 up 2>/dev/null || true
[ -n "${GW:-}" ] && ip route replace default via "$GW" 2>/dev/null || true
exec /usr/lib/frr/docker-start
