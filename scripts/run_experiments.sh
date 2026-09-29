#!/usr/bin/env bash
# =============================================================================
# run_experiments.sh
# -----------------------------------------------------------------------------
# Orchestrates the full research campaign with NO manual intervention:
#
#     3 protocols x 5 network scenarios x 10 repetitions = 150 runs
#
# HTTP/1.1 and HTTP/2 use the stock k6 image (service "k6"); HTTP/3 uses the
# separate xk6-http3 image (service "k6-http3") — run_once picks the right one.
#
# For every combination it:
#   1. applies the network scenario to Caddy (docker-tc, no restart)
#   2. waits for the qdisc to stabilise
#   3. runs k6 in its own container (load generator resources are separate)
#   4. writes the raw k6 summary JSON and the stdout log
#   5. resets the network and pauses to release TIME_WAIT sockets
#   6. appends a row to results/run_index.csv (used later by export_results.sh)
#
# Failures are logged and SKIPPED so a single bad run never aborts the other 149.
# The script is idempotent/restartable: already-successful runs are skipped
# (set RESUME=0 to force a full re-run).
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE=(docker compose -f "${ROOT_DIR}/docker-compose.yml")

RESULTS_DIR="${ROOT_DIR}/results"
RAW_DIR="${RESULTS_DIR}/raw"
LOG_DIR="${RESULTS_DIR}/logs"
INDEX_FILE="${RESULTS_DIR}/run_index.csv"

REPETITIONS="${REPETITIONS:-10}"
STABILIZE_SECONDS="${STABILIZE_SECONDS:-3}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-8}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"     # 1 retry on infrastructure failure
RESUME="${RESUME:-1}"
DRY_RUN="${DRY_RUN:-0}"

# All three protocols are exercised. HTTP/1.1 and HTTP/2 run on the stock k6
# image; HTTP/3 runs on the xk6-http3 image (selected per-protocol in run_once).
PROTOCOLS=("http1.1" "http2" "http3")
declare -A PROTO_PORT=( ["http1.1"]="8443" ["http2"]="8444" ["http3"]="8445" )
SCENARIOS_LIST=(S1 S2 S3 S4 S5)

mkdir -p "${RAW_DIR}" "${LOG_DIR}"

CAMPAIGN_LOG="${LOG_DIR}/campaign.log"

# Print to the terminal AND append to the single campaign log, with a timestamp.
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "${CAMPAIGN_LOG}"; }

if [[ ! -f "${INDEX_FILE}" ]]; then
  echo "protocol,scenario,repetition,run_id,start_epoch,end_epoch,sustained_start_epoch,sustained_end_epoch,status,attempts,summary_file" > "${INDEX_FILE}"
fi

is_done() {
  # A run is considered done if a success row AND the summary file exist.
  [[ "${RESUME}" == "1" ]] || return 1
  local run_id="$1"
  [[ -s "${RAW_DIR}/${run_id}.json" ]] || return 1
  grep -q ",${run_id},.*,success," "${INDEX_FILE}" 2>/dev/null
}

run_once() {
  local protocol="$1" scenario="$2" rep="$3" run_id="$4" port="$5"
  local url="https://caddy:${port}/api/data"

  if (( DRY_RUN )); then
    echo "[dry-run] ${run_id}: k6 -> ${url}"
    return 0
  fi

  # HTTP/3 needs the xk6-http3 build; h1/h2 use the stock k6 image. The two k6
  # services share a cpuset but never run at the same time.
  local service="k6"
  [[ "${protocol}" == "http3" ]] && service="k6-http3"

  "${COMPOSE[@]}" run --rm --no-deps \
    -e TARGET_URL="${url}" \
    -e PROTOCOL_LABEL="${protocol}" \
    -e SCENARIO="${scenario}" \
    -e REPETITION="${rep}" \
    -e SUMMARY_PATH="/results/raw/${run_id}.json" \
    "${service}" run \
      --out experimental-prometheus-rw \
      --tag run_id="${run_id}" \
      --tag protocol="${protocol}" \
      --tag net_scenario="${scenario}" \
      --tag repetition="${rep}" \
      /scripts/script.js
}

TOTAL=$(( ${#PROTOCOLS[@]} * ${#SCENARIOS_LIST[@]} * REPETITIONS ))
CURRENT=0
SUCCEEDED=0
FAILED=0

echo "==============================================================="
echo " HTTP testbed campaign: ${TOTAL} runs "
echo " $(date -u '+%Y-%m-%dT%H:%M:%SZ') "
echo "==============================================================="

for protocol in "${PROTOCOLS[@]}"; do
  for scenario in "${SCENARIOS_LIST[@]}"; do
    for (( rep = 1; rep <= REPETITIONS; rep++ )); do
      CURRENT=$((CURRENT + 1))
      run_id="${protocol}_${scenario}_${rep}"
      port="${PROTO_PORT[$protocol]}"

      if is_done "${run_id}"; then
        echo "[${CURRENT}/${TOTAL}] ${run_id} - already done, skipping"
        continue
      fi

      echo "[${CURRENT}/${TOTAL}] ${protocol} - ${scenario} - rep ${rep}"

      if "${SCRIPT_DIR}/set_network_scenario.sh" "${scenario}" >> "${CAMPAIGN_LOG}" 2>&1; then
        log "    [net] ${scenario} apply: OK"
      else
        log "    [net] ${scenario} apply: FAILED (continuing anyway)"
      fi

      sleep "${STABILIZE_SECONDS}"

      start_epoch="$(date +%s)"
      attempt=1
      status="failed"
      while (( attempt <= MAX_ATTEMPTS )); do
        if run_once "${protocol}" "${scenario}" "${rep}" "${run_id}" "${port}" \
              >> "${LOG_DIR}/${run_id}.log" 2>&1; then
          status="success"
          break
        fi
        echo "[${CURRENT}/${TOTAL}] ${run_id} failed on attempt ${attempt}; retrying..." | tee -a "${LOG_DIR}/${run_id}.log"
        attempt=$((attempt + 1))
        sleep 3
      done
      end_epoch="$(date +%s)"

      # Sustained phase is [t_start+10s, t_start+70s]; with a total test time of
      # 80s, t_end - 80s is the test start, so sustained = [t_end-70, t_end-10].
      sustained_start=$(( end_epoch - 70 ))
      sustained_end=$(( end_epoch - 10 ))

      echo "${protocol},${scenario},${rep},${run_id},${start_epoch},${end_epoch},${sustained_start},${sustained_end},${status},${attempt},/results/raw/${run_id}.json" >> "${INDEX_FILE}"

      if [[ "${status}" == "success" ]]; then
        SUCCEEDED=$((SUCCEEDED + 1))
        echo "    -> ${status}"
      else
        FAILED=$((FAILED + 1))
        echo "    -> FAILED (logged, continuing)"
      fi

      # Release the emulated condition and let TCP state drain before the next
      # run so runs do not contaminate each other.
      if (( DRY_RUN == 0 )); then
        if "${SCRIPT_DIR}/reset_network.sh" >> "${CAMPAIGN_LOG}" 2>&1; then
          log "    [net] reset: OK"
        else
          log "    [net] reset: FAILED (continuing anyway)"
        fi
      fi
      sleep "${COOLDOWN_SECONDS}"
    done
  done
done

echo "==============================================================="
echo " Campaign finished: ${SUCCEEDED} succeeded, ${FAILED} failed, ${TOTAL} total"
echo " Index: ${INDEX_FILE}"
echo " $(date -u '+%Y-%m-%dT%H:%M:%SZ') "
echo " Next: ./scripts/export_results.sh"
echo "==============================================================="
