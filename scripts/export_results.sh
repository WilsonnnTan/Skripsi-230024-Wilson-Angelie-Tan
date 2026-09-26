#!/usr/bin/env bash
# =============================================================================
# export_results.sh
# -----------------------------------------------------------------------------
# Builds the final, graph-ready CSV from the 150 run records.
#
# Two data sources, each used for what it does best:
#   * CLIENT metrics (throughput, latency p50/p90/p95/p99, error rate)
#       come straight from the per-run k6 summary JSON written by
#       handleSummary(). Those are EXACT whole-window percentiles over the
#       sustained phase (via the "{phase:sustained}" sub-metrics), so no
#       averaging-of-percentiles from Prometheus is involved.
#   * SERVER metrics (Caddy / backend CPU %, memory MB) come from cAdvisor via
#       Prometheus, averaged over the exact sustained window recorded in
#       results/run_index.csv (columns sustained_start_epoch/sustained_end_epoch).
#
# Prometheus/Grafana remain the LIVE dashboard; this export does not depend on
# k6 remote-write, so a remote-write hiccup never corrupts the thesis CSV.
#
# Outputs:
#   results/summary.csv             one row per run (150 rows)
#   results/summary_aggregated.csv  mean +/- std across the 10 repetitions
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
INDEX_FILE="${RESULTS_DIR}/run_index.csv"
SUMMARY_CSV="${RESULTS_DIR}/summary.csv"
AGG_CSV="${RESULTS_DIR}/summary_aggregated.csv"
PROM_URL="${PROM_URL:-http://localhost:9090}"
# cAdvisor scrapes at 1 s; a 30 s rate window is stable without reaching far
# outside the sustained window. Sub-query resolution for the CPU average.
CPU_RATE_WINDOW="${CPU_RATE_WINDOW:-30s}"
QUERY_STEP="${QUERY_STEP:-5s}"

command -v jq  >/dev/null 2>&1 || { echo "jq is required (apt install jq)"  >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "awk is required"                  >&2; exit 1; }
[[ -f "${INDEX_FILE}" ]] || { echo "missing ${INDEX_FILE}; run run_experiments.sh first" >&2; exit 1; }

# --- Prometheus instant query -> bare number or "NaN" (server metrics only) --
promq() {
  local query="$1" at="$2"
  curl -sS -G "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=${query}" \
    --data-urlencode "time=${at}" \
    | jq -r 'if (.data.result | length) > 0 then .data.result[0].value[1] else "NaN" end' 2>/dev/null || echo "NaN"
}

# --- Read one stat from a k6 handleSummary() JSON: .metrics[m].values[s] -----
json_stat() {
  local file="$1" metric="$2" stat="$3"
  [[ -s "${file}" ]] || { echo "NaN"; return; }
  jq -r --arg m "${metric}" --arg s "${stat}" \
    '(.metrics[$m].values[$s]) // "NaN"' "${file}" 2>/dev/null || echo "NaN"
}

# --- Safe arithmetic that propagates NaN -------------------------------------
divide() { awk -v a="$1" -v b="$2" 'BEGIN{ if(a=="NaN"||b=="NaN"||b+0==0){print "NaN"} else printf "%.4f", a/b }'; }
mul()    { awk -v a="$1" -v b="$2" 'BEGIN{ if(a=="NaN"||b=="NaN"){print "NaN"} else printf "%.4f", a*b }'; }

echo "protocol,scenario,repetition,throughput_rps,latency_p50,latency_p90,latency_p95,latency_p99,error_rate_pct,cpu_caddy_pct,mem_caddy_mb,cpu_backend_pct,mem_backend_mb" > "${SUMMARY_CSV}"

ROWS=0
while IFS=',' read -r protocol scenario repetition run_id start_epoch end_epoch sus_start sus_end status attempts summary_file; do
  [[ "${protocol}" == "protocol" ]] && continue           # header
  [[ "${status}" == "success" ]] || continue
  [[ -n "${sus_end}" ]] || sus_end="${end_epoch}"
  [[ -n "${sus_start}" ]] || sus_start=$(( sus_end - 60 ))

  local_summary="${RESULTS_DIR}/raw/$(basename "${summary_file}")"

  # ---- client metrics: exact sustained sub-metrics from the k6 summary ----
  p50="$(json_stat "${local_summary}" "req_duration_ms{phase:sustained}" "p(50)")"
  p90="$(json_stat "${local_summary}" "req_duration_ms{phase:sustained}" "p(90)")"
  p95="$(json_stat "${local_summary}" "req_duration_ms{phase:sustained}" "p(95)")"
  p99="$(json_stat "${local_summary}" "req_duration_ms{phase:sustained}" "p(99)")"

  # Throughput = sustained request count / sustained duration (60 s).
  sus_count="$(json_stat "${local_summary}" "reqs{phase:sustained}" "count")"
  throughput="$(divide "${sus_count}" 60)"

  # Error rate as a percentage.
  err_rate="$(json_stat "${local_summary}" "req_errors{phase:sustained}" "rate")"
  err="$(mul "${err_rate}" 100)"

  # ---- server metrics: cAdvisor, averaged over the recorded sustained window
  window=$(( sus_end - sus_start ))
  (( window > 0 )) || window=60

  cpu_caddy="$(promq "avg_over_time((sum(rate(container_cpu_usage_seconds_total{name=\"caddy\"}[${CPU_RATE_WINDOW}])) * 100)[${window}s:${QUERY_STEP}])" "${sus_end}")"
  mem_caddy="$(promq "avg_over_time(container_memory_working_set_bytes{name=\"caddy\"}[${window}s]) / 1048576" "${sus_end}")"
  cpu_backend="$(promq "avg_over_time((sum(rate(container_cpu_usage_seconds_total{name=\"backend\"}[${CPU_RATE_WINDOW}])) * 100)[${window}s:${QUERY_STEP}])" "${sus_end}")"
  mem_backend="$(promq "avg_over_time(container_memory_working_set_bytes{name=\"backend\"}[${window}s]) / 1048576" "${sus_end}")"

  # Normalise empty values to NaN.
  for v in throughput p50 p90 p95 p99 err cpu_caddy mem_caddy cpu_backend mem_backend; do
    [[ -n "${!v}" ]] || printf -v "${v}" '%s' "NaN"
  done

  echo "${protocol},${scenario},${repetition},${throughput},${p50},${p90},${p95},${p99},${err},${cpu_caddy},${mem_caddy},${cpu_backend},${mem_backend}" >> "${SUMMARY_CSV}"
  ROWS=$((ROWS + 1))
  echo "[export] ${protocol}/${scenario}/rep${repetition} -> rps=${throughput} p95=${p95} err=${err}%"
done < "${INDEX_FILE}"

echo "[export] wrote ${ROWS} rows to ${SUMMARY_CSV}"

# --- Aggregate: mean and standard deviation across the 10 repetitions -------
awk -F',' '
NR==1 { next }
{
  key=$1"|"$2
  n[key]++
  for (i=4; i<=13; i++) {
    v=$i; if (v=="NaN") v=0
    sum[key,i]+=v
    sumsq[key,i]+=v*v
  }
  keys[key]=1
}
END {
  printf "protocol,scenario,repetitions"
  split("throughput_rps latency_p50 latency_p90 latency_p95 latency_p99 error_rate_pct cpu_caddy_pct mem_caddy_mb cpu_backend_pct mem_backend_mb", names, " ")
  for (i=1;i<=10;i++) printf ",%s_mean,%s_std", names[i], names[i]
  printf "\n"
  for (k in keys) {
    split(k, p, "|")
    printf "%s,%s,%d", p[1], p[2], n[k]
    for (i=4;i<=13;i++) {
      m = sum[k,i]/n[k]
      if (n[k] > 1) { var=(sumsq[k,i]-n[k]*m*m)/(n[k]-1); if (var<0) var=0; sd=sqrt(var) } else sd=0
      printf ",%.4f,%.4f", m, sd
    }
    printf "\n"
  }
}' "${SUMMARY_CSV}" > "${AGG_CSV}"

# Deterministic ordering: header first, then protocol/scenario.
{
  head -n 1 "${AGG_CSV}"
  tail -n +2 "${AGG_CSV}" | sort -t',' -k1,1 -k2,2
} > "${AGG_CSV}.tmp" && mv "${AGG_CSV}.tmp" "${AGG_CSV}"

echo "[export] wrote aggregated table to ${AGG_CSV}"
echo "[export] done."
