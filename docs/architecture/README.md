# System Overview

The testbed is a fully Dockerized environment that measures HTTP protocol performance under controlled network conditions. This page provides the high-level architecture diagram and explains how all components interact.

## Architecture Diagram

The following diagram illustrates the complete testbed topology and component interactions across the three isolated Docker networks:

![System Architecture](../.gitbook/assets/design.png)

*Figure 1: High-level testbed architecture showing `edge_net`, `backend_net`, and `monitoring_net`.*


## Request Flow

The data path for every request follows this route:

```mermaid
sequenceDiagram
    participant L as h2load (×10)
    participant TC as docker-tc
    participant C as Caddy
    participant B as Backend

    Note over TC,L: Netem rules applied BEFORE load starts
    TC->>L: Apply symmetric netem<br/>(egress + ifb ingress)
    
    loop Every request (80s duration)
        L->>C: HTTPS request<br/>(HTTP/1.1 | HTTP/2 | HTTP/3)
        Note over L,C: Shaped by netem:<br/>delay + jitter + loss + rate limit
        C->>B: Plain HTTP proxy<br/>(internal, unimpaired)
        B->>C: JSON response (8 KiB)
        C->>L: TLS-encrypted response
        Note over L: Log: start_us, status, duration_us
    end
```

## Network Separation

The testbed uses three isolated Docker bridge networks to ensure clean measurement:

```mermaid
graph LR
    subgraph edge["edge_net (172.28.0.0/24)"]
        direction TB
        E1["h2load ×10"]
        E2["Caddy (edge side)"]
    end
    
    subgraph back["backend_net (172.29.0.0/24)"]
        direction TB
        B1["Caddy (backend side)"]
        B2["Backend"]
    end
    
    subgraph mon["monitoring_net (172.30.0.0/24)"]
        direction TB
        M1["Caddy (metrics)"]
        M2["cAdvisor"]
        M3["h2load-exporter"]
        M4["Prometheus"]
        M5["Grafana"]
    end
    
    E1 <-->|"Emulated link\n(netem shaped)"| E2
    B1 <-->|"Internal link\n(unimpaired)"| B2
    M2 & M3 -->|"Scrape @ 1s"| M4
    M4 -->|"Query"| M5

    style edge fill:#e3f2fd,stroke:#1565c0
    style back fill:#e8f5e9,stroke:#2e7d32
    style mon fill:#fce4ec,stroke:#c62828
```

| Network | Subnet | Purpose | Shaped? |
| --- | --- | --- | --- |
| `edge_net` | `172.28.0.0/24` | Client ↔ Proxy traffic | ✅ Yes (netem per loader) |
| `backend_net` | `172.29.0.0/24` | Proxy ↔ Backend internal traffic | ❌ No |
| `monitoring_net` | `172.30.0.0/24` | Observability plane | ❌ No |

{% hint style="info" %}
**Why separate networks?** Network emulation is only applied to the `edge_net` interfaces of each h2load container. By isolating backend and monitoring traffic on different subnets, those flows are never affected by the netem rules — ensuring that Prometheus scrapes and internal proxy ↔ backend communication remain clean.
{% endhint %}
