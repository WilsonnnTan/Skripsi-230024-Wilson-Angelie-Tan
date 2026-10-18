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

### 1. Latency Percentiles ($p_{50}$, $p_{90}$, $p_{95}$, $p_{99}$)
- `scripts/compute_percentiles.py` pools the raw per-request durations (converted to milliseconds) for all requests initiated inside the 60-second sustained phase across all 10 loaders.
- Percentiles are calculated via linear rank interpolation over the entire pooled population ($N \approx 60,000$ requests per run), guaranteeing mathematical precision rather than an average of percentiles.

### 2. Sustained Throughput
$$\text{Throughput (req/s)} = \frac{N_{\text{sustained}}}{60.0\text{ seconds}}$$
where $N_{\text{sustained}}$ is the total count of requests started within the sustained window.

### 3. Error Rate
$$\text{Error Rate (\%)} = \frac{N_{\text{error}}}{N_{\text{sustained}}} \times 100$$
where $N_{\text{error}}$ represents all requests where status is either $< 200$, $\ge 400$, or equal to $-1$.
