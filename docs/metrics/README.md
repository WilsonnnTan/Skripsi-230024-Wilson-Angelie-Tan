# Metrics & Calculations Overview

The testbed extracts, transforms, and mathematically aggregates performance metrics from both client-side load generators (`h2load`) and server-side container instrumentation (`cAdvisor` via Prometheus).

## Metric Categories

```mermaid
graph LR
    subgraph client["Client-Side Metrics (h2load logs)"]
        direction TB
        T["Throughput (req/s)"]
        L["Latency Percentiles (p50, p90, p95, p99)"]
        E["Error Rate (%)"]
    end

    subgraph server["Server-Side Metrics (cAdvisor TSDB)"]
        direction TB
        CPU["CPU Usage (% of core)"]
        MEM["Working Set Memory (MB)"]
    end

    subgraph pipeline["Aggregation Pipeline"]
        direction TB
        RAW["Per-Run Metrics\n(150 runs in summary.csv)"]
        AGG["Aggregated Statistics\n(Mean & StdDev in summary_aggregated.csv)"]
    end

    client --> RAW
    server --> RAW
    RAW --> AGG
```

## Data Slicing Principle

All metrics are evaluated exclusively over the **60-second sustained steady-state window** ($t_{warmup}=10\text{s}$ to $t_{cooldown}=70\text{s}$). Startup connection handshakes and cooldown drain periods are deliberately excluded from measurement.

## Detail Pages

- [Client-Side Metrics](client-metrics.md): Exact percentiles, throughput formula, and error classification.
- [Server-Side Metrics](server-metrics.md): PromQL cgroup CPU rate integration and memory working set calculations.
- [Aggregation & Statistics](aggregation.md): Multi-run Bessel correction sample variance, standard deviation, and NaN handling.
