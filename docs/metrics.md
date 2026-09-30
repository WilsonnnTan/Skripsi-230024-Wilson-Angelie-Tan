# Metrics & Calculations

This document details exactly how the metrics are extracted, transformed, and aggregated mathematically by the `scripts/export_results.sh` pipeline to build the final CSV files.

---

## 1. Per-Run Metrics (The `summary.csv` File)

For each of the 150 successful runs, the test measures **Client Metrics** from the `k6` summary JSON and **Server Metrics** queried directly from Prometheus via cAdvisor.

### Client Metrics (from k6)
The k6 runner is configured to emit exact whole-window statistics per phase. For the headline results, the pipeline extracts the exact statistics from the `sustained` phase (a 60-second window).

*   **Latency Percentiles ($p_{50}$, $p_{90}$, $p_{95}$, $p_{99}$):**
    Extracted verbatim from the k6 trend `req_duration_ms{phase:sustained}`. These are mathematically exact percentiles calculated across all requests in the 60s window, not an average of percentiles.
*   **Throughput (req/s):**
    $$Throughput = \frac{\text{reqs\{phase:sustained\}.count}}{60 \text{ seconds}}$$
    This divides the total number of request attempts during the sustained phase by 60.
*   **Error Rate (%):**
    $$Error Rate = \text{req\_errors\{phase:sustained\}.rate} \times 100$$
    The rate (a float between 0.0 and 1.0 representing the fraction of failed requests) is converted to a percentage.

### Server Metrics (from cAdvisor -> Prometheus)
Server metrics are aligned by time using the exact `sustained_start_epoch` and `sustained_end_epoch` recorded in `run_index.csv`.

*   **CPU Usage (%):**
    Calculated as the rate of CPU time used per second (where 1.0 = 1 full core) converted to a percentage. The script uses a 5-second rate window and samples every 5 seconds over the 60-second sustained window:
    $$CPU\% = \text{avg\_over\_time}\left( \left( \sum \text{rate}( \text{cpu\_seconds\_total}[5s] ) \times 100 \right)[60s:5s] \right)$$
*   **Memory (MB):**
    The working set memory (the memory the container actively needs) is summed, averaged over the same 60-second window (sampled every 5s), and converted to Mebibytes ($1024^2$):
    $$Memory (MB) = \frac{\text{avg\_over\_time}\left( \sum \text{memory\_working\_set\_bytes}[60s:5s] \right)}{1048576}$$

---

## 2. Aggregation Across Repetitions (The `summary_aggregated.csv` File)

To analyze the variance caused by network conditions, each scenario/protocol combination is repeated 10 times. The AWK script at the end of `export_results.sh` groups these 10 repetitions and computes the **mean** and **standard deviation** for every metric. 

### Handling Missing Data
If a run failed to record a server metric (e.g., a cAdvisor scrape gap yielding `NaN`), the script skips that `NaN` value entirely for that specific column. It does **not** coerce missing data to 0. The count of valid samples ($c$) is tracked separately for every metric.

### Mathematical Formulas
For a given metric column across the 10 repetitions, let $v_i$ be a valid sample.
The script tracks:
*   $c$: the count of valid samples
*   $S = \sum v_i$: the sum of the samples
*   $Q = \sum v_i^2$: the sum of the squared samples

1.  **Mean ($\mu$):**
    $$\mu = \frac{S}{c}$$
2.  **Sample Variance ($s^2$):**
    Using Bessel's correction ($n-1$ denominator) for an unbiased estimate of the population variance:
    $$s^2 = \frac{Q - c \cdot \mu^2}{c - 1}$$
    *(Note: The script clamps variance to 0 if it briefly dips negative due to floating-point precision limits).*
3.  **Standard Deviation ($s$):**
    $$s = \sqrt{\max(s^2, 0)}$$
    *(If $c \le 1$, standard deviation is set to 0).*
