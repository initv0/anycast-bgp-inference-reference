#!/usr/bin/env python3
"""Fixed-rate load generator. Sends GET http://VIP:8080/ at a steady rate for a fixed
duration and writes one CSV row per request: send_ts, recv_ts, status, latency_ms, region.
Stdlib only, so it runs in a bare python:slim container. Timestamps are epoch wall-clock,
which is directly comparable to the inject timestamp recorded by run-trial.sh.
"""
import argparse, csv, json, threading, time, urllib.request, urllib.error
import concurrent.futures as cf


def one_request(vip, timeout):
    url = f"http://{vip}:8080/"
    send = time.time()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            body = r.read().decode()
            recv = time.time()
            region = ""
            try:
                region = json.loads(body).get("region", "")
            except Exception:
                pass
            return (send, recv, r.status, (recv - send) * 1000.0, region)
    except urllib.error.HTTPError as e:
        recv = time.time()
        return (send, recv, e.code, (recv - send) * 1000.0, "")
    except Exception:
        recv = time.time()
        return (send, recv, 0, (recv - send) * 1000.0, "")  # 0 = connect/timeout error


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vip", default="10.0.0.1")
    ap.add_argument("--rate", type=float, default=50.0)      # requests/sec
    ap.add_argument("--duration", type=float, default=40.0)  # seconds
    ap.add_argument("--timeout", type=float, default=2.0)    # per-request timeout
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    rows = []
    lock = threading.Lock()
    interval = 1.0 / a.rate
    start = time.time()
    workers = max(20, int(a.rate * 3))  # enough to absorb the failover gap without back-pressure

    def record(fut):
        with lock:
            rows.append(fut.result())

    with cf.ThreadPoolExecutor(max_workers=workers) as ex:
        n = 0
        while time.time() - start < a.duration:
            ex.submit(one_request, a.vip, a.timeout).add_done_callback(record)
            n += 1
            nxt = start + n * interval
            slp = nxt - time.time()
            if slp > 0:
                time.sleep(slp)
        # ThreadPoolExecutor.__exit__ waits for in-flight requests to finish.

    rows.sort(key=lambda r: r[0])
    with open(a.out, "w", newline="") as fp:
        w = csv.writer(fp)
        w.writerow(["send_ts", "recv_ts", "status", "latency_ms", "region"])
        for r in rows:
            w.writerow([f"{r[0]:.6f}", f"{r[1]:.6f}", r[2], f"{r[3]:.2f}", r[4]])

    ok = sum(1 for r in rows if r[2] == 200)
    print(f"requests={len(rows)} ok={ok} err={len(rows) - ok} out={a.out}")


if __name__ == "__main__":
    main()
