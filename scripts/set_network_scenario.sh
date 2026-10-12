#!/usr/bin/env bash
# =============================================================================
# set_network_scenario.sh <S1|S2|S3|S4|S5> [container ...]
# -----------------------------------------------------------------------------
# Applies the given network scenario to each listed container's client-facing
# (edge) interface through the docker-tc REST API. With no containers given it
# falls back to TARGET_CONTAINER (ad-hoc use). The campaign passes the 10
# h2load loader names so every loader experiences the emulated link.
#
# Emulation is SYMMETRIC (direction=both): netem on egress (uplink) + an ifb
# mirror on ingress (downlink), so each loader sees the full per-client link.
#
# Validation: for every container the API response echoes `tc qdisc show` and
# this script fails loudly if `netem` is not present.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scenarios.conf
source "${SCRIPT_DIR}/scenarios.conf"

DOCKER_TC_HOST="${DOCKER_TC_HOST:-localhost}"
DOCKER_TC_PORT="${DOCKER_TC_PORT:-4080}"
DIRECTION="${DIRECTION:-both}"

SCENARIO="${1:-}"
if [[ -z "${SCENARIO}" ]]; then
  echo "usage: $0 <S1|S2|S3|S4|S5> [container ...]" >&2
  exit 2
fi
shift || true

CONTAINERS=("$@")
if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
  CONTAINERS=("${TARGET_CONTAINER:-caddy}")
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

BODY="rate=${!RATE_VAR}&delay=${!DELAY_VAR}&jitter=${!JITTER_VAR}&loss=${!LOSS_VAR}&direction=${DIRECTION}"
echo "[net] applying ${SCENARIO} (${!DESC_VAR}) dir=${DIRECTION} to ${#CONTAINERS[@]} container(s) -> ${BODY}"

RC=0
for c in "${CONTAINERS[@]}"; do
  API_URL="http://${DOCKER_TC_HOST}:${DOCKER_TC_PORT}/${c}"
  RESPONSE="$(curl -sS -X POST "${API_URL}" -d "${BODY}" || true)"
  echo "[net] ${c}: ${RESPONSE}"
  if ! curl -sS -X GET "${API_URL}" | grep -q "netem"; then
    echo "[net] ERROR: netem qdisc not found on ${c} after applying ${SCENARIO}" >&2
    RC=1
  fi
done

if (( RC != 0 )); then
  echo "[net] one or more containers failed verification" >&2
  exit 1
fi
echo "[net] ${SCENARIO} applied and verified on all containers"
