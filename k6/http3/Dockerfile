# --- Stage 1: build a custom k6 binary with HTTP/3 --------------------------
# HTTP/3 needs the xk6-http3 extension (k6 has no native HTTP/3). Version
# v0.2.0 of github.com/bandorko/xk6-http3 pins go.k6.io/k6 v0.48.0 in its
# go.mod, so the k6 core here is PINNED to v0.48.0 (older than the h1/h2 image
# on purpose — that is why HTTP/3 lives in its own image). The extension
# registers the `k6/x/http3` JS module used by script.js.
#
# The builder Go image is pinned to 1.21 (known-good pairing for k6 v0.48).
# This ALSO forces xk6 itself to be pinned (below): the current xk6 (v1.4.x)
# requires Go >= 1.26 and cannot run on this toolchain.
FROM golang:1.21 AS builder

# Safety net: if any module in the build graph requires a newer Go than 1.21,
# let the go command fetch that toolchain instead of hard-failing.
ENV GOTOOLCHAIN=auto

RUN apt-get update \
    && apt-get install -y --no-install-recommends git build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# xk6 pinned to v0.11.0 (go 1.16 line) so it compiles under Go 1.21.
RUN go install go.k6.io/xk6/cmd/xk6@v0.11.0

WORKDIR /xk6

# =============================================================================
# Patches to xk6-http3 v0.2.0. Every patch is followed by an ASSERTION, so if a
# `sed` pattern silently fails to match, the image build FAILS instead of
# producing a binary that crashes mid-campaign.
#
# PATCH 1 (stats.go) — nil-TagSet crash with experimental-prometheus-rw.
#   The extension emits its samples with a nil tag set; k6 v0.48's remote-write
#   output dereferences it on flush (MapTagSet -> atlas.(*Node).Len). We attach
#   the VU's current tag set instead. 5 `Tags: nil` + DataReceived + DataSent
#   = 7 occurrences of GetCurrentValues afterwards.
#
# PATCH 2 (stats.go) — nil *streamMetrics crash in handleFramesSent
#   (panic at stats.go:179, addr=0x68 = the `sentBytes` field).
#   Root cause: sendMetrics() ends a finished stream with
#       mh.streams[streamID] = nil
#   which leaves a key present with a nil value. getStreamMetrics() returns
#   `m, ok` from the map when ok==true, so it hands back that nil pointer even
#   with createIfNotFound=true. If quic-go later re-sends a frame for that
#   already-finished stream (PTO probe / retransmission — i.e. whenever there is
#   packet loss or delay, exactly scenarios S2-S5 with netem), handleFramesSent
#   does `streamMetrics.sentBytes += ...` on nil and the whole k6 process dies
#   with SIGSEGV. The fix is a nil guard: skip frames of finished streams.
#   (Latency/error metrics are unaffected: they come from script.js.)
#
# PATCH 3 (http3.go) — shutdown panic at http3.go:66.
#   The per-VU TestEnd goroutine calls ev.Done() on a nil event (addr=0x18 is a
#   nil-interface/pointer method call). Guard it.
# =============================================================================
RUN git clone --depth 1 --branch v0.2.0 \
      https://github.com/bandorko/xk6-http3.git /xk6/xk6-http3-src

# ---- PATCH 1: non-nil tag sets ---------------------------------------------
RUN cd /xk6/xk6-http3-src \
 && sed -i -E 's/Tags:[[:space:]]+nil,/Tags:   mh.vu.State().Tags.GetCurrentValues().Tags,/g' stats.go \
 && sed -i 's|Metric: mh.vu.State().BuiltinMetrics.DataReceived,|Metric: mh.vu.State().BuiltinMetrics.DataReceived,\n\t\t\tTags:   mh.vu.State().Tags.GetCurrentValues().Tags,|' stats.go \
 && sed -i 's|Metric: mh.vu.State().BuiltinMetrics.DataSent,|Metric: mh.vu.State().BuiltinMetrics.DataSent,\n\t\t\tTags:   mh.vu.State().Tags.GetCurrentValues().Tags,|' stats.go \
 && echo "patch1: GetCurrentValues count = $(grep -c 'GetCurrentValues' stats.go) (expect 7)" \
 && [ "$(grep -c 'GetCurrentValues' stats.go)" -eq 7 ] \
 && ! grep -Eq 'Tags:[[:space:]]+nil' stats.go

# ---- PATCH 2: skip frames of already-finished streams ----------------------
RUN cd /xk6/xk6-http3-src \
 && sed -i 's|streamMetrics := mh.getStreamMetrics(streamID, true)|streamMetrics := mh.getStreamMetrics(streamID, true)\n\t\t\t\tif streamMetrics == nil {\n\t\t\t\t\tcontinue\n\t\t\t\t}|' stats.go \
 && echo "patch2: 'streamMetrics == nil' count = $(grep -c 'streamMetrics == nil' stats.go) (expect 3)" \
 && [ "$(grep -c 'streamMetrics == nil' stats.go)" -eq 3 ] \
 && grep -n -B2 -A4 'getStreamMetrics(streamID, true)' stats.go

# ---- PATCH 3: guard the TestEnd goroutine ----------------------------------
RUN cd /xk6/xk6-http3-src \
 && sed -i 's|^\(\s*\)ev\.Done()$|\1if ev != nil {\n\1\tev.Done()\n\1}|' http3.go \
 && grep -n -B3 -A4 'ev != nil' http3.go \
 && grep -q 'if ev != nil' http3.go

# Build k6 v0.48.0 with the PATCHED HTTP/3 extension. `@v0.2.0=<path>` tells
# xk6 to use the local (patched) copy in place of the published module.
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