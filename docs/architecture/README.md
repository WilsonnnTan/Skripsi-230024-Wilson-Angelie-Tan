# System Overview

The testbed is a fully Dockerized environment that measures HTTP protocol performance under controlled network conditions. This page provides the high-level architecture diagram and explains how all components interact.

## Architecture Diagram

The following diagram shows the complete system architecture, including all three Docker networks and the data flow between services:

```mermaid
graph TB
    subgraph Host["🖥️ Host Machine"]
        subgraph edge_net["edge_net 172.28.0.0/24"]
            h2load_1["h2load #1"]
            h2load_2["h2load #2"]
            h2load_N["h2load #3–#10\n(8 more containers)"]
            caddy_edge["Caddy\n:8443 HTTP/1.1\n:8444 HTTP/2\n:8445 HTTP/3"]
            
            h2load_1 -->|"Request &\nResponse"| caddy_edge
            h2load_2 -->|"Request &\nResponse"| caddy_edge
            h2load_N -->|"Request &\nResponse"| caddy_edge
        end

        docker_tc["docker-tc\n(Traffic Control)"]
        docker_tc -->|"Network\nEmulation"| h2load_1
        docker_tc -->|"Network\nEmulation"| h2load_2
        docker_tc -->|"Network\nEmulation"| h2load_N

        subgraph backend_net["backend_net 172.29.0.0/24"]
            caddy_backend["Caddy"]
            backend["Backend\n(Express.js)"]
            caddy_backend -->|"Request &\nResponse"| backend
        end

        subgraph monitoring_net["monitoring_net 172.30.0.0/24"]
            cadvisor["cAdvisor"]
            exporter["h2load-exporter\n(Read h2load Logs)"]
            prometheus["Prometheus"]
            grafana["Grafana"]
            
            cadvisor -->|"Scrape\nMetrics"| prometheus
            exporter -->|"Scrape\nMetrics"| prometheus
            prometheus -->|"Query\nData"| grafana
        end

        cadvisor -.->|"Read Resource\nMetrics"| backend
        cadvisor -.->|"Read Resource\nMetrics"| caddy_edge
    end

    style edge_net fill:#fff3e0,stroke:#e65100,color:#e65100
    style backend_net fill:#fff3e0,stroke:#e65100,color:#e65100
    style monitoring_net fill:#fff3e0,stroke:#e65100,color:#e65100
    style Host fill:#fafafa,stroke:#333,color:#333
```

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
