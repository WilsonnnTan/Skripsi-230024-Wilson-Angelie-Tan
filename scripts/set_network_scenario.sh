#!/usr/bin/env bash
# =============================================================================
# set_network_scenario.sh <S1|S2|S3|S4|S5>
# -----------------------------------------------------------------------------
# Applies the given network scenario to the Caddy container's client-facing
# interface through the docker-tc REST API. No container restart is required;
# rules can be swapped between runs without any downtime.
#
# Validation: the API response echoes the effective `tc qdisc show`, and this
# script fails loudly if `netem` is not present in it.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scenarios.conf
source "${SCRIPT_DIR}/scenarios.conf"

DOCKER_TC_HOST="${DOCKER_TC_HOST:-localhost}"
DOCKER_TC_PORT="${DOCKER_TC_PORT:-4080}"
TARGET_CONTAINER="${TARGET_CONTAINER:-caddy}"
API_URL="http://${DOCKER_TC_HOST}:${DOCKER_TC_PORT}/${TARGET_CONTAINER}"

SCENARIO="${1:-}"
if [[ -z "${SCENARIO}" ]]; then
  echo "usage: $0 <S1|S2|S3|S4|S5>" >&2
  exit 2
fi

RATE_VAR="${SCENARIO}_RATE"
DELAY_VAR="${SCENARIO}_DELAY"
JITTER_VAR="${SCENARIO}_JITTER"
LOSS_VAR="${SCENARIO}_LOSS"
DESC_VAR="${SCENARIO}_DESC"

if [[ -z "${!RATE_VAR:-}" ]]; then
  echo "unknown scenario '${SCENARIO}' (expected one of: ${SCENARIOS})" >&2
  exit 2
fi

BODY="rate=${!RATE_VAR}&delay=${!DELAY_VAR}&jitter=${!JITTER_VAR}&loss=${!LOSS_VAR}"

echo "[net] applying ${SCENARIO} (${!DESC_VAR}) -> ${BODY}"

RESPONSE="$(curl -sS -X POST "${API_URL}" -d "${BODY}")"
echo "[net] docker-tc: ${RESPONSE}"

# --- validation -------------------------------------------------------------
# The POST already verifies `netem` server-side; this is a second check that
# the rule is really present.
if ! curl -sS -X GET "${API_URL}" | grep -q "netem"; then
  echo "[net] ERROR: netem qdisc not found after applying ${SCENARIO}" >&2
  exit 1
fi

echo "[net] ${SCENARIO} applied and verified"
