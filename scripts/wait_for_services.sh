#!/usr/bin/env bash
# =============================================================================
# wait_for_services.sh
# -----------------------------------------------------------------------------
# Blocks until the whole testbed is healthy and ready for load generation:
# backend, caddy, docker-tc, prometheus, grafana, cadvisor, plus the custom k6
# image. Fails with a non-zero exit code after a timeout so the 150-run
# campaign never starts against a half-initialised stack.
#
# docker-tc shapes BOTH directions (egress + ifb ingress), so a one-way delay
# of 75ms gives a round-trip time of 150ms.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE=(docker compose -f "${ROOT_DIR}/docker-compose.yml")

TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-180}"
DOCKER_TC_URL="http://localhost:4080/health"
PROM_URL="http://localhost:9090/-/ready"
# The exporter is NOT published on the host (monitoring_net only), so it is
# probed from inside its own container instead of via localhost:9115.
EXPORTER_URL="http://127.0.0.1:9115/health"

# Delay is applied on egress AND ingress, so RTT = 2 x per-direction delay.
RTT_MS="${TEST_RTT_MS:-150}"
DELAY_PER_DIR_MS=$(( RTT_MS / 2 ))        # 75 ms each way
RTT_MIN_MS=$(( RTT_MS - 10 ))             # 140
RTT_MAX_MS=$(( RTT_MS + 25 ))             # 175 (catches delay applied twice)
TC_RETRIES="${TC_RETRIES:-5}"

wait_for() {
  local description="$1"
  shift
  local waited=0
  until "$@" >/dev/null 2>&1; do
    if (( waited >= TIMEOUT_SECONDS )); then
      echo "[wait] TIMEOUT waiting for ${description}" >&2
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
    echo "[wait] ... ${description} (${waited}s)"
  done
  echo "[wait] OK  ${description}"
}

container_healthy() {
  local name="$1"
  local status
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${name}" 2>/dev/null || true)"
  [[ "${status}" == "healthy" || "${status}" == "running" ]]
}

# retry <attempts> <command...>: run until it succeeds, 2s pause between tries.
retry() {
  local attempts="$1"; shift
  local i
  for (( i = 1; i <= attempts; i++ )); do
    if "$@"; then return 0; fi
    echo "[wait] attempt ${i}/${attempts} failed: $*" >&2
    sleep 2
  done
  return 1
}

echo "[wait] checking containers..."
wait_for "backend container" container_healthy backend
wait_for "caddy container"   container_healthy caddy
wait_for "docker-tc container" container_healthy docker-tc
wait_for "prometheus container" container_healthy prometheus
wait_for "h2load-exporter container" container_healthy h2load-exporter

echo "[wait] checking service endpoints..."
wait_for "docker-tc API"      curl -sSf "${DOCKER_TC_URL}"
wait_for "prometheus ready"   curl -sSf "${PROM_URL}"
wait_for "h2load-exporter"    docker exec h2load-exporter python3 -c "import urllib.request;urllib.request.urlopen('${EXPORTER_URL}', timeout=3)"

TC_URL="http://localhost:4080/caddy"

# Always leave Caddy without a test rule, even if the script fails or is interrupted.
cleanup_tc() { curl -sS -X DELETE "${TC_URL}" >/dev/null 2>&1 || true; }
trap cleanup_tc EXIT

# ---- helpers ----------------------------------------------------------------
tc_clear() {
  curl -sSf -X DELETE "${TC_URL}" >/dev/null || return 1
}

# Apply a rule and poll the readback until it contains the expected delay.
# docker-tc can take a moment before the qdisc is visible, so poll instead of
# failing on the first read.
tc_apply_and_confirm() {
  local params="$1" expect_delay="$2"
  local resp i

  resp="$(curl -sSf -X POST "${TC_URL}" -d "${params}")" || return 1
  echo "[wait] tc apply response: ${resp}"

  for (( i = 1; i <= 10; i++ )); do
    resp="$(curl -sSf "${TC_URL}")" || return 1
    if grep -q "netem" <<<"${resp}" \
       && grep -Eq "delay ${expect_delay}(\.0+)?ms" <<<"${resp}"; then
      echo "[wait] tc readback: ${resp}"
      return 0
    fi
    sleep 1
  done
  echo "[wait] tc readback never showed delay ${expect_delay}ms: ${resp}" >&2
  return 1
}

# Clear the rule and confirm netem is gone.
tc_clear_and_confirm() {
  local resp i
  tc_clear || return 1
  for (( i = 1; i <= 10; i++ )); do
    resp="$(curl -sSf "${TC_URL}")" || return 1
    if ! grep -q "netem" <<<"${resp}"; then
      return 0
    fi
    sleep 1
  done
  echo "[wait] netem still present after DELETE: ${resp}" >&2
  return 1
}

echo "[wait] verifying netem can be applied (symmetric egress+ifb, ${DELAY_PER_DIR_MS}ms each way) to caddy as a docker-tc self-test..."

test_tc() {
  # start from a clean state
  tc_clear || return 1
  # 1+2. apply a throwaway rule and read it back
  tc_apply_and_confirm "rate=50mbit&delay=${DELAY_PER_DIR_MS}ms&jitter=5ms&loss=1%" "${DELAY_PER_DIR_MS}" || return 1
  # 3. clear it and confirm it is gone
  tc_clear_and_confirm
}

if retry "${TC_RETRIES}" test_tc; then
  echo "[wait] OK  tc netem apply/read/clear works"
else
  echo "[wait] ERROR: tc netem test failed (check docker-tc logs: docker logs docker-tc)" >&2
  exit 1
fi

# ---- ping test: does the rule actually change traffic? ----------------------
echo "[wait] verifying netem really delays traffic (ping test, expecting +${RTT_MS}ms RTT)..."

command -v ping >/dev/null 2>&1 || { echo "[wait] ERROR: ping not installed (apt install iputils-ping)" >&2; exit 1; }

# Caddy's IP on the edge subnet (the shaped interface), not the backend one.
CADDY_IP="$(docker inspect -f '{{range $n,$c := .NetworkSettings.Networks}}{{$c.IPAddress}} {{end}}' caddy \
  | tr ' ' '\n' | grep '^172\.28\.' | head -n1 || true)"
[[ -n "${CADDY_IP}" ]] || { echo "[wait] ERROR: could not find Caddy's 172.28.x edge IP" >&2; exit 1; }
echo "[wait] pinging Caddy edge IP ${CADDY_IP}"

avg_rtt() {
  # prints the average RTT in ms, or nothing if ping failed
  ping -c 10 -i 0.2 -q "${CADDY_IP}" 2>/dev/null \
    | awk -F'/' '/^(rtt|round-trip)/ {print $5}' || true
}

test_tc_ping() {
  local base shaped

  tc_clear_and_confirm || return 1
  base="$(avg_rtt)"
  [[ -n "${base}" ]] || { echo "[wait] ping baseline failed"; return 1; }

  # delay only, no loss/jitter, so random drops cannot hurt the 10 pings.
  # 75ms on egress + 75ms on ingress (ifb) = 150ms RTT.
  tc_apply_and_confirm "delay=${DELAY_PER_DIR_MS}ms" "${DELAY_PER_DIR_MS}" || { tc_clear || true; return 1; }
  sleep 1
  shaped="$(avg_rtt)"
  tc_clear_and_confirm || return 1
  [[ -n "${shaped}" ]] || { echo "[wait] ping with rule failed"; return 1; }

  echo "[wait] ping avg RTT: baseline=${base} ms, with ${DELAY_PER_DIR_MS}ms each way=${shaped} ms"

  # Expect about +150 ms RTT: at least +140 (both directions shaped) and at
  # most +175 (anything near +300 would mean the delay was applied twice).
  awk -v b="${base}" -v s="${shaped}" -v lo="${RTT_MIN_MS}" -v hi="${RTT_MAX_MS}" \
    'BEGIN { d = s - b; if (d < lo) { print "[wait] added RTT " d " ms is below " lo " ms (is ingress/ifb shaping missing?)" > "/dev/stderr"; exit 1 }
             if (d > hi) { print "[wait] added RTT " d " ms is above " hi " ms (delay applied more than once?)" > "/dev/stderr"; exit 1 }
             exit 0 }'
}

if retry "${TC_RETRIES}" test_tc_ping; then
  echo "[wait] OK  netem confirmed: ping RTT increased by ~${RTT_MS}ms with the rule applied"
else
  echo "[wait] ERROR: ping did not show the expected delay; netem may not be shaping traffic" >&2
  exit 1
fi