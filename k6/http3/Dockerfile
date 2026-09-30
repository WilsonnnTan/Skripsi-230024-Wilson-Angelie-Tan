# --- Stage 1: build a custom k6 binary with HTTP/3 --------------------------
# HTTP/3 needs the xk6-http3 extension. Version v0.2.0 of
# github.com/bandorko/xk6-http3 pins go.k6.io/k6 v0.48.0 in its go.mod, so the
# k6 core here is PINNED to v0.48.0 (older than the h1/h2 image on purpose —
# that is why HTTP/3 lives in its own image). The extension registers the
# `k6/x/http3` JS module used by script.js.
#
# The builder Go image is pinned to 1.21: k6 v0.48's go.mod declares `go 1.19`,
# and this keeps a known-good pairing for building k6 v0.48. This ALSO forces
# xk6 itself to be pinned (below): the current xk6 (v1.4.x) requires Go >= 1.26
# and cannot run on this toolchain.
FROM golang:1.21 AS builder

# Safety net: if any module in the build graph requires a newer Go than 1.21,
# let the go command fetch that toolchain instead of hard-failing. In the normal
# case (k6 v0.48 + xk6-http3 v0.2.0 + xk6 v0.11.0, all <= go 1.21) nothing is
# downloaded and the pinned 1.21 toolchain is used.
ENV GOTOOLCHAIN=auto

RUN apt-get update \
    && apt-get install -y --no-install-recommends git build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# xk6 is the official k6 extension build tool. It is PINNED to v0.11.0 (the
# v0.x line, whose go.mod is `go 1.16`) so it compiles under Go 1.21. The
# current `xk6@latest` (v1.4.x) declares `go >= 1.26` and fails to install on
# the 1.21 toolchain required to build the old k6 v0.48 core. v0.11.0 is
# contemporary with k6 v0.48 and builds it with an extension fine.
RUN go install go.k6.io/xk6/cmd/xk6@v0.11.0

WORKDIR /xk6

# --- Patch a nil-TagSet crash in xk6-http3 v0.2.0 --------------------------
# The extension emits ALL of its samples with a nil tag set (stats.go:
# `Tags: nil` on the 5 http3_* metrics, and no Tags field at all on the
# DataSent/DataReceived builtins). That is harmless for k6's JSON summary
# output, but k6 v0.48's bundled experimental-prometheus-rw output
# (xk6-output-prometheus-remote v0.3.1) dereferences the tag set while
# flushing every series, so a nil one panics:
#     panic: runtime error: invalid memory address or nil pointer dereference
#     ...remotewrite.MapTagSet(0x0) -> atlas.(*Node).Len
# Without this the HTTP/3 image starts, ramps VUs, then SIGSEGVs on the first
# remote-write flush. Since the live Grafana feed depends on remote-write, we
# fix the extension rather than disable the output: clone the pinned tag and
# attach the VU's current (non-nil, at least root) tag set — the same value the
# extension already uses elsewhere (client.go: vu.State().Tags.GetCurrentValues()).
RUN git clone --depth 1 --branch v0.2.0 \
      https://github.com/bandorko/xk6-http3.git /xk6/xk6-http3-src \
 && sed -i 's/Tags:   nil,/Tags:   mh.vu.State().Tags.GetCurrentValues().Tags,/g' \
      /xk6/xk6-http3-src/stats.go \
 && sed -i 's|Metric: mh.vu.State().BuiltinMetrics.DataReceived,|Metric: mh.vu.State().BuiltinMetrics.DataReceived,\n\t\t\tTags:   mh.vu.State().Tags.GetCurrentValues().Tags,|' \
      /xk6/xk6-http3-src/stats.go \
 && sed -i 's|Metric: mh.vu.State().BuiltinMetrics.DataSent,|Metric: mh.vu.State().BuiltinMetrics.DataSent,\n\t\t\tTags:   mh.vu.State().Tags.GetCurrentValues().Tags,|' \
      /xk6/xk6-http3-src/stats.go

RUN sed -i '61s|.*|\tgo func() {\n\t\tdefer func() { _ = recover() }()|' /xk6/xk6-http3-src/http3.go \
 && sed -n 58,70p /xk6/xk6-http3-src/http3.go \
 && grep -c "recover()" /xk6/xk6-http3-src/http3.go

# Build k6 v0.48.0 with the PATCHED HTTP/3 extension. The `@v0.2.0=<path>`
# form tells xk6 to use the local (patched) copy in place of the published
# module. Syntax: xk6 build [k6-version] --with <module>@<version>[=<path>].
RUN xk6 build v0.48.0 \
      --with github.com/bandorko/xk6-http3@v0.2.0=/xk6/xk6-http3-src \
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
