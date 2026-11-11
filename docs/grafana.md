# Grafana & Prometheus

Monitoring is fully automated using Prometheus and Grafana.

- **Prometheus**: Scrapes server metrics from cAdvisor and live client metrics from the `h2load-exporter` (which tails the loaders' per-request logs). h2load has no remote-write, so there is no load-generator remote-write stream anymore.
- **Grafana**: Available at `http://localhost:3000`. It includes two pre-built dashboards:
  - **Live Dashboard**: Watch the active run (throughput, error rate, latency percentiles from the exporter; CPU/mem from cAdvisor).
  - **Aggregate Analysis Dashboard**: Compare protocols and network scenarios after runs are completed. It shows the *exact per-run results* that `h2load-exporter` publishes as `h2load_final_*` gauges, averaged over the repetitions, so it reproduces `results/summary_aggregated.csv`.

## Why the Aggregate dashboard matches the CSV

The Live dashboard uses rolling gauges (10 s trailing window, scraped every second). They are approximate: throughput is too low at the edges of the sustained phase and percentiles are averages of short windows. The Aggregate dashboard therefore does **not** use them. Once a run has finished (and no other run is in progress), `h2load-exporter` reads `results/run_index.csv` and, for every successful run:

- computes the client metrics with `scripts/compute_percentiles.py` (`compute_metrics()`, the same function `export_results.sh` calls) over the exact 60 s sustained window;
- queries Prometheus for CPU/memory with the same PromQL as `export_results.sh` (`server_avg`), evaluated at the run's `sustained_end` over its recorded sustained window.

The values are exposed as `h2load_final_throughput_rps`, `h2load_final_latency_p50_ms` … `_p99_ms`, `h2load_final_error_rate_pct`, `h2load_final_cpu_caddy_pct`, `h2load_final_mem_caddy_mb`, `h2load_final_cpu_backend_pct`, `h2load_final_mem_backend_mb` (labels `protocol`, `scenario`, `repetition`). `avg by (protocol, scenario)` over them equals the CSV mean.

Requirements to keep the two identical:

- `WARMUP_S` / `SUSTAINED_S` / `COOLDOWN_S`, `CPU_RATE_WINDOW` and `QUERY_STEP` in the exporter's environment (`docker-compose.yml`) must equal the values used by `export_results.sh` (defaults: 10 / 60 / 10, `5s`, `5s`).
- `results/raw/<run_id>/` must exist for every run (the exporter re-reads the raw logs) and Prometheus must still hold the cAdvisor data of those runs (retention is 30 days).
- Set the dashboard time range so it ends after the last run. The metrics are re-published continuously while the exporter runs, so the range length does not matter.
- `docker compose up -d --build h2load-exporter` after pulling this change.

The authoritative numbers remain `results/summary*.csv`.
