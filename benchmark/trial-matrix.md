# Trial matrix

The exact experiment so results are comparable and reproducible. Record every parameter in the
report; a benchmark without its parameters is an anecdote.

## Fixed parameters (record these)

| Parameter | Value | Notes |
|-----------|-------|-------|
| Request rate | 50 req/s | Sets the failed-request count directly. Report it next to counts. |
| Trial duration | 40 s | 20 s steady state, inject at +20 s, ~20 s to observe recovery. |
| Warmup | 5 s | After convergence, before load starts. |
| Trials per arm | 20 | Minimum for a meaningful p95. Bump to 50 for a headline number. |
| BGP timers | keepalive 3 s / hold 9 s | Set in `frr.conf`. A2's result is bounded by the hold timer. |
| BFD (A3 only) | 100 ms tx/rx, mult 3 | ~300 ms detection. Set in `reset-arm.sh`. |
| FRR image | quay.io/frrouting/frr:10.2.6 | Pin and record (Docker Hub frrouting/frr is stale). |
| Request timeout | 2 s | Longer than base latency, shorter than the hold timer. |

## Arms

Run all three on the same testbed. Only the failure and its detection change.

- **A1 - health-triggered withdraw.** Region 1 explicitly withdraws the anycast route
  (`no network 10.0.0.1/32`) the instant its health trips. Models routing wired to real health.
  Expectation: sub-second, near-zero drops.
- **A2 - silent death, hold-timer detection.** Region 1 and its backend are both paused with no
  warning (whole region gone, data plane included). Transit only notices when the BGP hold timer
  expires. Models liveness-only infrastructure (the L1/L2 trap). Expectation: convergence near the
  hold timer, a burst of drops.
- **A3 - silent death, BFD detection.** Same whole-region failure, but BFD is up on the session. The
  network detects the loss in a few hundred milliseconds without the app doing anything.
  Expectation: sub-second, between A1 and A2 in setup effort.

The story is the three-way gap: what wiring health into routing (A1), or adding BFD (A3), buys you
over hoping the hold timer saves you (A2).

## Non-BGP baselines (optional, for scale)

These are not BGP, so their failover time is mostly set by configuration rather than protocol
dynamics. Include them to show the order-of-magnitude difference, not as the empirical centerpiece.

- **B - GeoDNS TTL.** Failover requires the record to change and clients to re-resolve after the TTL
  expires. Effective gap is roughly the TTL plus client resolver behavior (often ignored, which is
  the point). Model with a short-TTL zone and note real clients cache past TTL.
- **C - global load-balancer health check.** A reverse proxy with active health checks fails over
  after `interval x unhealthy_threshold` plus connection draining. Model with HAProxy or nginx and
  report the configured interval and threshold.

## Procedure per trial (automated by `run-trial.sh`)

1. Restore region 1, apply the arm's BFD state, wait until the VIP is served by region 1.
2. Warm up, then start the loadgen at the fixed rate.
3. At +20 s, record the inject timestamp and fail region 1 per the arm.
4. Let the loadgen run through recovery; save the per-request CSV and the inject timestamp.
5. `analyze.py` computes convergence and drops per trial and aggregates per arm.

## What to hand over for the write-up

- `results/summary.json`
- `results/charts/convergence_cdf.png` and `results/charts/errored_requests.png`
- The exact timer values and FRR image tag you ran with (so the report states them).
