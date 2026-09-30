# Scripts

The automation is handled by bash scripts in the `scripts/` directory:

- `wait_for_services.sh`: Ensures all containers and the network emulator are ready.
- `run_experiments.sh`: Loops through the 3 protocols and 5 network scenarios, executing 10 repetitions each. Total 150 runs.
- `export_results.sh`: Parses the raw JSON and Prometheus data into final `summary.csv` and `summary_aggregated.csv` files.
- `set_network_scenario.sh` & `reset_network.sh`: Helpers to apply and remove network shaping rules dynamically.
