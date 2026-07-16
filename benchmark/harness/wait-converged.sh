#!/usr/bin/env bash
# Block until the client can reach the anycast VIP and it is served by region1.
set -euo pipefail
VIP="${VIP:-10.0.0.1}"
for _ in $(seq 1 60); do
  who=$(docker exec -i client python3 - "$VIP" <<'PY' 2>/dev/null || true
import sys, urllib.request, json
try:
    b = urllib.request.urlopen(f"http://{sys.argv[1]}:8080/", timeout=1).read().decode()
    print(json.loads(b).get("region", ""))
except Exception:
    print("")
PY
)
  if [ "$who" = "region1" ]; then echo "converged: VIP served by region1"; exit 0; fi
  if [ -n "$who" ]; then echo "reachable but served by $who (waiting for region1)"; fi
  sleep 1
done
echo "did not converge to region1 in time" >&2
exit 1
