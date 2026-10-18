# HTTP/1.1 vs HTTP/2 vs HTTP/3 Research Testbed

> **Automated, Dockerized testbed for measuring throughput, latency, and error rate across HTTP/1.1, HTTP/2, and HTTP/3 under five controlled network conditions.**

## What Is This Project?

This project is a fully automated research testbed designed for a thesis (Skripsi) comparing the performance of three HTTP protocol versions — **HTTP/1.1**, **HTTP/2**, and **HTTP/3** — over a REST API under realistic network conditions.

The testbed runs **150 experiments** in total:

$$
3 \text{ protocols} \times 5 \text{ network scenarios} \times 10 \text{ repetitions} = 150 \text{ runs}
$$

Each run launches **10 parallel load-generator containers** that drive traffic through a Caddy reverse proxy to an Express.js backend, while network conditions (bandwidth, latency, jitter, packet loss) are applied symmetrically to each loader via Linux `tc netem`.

## Key Features

| Feature | Description |
| --- | --- |
| **Multi-protocol** | HTTP/1.1, HTTP/2, HTTP/3 (QUIC) from a single `h2load` binary |
| **Network emulation** | 5 scenarios from baseline (4 ms RTT) to long-distance (230 ms RTT, 1% loss) |
| **Symmetric shaping** | Egress + ingress (via `ifb` mirror) on every loader — full per-client link |
| **Exact percentiles** | p50/p90/p95/p99 computed from merged per-request logs, not averaged |
| **Live monitoring** | Prometheus + Grafana dashboards with real-time client & server metrics |
| **Fully automated** | One command runs all 150 experiments; another exports graph-ready CSVs |
| **Reproducible** | Pinned image versions, CPU pinning, fixed payload, deterministic subnets |

## Quick Navigation

{% content-ref url="getting-started/prerequisites.md" %}
[prerequisites.md](getting-started/prerequisites.md)
{% endcontent-ref %}

{% content-ref url="architecture/README.md" %}
[System Architecture](architecture/README.md)
{% endcontent-ref %}

{% content-ref url="test-methodology/README.md" %}
[Test Methodology](test-methodology/README.md)
{% endcontent-ref %}

{% content-ref url="scripts/README.md" %}
[Automation Scripts](scripts/README.md)
{% endcontent-ref %}

## Project Structure

```
.
├── backend/                # Express.js API (system under test)
│   ├── Dockerfile
│   ├── package.json
│   └── src/server.js
├── caddy/                  # Caddy reverse proxy configuration
│   └── Caddyfile
├── docker-tc/              # Extended network emulation controller
│   ├── Dockerfile
│   └── server.py
├── h2load/                 # Load generator (HTTP/1.1 + HTTP/2 + HTTP/3)
│   ├── Dockerfile
│   └── entrypoint.sh
├── monitoring/
│   ├── exporter/           # h2load live metrics exporter
│   ├── grafana/            # Dashboards & provisioning
│   └── prometheus/         # Scrape configuration
├── scripts/                # Experiment orchestration & export
│   ├── run_experiments.sh
│   ├── export_results.sh
│   ├── scenarios.conf
│   └── ...
├── results/                # Output CSVs and per-request logs
├── docs/                   # This documentation (GitBook)
├── docker-compose.yml      # Full stack definition
└── .env.example            # Tunable parameters
```
