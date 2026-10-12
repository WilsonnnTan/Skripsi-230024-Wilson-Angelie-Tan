# Architecture

The testbed consists of the following components:

- **h2load (×10)**: Load generators (nghttp2's `h2load`, one image built with HTTP/3) that simulate clients for HTTP/1.1, HTTP/2, and HTTP/3. Each run launches 10 containers (0.25 vCPU each) that together keep ~60 requests in flight.
- **Caddy**: The edge proxy that handles TLS and the 3 HTTP protocols on different ports (8443, 8444, 8445).
- **Backend (Express)**: A simple Node.js API that returns a fixed 8192-byte JSON payload.
- **docker-tc**: Emulates network conditions (delay, jitter, loss, rate) on **each loader's** edge interface, **symmetrically** (egress netem + ingress via an `ifb` mirror) so every h2load container experiences a full per-client link.
- **h2load-exporter**: Tails the loaders' per-request logs and exposes rolling client-side metrics for Prometheus to scrape (h2load cannot remote-write like k6 did).
- **Monitoring (Prometheus + Grafana + cAdvisor)**: Collects and visualizes server resource usage (cAdvisor) and live client metrics (h2load-exporter).

### Request Flow
`h2load ×10` (per-client network emulated) --> `Caddy` --> `Backend`
