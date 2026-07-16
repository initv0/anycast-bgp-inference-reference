#!/bin/sh
set -e
if ! command -v ip >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq iproute2 >/dev/null 2>&1 || true
fi
ip route replace default via "${GW:-10.9.9.2}" 2>/dev/null || true
echo "client ready: default via ${GW:-10.9.9.2}"
exec sleep infinity
