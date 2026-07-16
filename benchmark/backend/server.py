#!/usr/bin/env python3
"""Anycast backend. Binds 0.0.0.0:8080 inside a region's network namespace, so it
answers on the anycast VIP. Returns which region served the request and simulates
inference-shaped latency (a base cost plus an occasional slow path). /health can be
toggled to model a health-triggered withdraw.
"""
import os, time, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGION = os.environ.get("REGION", "unknown")
BASE = int(os.environ.get("BASE_LATENCY_MS", "40")) / 1000.0
SLOW = int(os.environ.get("SLOW_PATH_MS", "250")) / 1000.0
state = {"healthy": True}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            code = 200 if state["healthy"] else 503
            return self._send(code, {"region": REGION, "healthy": state["healthy"]})
        # Simulate inference latency: base cost, with ~10% of requests hitting a slow path.
        extra = SLOW if (time.time_ns() // 1_000_000) % 10 == 0 else 0.0
        time.sleep(BASE + extra)
        return self._send(200, {"region": REGION, "served_ms": round((BASE + extra) * 1000)})

    def do_POST(self):
        if self.path.startswith("/toggle"):
            state["healthy"] = not state["healthy"]
            return self._send(200, {"region": REGION, "healthy": state["healthy"]})
        return self._send(404, {})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
