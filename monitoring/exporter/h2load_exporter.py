#!/usr/bin/env python3
# =============================================================================
# h2load live metrics exporter (Prometheus scrape target)
# -----------------------------------------------------------------------------
# h2load has no Prometheus remote-write (k6 had). To keep the LIVE Grafana view,
# this stdlib-only exporter tails the per-request --log-file written by all 10
# h2load containers of the CURRENT run and exposes rolling client-side metrics
# that Prometheus scrapes every 1 s:
#
#   h2load_reqs_per_second{protocol,scenario,repetition,phase}
#   h2load_error_rate{...}                        (0..1)
#   h2load_req_duration_ms_p50 / _p90 / _p95 / _p99{...}
#
# Server-side CPU/memory stay on cAdvisor exactly as before — this exporter does
# not touch them.
#
# The orchestrator writes /results/live/current_run.json describing the run in
# progress; we read it each scrape, (re)open that run's logs, and compute stats
# over a trailing WINDOW_S window, bucketing each request into its phase by the
# request's own start timestamp (same warmup/sustained/cooldown model as before).
#
# h2load --log-file columns are TAB-separated:
#     <request start time, microseconds since epoch> \t <status> \t <duration us>
# status == -1 marks a failed request.
# =============================================================================

import glob
import json
import os
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTTP_BIND = os.environ.get("HTTP_BIND", "0.0.0.0")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "9115"))
LIVE_DIR = os.environ.get("LIVE_DIR", "/results/live")
WINDOW_S = float(os.environ.get("WINDOW_S", "10"))

CURRENT_RUN_FILE = os.path.join(LIVE_DIR, "current_run.json")

# ---- rolling state (guarded by _lock) --------------------------------------
_lock = threading.Lock()
_run_id = None             # run currently being tracked
_run_meta = {}             # parsed current_run.json
_offsets = {}              # log path -> bytes already consumed
# deque of (start_epoch_s, dur_ms, ok_bool), trimmed to the trailing window
_samples = deque()


def _load_current_run():
    """Return the current_run.json dict, or None if absent/invalid."""
    try:
        with open(CURRENT_RUN_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError, OSError):
        return None


def _reset(meta):
    global _run_id, _run_meta, _offsets, _samples
    _run_id = meta.get("run_id")
    _run_meta = meta
    _offsets = {}
    _samples = deque()


def _phase_for(start_epoch_s):
    """Bucket a request start time into warmup / sustained / cooldown."""
    base = float(_run_meta.get("run_start_epoch", 0))
    warm = float(_run_meta.get("warmup_s", 10))
    sust = float(_run_meta.get("sustained_s", 60))
    elapsed = start_epoch_s - base
    if elapsed < warm:
        return "warmup"
    if elapsed < warm + sust:
        return "sustained"
    return "cooldown"


def _ingest_new_lines():
    """Read bytes appended to each current-run log since the last scrape."""
    log_glob = _run_meta.get("log_glob")
    if not log_glob:
        return
    for path in glob.glob(log_glob):
        try:
            start = _offsets.get(path, 0)
            size = os.path.getsize(path)
            if size < start:          # file truncated/rotated -> re-read
                start = 0
            if size == start:
                continue
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                fh.seek(start)
                chunk = fh.read()
                _offsets[path] = fh.tell()
        except OSError:
            continue
        for line in chunk.splitlines():
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            try:
                start_us = int(parts[0])
                status = int(parts[1])
                dur_us = int(parts[2])
            except ValueError:
                continue
            ok = (200 <= status < 400)
            _samples.append((start_us / 1_000_000.0, dur_us / 1000.0, ok))


def _trim(now_s):
    cutoff = now_s - WINDOW_S
    while _samples and _samples[0][0] < cutoff:
        _samples.popleft()


def _percentile(sorted_vals, q):
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    # Linear interpolation between closest ranks (the numpy default method).
    pos = q * (len(sorted_vals) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = pos - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def _render_metrics():
    """Compute per-phase rolling stats and render Prometheus text format."""
    now_s = time.time()
    with _lock:
        meta = _load_current_run()
        if meta is None:
            # No run in progress: expose nothing but a liveness gauge.
            return "# no run in progress\nh2load_exporter_up 1\n"
        if meta.get("run_id") != _run_id:
            _reset(meta)
        _ingest_new_lines()
        _trim(now_s)

        protocol = _run_meta.get("protocol", "unknown")
        scenario = _run_meta.get("scenario", "S0")
        repetition = str(_run_meta.get("repetition", "0"))

        # Bucket the windowed samples by phase.
        buckets = {}
        for start_s, dur_ms, ok in _samples:
            ph = _phase_for(start_s)
            b = buckets.setdefault(ph, {"durs": [], "ok": 0, "n": 0})
            b["durs"].append(dur_ms)
            b["n"] += 1
            if ok:
                b["ok"] += 1

    lines = [
        "# HELP h2load_reqs_per_second rolling client throughput",
        "# TYPE h2load_reqs_per_second gauge",
        "# HELP h2load_error_rate rolling fraction of failed requests (0..1)",
        "# TYPE h2load_error_rate gauge",
        "# HELP h2load_req_duration_ms_p50 rolling p50 request duration (ms)",
        "# TYPE h2load_req_duration_ms_p50 gauge",
        "# TYPE h2load_req_duration_ms_p90 gauge",
        "# TYPE h2load_req_duration_ms_p95 gauge",
        "# TYPE h2load_req_duration_ms_p99 gauge",
        "h2load_exporter_up 1",
    ]

    def lbl(phase):
        return (f'{{protocol="{protocol}",scenario="{scenario}",'
                f'repetition="{repetition}",phase="{phase}"}}')

    for phase, b in buckets.items():
        durs = sorted(b["durs"])
        rps = b["n"] / WINDOW_S
        err = (b["n"] - b["ok"]) / b["n"] if b["n"] else 0.0
        tag = lbl(phase)
        lines.append(f"h2load_reqs_per_second{tag} {rps:.4f}")
        lines.append(f"h2load_error_rate{tag} {err:.6f}")
        if durs:
            lines.append(f"h2load_req_duration_ms_p50{tag} {_percentile(durs, 0.50):.4f}")
            lines.append(f"h2load_req_duration_ms_p90{tag} {_percentile(durs, 0.90):.4f}")
            lines.append(f"h2load_req_duration_ms_p95{tag} {_percentile(durs, 0.95):.4f}")
            lines.append(f"h2load_req_duration_ms_p99{tag} {_percentile(durs, 0.99):.4f}")
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") in ("/health", "/healthz"):
            body = b"ok\n"
        else:
            body = _render_metrics().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass  # quiet; one scrape/sec would spam


if __name__ == "__main__":
    srv = ThreadingHTTPServer((HTTP_BIND, HTTP_PORT), Handler)
    print(f"[h2load-exporter] listening on {HTTP_BIND}:{HTTP_PORT}, "
          f"live dir={LIVE_DIR}, window={WINDOW_S}s", flush=True)
    srv.serve_forever()
