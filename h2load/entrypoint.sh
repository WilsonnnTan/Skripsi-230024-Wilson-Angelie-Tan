#!/usr/bin/env bash
# =============================================================================
# h2load container entrypoint
# -----------------------------------------------------------------------------
# Reads the run parameters from the environment (set per-run by
# scripts/run_experiments.sh) and launches a single h2load process that drives
# ONE protocol against Caddy, writing a per-request log the analysis pipeline
# turns into exact p50/p90/p95/p99.
#
# Phase model (warmup / sustained / cooldown) is NOT delegated to h2load's
# --warm-up-time; instead h2load runs for the FULL DURATION and every request
# is timestamped in --log-file. The orchestrator and exporter slice phases by
# timestamp, identical to how the old k6 script tagged phases. This keeps the
# three-phase analysis and the per-run CSV consistent with the previous design.
#
# PRESTART gives scripts/run_experiments.sh a window to attach the netem rules
# to THIS container's edge interface (docker-tc) before the measured load
# begins — the 10 s warmup then fully absorbs any remaining setup jitter.
#
# Env vars (all set by the orchestrator):
#   TARGET_URL   full URL incl. port, e.g. https://caddy:8444/api/data   (required)
#   PROTOCOL     http1.1 | http2 | http3                                  (required)
#   LOG_FILE     per-request log path, e.g. /results/raw/<run>/h2load_3.log (required)
#   DURATION     total seconds h2load runs (warmup+sustained+cooldown)    (default 80)
#   CLIENTS      -c, concurrent connections per container                 (default 1)
#   STREAMS      -m, max concurrent streams per connection                (default 6)
#   THREADS      -t, native threads                                       (default 1)
#   PRESTART     seconds to sleep before load, for netem attach           (default 3)
# =============================================================================
set -euo pipefail

: "${TARGET_URL:?TARGET_URL is required}"
: "${PROTOCOL:?PROTOCOL is required}"
: "${LOG_FILE:?LOG_FILE is required}"
DURATION="${DURATION:-80}"
CLIENTS="${CLIENTS:-1}"
STREAMS="${STREAMS:-6}"
THREADS="${THREADS:-1}"
PRESTART="${PRESTART:-3}"

# Select the protocol. Caddy isolates each protocol on its own port, so forcing
# ALPN here is belt-and-suspenders — a mismatch would simply fail to connect.
case "${PROTOCOL}" in
  http1.1) PROTO_FLAGS=(--alpn-list=http/1.1) ;;
  http2)   PROTO_FLAGS=(--alpn-list=h2) ;;
  http3)   PROTO_FLAGS=(--h3) ;;
  *) echo "[h2load] unknown PROTOCOL '${PROTOCOL}'" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "${LOG_FILE}")"

echo "[h2load] protocol=${PROTOCOL} url=${TARGET_URL} c=${CLIENTS} m=${STREAMS} t=${THREADS} duration=${DURATION}s prestart=${PRESTART}s log=${LOG_FILE}"

# Give the orchestrator time to attach netem to this container's edge iface.
if [[ "${PRESTART}" -gt 0 ]]; then
  sleep "${PRESTART}"
fi

# Closed-loop, duration-based load: h2load keeps CLIENTS*STREAMS requests
# in flight for the whole DURATION (the h2load analogue of k6's batched VUs).
# h2load does not verify the server certificate, so Caddy's internal CA is fine.
exec h2load \
  -t "${THREADS}" \
  -c "${CLIENTS}" \
  -m "${STREAMS}" \
  --duration="${DURATION}" \
  --log-file="${LOG_FILE}" \
  "${PROTO_FLAGS[@]}" \
  "${TARGET_URL}"
