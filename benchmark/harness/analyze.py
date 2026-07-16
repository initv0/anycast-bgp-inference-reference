#!/usr/bin/env python3
"""Analyze failover trials.

For each trial (a <ts>.csv plus its <ts>.inject sidecar) compute:
  - convergence: seconds from the inject instant to the first request served again after the
    failure gap
  - errored: number of failed/timed-out requests inside that gap
  - pre/post region: which region served before the failure and which took over

Then aggregate per arm (p50/p95/p99 of convergence, median errored) and write summary.json plus
charts. Charts need matplotlib; everything else is stdlib.

Usage: python3 harness/analyze.py results/
"""
import csv, json, os, sys, glob, statistics
from collections import Counter


def percentile(values, p):
    if not values:
        return None
    xs = sorted(values)
    if len(xs) == 1:
        return xs[0]
    k = (len(xs) - 1) * (p / 100.0)
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def load_trial(csv_path):
    inject_path = csv_path[:-4] + ".inject"
    if not os.path.exists(inject_path):
        return None
    with open(inject_path) as f:
        inject_ts = float(f.read().strip())
    rows = []
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            rows.append((float(r["send_ts"]), int(r["status"]), r["region"]))
    if not rows:
        return None
    rows.sort()

    pre = [reg for ts, st, reg in rows if ts < inject_ts and st == 200]
    pre_region = Counter(pre).most_common(1)[0][0] if pre else ""

    post_fail = [(ts, st) for ts, st, reg in rows if ts >= inject_ts and st != 200]
    if not post_fail:
        first_after = next((reg for ts, st, reg in rows if ts >= inject_ts and st == 200), "")
        return {"convergence": 0.0, "errored": 0, "pre_region": pre_region, "post_region": first_after}

    fail_start = min(ts for ts, st in post_fail)
    recovery_ts, post_region = None, ""
    for ts, st, reg in rows:
        if ts >= fail_start and st == 200:
            recovery_ts, post_region = ts, reg
            break
    if recovery_ts is None:  # never recovered inside the window
        recovery_ts = max(ts for ts, st, reg in rows)
    errored = sum(1 for ts, st in post_fail if fail_start <= ts < recovery_ts)
    return {"convergence": recovery_ts - inject_ts, "errored": errored,
            "pre_region": pre_region, "post_region": post_region}


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "results"
    arms = {}
    for arm_dir in sorted(glob.glob(os.path.join(root, "A*"))):
        arm = os.path.basename(arm_dir)
        trials = [t for t in (load_trial(c) for c in sorted(glob.glob(os.path.join(arm_dir, "*.csv")))) if t]
        if trials:
            arms[arm] = trials

    if not arms:
        print(f"no trials found under {root}/", file=sys.stderr)
        sys.exit(1)

    summary = {}
    print(f"\n{'arm':<4} {'n':>3} {'conv_p50':>9} {'conv_p95':>9} {'conv_p99':>9} {'err_med':>8}  post_region")
    print("-" * 60)
    for arm, trials in arms.items():
        conv = [t["convergence"] for t in trials]
        err = [t["errored"] for t in trials]
        post = Counter(t["post_region"] for t in trials).most_common(1)[0][0]
        agg = {
            "trials": len(trials),
            "conv_p50": round(percentile(conv, 50), 3),
            "conv_p95": round(percentile(conv, 95), 3),
            "conv_p99": round(percentile(conv, 99), 3),
            "conv_max": round(max(conv), 3),
            "errored_median": int(statistics.median(err)),
            "errored_max": max(err),
            "post_region": post,
            "raw_convergence": [round(c, 3) for c in conv],
            "raw_errored": err,
        }
        summary[arm] = agg
        print(f"{arm:<4} {agg['trials']:>3} {agg['conv_p50']:>9} {agg['conv_p95']:>9} "
              f"{agg['conv_p99']:>9} {agg['errored_median']:>8}  {post}")

    os.makedirs(os.path.join(root, "charts"), exist_ok=True)
    with open(os.path.join(root, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(f"\nwrote {os.path.join(root, 'summary.json')}")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        print("matplotlib not installed; skipping charts (pip install matplotlib to enable)")
        return

    # Convergence CDF per arm
    fig, ax = plt.subplots(figsize=(7, 4))
    for arm, agg in summary.items():
        xs = sorted(agg["raw_convergence"])
        ys = [(i + 1) / len(xs) for i in range(len(xs))]
        ax.step(xs, ys, where="post", label=f"{arm} (p50={agg['conv_p50']}s)")
    ax.set_xlabel("convergence time (s)"); ax.set_ylabel("fraction of trials")
    ax.set_title("Failover convergence CDF by arm"); ax.legend(); ax.grid(True, alpha=0.3)
    fig.tight_layout(); fig.savefig(os.path.join(root, "charts", "convergence_cdf.png"), dpi=140)

    # Median errored requests per arm
    fig2, ax2 = plt.subplots(figsize=(7, 4))
    labels = list(summary.keys())
    ax2.bar(labels, [summary[a]["errored_median"] for a in labels])
    ax2.set_ylabel("failed requests (median)"); ax2.set_title("Requests dropped during failover")
    ax2.grid(True, axis="y", alpha=0.3)
    fig2.tight_layout(); fig2.savefig(os.path.join(root, "charts", "errored_requests.png"), dpi=140)
    print(f"wrote charts to {os.path.join(root, 'charts')}/")


if __name__ == "__main__":
    main()
