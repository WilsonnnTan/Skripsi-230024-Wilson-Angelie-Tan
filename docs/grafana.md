# Grafana & Prometheus

Monitoring is fully automated using Prometheus and Grafana.

- **Prometheus**: Scrapes container metrics from cAdvisor and receives load test metrics from k6 via remote-write.
- **Grafana**: Available at `http://localhost:3000`. It includes two pre-built dashboards:
  - **Live Dashboard**: Watch the active run.
  - **Aggregate Analysis Dashboard**: Compare protocols and network scenarios after runs are completed.
