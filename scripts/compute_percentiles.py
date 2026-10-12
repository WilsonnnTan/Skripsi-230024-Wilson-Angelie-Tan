#!/usr/bin/env python3
# =============================================================================
# compute_percentiles.py <log_dir> [warmup_s] [sustained_s] [cooldown_s]
# -----------------------------------------------------------------------------
# Reads every h2load --log-file in <log_dir> (the 10 loaders of one run) and
# computes EXACT client-side metrics per phase, printed as JSON on stdout:
#
#   { "<phase>": { "count", "errors", "rps", "error_rate_pct",
#                  "p50", "p90", "p95", "p99" }, ... }   (durations in ms)
#
# Phases are sliced from the request timestamps themselves (t0 = earliest
# request across all loaders), so the window is immune to container launch
# latency. h2load --log-file columns are TAB-separated:
#     <start time us since epoch> \t <status> \t <duration us>   (status -1 = fail)
# =============================================================================

import glob
import json
import os
import sys


def percentile(sorted_vals, q):
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    pos = q * (len(sorted_vals) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = pos - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: compute_percentiles.py <log_dir> [warmup_s sustained_s cooldown_s]\n")
        sys.exit(2)
    log_dir = sys.argv[1]
    warmup = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
    sustained = float(sys.argv[3]) if len(sys.argv) > 3 else 60.0
    cooldown = float(sys.argv[4]) if len(sys.argv) > 4 else 10.0

    records = []  # (start_us, dur_ms, ok)
    for path in glob.glob(os.path.join(log_dir, "h2load_*.log")):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) < 3:
                        continue
                    try:
                        start_us = int(parts[0])
                        status = int(parts[1])
                        dur_us = int(parts[2])
                    except ValueError:
                        continue
                    ok = (200 <= status < 400)
                    records.append((start_us, dur_us / 1000.0, ok))
        except OSError:
            continue

    phases = {
        "warmup": {"durs": [], "count": 0, "errors": 0, "dur_s": warmup},
        "sustained": {"durs": [], "count": 0, "errors": 0, "dur_s": sustained},
        "cooldown": {"durs": [], "count": 0, "errors": 0, "dur_s": cooldown},
    }

    if records:
        t0 = min(r[0] for r in records)
        warm_end = t0 + warmup * 1e6
        sust_end = warm_end + sustained * 1e6
        cool_end = sust_end + cooldown * 1e6
        for start_us, dur_ms, ok in records:
            if start_us < warm_end:
                ph = "warmup"
            elif start_us < sust_end:
                ph = "sustained"
            elif start_us < cool_end:
                ph = "cooldown"
            else:
                continue  # tail beyond the planned duration
            b = phases[ph]
            b["count"] += 1
            if not ok:
                b["errors"] += 1
            b["durs"].append(dur_ms)

    out = {}
    for name, b in phases.items():
        durs = sorted(b["durs"])
        n = b["count"]
        rps = n / b["dur_s"] if b["dur_s"] > 0 else float("nan")
        err_pct = (b["errors"] / n * 100.0) if n else float("nan")
        out[name] = {
            "count": n,
            "errors": b["errors"],
            "rps": rps,
            "error_rate_pct": err_pct,
            "p50": percentile(durs, 0.50),
            "p90": percentile(durs, 0.90),
            "p95": percentile(durs, 0.95),
            "p99": percentile(durs, 0.99),
        }
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
