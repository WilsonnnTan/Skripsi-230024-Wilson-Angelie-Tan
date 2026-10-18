# Output Files Overview

Benchmark execution produces structured datasets in the `results/` directory, categorized into run indices, per-run metrics, aggregated statistics, and raw trace files.

## Directory Structure

```text
results/
├── run_index.csv              # Timestamps, run IDs, protocol, scenario, repetitions
├── summary.csv                # 150-row per-run steady-state metrics
├── summary_aggregated.csv     # 15-row mean ± std grouped by protocol & scenario
├── summary_by_phase.csv       # Sliced metrics across warmup, sustained, and cooldown
├── logs/                      # Raw per-loader execution logs (.log)
└── raw/                       # Prometheus TSDB exported metrics (.json)
```

## Dataset Summary

| File | Rows | Description |
| --- | --- | --- |
| `run_index.csv` | 150 | Catalog of all completed runs with exact unix start/end epoch stamps |
| `summary.csv` | 150 | Sustained-window throughput, percentiles, error rate, and server resource metrics for each individual run |
| `summary_aggregated.csv` | 15 | Statistical mean (μ) and standard deviation (s) for each of the 3 × 5 condition combinations |
| `summary_by_phase.csv` | 450 | Phase-by-phase breakdown (warmup, sustained, cooldown) for transient behavior analysis |
