# Anycast/BGP failover benchmark for inference traffic

A reproducible testbed that measures one thing honestly: when a region goes unhealthy, how long
until inference traffic actually lands in a healthy region, and how many requests fail in the gap.

The interesting result is not a single number. It is the gap between *detection methods*. A region
that withdraws its own route the moment its health check trips recovers in well under a second. The
same region dying silently, with nothing but the BGP hold timer to notice, can black-hole traffic
for the length of that timer. This benchmark puts real numbers on that difference, on a lab anyone
can rerun.

It backs the L3 rung of the [AI Inference Networking Maturity
Model](https://vkafed.com/ai-inference-networking-maturity-model/), which claims health-aware
routing fails over "in seconds." This is where you prove or qualify that claim.

## The question

For a single anycast VIP served from three regions, with region 1 preferred, measure across trials:

- **Convergence time:** seconds from the moment region 1 fails to the first request served by a
  healthy region.
- **Failed requests:** how many requests error or time out during the gap, at a fixed request rate.
- **Where traffic lands:** confirm the VIP shifts to region 2 (next-best path), not a black hole.

## The arms

All arms run on the same testbed. Only the failure and its detection change.

| Arm | Failure | Detection | Measured (validation run, 1 trial) |
|-----|---------|-----------|------------------------------------|
| A1  | Region withdraws its own route on health-check failure (box stays up) | Explicit BGP withdraw | ~0.4 s, ~2 dropped |
| A2  | Whole region dies silently (router + backend paused) | BGP hold timer expiry | ~7 s, ~360 dropped |
| A3  | Whole region dies silently, BFD enabled on the session | BFD (~300 ms) | ~0.2 s, ~8 dropped |

The numbers above are from a single smoke-test trial on Docker Desktop (arm64), not the real 20-trial
matrix. They show the shape: proactive withdraw (A1) or BFD (A3) is sub-second with a handful of
drops; leaning on the hold timer (A2) black-holes for seconds and drops hundreds. Run the matrix for
publishable p50/p95/p99.

A1 is the maturity-model L3 behavior: health wired into routing. A2 is what you get when nobody
wired it (liveness-only, the L1/L2 trap). A3 is the middle path: the network detects the failure
fast without the app doing anything. The three-way comparison is the story.

Two non-BGP baselines are documented in `trial-matrix.md` for contrast (GeoDNS TTL expiry, and a
reverse-proxy health check). Their failover time is mostly set by config (TTL, check interval times
threshold), so they are included for scale, not as the empirical centerpiece.

## Topology

```
                 client (loadgen)
                     |
                 [ transit / AS 65000 ]      <- learns 10.0.0.1/32 from all three regions
                 /        |        \             prefers region1 (local-pref), then r2, then r3
          AS65001     AS65002    AS65003
          region1     region2    region3
          backend1    backend2   backend3     <- each binds the anycast VIP 10.0.0.1:8080
```

- Anycast VIP: `10.0.0.1/32`, announced by every region, served by a backend in that region.
- Transit prefers region 1 via local-preference, so region 1 is active and 2/3 are standby paths.
- Each region is an FRR container; its backend shares the region's network namespace and binds the
  VIP. The client sends a steady stream at the VIP through transit.

## Prerequisites

- Docker and Docker Compose v2. Validated on Docker Desktop for Mac (arm64, linuxkit 6.12 kernel);
  a native Linux host works the same.
- Internet reachable from containers on first `up`: the `client` (a `python:slim` image) installs
  `iproute2` at startup so it can set its default route. Watch for `client ready:` in
  `docker logs client` before running trials (`wait-converged.sh` also gates on convergence).
- FRR image is `quay.io/frrouting/frr:10.2.6` (the Docker Hub `frrouting/frr` repo is stale at
  v8.4.x). quay publishes multi-arch, so it runs native on Apple Silicon. Pin and record the tag.
- Python 3.10+ on the host to run `analyze.py`; `pip install matplotlib` for the charts.

## Run one trial

```bash
# 1. Bring the lab up and let BGP converge (~15s)
docker compose up -d
./harness/wait-converged.sh          # blocks until the VIP is reachable and served by region1

# 2. Run a single trial of an arm (A1 | A2 | A3). Writes results/<arm>/<timestamp>.csv
./harness/run-trial.sh A1

# 3. Tear down between arms if you want a clean slate
docker compose restart region1 transit
```

`run-trial.sh` warms up, starts the loadgen at a fixed rate, injects the failure at a known instant,
keeps sending through the gap and recovery, then stops and saves a per-request CSV.

## Run the full matrix

```bash
./harness/run-matrix.sh              # runs N trials of A1, A2, A3 per trial-matrix.md
python3 harness/analyze.py results/  # aggregates p50/p95/p99 + writes charts to results/charts/
```

## Interpret

`analyze.py` prints a summary table and writes charts:

- **Convergence CDF** per arm (how consistent is recovery, not just the median).
- **Failed-requests bar** per arm at the fixed rate.
- A one-line **verdict** per arm: median convergence and median failed requests.

Hand me `results/summary.json` plus the charts and I fill the report from `report-template.md`.

## Honesty notes (put these in the report too)

- Lab BGP convergence is optimistic versus the real internet: no route-reflector hierarchy, no
  RIB scale, no upstream damping. The lab isolates *detection* time, which is the variable you
  control. Say so plainly.
- Default FRR timers matter. Record them. A2's result *is* the hold timer, so state the timer.
- Request rate sets the failed-request count directly. Report the rate next to the count.
- Run enough trials (start at 20 per arm) that p95 means something. One run is an anecdote.

## Layout

```
docker-compose.yml        the testbed
frr/                      per-node FRR configs + daemons
backend/                  anycast backend (region id + simulated inference latency + /health)
harness/                  loadgen, failure injection, trial runner, analysis
trial-matrix.md           the exact experiment plan
report-template.md        write-up skeleton with placeholders for your numbers
```
