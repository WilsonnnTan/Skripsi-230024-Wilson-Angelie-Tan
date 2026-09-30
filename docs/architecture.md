# Architecture

The testbed consists of the following components:

- **k6**: Load generator used to simulate clients for HTTP/1.1, HTTP/2, and HTTP/3.
- **Caddy**: The edge proxy that handles TLS and the 3 HTTP protocols on different ports (8443, 8444, 8445).
- **Backend (Express)**: A simple Node.js API that returns a fixed 8192-byte JSON payload.
- **docker-tc**: Emulates network conditions (delay, jitter, loss) on Caddy's network interface.
- **Monitoring (Prometheus + Grafana + cAdvisor)**: Collects and visualizes server resource usage and test metrics.

### Request Flow
`k6` --> `Caddy` (Network emulated) --> `Backend`
