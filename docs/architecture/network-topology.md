# Network Topology

This page details how network emulation is structured and applied in the testbed.

## Topology Overview

```mermaid
graph TB
    subgraph loaders["Load Generator Cluster (edge_net)"]
        L1["h2load_run_1\n0.25 vCPU / 256 MB"]
        L2["h2load_run_2\n0.25 vCPU / 256 MB"]
        L3["h2load_run_3"]
        L4["..."]
        L10["h2load_run_10\n0.25 vCPU / 256 MB"]
    end

    subgraph tc["Traffic Control (host network)"]
        DTC["docker-tc\n(nsenter + tc netem)"]
    end

    subgraph server["System Under Test"]
        C["Caddy\n1 vCPU / 1 GB"]
        B["Backend\n1 vCPU / 1 GB"]
    end

    DTC ==>|"netem egress\n+ ifb ingress"| L1
    DTC ==>|"netem egress\n+ ifb ingress"| L2
    DTC ==>|"netem egress\n+ ifb ingress"| L3
    DTC ==>|"netem"| L4
    DTC ==>|"netem egress\n+ ifb ingress"| L10

    L1 & L2 & L3 & L4 & L10 -->|"HTTPS\n(shaped)"| C
    C -->|"HTTP\n(unimpaired)"| B

    style loaders fill:#e3f2fd,stroke:#1565c0
    style tc fill:#fff8e1,stroke:#f57f17
    style server fill:#e8f5e9,stroke:#2e7d32
```

## Per-Client Link Emulation

Unlike traditional approaches that shape the server's interface (affecting all clients equally), this testbed shapes **each loader's individual interface**. This models real-world conditions where every client has its own last-mile link.

### How It Works

```mermaid
flowchart LR
    subgraph loader["h2load container netns"]
        ETH["eth0\n(172.28.x.x)"]
        IFB["ifb0\n(mirror device)"]
    end

    subgraph rules["tc netem rules"]
        EG["Egress\n(uplink: client→server)"]
        IG["Ingress via ifb\n(downlink: server→client)"]
    end

    ETH -->|"outgoing packets"| EG
    ETH -->|"incoming packets\nredirected"| IFB
    IFB --> IG

    style loader fill:#e3f2fd,stroke:#1565c0
    style rules fill:#fff3e0,stroke:#e65100
```

1. **Egress shaping (uplink):** A `netem` qdisc is attached to the loader's `eth0` root. All outgoing packets (requests) pass through it and experience the configured delay, jitter, loss, and rate limit.

2. **Ingress shaping (downlink):** Linux `tc netem` is egress-only by design. To shape incoming packets (responses), the testbed:
   - Creates an `ifb0` (Intermediate Functional Block) device inside the loader's network namespace
   - Adds an `ingress` qdisc on `eth0` with a `u32` filter that redirects all incoming traffic to `ifb0`
   - Applies the same `netem` rules on `ifb0`'s root qdisc

This creates a **symmetric** emulated link where both directions experience identical impairment.

### Interface Auto-Detection

docker-tc automatically detects the correct interface to shape by scanning the container's network namespace for an IPv4 address on the `172.28.0.0/24` edge subnet:

```
nsenter -t <pid> -n ip -o -4 addr show
→ "3: eth0    inet 172.28.0.5/24 brd ..."
→ Selected: eth0 (matches EDGE_SUBNET_PREFIX=172.28.)
```

## Emulation Parameters

Each network scenario defines four parameters that map to `tc netem` arguments:

| Parameter | netem Argument | Direction | Example |
| --- | --- | --- | --- |
| `delay` | `netem delay <ms>` | Both (one-way) | `35ms` → 70 ms RTT |
| `jitter` | appended after delay | Both | `5ms` |
| `loss` | `netem loss <pct>` | Both | `2%` |
| `rate` | `netem rate <bps>` | Both | `20mbit` |

{% hint style="warning" %}
The `delay` value is **one-way**. Since it is applied symmetrically (egress + ingress), the effective round-trip time is **2 × delay**. For example, `delay=35ms` produces a 70 ms RTT.
{% endhint %}
