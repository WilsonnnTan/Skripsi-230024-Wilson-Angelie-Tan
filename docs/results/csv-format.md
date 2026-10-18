# CSV Format Reference

This reference documents the schema and units of the final aggregated datasets.

## `summary_aggregated.csv` Schema

Each row corresponds to one unique `(protocol, scenario)` combination evaluated over 10 repetitions ($N=10$).

| Column | Type | Unit | Description |
| --- | --- | --- | --- |
| `protocol` | string | - | Protocol evaluated (`http1.1`, `http2`, `http3`) |
| `scenario` | string | - | Network scenario evaluated (`S1` to `S5`) |
| `repetitions` | integer | count | Number of successful runs aggregated (10) |
| `throughput_rps_mean` | float | req/s | Mean sustained throughput |
| `throughput_rps_std` | float | req/s | Standard deviation of sustained throughput |
| `latency_p50_mean` | float | ms | Mean 50th percentile latency (median) |
| `latency_p50_std` | float | ms | Standard deviation of 50th percentile latency |
| `latency_p90_mean` | float | ms | Mean 90th percentile latency |
| `latency_p90_std` | float | ms | Standard deviation of 90th percentile latency |
| `latency_p95_mean` | float | ms | Mean 95th percentile latency |
| `latency_p95_std` | float | ms | Standard deviation of 95th percentile latency |
| `latency_p99_mean` | float | ms | Mean 99th percentile latency |
| `latency_p99_std` | float | ms | Standard deviation of 99th percentile latency |
| `error_rate_pct_mean` | float | % | Mean percentage of failed or errored requests |
| `error_rate_pct_std` | float | % | Standard deviation of error rate |
| `cpu_caddy_pct_mean` | float | % core | Mean CPU utilization of Caddy reverse proxy |
| `cpu_caddy_pct_std` | float | % core | Standard deviation of Caddy CPU utilization |
| `mem_caddy_mb_mean` | float | MiB | Mean working set memory of Caddy container |
| `mem_caddy_mb_std` | float | MiB | Standard deviation of Caddy memory |
| `cpu_backend_pct_mean` | float | % core | Mean CPU utilization of Express backend |
| `cpu_backend_pct_std` | float | % core | Standard deviation of Express backend CPU |
| `mem_backend_mb_mean` | float | MiB | Mean working set memory of Express backend |
| `mem_backend_mb_std` | float | MiB | Standard deviation of Express backend memory |
