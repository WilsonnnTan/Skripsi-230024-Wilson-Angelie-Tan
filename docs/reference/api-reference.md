# docker-tc REST API Reference

`docker-tc` provides a programmatic HTTP REST interface on port `4000` to manipulate network queuing disciplines on the fly.

## Endpoints

### 1. `POST /apply`

Injects network constraints into target container interfaces.

#### Request Headers
`Content-Type: application/json`

#### Request Body
```json
{
  "target": "edge_net",
  "delay": "40ms",
  "jitter": "2ms",
  "loss": "1%",
  "rate": "50mbit"
}
```

#### Parameters

| Field | Type | Required | Description | Example |
| --- | --- | --- | --- | --- |
| `target` | string | Yes | Network name or container name prefix | `"edge_net"` |
| `delay` | string | No | One-way propagation delay injected via netem | `"40ms"` |
| `jitter` | string | No | Delay standard deviation variation | `"2ms"` |
| `loss` | string | No | Independent packet loss probability | `"1%"` |
| `rate` | string | No | Bandwidth cap enforced via Token Bucket Filter | `"50mbit"` |

#### Response (`200 OK`)
```json
{
  "status": "success",
  "applied": {
    "interfaces": ["veth0a1", "veth0b2"],
    "rules": "delay 40ms 2ms loss 1% rate 50mbit"
  }
}
```

---

### 2. `POST /reset`

Deletes all active qdisc rules, returning interfaces to the default `pfifo_fast` or `fq_codel` disciplines.

#### Response (`200 OK`)
```json
{
  "status": "success",
  "message": "All qdiscs flushed"
}
```

---

### 3. `GET /status`

Inspects current active qdiscs and packet statistics.

#### Response (`200 OK`)
```json
{
  "interfaces": {
    "eth0": {
      "qdisc": "netem",
      "delay": "40ms",
      "loss": "1%"
    }
  }
}
```
