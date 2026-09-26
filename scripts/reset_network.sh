#!/usr/bin/env bash
# =============================================================================
# reset_network.sh
# -----------------------------------------------------------------------------
# Clears ALL traffic-control rules from the Caddy client-facing interface,
# returning the link to its unrestricted (line-rate, zero-latency) state.
# Run between test runs to release TIME_WAIT sockets and avoid state bleed.
# =============================================================================
set -euo pipefail

DOCKER_TC_HOST="${DOCKER_TC_HOST:-localhost}"
DOCKER_TC_PORT="${DOCKER_TC_PORT:-4080}"
TARGET_CONTAINER="${TARGET_CONTAINER:-caddy}"
API_URL="http://${DOCKER_TC_HOST}:${DOCKER_TC_PORT}/${TARGET_CONTAINER}"

# DELETE removes the root qdisc (no-op if none exists).
RESPONSE="$(curl -sS -X DELETE "${API_URL}")"
echo "[net] reset -> ${RESPONSE}"

# Confirm the netem qdisc is gone (best-effort; absence is success).
if curl -sS -X GET "${API_URL}" | grep -q "netem"; then
  echo "[net] WARNING: netem qdisc still present after reset" >&2
fi

exit 0
