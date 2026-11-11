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
#
# FINAL per-run metrics (h2load_final_*)
# -----------------------------------------------------------------------------
# The rolling gauges above are approximate (10 s trailing window, edge effects at
# the phase boundaries). For the "Aggregate Analysis" dashboard the exporter ALSO
# publishes, once a run has finished, the exact per-run numbers that
# scripts/export_results.sh writes to results/summary.csv:
#   * client metrics: scripts/compute_percentiles.compute_metrics() (same code),
#   * server metrics: the same PromQL as export_results.sh server_avg(), queried
#     at the run's recorded sustained_end over the recorded sustained window.
# Averaging h2load_final_* over the repetitions therefore reproduces
# results/summary_aggregated.csv. Runs are read from results/run_index.csv.
#
#   h2load_final_throughput_rps / _latency_p50_ms / _p90_ms / _p95_ms / _p99_ms
#   h2load_final_error_rate_pct
#   h2load_final_cpu_caddy_pct / _mem_caddy_mb / _cpu_backend_pct / _mem_backend_mb
# =============================================================================

import csv
import glob
import json
import math
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTTP_BIND = os.environ.get("HTTP_BIND", "0.0.0.0")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "9115"))
LIVE_DIR = os.environ.get("LIVE_DIR", "/results/live")
WINDOW_S = float(os.environ.get("WINDOW_S", "10"))

CURRENT_RUN_FILE = os.path.join(LIVE_DIR, "current_run.json")

# ---- final per-run metrics (must mirror scripts/export_results.sh defaults) --
RESULTS_DIR = os.environ.get("RESULTS_DIR", "/results")
SCRIPTS_DIR = os.environ.get("SCRIPTS_DIR", "/scripts")
PROM_URL = os.environ.get("PROM_URL", "http://prometheus:9090")
WARMUP_S = float(os.environ.get("WARMUP_S", "10"))
SUSTAINED_S = float(os.environ.get("SUSTAINED_S", "60"))
COOLDOWN_S = float(os.environ.get("COOLDOWN_S", "10"))
CPU_RATE_WINDOW = os.environ.get("CPU_RATE_WINDOW", "5s")
QUERY_STEP = os.environ.get("QUERY_STEP", "5s")
FINAL_REFRESH_S = float(os.environ.get("FINAL_REFRESH_S", "10"))
# Wait this long after sustained_end before querying server metrics, so the last
# cAdvisor scrapes are in Prometheus; after FINAL_NAN_AFTER_S an empty result is
# accepted as NaN (export_results.sh would record NaN too).
FINAL_SETTLE_S = float(os.environ.get("FINAL_SETTLE_S", "15"))
FINAL_NAN_AFTER_S = float(os.environ.get("FINAL_NAN_AFTER_S", "90"))
INDEX_FILE = os.path.join(RESULTS_DIR, "run_index.csv")

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
            return "# no run in progress\nh2load_exporter_up 1\n" + _final_text()
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
    return "\n".join(lines) + "\n" + _final_text()


# ============================================================================
# FINAL per-run metrics
# ============================================================================
_final_lock = threading.Lock()
_final = {}          # run_id -> {"labels": (protocol, scenario, rep), "m": {metric: float}}

# metric exposed name -> key inside the computed dict
_FINAL_METRICS = [
    ("h2load_final_throughput_rps", "throughput_rps"),
    ("h2load_final_latency_p50_ms", "latency_p50"),
    ("h2load_final_latency_p90_ms", "latency_p90"),
    ("h2load_final_latency_p95_ms", "latency_p95"),
    ("h2load_final_latency_p99_ms", "latency_p99"),
    ("h2load_final_error_rate_pct", "error_rate_pct"),
    ("h2load_final_cpu_caddy_pct", "cpu_caddy_pct"),
    ("h2load_final_mem_caddy_mb", "mem_caddy_mb"),
    ("h2load_final_cpu_backend_pct", "cpu_backend_pct"),
    ("h2load_final_mem_backend_mb", "mem_backend_mb"),
]


class _PromUnavailable(Exception):
    pass


def _promq(query, at):
    """Prometheus instant query -> float (NaN when the result is empty).

    Same request as export_results.sh promq(): GET /api/v1/query?query=..&time=..
    and the first series' value. Raises _PromUnavailable on transport errors so
    the caller retries instead of caching a wrong NaN.
    """
    url = PROM_URL + "/api/v1/query?" + urllib.parse.urlencode({"query": query, "time": at})
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.load(resp)
        result = data["data"]["result"]
    except Exception as exc:  # network error, bad JSON, status != success ...
        raise _PromUnavailable(str(exc))
    if not result:
        return float("nan")
    return float(result[0]["value"][1])


def _server_avg(at, win):
    """Mirror of export_results.sh server_avg(): returns the 4 server metrics."""
    out = {}
    for svc in ("caddy", "backend"):
        sel = 'container_label_com_docker_compose_service="%s"' % svc
        out["cpu_%s_pct" % svc] = _promq(
            "avg_over_time((sum(rate(container_cpu_usage_seconds_total{%s}[%s])) * 100)[%ds:%s])"
            % (sel, CPU_RATE_WINDOW, win, QUERY_STEP), at)
        out["mem_%s_mb" % svc] = _promq(
            "avg_over_time(sum(container_memory_working_set_bytes{%s})[%ds:%s]) / 1048576"
            % (sel, win, QUERY_STEP), at)
    return out


def _import_compute_percentiles():
    if SCRIPTS_DIR not in sys.path:
        sys.path.insert(0, SCRIPTS_DIR)
    import compute_percentiles  # scripts/compute_percentiles.py (mounted read-only)
    return compute_percentiles


def _num(v):
    """float or NaN for anything that is not a finite number (like jnum in bash)."""
    if isinstance(v, (int, float)) and not (isinstance(v, float) and math.isnan(v)):
        return float(v)
    return float("nan")


def _read_success_rows():
    """Successful runs from run_index.csv, in file order (same filter as the CSV)."""
    try:
        with open(INDEX_FILE, "r", encoding="utf-8", newline="") as fh:
            rows = list(csv.DictReader(fh))
    except (FileNotFoundError, OSError):
        return []
    return [r for r in rows if (r.get("status") or "") == "success" and r.get("run_id")]


def _finalize_run(row, pct, now_s):
    """Compute the final metrics of one run, or return None to retry later."""
    sus_end_s = (row.get("sustained_end_epoch") or "").strip()
    end_s = (row.get("end_epoch") or "").strip()
    sus_end = int(sus_end_s) if sus_end_s else int(end_s)
    sus_start_s = (row.get("sustained_start_epoch") or "").strip()
    sus_start = int(sus_start_s) if sus_start_s else sus_end - int(SUSTAINED_S)
    win = sus_end - sus_start
    if win <= 0:
        win = int(SUSTAINED_S)

    age = now_s - sus_end
    if age < FINAL_SETTLE_S:
        return None                       # server samples not all in Prometheus yet

    host_logdir = os.path.join(RESULTS_DIR, "raw", os.path.basename(row.get("log_dir") or row["run_id"]))
    sus = pct.compute_metrics(host_logdir, WARMUP_S, SUSTAINED_S, COOLDOWN_S)["sustained"]
    m = {
        "throughput_rps": _num(sus.get("rps")),
        "latency_p50": _num(sus.get("p50")),
        "latency_p90": _num(sus.get("p90")),
        "latency_p95": _num(sus.get("p95")),
        "latency_p99": _num(sus.get("p99")),
        "error_rate_pct": _num(sus.get("error_rate_pct")),
    }
    server = _server_avg(sus_end, win)    # may raise _PromUnavailable -> retry
    if any(math.isnan(v) for v in server.values()) and age < FINAL_NAN_AFTER_S:
        return None                       # maybe not ingested yet; try again soon
    m.update(server)
    return {"labels": (row["protocol"], row["scenario"], row["repetition"]), "m": m}


def _finalizer_loop():
    """Background thread: finalize finished runs one at a time, between runs."""
    try:
        pct = _import_compute_percentiles()
    except Exception as exc:
        print("[h2load-exporter] final metrics disabled: cannot import "
              "compute_percentiles from %s (%s)" % (SCRIPTS_DIR, exc), flush=True)
        return
    while True:
        did_work = False
        try:
            meta = _load_current_run()
            if not (meta and meta.get("run_id")):      # never compete with a live run
                for row in _read_success_rows():
                    rid = row["run_id"]
                    with _final_lock:
                        if rid in _final:
                            continue
                    try:
                        res = _finalize_run(row, pct, time.time())
                    except _PromUnavailable as exc:
                        print("[h2load-exporter] Prometheus unavailable for %s: %s" % (rid, exc), flush=True)
                        break
                    except Exception as exc:
                        print("[h2load-exporter] cannot finalize %s: %s" % (rid, exc), flush=True)
                        continue
                    if res is None:
                        continue
                    with _final_lock:
                        _final[rid] = res
                    did_work = True
                    break                                # re-check "run in progress" between runs
        except Exception as exc:
            print("[h2load-exporter] finalizer error: %s" % exc, flush=True)
        if not did_work:
            time.sleep(FINAL_REFRESH_S)


def _final_text():
    """Render the h2load_final_* gauges (NaN samples are omitted, like the CSV mean)."""
    with _final_lock:
        items = list(_final.values())
    if not items:
        return ""
    lines = []
    for name, key in _FINAL_METRICS:
        samples = []
        for it in items:
            v = it["m"].get(key, float("nan"))
            if v is None or (isinstance(v, float) and (math.isnan(v) or math.isinf(v))):
                continue
            protocol, scenario, rep = it["labels"]
            samples.append('%s{protocol="%s",scenario="%s",repetition="%s"} %r'
                           % (name, protocol, scenario, rep, float(v)))
        if samples:
            lines.append("# HELP %s final per-run value (same as results/summary.csv)" % name)
            lines.append("# TYPE %s gauge" % name)
            lines.extend(samples)
    return "\n".join(lines) + "\n" if lines else ""


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
    threading.Thread(target=_finalizer_loop, name="finalizer", daemon=True).start()
    srv = ThreadingHTTPServer((HTTP_BIND, HTTP_PORT), Handler)
    print(f"[h2load-exporter] listening on {HTTP_BIND}:{HTTP_PORT}, "
          f"live dir={LIVE_DIR}, window={WINDOW_S}s", flush=True)
    srv.serve_forever()
    