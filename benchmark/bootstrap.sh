#!/usr/bin/env bash
# Generates the FRR node configs, the daemons file, and the container entrypoints.
# Run once before `docker compose up`. Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p frr/transit frr/region1 frr/region2 frr/region3 harness results

# Which FRR daemons to start on every node. bfdd is enabled so arm A3 can turn BFD on.
DAEMONS='zebra=yes
bgpd=yes
bfdd=yes
staticd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
pim6d=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
fabricd=no
vrrpd=no
pathd=no
vtysh_enable=yes
watchfrr_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
bfdd_options="   -A 127.0.0.1"
staticd_options="-A 127.0.0.1"'

# --- transit (AS 65000): learns the VIP from all three regions, prefers region1 ---
printf '%s\n' "$DAEMONS" > frr/transit/daemons
cat > frr/transit/frr.conf <<'EOF'
frr version 10.2
frr defaults datacenter
hostname transit
!
router bgp 65000
 bgp router-id 10.1.1.2
 no bgp ebgp-requires-policy
 neighbor 10.1.1.3 remote-as 65001
 neighbor 10.1.1.3 timers 3 9
 neighbor 10.1.2.3 remote-as 65002
 neighbor 10.1.2.3 timers 3 9
 neighbor 10.1.3.3 remote-as 65003
 neighbor 10.1.3.3 timers 3 9
 address-family ipv4 unicast
  neighbor 10.1.1.3 route-map PREFER-R1 in
  neighbor 10.1.2.3 route-map PREFER-R2 in
  neighbor 10.1.3.3 route-map PREFER-R3 in
 exit-address-family
!
route-map PREFER-R1 permit 10
 set local-preference 300
route-map PREFER-R2 permit 10
 set local-preference 200
route-map PREFER-R3 permit 10
 set local-preference 100
!
line vty
!
EOF

# --- regions (AS 6500X): each announces the anycast /32 ---
i=1
for spec in "65001 10.1.1" "65002 10.1.2" "65003 10.1.3"; do
  asn=${spec%% *}; net=${spec##* }
  printf '%s\n' "$DAEMONS" > "frr/region$i/daemons"
  cat > "frr/region$i/frr.conf" <<EOF
frr version 10.2
frr defaults datacenter
hostname region$i
!
router bgp $asn
 bgp router-id ${net}.3
 no bgp ebgp-requires-policy
 neighbor ${net}.2 remote-as 65000
 neighbor ${net}.2 timers 3 9
 address-family ipv4 unicast
  network 10.0.0.1/32
 exit-address-family
!
line vty
!
EOF
  i=$((i+1))
done

# --- region entrypoint: put the anycast VIP on dummy0, default-route back to transit, start FRR ---
cat > frr/region-entrypoint.sh <<'EOF'
#!/bin/sh
set -e
ip link add dummy0 type dummy 2>/dev/null || true
ip addr add "${VIP:-10.0.0.1}/32" dev dummy0 2>/dev/null || true
ip link set dummy0 up 2>/dev/null || true
[ -n "${GW:-}" ] && ip route replace default via "$GW" 2>/dev/null || true
exec /usr/lib/frr/docker-start
EOF
chmod +x frr/region-entrypoint.sh

# --- client entrypoint: install iproute2 (python:slim lacks `ip`), default-route via transit, idle ---
cat > harness/client-entrypoint.sh <<'EOF'
#!/bin/sh
set -e
if ! command -v ip >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq iproute2 >/dev/null 2>&1 || true
fi
ip route replace default via "${GW:-10.9.9.2}" 2>/dev/null || true
echo "client ready: default via ${GW:-10.9.9.2}"
exec sleep infinity
EOF
chmod +x harness/client-entrypoint.sh

echo "Generated FRR configs, daemons, and entrypoints. Next: docker compose up -d"
