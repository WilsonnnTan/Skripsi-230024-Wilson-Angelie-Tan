# =============================================================================
# h2load load generator with HTTP/1.1 + HTTP/2 + HTTP/3 (single image)
# -----------------------------------------------------------------------------
# h2load (from nghttp2) drives ALL THREE protocols from one binary:
#   HTTP/1.1 -> --alpn-list=http/1.1   (TCP, Caddy :8443)
#   HTTP/2   -> --alpn-list=h2         (TCP, Caddy :8444)
#   HTTP/3   -> --h3                   (QUIC/UDP, Caddy :8445)
#
# HTTP/3 needs nghttp2 built with --enable-http3, which needs a QUIC-capable TLS
# stack. OpenSSL >= 3.5 carries the QUIC TLS API upstream, so the frozen quictls
# fork is no longer needed: ngtcp2 uses OpenSSL's native QUIC backend
# (libngtcp2_crypto_ossl). Build chain:  nghttp3 -> ngtcp2 -> nghttp2 (h2load).
#
# WHY debian:trixie-slim (NOT bookworm): nghttp2 >= 1.64 compiles its C++ apps
# (h2load included) as C++23 -- its README states "g++ >= 14 and clang++ >= 19
# are known to work". Debian bookworm ships g++ 12, which cannot compile the
# 1.70 sources and fails the build mid-`make`. Trixie ships g++ 14 (C++23) AND
# OpenSSL 3.5.x as a system package, so we also drop the slow build-OpenSSL-from
# -source step the bookworm image needed and link the distro's libssl instead.
#
# NOTE on pinning: nghttp3/ngtcp2 are pinned to release tarballs (./configure
# pre-generated) for reproducibility; nghttp2 is pinned to a git tag and
# regenerated with the autotools per its "Building from Git" instructions.
# ngtcp2 >= 1.23.0 and nghttp3 >= 1.17.0 are the minimums nghttp2 1.70 requires
# for HTTP/3; the pins below satisfy that.
# =============================================================================

ARG NGHTTP2_VERSION=1.70.0
ARG NGTCP2_VERSION=1.25.0
ARG NGHTTP3_VERSION=1.18.0

# --- Stage 1: build everything from source ----------------------------------
FROM debian:trixie-slim AS build

ARG NGHTTP2_VERSION
ARG NGTCP2_VERSION
ARG NGHTTP3_VERSION

ENV DEBIAN_FRONTEND=noninteractive

# g++ 14 (C++23) comes from build-essential on trixie. libssl-dev is OpenSSL
# 3.5.x -> the native QUIC TLS API ngtcp2's crypto_ossl backend needs. nghttp3
# and ngtcp2 ship release tarballs (pre-generated ./configure); nghttp2/h2load
# is built from git, so it also needs the autotools (autoconf >= 2.68, automake,
# libtool) to regenerate ./configure.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config ca-certificates curl xz-utils git \
      autoconf automake libtool \
      libssl-dev libev-dev zlib1g-dev libc-ares-dev libjansson-dev \
    && rm -rf /var/lib/apt/lists/*

# The nghttp3/ngtcp2/nghttp2 stack installs into /usr/local (already on the
# default linker and pkg-config search paths on Debian); OpenSSL is the system
# one, found automatically. We still export PKG_CONFIG_PATH so each ./configure
# resolves the just-installed /usr/local/lib/pkgconfig .pc files.
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

# ---- nghttp3 (HTTP/3 framing) ----------------------------------------------
WORKDIR /src/nghttp3
RUN curl -fsSL -o nghttp3.tar.xz \
      "https://github.com/ngtcp2/nghttp3/releases/download/v${NGHTTP3_VERSION}/nghttp3-${NGHTTP3_VERSION}.tar.xz" \
 && tar xf nghttp3.tar.xz --strip-components=1 \
 && ./configure --prefix=/usr/local --enable-lib-only \
 && make -j"$(nproc)" \
 && make install

# ---- ngtcp2 (QUIC transport), against the system OpenSSL 3.5 ----------------
# --with-openssl detects OpenSSL's QUIC API (SSL_set_quic_tls_cbs) and builds
# libngtcp2_crypto_ossl, the backend nghttp2 1.70 links for HTTP/3.
WORKDIR /src/ngtcp2
RUN curl -fsSL -o ngtcp2.tar.xz \
      "https://github.com/ngtcp2/ngtcp2/releases/download/v${NGTCP2_VERSION}/ngtcp2-${NGTCP2_VERSION}.tar.xz" \
 && tar xf ngtcp2.tar.xz --strip-components=1 \
 && ./configure --prefix=/usr/local --enable-lib-only --with-openssl \
 && make -j"$(nproc)" \
 && make install

# ---- nghttp2 + h2load, with HTTP/3 enabled (built from git) ----------------
# Follows nghttp2's "Building from Git": clone, pull submodules, regenerate
# ./configure with the autotools, then configure with --enable-app (h2load) and
# --enable-http3 (QUIC via system OpenSSL + ngtcp2/nghttp3). Pinned to a release
# tag so the build stays reproducible. rpath on /usr/local/lib keeps the
# nghttp3/ngtcp2 shared libs resolvable without ldconfig tweaks.
RUN git clone --depth 1 -b "v${NGHTTP2_VERSION}" \
      https://github.com/nghttp2/nghttp2 /src/nghttp2 \
 && cd /src/nghttp2 \
 && git submodule update --init \
 && autoreconf -i \
 && automake \
 && autoconf \
 && ./configure --prefix=/usr/local \
      --enable-app --enable-http3 \
      --disable-examples --disable-python-bindings --disable-hpack-tools \
      LDFLAGS="-Wl,-rpath,/usr/local/lib" \
 && make -j"$(nproc)" \
 && make install-strip

# Fail the build NOW (not mid-campaign) if h2load lacks HTTP/3 support -- this
# is the gate that catches a silently-disabled --enable-http3.
RUN h2load --version \
 && h2load --help | grep -q -- '--h3' \
 && echo "h2load HTTP/3 support: OK"

# --- Stage 2: slim runtime image --------------------------------------------
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Runtime shared libs (trixie post-t64 names): OpenSSL 3.5 (libssl3t64),
# libev (libev4t64), c-ares (libcares2), zlib, jansson, libstdc++.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libssl3t64 libev4t64 libcares2 zlib1g libjansson4 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# The nghttp3/ngtcp2/nghttp2 shared libs and the h2load binary. OpenSSL is the
# distro's, already present from the apt step above.
COPY --from=build /usr/local/lib /usr/local/lib
COPY --from=build /usr/local/bin/h2load /usr/local/bin/h2load

# /usr/local/lib is on Debian's default loader path, but refresh the cache so
# the nghttp3/ngtcp2 libs are found at launch.
RUN ldconfig

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /results

# The entrypoint reads env vars (PROTOCOL, TARGET_URL, ...) and runs h2load.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
