# Components Overview

The testbed is composed of seven Docker services organized into four functional groups.

## Component Diagram

```mermaid
graph TB
    subgraph sut["🟢 System Under Test"]
        backend["Backend\n(Express.js)"]
        caddy["Caddy\n(Reverse Proxy)"]
    end
    
    subgraph load["🔵 Load Generation"]
        h2load["h2load ×10"]
        exporter["h2load-exporter"]
    end
    
    subgraph emul["🟠 Network Emulation"]
        dockertc["docker-tc"]
    end
    
    subgraph mon["🔴 Monitoring"]
        cadvisor["cAdvisor"]
        prom["Prometheus"]
        graf["Grafana"]
    end

    h2load -->|"HTTPS"| caddy
    caddy -->|"HTTP"| backend
    dockertc -->|"tc netem"| h2load
    
    exporter -->|"tail logs"| h2load
    cadvisor -.->|"cgroups"| backend
    cadvisor -.->|"cgroups"| caddy
    exporter & cadvisor -->|"scrape"| prom
    prom --> graf

    style sut fill:#e8f5e9,stroke:#2e7d32
    style load fill:#e3f2fd,stroke:#1565c0
    style emul fill:#fff8e1,stroke:#f57f17
    style mon fill:#fce4ec,stroke:#c62828
```

## Component Summary

| Component | Technology | Role | Page |
| --- | --- | --- | --- |
| Backend | Node.js 24 + Express 4 | Fixed-payload API endpoint | [Backend](backend.md) |
| Caddy | Caddy 2.11.4 | TLS termination, protocol isolation | [Caddy](caddy.md) |
| docker-tc | Python 3 + tc netem | Symmetric network emulation | [docker-tc](docker-tc.md) |
| h2load | nghttp2 1.70 | Load generation (HTTP/1.1, 2, 3) | [h2load](h2load.md) |
| Monitoring | Prometheus + Grafana + cAdvisor | Metrics collection & visualization | [Monitoring](monitoring.md) |
