# Client-Side Metrics

Client-side metrics are computed directly from the merged per-request event logs produced by the 10 `h2load` containers.

## Per-Request Log Format

Each loader container writes an h2load `--log-file` containing tab-separated records for every initiated request:

```tsv
start_us    status    duration_us
```
- `start_us`: Microsecond timestamp when the request started.
- `status`: HTTP response status code (e.g. `200`). Set to `-1` on network or protocol failure (e.g. timeout, connection reset).
- `duration_us`: Time elapsed from first byte sent until complete response received (TTFB + transfer).

## Metrics Computed

### 1. Latency Percentiles (p50, p90, p95, p99)
- `scripts/compute_percentiles.py` pools the raw per-request durations (converted to milliseconds) for all requests initiated inside the 60-second sustained phase across all 10 loaders.
- Percentiles are calculated via linear rank interpolation over the entire pooled population (~60,000 requests per run), guaranteeing mathematical precision rather than an average of percentiles.

### 2. Sustained Throughput

```text
Throughput (req/s) = N_sustained / 60.0
```

Where:
- `N_sustained`: Total number of requests initiated within the 60-second sustained measurement window.

### 3. Error Rate

```text
Error Rate (%) = (N_failed / N_total) × 100
```

Where:
- `N_failed`: Total requests with status `< 200`, `≥ 400`, or `-1` (connection timeout or TCP reset).
- `N_total`: Total requests initiated within the sustained window.
