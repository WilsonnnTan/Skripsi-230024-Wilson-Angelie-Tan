# Scripts

The automation is handled by bash scripts in the `scripts/` directory:

- `wait_for_services.sh`: Ensures all containers and the network emulator (including the `ifb`-based symmetric shaping path) are ready.
- `run_experiments.sh`: Loops through the 3 protocols and 5 network scenarios, 10 repetitions each (150 runs). Each run launches 10 parallel `h2load` loader containers, applies the scenario's symmetric netem to every loader, waits for them to finish, and records the run.
- `export_results.sh`: Computes exact client percentiles from the merged per-request h2load logs (via `compute_percentiles.py`) and joins cAdvisor server metrics from Prometheus into `summary.csv`, `summary_aggregated.csv`, and `summary_by_phase.csv`.
- `compute_percentiles.py`: Reads one run's 10 h2load `--log-file` logs and prints exact per-phase p50/p90/p95/p99, throughput, and error rate as JSON.
- `set_network_scenario.sh` & `reset_network.sh`: Apply / remove symmetric network shaping on a list of containers (the 10 loaders) via the docker-tc REST API.
