#!/usr/bin/env bash
# =============================================================================
# reset_network.sh [container ...]
# -----------------------------------------------------------------------------
# Clears ALL traffic-control rules (egress netem + ingress ifb mirror) from
# each listed container's edge interface, returning the link to line rate.
# With no containers given it falls back to TARGET_CONTAINER. The campaign
# passes the 10 h2load loader names between runs to release TIME_WAIT sockets
# and avoid state bleed.
# =============================================================================
set -uo pipefail

DOCKER_TC_HOST="${DOCKER_TC_HOST:-localhost}"
DOCKER_TC_PORT="${DOCKER_TC_PORT:-4080}"

CONTAINERS=("$@")
if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
  CONTAINERS=("${TARGET_CONTAINER:-caddy}")
fi

RC=0
for c in "${CONTAINERS[@]}"; do
  API_URL="http://${DOCKER_TC_HOST}:${DOCKER_TC_PORT}/${c}"
  RESPONSE="$(curl -sS -X DELETE "${API_URL}" || true)"
  echo "[net] reset ${c} -> ${RESPONSE}"
  if curl -sS -X GET "${API_URL}" 2>/dev/null | grep -q "netem"; then
    echo "[net] WARNING: netem qdisc still present on ${c} after reset" >&2
    RC=1
  fi
done

exit "${RC}"
