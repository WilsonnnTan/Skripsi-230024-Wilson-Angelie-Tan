#!/usr/bin/env bash
# =============================================================================
# run_experiments.sh
# -----------------------------------------------------------------------------
# Orchestrates the full research campaign with NO manual intervention:
#
#     3 protocols x 5 network scenarios x 10 repetitions = 150 runs
#
# A single h2load image (built with HTTP/3) drives all three protocols. Each run
# launches LOADERS (10) h2load containers in parallel;
# Phases are sliced by request timestamp afterwards.

# For every combination it:
#   1. launches the 10 loader containers (each sleeps PRESTART before loading)
#   2. applies the network scenario to EACH loader (docker-tc, symmetric netem)
#   3. marks run_start and publishes current_run.json for the live exporter
#   4. waits for all 10 h2load processes to finish
#   5. clears the network on every loader and removes the containers
#   6. appends a row to results/run_index.csv (used by export_results.sh)
#
# Failures are logged and SKIPPED so one bad run never aborts the other 149.
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
LIVE_DIR="${RESULTS_DIR}/live"
INDEX_FILE="${RESULTS_DIR}/run_index.csv"

REPETITIONS="${REPETITIONS:-10}"
LOADERS="${LOADERS:-10}"              # h2load containers per run
WARMUP_S="${WARMUP_S:-10}"
SUSTAINED_S="${SUSTAINED_S:-60}"
COOLDOWN_S="${COOLDOWN_S:-10}"
PRESTART="${PRESTART:-3}"             # per-container sleep before load (netem window)
DURATION=$(( WARMUP_S + SUSTAINED_S + COOLDOWN_S ))
THREADS="${THREADS:-1}"
STABILIZE_SECONDS="${STABILIZE_SECONDS:-2}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-8}"
RESUME="${RESUME:-1}"
DRY_RUN="${DRY_RUN:-0}"

PROTOCOLS=("http1.1" "http2" "http3")
declare -A PROTO_PORT=( ["http1.1"]="8443" ["http2"]="8444" ["http3"]="8445" )
declare -A PROTO_CLIENTS=( ["http1.1"]="1" ["http2"]="1" ["http3"]="1" )
# NOTE: HTTP/1.1 doesnt support concurrent stream and h2load will ignore the STREAMS flag
declare -A PROTO_STREAMS=( ["http1.1"]="6" ["http2"]="6" ["http3"]="6" )
SCENARIOS_LIST=(S1 S2 S3 S4 S5)

mkdir -p "${RAW_DIR}" "${LOG_DIR}" "${LIVE_DIR}"
CAMPAIGN_LOG="${LOG_DIR}/campaign.log"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "${CAMPAIGN_LOG}"; }

if [[ ! -f "${INDEX_FILE}" ]]; then
  echo "protocol,scenario,repetition,run_id,start_epoch,end_epoch,sustained_start_epoch,sustained_end_epoch,status,loaders,log_dir" > "${INDEX_FILE}"
fi

# Loader container names are fixed per slot so docker-tc can target them.
loader_names() {
  local i
  for (( i = 1; i <= LOADERS; i++ )); do echo "h2load_run_${i}"; done
}

is_done() {
  [[ "${RESUME}" == "1" ]] || return 1
  local run_id="$1"
  # Done if a success row exists AND at least one non-empty per-request log is present.
  grep -q ",${run_id},.*,success," "${INDEX_FILE}" 2>/dev/null || return 1
  ls -1 "${RAW_DIR}/${run_id}"/h2load_*.log >/dev/null 2>&1
}

# Remove any leftover loader containers from a previous (possibly crashed) run.
cleanup_loaders() {
  local name err
  for name in $(loader_names); do
    # Discard stdout (the removed ID), capture stderr. "No such container" is the
    # normal case (slot already empty), so only a *different* error is logged.
    err="$(docker rm -f "${name}" 2>&1 >/dev/null)" || true
    if [[ -n "${err}" ]] && ! grep -qi "no such container" <<<"${err}"; then
      echo "[cleanup] ${name}: ${err}" >> "${CAMPAIGN_LOG}"
    fi
  done
}

# Launch the 10 loader containers detached, IN PARALLEL so their h2load start
# times cluster within <1 s (keeps the shared phase window accurate; PRESTART +
# the 10 s warmup absorb any residual spread). Returns non-zero if any fail.
launch_loaders() {
  local protocol="$1" run_id="$2" url="$3" clients="$4" streams="$5"
  local i name pids=() rc=0
  mkdir -p "${RAW_DIR}/${run_id}"
  # Each `docker compose run` launch (container ID on success, or the daemon
  # create error on failure) is captured to a scratch file in a throwaway temp
  # dir -- NOT under results/ -- so nothing litters results/logs. Per-loader
  # files only avoid the garbled interleaving of 10 parallel appends; on failure
  # they are folded into the campaign log, and the temp dir is always removed.
  # campaign.log is the only lasting record.
  local launch_dir
  launch_dir="$(mktemp -d)"
  for (( i = 1; i <= LOADERS; i++ )); do
    name="h2load_run_${i}"
    (
      COMPOSE_PROFILES=loadgen "${COMPOSE[@]}" run -d --no-deps --name "${name}" \
        -e TARGET_URL="${url}" \
        -e PROTOCOL="${protocol}" \
        -e LOG_FILE="/results/raw/${run_id}/h2load_${i}.log" \
        -e CLIENTS="${clients}" \
        -e STREAMS="${streams}" \
        -e THREADS="${THREADS}" \
        -e DURATION="${DURATION}" \
        -e PRESTART="${PRESTART}" \
        h2load
    ) >"${launch_dir}/${i}.log" 2>&1 &
    pids+=("$!")
  done
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || rc=1
  done
  if (( rc != 0 )); then
    # A loader failed to start: fold every loader's captured output into the
    # campaign log (this is where the real create error was being lost).
    {
      echo "----- [launch_loaders] ${run_id}: one or more loaders failed to start -----"
      for (( i = 1; i <= LOADERS; i++ )); do
        echo "--- loader ${i} (h2load_run_${i}) ---"
        cat "${launch_dir}/${i}.log"
      done
      echo "----- end ${run_id} launch output -----"
    } >> "${CAMPAIGN_LOG}"
  fi
  rm -rf "${launch_dir}"
  return "${rc}"
}

# Block until every loader container is actually in the Running state.
wait_loaders_running() {
  local name tries
  for name in $(loader_names); do
    for tries in {1..20}; do
      if [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" == "true" ]]; then
        continue 2
      fi
      sleep 0.25
    done
    echo "[loader] ${name} never reached running state" >> "${CAMPAIGN_LOG}"
    return 1
  done
}

# Write the marker the live exporter reads to label + phase-slice the stream.
publish_current_run() {
  local run_id="$1" protocol="$2" scenario="$3" rep="$4" run_start="$5"
  cat > "${LIVE_DIR}/current_run.json" <<EOF
{
  "run_id": "${run_id}",
  "protocol": "${protocol}",
  "scenario": "${scenario}",
  "repetition": "${rep}",
  "run_start_epoch": ${run_start},
  "warmup_s": ${WARMUP_S},
  "sustained_s": ${SUSTAINED_S},
  "cooldown_s": ${COOLDOWN_S},
  "log_glob": "/results/raw/${run_id}/h2load_*.log"
}
EOF
}

clear_current_run() { echo '{}' > "${LIVE_DIR}/current_run.json"; }

TOTAL=$(( ${#PROTOCOLS[@]} * ${#SCENARIOS_LIST[@]} * REPETITIONS ))
CURRENT=0
SUCCEEDED=0
FAILED=0

echo "==============================================================="
echo " HTTP testbed campaign (h2load): ${TOTAL} runs, ${LOADERS} loaders each"
echo " $(date -u '+%Y-%m-%dT%H:%M:%SZ') "
echo "==============================================================="

# Build the h2load image ONCE, up front, and reuse it for every run. Without
# this, the first run's 10 parallel `docker compose run` could each try to build
# the same (missing) image simultaneously (10x a 10-30 min build, racing each
# other). `docker compose run` does NOT rebuild an image that already exists --
# it only builds when the image is missing, and `--build` would force a rebuild
# -- so once this up-front build has produced the image, the per-run launches
# just start containers from it. (There is no `--no-build` flag for `run`; that
# option exists only on `up`.)
if (( ! DRY_RUN )); then
  log "[build] building h2load image (once)..."
  if COMPOSE_PROFILES=loadgen "${COMPOSE[@]}" build h2load >> "${CAMPAIGN_LOG}" 2>&1; then
    log "[build] h2load image ready"
  else
    log "[build] FATAL: h2load image build failed (see ${CAMPAIGN_LOG}); aborting campaign"
    exit 1
  fi
fi

for protocol in "${PROTOCOLS[@]}"; do
  for scenario in "${SCENARIOS_LIST[@]}"; do
    for (( rep = 1; rep <= REPETITIONS; rep++ )); do
      CURRENT=$((CURRENT + 1))
      run_id="${protocol}_${scenario}_${rep}"
      port="${PROTO_PORT[$protocol]}"
      clients="${PROTO_CLIENTS[$protocol]}"
      streams="${PROTO_STREAMS[$protocol]}"
      url="https://caddy:${port}/api/data"

      if is_done "${run_id}"; then
        echo "[${CURRENT}/${TOTAL}] ${run_id} - already done, skipping"
        continue
      fi

      echo "[${CURRENT}/${TOTAL}] ${protocol} - ${scenario} - rep ${rep}"

      if (( DRY_RUN )); then
        echo "    [dry-run] ${LOADERS}x h2load -> ${url} (c=${clients} m=${streams})"
        continue
      fi

      cleanup_loaders

      # 1. launch loaders (they sleep PRESTART before loading)
      start_epoch="$(date +%s)"
      if ! launch_loaders "${protocol}" "${run_id}" "${url}" "${clients}" "${streams}"; then
        log "    [loader] launch failed; cleaning up and skipping"
        cleanup_loaders
        echo "${protocol},${scenario},${rep},${run_id},${start_epoch},$(date +%s),0,0,failed,${LOADERS},/results/raw/${run_id}" >> "${INDEX_FILE}"
        FAILED=$((FAILED + 1))
        continue
      fi

      # make sure every loader is really running before touching its netns
      if ! wait_loaders_running; then
        log "    [loader] not all loaders running; cleaning up and skipping"
        cleanup_loaders
        echo "${protocol},${scenario},${rep},${run_id},${start_epoch},$(date +%s),0,0,failed,${LOADERS},/results/raw/${run_id}" >> "${INDEX_FILE}"
        FAILED=$((FAILED + 1))
        continue
      fi

      # 2. apply the network scenario to every loader (symmetric netem), while
      #    the PRESTART sleep is still running inside the containers.
      if "${SCRIPT_DIR}/set_network_scenario.sh" "${scenario}" $(loader_names) >> "${CAMPAIGN_LOG}" 2>&1; then
        log "    [net] ${scenario} apply to loaders: OK"
      else
        log "    [net] ${scenario} apply to loaders: FAILED (continuing anyway)"
      fi

      # 3. wait out the remaining PRESTART window, then mark the measured start.
      sleep "${STABILIZE_SECONDS}"
      run_start=$(( start_epoch + PRESTART ))
      sustained_start=$(( run_start + WARMUP_S ))
      sustained_end=$(( sustained_start + SUSTAINED_S ))
      publish_current_run "${run_id}" "${protocol}" "${scenario}" "${rep}" "${run_start}"

      # 4. wait for all loaders to finish (DURATION + PRESTART + margin).
      status="success"
      for name in $(loader_names); do
        rc="$(docker wait "${name}" 2>>"${CAMPAIGN_LOG}" || echo 1)"
        if [[ "${rc}" != "0" ]]; then
          status="failed"
          echo "    [loader] ${name} exited rc=${rc}" | tee -a "${LOG_DIR}/${run_id}.log"
        fi
      done
      end_epoch="$(date +%s)"

      # Guard: a run with no request logs is a failure regardless of exit codes.
      if ! ls -1 "${RAW_DIR}/${run_id}"/h2load_*.log >/dev/null 2>&1; then
        status="failed"
      fi

      # 5. clear the network on every loader, collect logs, remove containers.
      if "${SCRIPT_DIR}/reset_network.sh" $(loader_names) >> "${CAMPAIGN_LOG}" 2>&1; then
        log "    [net] reset loaders: OK"
      else
        log "    [net] reset loaders: FAILED (continuing anyway)"
      fi
      for name in $(loader_names); do
        docker logs "${name}" >> "${LOG_DIR}/${run_id}.log" 2>&1 || true
      done
      clear_current_run
      cleanup_loaders

      # 6. record the run.
      echo "${protocol},${scenario},${rep},${run_id},${run_start},${end_epoch},${sustained_start},${sustained_end},${status},${LOADERS},/results/raw/${run_id}" >> "${INDEX_FILE}"

      if [[ "${status}" == "success" ]]; then
        SUCCEEDED=$((SUCCEEDED + 1)); echo "    -> ${status}"
      else
        FAILED=$((FAILED + 1)); echo "    -> FAILED (logged, continuing)"
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