# HTTP/1.1 vs HTTP/2 vs HTTP/3 Research Testbed

Automated testbed to measure throughput, latency, and error rate across different HTTP protocols and network conditions.

## How to Run the Experiments

1. **Start all services:**
   ```bash
   docker compose up -d --build
   ```
2. **Wait for services to be ready:**
   ```bash
   ./scripts/wait_for_services.sh
   ```
3. **Run all 150 experiments (approx 5 hours):**
   ```bash
   ./scripts/run_experiments.sh
   ```
4. **Export CSV results:**
   ```bash
   ./scripts/export_results.sh
   ```
Results will be saved in the `results/` folder.

## How to Check & Analyze Existing Data

If you just want to analyze the pre-recorded metrics without running the 5-hour test:

1. **Unzip the Prometheus data:**
   ```bash
   tar -xzf prometheus_data.tar.gz
   ```
   *(This extracts existing metrics to the `prometheus_data/` folder).*

2. **Start the monitoring stack:**
   ```bash
   docker compose up -d prometheus grafana
   ```

3. **View the Dashboards:**
   Open Grafana at **http://localhost:3000** (login `admin` / `admin`).
   Check the pre-configured **HTTP Testbed - Aggregate Analysis** dashboard to explore the data.

4. **View CSV Results:**
   Check the `results/` folder for `summary_aggregated.csv` and other detailed outputs.