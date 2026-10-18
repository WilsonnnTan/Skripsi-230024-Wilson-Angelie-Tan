# Server-Side Metrics

Server-side resource utilization metrics are collected by `cAdvisor` directly from Linux kernel cgroups and stored in Prometheus. They are queried over the exact `sustained_start_epoch` and `sustained_end_epoch` window.

## Metrics Computed

### 1. CPU Utilization (% of Core)

Measures the total CPU time consumed by the target container (`backend` or `caddy`) normalized to single-core percentage (where 100% = 1.0 full CPU core utilized):

```promql
avg_over_time((sum(rate(container_cpu_usage_seconds_total[5s])) * 100)[60s:5s])
```

- Evaluated across the 60-second sustained window sampled at 5-second sub-intervals.
- Accurately captures both user-space execution and kernel-space network socket overhead.

### 2. Memory Working Set (MB)

Measures the active resident memory required by the container:

```promql
avg_over_time(sum(container_memory_working_set_bytes)[60s:5s]) / (1024 * 1024)
```

- Using `working_set_bytes` instead of total memory prevents inactive filesystem page cache from inflating utilization numbers.
