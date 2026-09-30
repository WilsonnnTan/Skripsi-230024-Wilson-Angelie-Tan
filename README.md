# HTTP/1.1 vs HTTP/2 vs HTTP/3 Research Testbed

Automated testbed for the thesis:

> **Trade-off Analysis of Performance (Throughput, Latency, Error Rate) and
> Resource Usage between HTTP/1.1, HTTP/2, and HTTP/3 Protocols on a REST API
> Architecture Based on Network Condition Variations.**

It measures **client-side** metrics (throughput, latency p50/p90/p95/p99, error
rate) and **server-side** resource usage (CPU %, memory) for
**3 protocols × 5 network scenarios × 10 repetitions = 150 fully automated runs**.

---

## 1. Architecture

```
                                  MONITORING PLANE
        ┌──────────────┐   scrape 1s   ┌──────────────┐   read   ┌───────────┐
        │   cAdvisor   │ ────────────► │  Prometheus  │ ───────► │  Grafana  │
        │  (cgroups)   │               │  :9090       │          │  :3000    │
        └──────┬───────┘               └──────▲───────┘          └───────────┘
               │ reads cgroups                │ remote-write (k6 metrics)
               │                              │
               │                              │ monitoring_net
┌──────────────┴───────────────┐             │
│                              │             │
│  DATA PLANE (single host)    │             │
│                              │             │
│   ┌─────────┐   edge_net   ┌─┴──────┐  backend_net  ┌──────────┐
│   │   k6    │ ───────────► │ Caddy  │ ────────────► │ backend  │
│   │ (load)  │   TLS/QUIC   │  :8443 │  plain HTTP    │  :3000   │
│   └─────────┘              │  :8444 │               └──────────┘
│        ▲                   │  :8445 │                    ▲
│        │                   └─┬──────┘                    │
│        │                     │                           │
│        │            netem rules (delay/jitter/loss/rate) │
│        │                     ▲                           │
│        │              ┌──────┴───────┐                   │
│        │              │  docker-tc   │  nsenter into     │
│        │              │  REST :4080  │  Caddy's netns    │
│        │              └──────────────┘                   │
│        │                                                 │
│        └── k6 runs in its own container (2 vCPU / 1 GB)  │
│            so it never competes with the server.          │
└───────────────────────────────────────────────────────────┘

Protocol isolation (ALPN ambiguity removed by using 3 listeners):
    https://caddy:8443/api/data   -> HTTP/1.1 only
    https://caddy:8444/api/data   -> HTTP/2 only
    https://caddy:8445/api/data   -> HTTP/3 only (QUIC/UDP)

Network emulation is applied ONLY to Caddy's client-facing (172.28.x.x)
interface, so the server link and the monitoring plane stay unshaped.
```

### Components

| Service     | Image / build              | Role                                                        | CPU  | RAM   |
|-------------|----------------------------|-------------------------------------------------------------|------|-------|
| `backend`   | `./backend` (Node 24)      | Single static `GET /api/data`, fixed 8192 B JSON, no DB     | 1    | 1 GB  |
| `caddy`     | `caddy:2.11.4`             | TLS (`tls internal`) + 3 protocol listeners + reverse proxy | 1    | 1 GB  |
| `docker-tc` | `./docker-tc` (extended)   | Applies `netem` to Caddy's edge interface via REST :4080    | 1    | 0.5 GB|
| `k6`        | `./k6` (xk6 + xk6-http3)   | Load generator (HTTP/1.1, HTTP/2, HTTP/3), pinned to v1.8.1 | 2    | 1 GB  |
| `cadvisor`  | `gcr.io/cadvisor/cadvisor` | Per-container CPU / memory from cgroups                     | 1    | 0.5 GB|
| `prometheus`| `prom/prometheus:v3.13.3`  | Scrapes cAdvisor (1 s) + receives k6 remote write           | –    | –     |
| `grafana`   | `grafana/grafana:13.0.8`   | Provisioned datasource + dashboard                          | –    | –     |

> **Note on HTTP/2 isolation.** Go's standard library cannot serve HTTP/2
> without also allowing HTTP/1.1, so the `:8444` listener technically accepts
> h1.1 at the socket level too. k6 negotiates `h2` through ALPN, and because
> `:8443` has HTTP/2 fully disabled, any run that *does* end up on HTTP/1.1 is
> unambiguous. The `:8443` (h1 only) and `:8445` (h3 only) listeners are
> strictly single-protocol.

---

## 2. Prerequisites

* **Linux host** (or Windows/macOS with a **WSL2** distro). `docker-tc` uses
  `nsenter` + Linux `tc netem`, which do **not** work on native Windows/macOS
  containers. On Windows, clone the project *inside WSL2* and run everything
  from there.
* **Docker Engine 20.10+** and **Docker Compose v2.20+** (`docker compose version`).
* **Internet access once** to pull/build images and compile the custom k6
  binary. After that the stack runs fully offline.
* Host firewall: **UDP 8445 must be reachable** for HTTP/3.
* `curl`, `jq`, `awk`, `bash` for the scripts.

Resource recommendation: **4+ vCPU, 8 GB RAM** free for the stack.

### CPU pinning (Batasan #2)

The methodology requires the system-under-test to use **P-cores only** (never
E-cores). Each service therefore sets a `cpuset` driven by `CPUSET_*` in `.env`
(defaults target an i7-12650H: logical CPUs `0-11` = P-cores, `12-15` =
E-cores). **Verify your own mapping** with `lscpu -e` (inside WSL2 on Windows)
before the campaign and adjust the ranges.

> **WSL2 caveat.** A container `cpuset` pins to the WSL2 VM's CPUs, but Windows
> can still migrate those vCPU threads across P/E cores, so `cpuset` alone does
> **not** guarantee host P-core placement. For a strict batasan #2, run the
> stack on native Linux, or pin the WSL2 VM (`vmmemWSL`) to the host P-cores via
> Windows CPU affinity. Otherwise treat the pinning as best-effort and state the
> limitation in the thesis.

---

## 3. Quick start

```bash
# 0) from the project root
cp .env.example .env
chmod +x scripts/*.sh

# 1) build & start everything (first build compiles the custom k6 via xk6)
docker compose up -d --build

# 2) wait until every service is healthy
./scripts/wait_for_services.sh

# 3) run all 150 experiments (NO manual intervention, ~4.5-5.5 h)
./scripts/run_experiments.sh

# 4) export the final CSV files
./scripts/export_results.sh
```

Results:

* `results/summary.csv` – 150 rows (one per run), the columns requested:
  `protocol, scenario, repetition, throughput_rps, latency_p50, latency_p90,
  latency_p95, latency_p99, error_rate_pct, cpu_caddy_pct, mem_caddy_mb,
  cpu_backend_pct, mem_backend_mb`
* `results/summary_aggregated.csv` – mean and standard deviation across the
  10 repetitions per protocol × scenario.
* `results/raw/{protocol}_{scenario}_{rep}.json` – raw k6 summary per run.
* `results/logs/{protocol}_{scenario}_{rep}.log` – k6 stdout/stderr per run.
* `results/run_index.csv` – run ledger (timestamps, status) used by the export.

Grafana: <http://localhost:3000> — login `admin` / `admin`
(dashboard **“HTTP/1.1 vs HTTP/2 vs HTTP/3 Testbed”**, filter by
`protocol`, `scenario`, `repetition`).

Prometheus: <http://localhost:9090> · cAdvisor: <http://localhost:8080>

---

## 4. The custom k6 image (HTTP/3)

Official k6 has no stable HTTP/3 support, so `k6/Dockerfile` builds a custom
binary with [`xk6`](https://github.com/grafana/xk6) and the
[`xk6-http3`](https://github.com/bandorko/xk6-http3) extension:

```
FROM golang:latest AS builder
RUN go install go.k6.io/xk6/cmd/xk6@latest
RUN xk6 build v1.8.1 \
      --with github.com/bandorko/xk6-http3@latest \
      --output /xk6/k6
```

The k6 core version is **pinned to v1.8.1** for thesis reproducibility, while
the custom HTTP/3 extension is still built in. It is compiled **once** during
`docker compose build`; afterwards no network is needed.

> If the extension breaks in the future, change `xk6-http3` to another
> HTTP/3 extension and update the `import ... from 'k6/x/...'` line at the top
> of `k6/script.js`. The rest of the pipeline (metrics, tags, export) is
> extension-agnostic.

---

## 5. Network scenarios (applied to Caddy's edge interface)

| Scenario | Bandwidth | Delay | Packet loss | Jitter | Notes |
|---|---|---|---|---|---|
| **S1** Baseline (Ideal) | 100 Mbps | 2 ms | 0 % | 0 ms | midpoint of the 0–5 ms range |
| **S2** Stable 4G | 20 Mbps | 40 ms | 0 % | 5 ms | |
| **S3** Congested 4G | 10 Mbps | 100 ms | 2.5 % | 15 ms | midpoint of the 2–3 % range |
| **S4** Slow 4G / Fast 3G | 1.6 Mbps | 150 ms | 0.5 % | 10 ms | |
| **S5** Long Distance | 10 Mbps | 275 ms | 1 % | 20 ms | midpoint of the 250–300 ms range |

`tc netem` rules are applied with a single command:
`netem delay <D> <J> loss <L>% rate <R>`. All values live in
`scripts/scenarios.conf` and can be edited in one place.

```bash
./scripts/set_network_scenario.sh S3   # apply
./scripts/reset_network.sh             # clear (line-rate again)
```

### Why the extended docker-tc?

The upstream `lukaszlach/docker-tc` API cannot emulate **jitter**, which the
methodology requires. `docker-tc/server.py` is a small, API-compatible
superset: same `POST/DELETE/GET /<container>` convention on port 4080, plus a
`jitter=` parameter. It runs with host networking + host PID namespace and
uses `nsenter` to enter **Caddy's** netns only, auto-detecting the edge
interface by the `172.28.` subnet — so `backend` and `k6` are never shaped.

---

## 6. k6 methodology details

* **Load profile** (`stages`): 0→20 VUs over **10 s**, hold **20 VUs for 60 s**,
  20→0 VUs over **10 s**.
* **Phase tagging**: every request is tagged `phase = warmup|sustained|cooldown`
  based on time since scenario start, so steady-state data can be isolated.
* **Metric tags on every series**: `protocol`, `scenario` (reserved k6 tag,
  equals the network scenario name), `net_scenario`, `repetition`, `phase`,
  and `run_id`.
* **One set of custom metrics for all three protocols** so h1/h2/h3 are
  directly comparable and carry identical tags:
  * `req_duration_ms` (Trend, from the response's native `timings.duration`),
    `reqs` (Counter), `req_errors` (Rate), `resp_bytes` (Counter) — every
    request, tagged by `phase`;
  * `proto_mismatch` (Counter) — increments if `resp.proto` does not match the
    protocol the run intended (an ALPN sanity check; must be 0 for h1/h2).
  The HTTP/3 response object embeds k6's standard `httpext.Response`, so
  `resp.status`, `resp.body`, `resp.proto` and `resp.timings.duration` are the
  same fields as the built-in client — hence one code path, no protocol-specific
  status/body guessing.
* **Exact sustained percentiles without duplicate metrics**: trivially-true
  `thresholds` on `…{phase:sustained}` make k6 emit exact whole-window
  sustained sub-metrics (e.g. `req_duration_ms{phase:sustained}` with
  `p(50/90/95/99)`, `reqs{phase:sustained}.count`, `req_errors{phase:sustained}.rate`)
  into the summary. `summaryTrendStats` includes `p(50), p(90), p(95), p(99)`.
* **Prometheus remote write** (`-o experimental-prometheus-rw`,
  `K6_PROMETHEUS_RW_SERVER_URL`, push interval 1 s,
  `K6_PROMETHEUS_RW_TREND_STATS=avg,min,max,med,p(50),p(90),p(95),p(99),count`)
  feeds the **live Grafana dashboard only**.
* **Export split by source** (`export_results.sh`): **client** metrics
  (throughput, p50/p90/p95/p99, error rate) are read straight from each run's
  `handleSummary()` JSON — exact sustained-phase values, independent of
  remote-write. **Server** metrics (Caddy/backend CPU %, memory MB) come from
  cAdvisor via Prometheus, averaged over the exact sustained window recorded in
  `results/run_index.csv`.

> Because the h3 response is the same `httpext.Response` type as the built-in
> client, HTTP/3 requests are scored (status + non-empty body) and timed
> (`timings.duration`) identically to h1/h2 — no `status===0 ⇒ success`
> shortcut, so the error rate stays valid across all three protocols.

### Backend payload

`GET /api/data` returns a fixed JSON document of **exactly 8192 bytes** (a
`meta` block plus 8 telemetry items). The size is computed and logged at
startup (`payloadBytes=8192`) and is constant for every request. 8 KiB is large
enough to span several TCP segments / QUIC datagrams (so multiplexing and
head-of-line blocking are observable) yet small enough not to saturate the slow
network scenarios (S4/S5).

---

## 7. Runtime estimate

| Phase | Estimate |
|---|---|
| Image pull + build (once, online) | ~5–15 min |
| Each run: 80 s test + ~15–20 s switch/cooldown/startup | ~95–100 s |
| 150 runs | **~4 h – 4 h 15 m** |
| **Total (excluding builds)** | **≈ 4.5 – 5.5 hours** |

Run it overnight. The campaign is resumable: re-running
`./scripts/run_experiments.sh` skips combinations whose summary file already
exists (`RESUME=1`). Use `RESUME=0` for a clean full re-run.

---

## 8. Troubleshooting

**Port conflicts** – Caddy uses 8443/8444/8445 (+2019), Grafana 3000,
Prometheus 9090, cAdvisor 8080, docker-tc 4080. Change the host-side mapping
in `docker-compose.yml` if any are taken.

**HTTP/3 fails / times out** – make sure UDP **8445** is open on the host
firewall (`sudo ufw allow 8445/udp`) and that you are not behind a NAT that
drops QUIC. Quick check from the host:
`curl -sk --http3 https://localhost:8445/health` (if your curl has HTTP/3).

**docker-tc rule not applied** –
`docker-tc` must run with `network_mode: host`, `pid: host` and `privileged:
true` (already set). Verify the API and the qdisc:
```bash
curl -s localhost:4080/health
curl -s localhost:4080/caddy        # shows `tc qdisc show`
docker logs docker-tc
```
If `nsenter` reports “failed to inspect interfaces”, ensure the host PID
namespace is shared (`pid: host`) and that `tc`/`netem` kernel modules are
available (`modprobe sch_netem`).

**cAdvisor shows no metrics / missing containers** – on Docker with the
containerd snapshotter, cAdvisor may need `--containerd` or a newer image.
Check that `container_cpu_usage_seconds_total{name="caddy"}` exists in
Prometheus. If `name` differs, update the queries in `export_results.sh` and
the Grafana dashboard.

**k6 remote-write metrics missing** – confirm Prometheus was started with
`--web.enable-remote-write-receiver` (it is, via compose) and that k6 could
resolve `prometheus`. The export script automatically falls back to the k6
summary JSON when a Prometheus series is absent.

**TLS warnings** – expected: Caddy uses its internal CA and k6 is configured
with `insecureSkipTLSVerify: true` because this is a closed testbed.

**Container names** – the compose file sets fixed `container_name`s
(`caddy`, `backend`, ...) and an explicit project `name: http-testbed`, so
`docker-tc`, cAdvisor and the scripts always find the right targets.

**Full reset** – the stack is idempotent:
```bash
docker compose down -v && docker compose up -d --build
rm -f results/raw/*.json results/logs/*.log results/run_index.csv results/summary*.csv
./scripts/wait_for_services.sh && ./scripts/run_experiments.sh
```

---

## 9. Folder structure

```
.
├── docker-compose.yml
├── .env.example
├── .gitignore
├── README.md
├── backend/
│   ├── Dockerfile
│   ├── package.json
│   └── src/server.js
├── caddy/
│   └── Caddyfile
├── k6/
│   ├── Dockerfile          # xk6 + xk6-http3 custom build
│   └── script.js
├── docker-tc/
│   ├── Dockerfile          # extended docker-tc (adds jitter)
│   └── server.py
├── monitoring/
│   ├── prometheus/prometheus.yml
│   └── grafana/
│       ├── provisioning/
│       │   ├── datasources/prometheus.yml
│       │   └── dashboards/dashboard.yml
│       └── dashboards/http-testbed.json
├── scripts/
│   ├── scenarios.conf
│   ├── set_network_scenario.sh
│   ├── reset_network.sh
│   ├── wait_for_services.sh
│   ├── run_experiments.sh
│   └── export_results.sh
└── results/
    ├── logs/
    ├── raw/
    ├── run_index.csv             (generated)
    ├── summary.csv               (generated)
    └── summary_aggregated.csv    (generated)
```

---

## 10. Reproducibility notes

* Fixed payload size, no DB, no business logic → constant application time.
* k6 runs in its own container with its own CPU/RAM budget → no measurement
  bias on the server.
* 3 physical listeners → zero ALPN ambiguity when forcing a protocol.
* Emulation isolated to Caddy's edge interface → server link unshaped.
* Every combination repeated 10× with a reset + cooldown between runs.
* All raw per-run JSON/logs retained so the aggregated CSV can be re-derived.
