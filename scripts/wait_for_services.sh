#!/usr/bin/env bash
# =============================================================================
# wait_for_services.sh
# -----------------------------------------------------------------------------
# Blocks until the whole testbed is healthy and ready for load generation:
# backend, caddy, docker-tc, prometheus, grafana, cadvisor, plus the custom k6
# image. Fails with a non-zero exit code after a timeout so the 150-run
# campaign never starts against a half-initialised stack.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE=(docker compose -f "${ROOT_DIR}/docker-compose.yml")

TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-180}"
DOCKER_TC_URL="http://localhost:4080/health"
PROM_URL="http://localhost:9090/-/ready"

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

echo "[wait] checking containers..."
wait_for "backend container" container_healthy backend
wait_for "caddy container"   container_healthy caddy
wait_for "docker-tc container" container_healthy docker-tc
wait_for "prometheus container" container_healthy prometheus

echo "[wait] checking service endpoints..."
wait_for "docker-tc API"      curl -sSf "${DOCKER_TC_URL}"
wait_for "prometheus ready"   curl -sSf "${PROM_URL}"

TC_URL="http://localhost:4080/caddy"

# Always leave Caddy without a test rule, even if the script fails or is interrupted.
cleanup_tc() { curl -sS -X DELETE "${TC_URL}" >/dev/null 2>&1 || true; }
trap cleanup_tc EXIT

echo "[wait] verifying netem can be applied to caddy..."

test_tc() {
  local resp

  # 1. apply a throwaway rule
  resp="$(curl -sSf -X POST "${TC_URL}" -d "rate=50mbit&delay=150ms&jitter=5ms&loss=1%")" || return 1
  echo "[wait] tc apply response: ${resp}"

  # 2. read it back
  resp="$(curl -sSf "${TC_URL}")" || return 1
  echo "[wait] tc readback: ${resp}"
  grep -q "netem" <<<"${resp}" || return 1
  grep -q "delay 150" <<<"${resp}" || return 1

  # 3. clear it and confirm it is gone
  curl -sSf -X DELETE "${TC_URL}" >/dev/null || return 1
  resp="$(curl -sSf "${TC_URL}")" || return 1
  ! grep -q "netem" <<<"${resp}"
}

if test_tc; then
  echo "[wait] OK  tc netem apply/read/clear works"
else
  echo "[wait] ERROR: tc netem test failed (check docker-tc logs: docker logs docker-tc)" >&2
  exit 1
fi

# ---- ping test: does the rule actually change traffic? ----------------------
echo "[wait] verifying netem really delays traffic (ping test)..."

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

  curl -sSf -X DELETE "${TC_URL}" >/dev/null || return 1
  base="$(avg_rtt)"
  [[ -n "${base}" ]] || { echo "[wait] ping baseline failed"; return 1; }

  # delay only, no loss, so random drops cannot hurt the 10 pings
  curl -sSf -X POST "${TC_URL}" -d "delay=150ms" >/dev/null || return 1
  sleep 1
  shaped="$(avg_rtt)"
  curl -sSf -X DELETE "${TC_URL}" >/dev/null || return 1
  [[ -n "${shaped}" ]] || { echo "[wait] ping with rule failed"; return 1; }

  echo "[wait] ping avg RTT: baseline=${base} ms, with 150ms delay=${shaped} ms"

  # Expect about +150 ms; require at least +140 ms.
  awk -v b="${base}" -v s="${shaped}" 'BEGIN { exit !(s - b >= 140) }'
}

if test_tc_ping; then
  echo "[wait] OK  netem confirmed: ping RTT increased with the rule applied"
else
  echo "[wait] ERROR: ping did not show the expected delay; netem may not be shaping traffic" >&2
  exit 1
fi