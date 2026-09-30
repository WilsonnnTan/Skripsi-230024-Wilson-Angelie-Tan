# -----------------------------------------------------------------------------
# Extended docker-tc image
# -----------------------------------------------------------------------------
# The upstream image `lukaszlach/docker-tc` can emulate rate/delay/loss/corrupt/
# duplicate but NOT *jitter*, which the methodology requires. This image is an
# API-compatible superset: same REST shape (POST /<container>, DELETE, GET) on
# port 4080, plus a `jitter=` parameter.
#
# It runs on the host network + host PID namespace so that it can `nsenter`
# into the Caddy container's network namespace and drive `tc netem` directly.
# -----------------------------------------------------------------------------
FROM debian:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
        iproute2 \
        util-linux \
        docker-cli \
        python3 \
        bash \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 4080

# HTTP_PORT / HTTP_BIND / TARGET_CONTAINER / EDGE_SUBNET_PREFIX come from compose.
CMD ["python3", "/app/server.py"]
