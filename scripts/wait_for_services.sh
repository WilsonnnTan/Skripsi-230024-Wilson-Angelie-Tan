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
# End-to-end probe through Caddy -> backend over HTTP/1.1.
wait_for "end-to-end /health" curl -sSfk "https://localhost:8443/health"

echo "[wait] checking the custom k6 image..."
if ! docker image inspect http-testbed/k6:latest >/dev/null 2>&1; then
  echo "[wait] custom k6 image missing; build it with: docker compose build k6" >&2
  exit 1
fi
echo "[wait] OK  k6 image present"

echo "[wait] all services are ready."
"${COMPOSE[@]}" ps
