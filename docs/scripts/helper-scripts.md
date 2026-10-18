# Helper Scripts

The testbed relies on several purpose-built helper scripts to maintain clean isolation, check system health, and calculate percentiles.

## 1. `wait_for_services.sh`

Polls container health checks and endpoints before initiating any benchmarks:
- Verifies Docker socket connectivity.
- Sends HTTP requests to `caddy:8443`, `backend:3000`, `docker-tc:4000`, `prometheus:9090`, and `grafana:3000`.
- Blocks until all services respond with HTTP 200/404 (ready) or times out after 60 seconds.

## 2. `set_network_scenario.sh`

Invoked by `run_experiments.sh` at the start of each benchmark run.
- Reads scenario definitions from `scenarios.conf`.
- Submits an HTTP POST request to `docker-tc:4000/apply` with the target network constraints.
- Verifies that the netem qdiscs are applied correctly via `GET /status`.

```bash
# Example manual invocation:
./scripts/set_network_scenario.sh S3
```

## 3. `reset_network.sh`

Flushes all traffic shaping rules from the virtual bridge interfaces:
- Sends a POST request to `docker-tc:4000/reset`.
- Restores zero artificial latency, 0% packet loss, and unthrottled throughput.
- Run between individual test iterations to prevent queue contamination.

## 4. `compute_percentiles.py`

A vectorized Python script utilizing NumPy/Pandas to aggregate raw time-series latency measurements:
- Aggregates steady-state windows across all 10 repetitions per condition.
- Calculates:
  - Arithmetic Mean and Standard Deviation.
  - Median (p50), 90th percentile (p90), 95th percentile (p95), and 99th percentile (p99).
- Outputs formatted Markdown tables and CSV rows.
