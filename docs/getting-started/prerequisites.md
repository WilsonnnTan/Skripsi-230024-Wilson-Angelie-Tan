# Prerequisites

Before setting up the testbed, ensure the following requirements are met.

## Hardware Requirements

| Component | Minimum | Recommended |
| --- | --- | --- |
| CPU | 8 logical cores | 12+ logical cores (P-core + E-core, e.g. i7-12650H) |
| RAM | 8 GB | 16 GB |
| Disk | 10 GB free | 50 GB+ (Prometheus TSDB grows with retention) |

{% hint style="info" %}
The testbed pins different services to different CPU cores to prevent measurement bias. An Intel 12th-gen or later hybrid CPU (P-cores + E-cores) is ideal because the system-under-test can be pinned to P-cores while support services run on E-cores.
{% endhint %}

## Software Requirements

| Software | Version | Purpose |
| --- | --- | --- |
| **Docker Engine** | 24.0+ | Container runtime |
| **Docker Compose** | v2.20+ | Stack orchestration |
| **Linux kernel** | 5.15+ | `tc netem`, `ifb` module, `nsenter` |
| **bash** | 5.0+ | Automation scripts |
| **curl** | any | docker-tc API calls |
| **jq** | any | JSON parsing in export script |
| **Python 3** | 3.8+ | `compute_percentiles.py` |

{% hint style="warning" %}
**Linux host required.** The network emulation (`docker-tc`) uses Linux-only kernel features: `tc netem`, `nsenter`, and the `ifb` kernel module. It will **not** work on macOS or Windows without WSL2.
{% endhint %}

## WSL2 Users (Windows)

If you are running on Windows via WSL2:

1. Install Docker Desktop with WSL2 backend enabled
2. Verify the `ifb` kernel module is available:
   ```bash
   sudo modprobe ifb numifbs=0
   ```
3. **CPU pinning caveat:** Container `cpuset` pins to the WSL2 VM's vCPUs, but Windows may still migrate VM threads across P/E cores. For strict P-core placement, pin the WSL2 VM process (`vmmemWSL`) to host P-cores via Windows CPU affinity. See `.env.example` for details.

## Kernel Module Check

The `ifb` module is required for symmetric (ingress + egress) network shaping. Verify it is available:

```bash
# Check if ifb is loaded or loadable
modprobe ifb numifbs=0 && echo "OK: ifb module available"
```

If the module is not available, ingress shaping will fail and docker-tc will log a warning at startup.
