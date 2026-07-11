# anycast-bgp-inference-reference

Reference configuration for **anycast + BGP multi-region routing of AI inference
traffic**, with route advertisement tied to real inference SLOs instead of process
liveness.

Companion to the article: **[BGP for the AI Era: Multi-Region Routing for Inference
Workloads](https://vkafed.com/bgp-for-the-ai-era-multi-region-routing-for-inference-workloads/)**
by [Val Kafedzhy](https://vkafed.com).

> This is **reference material**, not a turnkey deployment. It uses documentation IP
> ranges (RFC 5737) and private ASNs (RFC 6996). Read it, adapt the addresses/ASNs/paths
> to your environment, and test in a lab before anything touches production.

## The idea

Announce one anycast VIP from every region. A health agent on each edge router watches
the region's *actual* inference SLO (p99 latency, GPU queue depth) and adds or removes the
VIP's loopback address. FRR advertises the VIP via `redistribute connected`, so removing
the loopback address withdraws the BGP route — and the internet's routing fabric steers new
connections to the next-closest healthy region within a BGP update cycle, accelerated by BFD.

```
   Global Internet (Anycast VIP 198.51.100.10/32)
                        |
     +------------------+------------------+
  Edge PoP IAD      Edge PoP FRA      Edge PoP SIN
 eBGP to transit   eBGP to transit   eBGP to transit
     |                  |                  |
  us-east-1         eu-central-1      ap-southeast-1
  Edge Router       Edge Router       Edge Router
     |                  |                  |
  L4/L7 LB          L4/L7 LB          L4/L7 LB
     |                  |                  |
  GPU cluster       GPU cluster       GPU cluster

  health-agent (SLO breach) -> removes VIP loopback -> FRR withdraws route
  -> anycast convergence redirects new connections to the next healthy PoP
```

## What's here

| Path | What it is |
|---|---|
| `frr/bgpd.conf` | FRR edge-router config: eBGP to two transits, BFD fast failure detection, health-conditional VIP advertisement via `redistribute connected`, regional communities |
| `scripts/health-agent.sh` | Ties the VIP loopback address to inference SLOs, with hysteresis (N-bad / M-good) to avoid flapping and BGP route-flap dampening |
| `systemd/health-agent.service` | Oneshot unit that runs the health agent |
| `systemd/health-agent.timer` | Runs the agent every 2s |

## Usage

1. **Adapt the addresses.** Replace the VIP (`198.51.100.10/32`), transit peer IPs
   (`203.0.113.x`), router-id, local ASN (`65001`), and transit ASN (`64500`) with yours.
2. **Install FRR** (8.x+ recommended) with BGP and BFD daemons enabled, and load
   `frr/bgpd.conf`. Confirm your transit providers support BFD on the peering.
3. **Deploy the health agent:**
   ```bash
   install -m 0755 scripts/health-agent.sh /usr/local/bin/health-agent.sh
   install -m 0644 systemd/health-agent.service /etc/systemd/system/
   install -m 0644 systemd/health-agent.timer   /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now health-agent.timer
   ```
4. **Point it at your metrics.** The agent expects an endpoint exposing
   `p99_inference_latency_ms` and `gpu_queue_depth`. Override defaults via environment
   (see the top of `scripts/health-agent.sh` or the `.service` file).

## Tunables (health agent)

| Env var | Default | Meaning |
|---|---|---|
| `VIP` | `198.51.100.10/32` | Anycast address bound to the loopback |
| `DEV` | `lo` | Interface the VIP is added to |
| `METRICS_URL` | `http://localhost:9100` | Base URL for the SLO metrics |
| `P99_THRESHOLD_MS` | `250` | p99 latency (ms) above which the region is unhealthy |
| `QUEUE_THRESHOLD` | `500` | GPU queue depth above which the region is unhealthy |
| `BAD_LIMIT` | `3` | Consecutive bad checks before withdrawing the route |
| `GOOD_LIMIT` | `5` | Consecutive good checks before re-announcing |

The `BAD_LIMIT` / `GOOD_LIMIT` hysteresis matters: a flapping health check triggers
upstream route-flap dampening, which can suppress your prefix for 30–60 minutes long after
the region recovered. Withdraw slowly, re-announce even more slowly.

## Requirements

- FRR 8.x+ (bgpd + bfdd), or adapt the config for your router OS
- Linux edge router with `ip` (iproute2) and the loopback-address pattern
- A metrics endpoint exposing real inference SLO signals
- Transit/IX peers that honor BFD for sub-second failure detection

## Related

- Article: [BGP for the AI Era](https://vkafed.com/bgp-for-the-ai-era-multi-region-routing-for-inference-workloads/)
- More: [vkafed.com/topics/ai-infrastructure-networking](https://vkafed.com/category/ai-infrastructure-networking/)

## License

MIT — see [LICENSE](LICENSE).
