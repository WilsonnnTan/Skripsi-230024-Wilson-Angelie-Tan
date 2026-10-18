# Server-Side Metrics

Server-side resource utilization metrics are collected by `cAdvisor` directly from Linux kernel cgroups and stored in Prometheus. They are queried over the exact `sustained_start_epoch` and `sustained_end_epoch` window.

## Metrics Computed

### 1. CPU Utilization (% of Core)

Measures the total CPU time consumed by the target container (`backend` or `caddy`) normalized to single-core percentage (where 100% = 1.0 full CPU core utilized):

$$\text{CPU \%} = \text{avg\_over\_time}\left( \left( \sum \text{rate}( \text{container\_cpu\_usage\_seconds\_total}[5s] ) \times 100 \right)[60s:5s] \right)$$

- Evaluated across the 60s sustained window sampled at 5-second sub-intervals.
- Accurately captures both user-space and kernel-space context switching overhead.

### 2. Memory Working Set (MB)

Measures the active resident memory required by the container:

$$\text{Memory (MB)} = \frac{\text{avg\_over\_time}\left( \sum \text{container\_memory\_working\_set\_bytes}[60s:5s] \right)}{1024 \times 1024}$$

- Using `working_set_bytes` instead of total memory prevents inactive filesystem page cache from inflating utilization numbers.
