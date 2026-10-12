#!/usr/bin/env bash
# =============================================================================
# export_results.sh
# -----------------------------------------------------------------------------
# Builds the final, graph-ready CSVs from the 150 run records.
#
# Two data sources, each used for what it does best:
#   * CLIENT metrics (throughput, latency p50/p90/p95/p99, error rate) are
#       computed EXACTLY from the merged h2load --log-file records of the run's
#       10 loaders by scripts/compute_percentiles.py. Phases are sliced from the
#       request timestamps themselves, so the sustained percentiles are whole-
#       window exact (no averaging-of-percentiles).
#   * SERVER metrics (Caddy / backend CPU %, memory MB) come from cAdvisor via
#       Prometheus, aligned to each run purely by TIME over the sustained window
#       recorded in results/run_index.csv (sustained_start/sustained_end).
#
# Outputs:
#   results/summary.csv             one row per run, sustained phase (client+server)
#   results/summary_aggregated.csv  mean +/- std across the 10 repetitions
#   results/summary_by_phase.csv    one row per run x phase (warmup/sustained/cooldown)
#
# Tunables (env): PROM_URL, CPU_RATE_WINDOW, PHASE_RATE_WINDOW, QUERY_STEP,
#                 WARMUP_S / SUSTAINED_S / COOLDOWN_S (must match the campaign).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
INDEX_FILE="${RESULTS_DIR}/run_index.csv"
SUMMARY_CSV="${RESULTS_DIR}/summary.csv"
AGG_CSV="${RESULTS_DIR}/summary_aggregated.csv"
PHASE_CSV="${RESULTS_DIR}/summary_by_phase.csv"
PROM_URL="${PROM_URL:-http://localhost:9090}"
CPU_RATE_WINDOW="${CPU_RATE_WINDOW:-5s}"
PHASE_RATE_WINDOW="${PHASE_RATE_WINDOW:-5s}"
QUERY_STEP="${QUERY_STEP:-5s}"
WARMUP_S="${WARMUP_S:-10}"
SUSTAINED_S="${SUSTAINED_S:-60}"
COOLDOWN_S="${COOLDOWN_S:-10}"
PCT="${SCRIPT_DIR}/compute_percentiles.py"

command -v jq      >/dev/null 2>&1 || { echo "jq is required (apt install jq)"  >&2; exit 1; }
command -v awk     >/dev/null 2>&1 || { echo "awk is required"                  >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"              >&2; exit 1; }
[[ -f "${INDEX_FILE}" ]] || { echo "missing ${INDEX_FILE}; run run_experiments.sh first" >&2; exit 1; }

# --- Prometheus instant query -> bare number or "NaN" (server metrics only) --
promq() {
  local query="$1" at="$2"
  curl -sS -G "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=${query}" \
    --data-urlencode "time=${at}" \
    | jq -r 'if (.data.result | length) > 0 then .data.result[0].value[1] else "NaN" end' 2>/dev/null || echo "NaN"
}

# --- Pull one phase stat from compute_percentiles.py JSON --------------------
# jnum <json> <phase> <key>  -> number or NaN
jnum() {
  local json="$1" phase="$2" key="$3"
  echo "${json}" | jq -r --arg p "${phase}" --arg k "${key}" \
    '(.[$p][$k]) as $v | if ($v == null or ($v|type) != "number" or ($v != $v)) then "NaN" else $v end' \
    2>/dev/null || echo "NaN"
}

# --- Safe arithmetic that propagates NaN -------------------------------------
divide() { awk -v a="$1" -v b="$2" 'BEGIN{ if(a=="NaN"||b=="NaN"||b+0==0){print "NaN"} else printf "%.4f", a/b }'; }
mul()    { awk -v a="$1" -v b="$2" 'BEGIN{ if(a=="NaN"||b=="NaN"){print "NaN"} else printf "%.4f", a*b }'; }

# --- Server metrics averaged over a window -----------------------------------
# server_avg <end_epoch> <window_seconds> <rate_window> -> "cpu_caddy,mem_caddy,cpu_backend,mem_backend"
server_avg() {
  local at="$1" win="$2" rw="$3" out="" svc c m
  for svc in caddy backend; do
    c="$(promq "avg_over_time((sum(rate(container_cpu_usage_seconds_total{container_label_com_docker_compose_service=\"${svc}\"}[${rw}])) * 100)[${win}s:${QUERY_STEP}])" "${at}")"
    m="$(promq "avg_over_time(sum(container_memory_working_set_bytes{container_label_com_docker_compose_service=\"${svc}\"})[${win}s:${QUERY_STEP}]) / 1048576" "${at}")"
    [[ -n "${c}" ]] || c="NaN"
    [[ -n "${m}" ]] || m="NaN"
    out+="${c},${m},"
  done
  echo "${out%,}"
}

echo "protocol,scenario,repetition,throughput_rps,latency_p50,latency_p90,latency_p95,latency_p99,error_rate_pct,cpu_caddy_pct,mem_caddy_mb,cpu_backend_pct,mem_backend_mb" > "${SUMMARY_CSV}"
echo "protocol,scenario,repetition,phase,throughput_rps,latency_p50,latency_p90,latency_p95,latency_p99,error_rate_pct,cpu_caddy_pct,mem_caddy_mb,cpu_backend_pct,mem_backend_mb" > "${PHASE_CSV}"

# Write one row per phase (client + server metrics) to PHASE_CSV for a run.
# Client stats come from the per-run JSON; server windows are derived from the
# sustained window recorded in run_index.csv:
#   warmup    = [sus_start-WARMUP, sus_start]
#   sustained = [sus_start,        sus_end]
#   cooldown  = [sus_end,          sus_end+COOLDOWN]
write_phase_rows() {
  local json="$1" protocol="$2" scenario="$3" repetition="$4" sus_start="$5" sus_end="$6"
  local phase pp50 pp90 pp95 pp99 pthr perr srv at win
  for phase in warmup sustained cooldown; do
    case "${phase}" in
      warmup)    at="${sus_start}";              win="${WARMUP_S}" ;;
      sustained) at="${sus_end}";                win=$(( sus_end - sus_start )) ;;
      cooldown)  at=$(( sus_end + COOLDOWN_S )); win="${COOLDOWN_S}" ;;
    esac
    (( win > 0 )) || win="${SUSTAINED_S}"

    pthr="$(jnum "${json}" "${phase}" "rps")"
    pp50="$(jnum "${json}" "${phase}" "p50")"
    pp90="$(jnum "${json}" "${phase}" "p90")"
    pp95="$(jnum "${json}" "${phase}" "p95")"
    pp99="$(jnum "${json}" "${phase}" "p99")"
    perr="$(jnum "${json}" "${phase}" "error_rate_pct")"
    srv="$(server_avg "${at}" "${win}" "${PHASE_RATE_WINDOW}")"

    for v in pthr pp50 pp90 pp95 pp99 perr; do
      [[ -n "${!v}" ]] || printf -v "${v}" '%s' "NaN"
    done
    echo "${protocol},${scenario},${repetition},${phase},${pthr},${pp50},${pp90},${pp95},${pp99},${perr},${srv}" >> "${PHASE_CSV}"
  done
}

ROWS=0
while IFS=',' read -r protocol scenario repetition run_id start_epoch end_epoch sus_start sus_end status loaders log_dir; do
  [[ "${protocol}" == "protocol" ]] && continue           # header
  [[ "${status}" == "success" ]] || continue
  [[ -n "${sus_end}" ]] || sus_end="${end_epoch}"
  [[ -n "${sus_start}" ]] || sus_start=$(( sus_end - SUSTAINED_S ))

  host_logdir="${RESULTS_DIR}/raw/$(basename "${log_dir}")"

  # ---- client metrics: exact per-phase stats from the merged h2load logs ----
  metrics_json="$(python3 "${PCT}" "${host_logdir}" "${WARMUP_S}" "${SUSTAINED_S}" "${COOLDOWN_S}" 2>/dev/null || echo '{}')"

  throughput="$(jnum "${metrics_json}" "sustained" "rps")"
  p50="$(jnum "${metrics_json}" "sustained" "p50")"
  p90="$(jnum "${metrics_json}" "sustained" "p90")"
  p95="$(jnum "${metrics_json}" "sustained" "p95")"
  p99="$(jnum "${metrics_json}" "sustained" "p99")"
  err="$(jnum "${metrics_json}" "sustained" "error_rate_pct")"

  # ---- server metrics: cAdvisor, averaged over the recorded sustained window
  window=$(( sus_end - sus_start ))
  (( window > 0 )) || window="${SUSTAINED_S}"
  IFS=',' read -r cpu_caddy mem_caddy cpu_backend mem_backend \
    <<< "$(server_avg "${sus_end}" "${window}" "${CPU_RATE_WINDOW}")"

  for v in throughput p50 p90 p95 p99 err cpu_caddy mem_caddy cpu_backend mem_backend; do
    [[ -n "${!v}" ]] || printf -v "${v}" '%s' "NaN"
  done

  echo "${protocol},${scenario},${repetition},${throughput},${p50},${p90},${p95},${p99},${err},${cpu_caddy},${mem_caddy},${cpu_backend},${mem_backend}" >> "${SUMMARY_CSV}"
  write_phase_rows "${metrics_json}" "${protocol}" "${scenario}" "${repetition}" "${sus_start}" "${sus_end}"

  ROWS=$((ROWS + 1))
  echo "[export] ${protocol}/${scenario}/rep${repetition} -> rps=${throughput} p95=${p95} err=${err}% cpu_caddy=${cpu_caddy}% cpu_backend=${cpu_backend}%"
done < "${INDEX_FILE}"

echo "[export] wrote ${ROWS} rows to ${SUMMARY_CSV}"

# --- Aggregate: mean and standard deviation across the 10 repetitions -------
# NaN samples are SKIPPED per column rather than coerced to 0, so one missing
# server-metric sample no longer drags the mean down.
awk -F',' '
NR==1 { next }
{
  key=$1"|"$2
  n[key]++
  for (i=4; i<=13; i++) {
    v=$i
    if (v=="NaN" || v=="") continue
    cnt[key,i]++
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
      c = cnt[k,i]
      if (c > 0) {
        m = sum[k,i]/c
        if (c > 1) { var=(sumsq[k,i]-c*m*m)/(c-1); if (var<0) var=0; sd=sqrt(var) } else sd=0
        printf ",%.4f,%.4f", m, sd
      } else {
        printf ",NaN,NaN"
      }
    }
    printf "\n"
  }
}' "${SUMMARY_CSV}" > "${AGG_CSV}"

{
  head -n 1 "${AGG_CSV}"
  tail -n +2 "${AGG_CSV}" | sort -t',' -k1,1 -k2,2
} > "${AGG_CSV}.tmp" && mv "${AGG_CSV}.tmp" "${AGG_CSV}"

echo "[export] wrote aggregated table to ${AGG_CSV}"

# Deterministic ordering for the per-phase CSV (phase warmup<sustained<cooldown).
{
  head -n 1 "${PHASE_CSV}"
  tail -n +2 "${PHASE_CSV}" \
    | awk -F',' 'BEGIN{OFS=","} {o=($4=="warmup"?0:($4=="sustained"?1:2)); print o,$0}' \
    | sort -t',' -k2,2 -k3,3 -k4,4n -k1,1n \
    | cut -d',' -f2-
} > "${PHASE_CSV}.tmp" && mv "${PHASE_CSV}.tmp" "${PHASE_CSV}"

echo "[export] wrote per-phase table to ${PHASE_CSV}"
echo "[export] done."
