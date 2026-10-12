# Grafana & Prometheus

Monitoring is fully automated using Prometheus and Grafana.

- **Prometheus**: Scrapes server metrics from cAdvisor and live client metrics from the `h2load-exporter` (which tails the loaders' per-request logs). h2load has no remote-write, so there is no load-generator remote-write stream anymore.
- **Grafana**: Available at `http://localhost:3000`. It includes two pre-built dashboards:
  - **Live Dashboard**: Watch the active run (throughput, error rate, latency percentiles from the exporter; CPU/mem from cAdvisor).
  - **Aggregate Analysis Dashboard**: Compare protocols and network scenarios after runs are completed. These are *exploratory* aggregates of the exporter's rolling stream — the authoritative numbers live in `results/summary*.csv`, computed exactly from the per-request logs.
