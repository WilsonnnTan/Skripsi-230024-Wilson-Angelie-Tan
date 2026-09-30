# --- Stage 1: build a plain k6 binary (HTTP/1.1 + HTTP/2) -------------------
# This image drives HTTP/1.1 and HTTP/2 only, so it uses a stock k6 with no
# extensions. The k6 core version is PINNED to v1.8.1 for thesis
# reproducibility. HTTP/3 is built separately in ../http3 (it requires an older
# k6 core pinned by the xk6-http3 extension).
FROM golang:latest AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends git build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# xk6 is the official k6 extension build tool.
RUN go install go.k6.io/xk6/cmd/xk6@latest

WORKDIR /xk6

# Build a plain k6 v1.8.1 (no extensions).
# Syntax: xk6 build [k6-version] --output <path>
RUN xk6 build v1.8.1 \
      --output /xk6/k6

# --- Stage 2: minimal runtime image ----------------------------------------
FROM debian:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /xk6/k6 /usr/bin/k6

# Default location of the shared test script (overridden by a read-only bind
# mount in docker-compose.yml so the script can be edited without rebuilding).
COPY script.js /scripts/script.js
WORKDIR /scripts

ENTRYPOINT ["k6"]
CMD ["version"]
