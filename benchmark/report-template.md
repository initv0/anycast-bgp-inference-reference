# How fast does anycast really fail over? A reproducible benchmark for inference traffic

*Placeholders in `{{ }}` get filled from `results/summary.json` and the charts. Keep the honesty
notes. Target length ~1,500 words plus the two charts.*

## The claim I wanted to test

The [AI Inference Networking Maturity
Model](https://vkafed.com/ai-inference-networking-maturity-model/) says health-aware routing (level
3) fails over "in seconds." That is the kind of sentence people nod along to and never measure. So I
built a small lab and measured it, three ways, because the number depends entirely on how the
failure is detected.

An inference request is not a stateless web GET. When it lands in a region that just died, there is
no free retry: the request errors, a caller waits, and an expensive accelerator sat idle for
nothing. Failover time is not a networking curiosity here. It is dropped requests.

## Setup

One anycast VIP (`10.0.0.1`), served from three regions, each its own AS, peered with a transit AS
over eBGP. Transit prefers region 1, so region 1 is active and 2 and 3 are standby paths. A client
sends {{rate}} requests per second at the VIP through transit. At a known instant I fail region 1
and watch where traffic goes and how many requests die in the gap.

- BGP timers: keepalive {{keepalive}} s, hold {{hold}} s.
- FRR {{frr_version}}, {{trials}} trials per arm.
- Full lab and harness: [anycast-bgp-inference-reference]({{repo_url}}). It is one `docker compose up`.

Three arms, same lab, only the failure and its detection change:

- **A1, health-triggered withdraw:** region 1 withdraws its route the instant health trips.
- **A2, silent death:** region 1 vanishes; transit only notices when the hold timer expires.
- **A3, silent death with BFD:** same failure, but BFD detects the loss in a few hundred ms.

## Results

| Arm | Detection | Convergence p50 | p95 | p99 | Requests dropped (median) |
|-----|-----------|-----------------|-----|-----|---------------------------|
| A1  | Health-triggered withdraw | {{A1_p50}} s | {{A1_p95}} s | {{A1_p99}} s | {{A1_err}} |
| A2  | Hold-timer expiry | {{A2_p50}} s | {{A2_p95}} s | {{A2_p99}} s | {{A2_err}} |
| A3  | BFD | {{A3_p50}} s | {{A3_p95}} s | {{A3_p99}} s | {{A3_err}} |

![Convergence CDF](results/charts/convergence_cdf.png)

![Requests dropped during failover](results/charts/errored_requests.png)

**What it says.** {{one_paragraph_reading_of_the_numbers}} The headline is the gap between A1/A3 and
A2: wiring health into routing, or adding BFD, turns a {{A2_p50}}-second black hole into a
{{A1_p50}}-second blip. At {{rate}} requests per second that is the difference between {{A2_err}} and
{{A1_err}} dropped requests per regional failure.

## Why the difference is so large

A2 is not slow because BGP is slow. It is slow because nothing told BGP the region was gone, so it
waited for the hold timer to run out. That is the whole point of the maturity model's level 3: the
route has to react to real health, not to a session that has not timed out yet. A1 does that in the
application. A3 does it in the network with BFD. Either beats waiting.

## Honesty about the lab

- This is a lab, not the internet. No route-reflector hierarchy, no RIB at scale, no upstream
  damping or prefix-limit effects. The lab isolates *detection* time, which is the variable you
  control; real convergence adds propagation on top.
- A2's number is the hold timer I configured ({{hold}} s). Production defaults are often 180 s, which
  makes the gap worse, not better. Tune timers, or do not rely on them at all.
- Dropped-request counts scale with the request rate. They are reported at {{rate}} req/s; multiply
  for your own load.
- {{n}} trials per arm. The CDF shows the spread, not just the median.

## Reproduce it

```bash
git clone {{repo_url}}
cd anycast-bgp-inference-reference/benchmark
./bootstrap.sh && docker compose up -d
./harness/run-matrix.sh 20
python3 harness/analyze.py results/
```

Everything here is open: the topology, the FRR configs, the load generator, the analysis. If your
numbers differ, I want to know why.

*Cite as: Kafedzhy, V. "How fast does anycast really fail over? A reproducible benchmark for
inference traffic." vkafed.com, {{year}}.*
