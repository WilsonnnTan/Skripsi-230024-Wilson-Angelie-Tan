# export_results.sh

`scripts/export_results.sh` extracts metric slices from Prometheus for each run's steady-state window ($t_{warmup}+10\text{s}$ to $t_{cooldown}-10\text{s}$), calculates summary statistics, and generates CSV output files.

## Usage

```bash
./scripts/export_results.sh
```

## Extraction Process

```mermaid
flowchart LR
    LOG["results/experiment_log.txt\n(Timestamps: T_start, T_end)"] --> SCRIPT["export_results.sh"]
    PROM["Prometheus API\n/api/v1/query_range"] --> SCRIPT
    SCRIPT --> RAW["results/raw_metrics.csv"]
    SCRIPT --> PY["compute_percentiles.py"]
    PY --> AGG["results/summary_aggregated.csv"]
```

## Key PromQL Queries Used

1. **Throughput (Requests/sec)**:
   ```promql
   sum(rate(h2load_requests_total[10s]))
   ```

2. **Error Rate (%)**:
   ```promql
   sum(rate(h2load_requests_failed_total[10s])) / sum(rate(h2load_requests_total[10s])) * 100
   ```

3. **Client Latency (TTFB)**:
   ```promql
   h2load_latency_seconds{quantile="0.5"}
   ```

4. **Server CPU Utilization**:
   ```promql
   sum(rate(container_cpu_usage_seconds_total{name="backend"}[10s])) by (name)
   ```
