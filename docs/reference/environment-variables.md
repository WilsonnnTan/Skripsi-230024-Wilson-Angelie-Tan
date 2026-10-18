# Environment Variables Reference

Configuration values can be overridden via a `.env` file placed in the repository root. Docker Compose automatically loads this file at launch.

## Complete Variables Catalog

| Variable | Default Value | Category | Description |
| --- | --- | --- | --- |
| `GF_SECURITY_ADMIN_USER` | `admin` | Security | Admin username for Grafana web console |
| `GF_SECURITY_ADMIN_PASSWORD` | `admin` | Security | Admin password for Grafana web console |
| `REPETITIONS` | `10` | Experiment | Number of test repetitions per protocol-scenario cell |
| `LOADERS` | `10` | Experiment | Number of parallel client containers (`h2load_run_X`) |
| `PRESTART` | `3` | Experiment | Sleep buffer (seconds) allowing `docker-tc` to bind qdiscs |
| `STABILIZE_SECONDS` | `2` | Experiment | Pause (seconds) after applying qdisc before load begins |
| `COOLDOWN_SECONDS` | `8` | Experiment | Rest period (seconds) between runs to flush sockets |
| `RESUME` | `1` | Experiment | Resume mode (skip completed runs present in log) |
| `PROM_URL` | `http://localhost:9090` | Monitoring | Prometheus query URL for data exporter |
| `CPU_RATE_WINDOW` | `30s` | Monitoring | PromQL rate calculation window for cgroup metrics |
| `QUERY_STEP` | `5s` | Monitoring | Sampling step resolution for time-series extraction |
| `CPUSET_BACKEND` | `0-1` | CPU Pinning | Logical cores reserved for Express backend |
| `CPUSET_CADDY` | `2-3` | CPU Pinning | Logical cores reserved for Caddy reverse proxy |
| `CPUSET_LOADER` | `4-7` | CPU Pinning | Logical cores reserved for 10x h2load client cluster |
| `CPUSET_SUPPORT` | `8-11` | CPU Pinning | Logical cores reserved for Prometheus, Grafana, cAdvisor, and docker-tc |
