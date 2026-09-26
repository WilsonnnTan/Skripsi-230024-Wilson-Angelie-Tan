# --- Stage 1: build a custom k6 binary with HTTP/3 (QUIC) support -----------
# Official k6 has no stable native HTTP/3, so we compile a custom binary with
# the `xk6-http3` extension via xk6. The k6 core version is PINNED to v1.8.1
# for thesis reproducibility.
FROM golang:latest AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends git build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# xk6 is the official k6 extension build tool.
RUN go install go.k6.io/xk6/cmd/xk6@latest

WORKDIR /xk6

# Build k6 v1.8.1 + xk6-http3 (exports the `k6/x/http3` JS module).
# Syntax: xk6 build [k6-version] --with <module> --output <path>
RUN xk6 build v1.8.1 \
      --with github.com/bandorko/xk6-http3@latest \
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
