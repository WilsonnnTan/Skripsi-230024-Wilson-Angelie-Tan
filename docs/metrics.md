# Metrics & Calculations

This document details exactly how the metrics are extracted, transformed, and aggregated mathematically by the `scripts/export_results.sh` pipeline to build the final CSV files.

---

## 1. Per-Run Metrics (The `summary.csv` File)

For each of the 150 successful runs, the test measures **Client Metrics** from the merged h2load per-request logs and **Server Metrics** queried directly from Prometheus via cAdvisor.

### Client Metrics (from the h2load logs)
Every loader writes an h2load `--log-file` with one TAB-separated line per request: `start_us \t status \t duration_us` (`status = -1` on failure). `scripts/compute_percentiles.py` merges all 10 loader logs for a run, slices phases from the request timestamps themselves (`t0 = earliest request`; warmup 10 s, sustained 60 s, cooldown 10 s), and computes exact statistics over the `sustained` window.

*   **Latency Percentiles (p50, p90, p95, p99):**
    Computed directly from the sorted per-request `duration_us` (converted to ms) of every request started inside the sustained window, across all 10 loaders. These are mathematically exact percentiles over the whole 60 s window (linear interpolation between ranks), not an average of percentiles.
*   **Throughput (req/s):**
    ```text
    Throughput = (Total requests started in sustained window) / 60.0
    ```
*   **Error Rate (%):**
    ```text
    Error Rate = (Requests with status < 200 or >= 400 or -1) / (Total requests) * 100
    ```

### Server Metrics (from cAdvisor -> Prometheus)
Server metrics are aligned by time using the exact `sustained_start_epoch` and `sustained_end_epoch` recorded in `run_index.csv`.

*   **CPU Usage (%):**
    Calculated as the rate of CPU time used per second (where 1.0 = 1 full core) converted to a percentage. The script uses a 5-second rate window and samples every 5 seconds over the 60-second sustained window:
    ```promql
    avg_over_time((sum(rate(cpu_seconds_total[5s])) * 100)[60s:5s])
    ```
*   **Memory (MB):**
    The working set memory (the memory the container actively needs) is summed, averaged over the same 60-second window (sampled every 5s), and converted to Mebibytes (1024 * 1024):
    ```promql
    avg_over_time(sum(memory_working_set_bytes)[60s:5s]) / 1048576
    ```

---

## 2. Aggregation Across Repetitions (The `summary_aggregated.csv` File)

To analyze the variance caused by network conditions, each scenario/protocol combination is repeated 10 times. The AWK script at the end of `export_results.sh` groups these 10 repetitions and computes the **mean** and **standard deviation** for every metric. 

### Handling Missing Data
If a run failed to record a server metric (e.g., a cAdvisor scrape gap yielding `NaN`), the script skips that `NaN` value entirely for that specific column. It does **not** coerce missing data to 0. The count of valid samples (`c`) is tracked separately for every metric.

### Mathematical Formulas
For a given metric column across the 10 repetitions, let `v_i` be a valid sample.
The script tracks:
*   `c`: the count of valid samples
*   `S = Σ(v_i)`: the sum of the samples
*   `Q = Σ(v_i²)`: the sum of the squared samples

1.  **Mean (μ):**
    ```text
    μ = S / c
    ```
2.  **Sample Variance (s²):**
    Using Bessel's correction (`c - 1` denominator) for an unbiased estimate of the population variance:
    ```text
    s² = [ Q - c * μ² ] / (c - 1)
    ```
    *(Note: The script clamps variance to 0 if it briefly dips negative due to floating-point precision limits).*
3.  **Standard Deviation (s):**
    ```text
    s = √( max(s², 0) )
    ```
    *(If `c <= 1`, standard deviation is set to 0).*
