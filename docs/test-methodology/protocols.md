# HTTP Protocols

The testbed measures all three major HTTP protocol versions using a single tool — `h2load` from nghttp2, compiled with HTTP/3 support.

## Protocol Comparison

```mermaid
graph LR
    subgraph h11["HTTP/1.1"]
        direction TB
        T1["TCP"]
        TLS1["TLS 1.3"]
        H1["HTTP/1.1"]
        T1 --> TLS1 --> H1
    end
    
    subgraph h2["HTTP/2"]
        direction TB
        T2["TCP"]
        TLS2["TLS 1.3"]
        H2M["HTTP/2\n(multiplexed)"]
        T2 --> TLS2 --> H2M
    end
    
    subgraph h3["HTTP/3"]
        direction TB
        Q["QUIC\n(UDP + TLS 1.3)"]
        H3M["HTTP/3\n(multiplexed)"]
        Q --> H3M
    end

    style h11 fill:#ffebee,stroke:#c62828
    style h2 fill:#e3f2fd,stroke:#1565c0
    style h3 fill:#e8f5e9,stroke:#2e7d32
```

| Feature | HTTP/1.1 | HTTP/2 | HTTP/3 |
| --- | --- | --- | --- |
| **Transport** | TCP | TCP | QUIC (UDP) |
| **TLS** | Separate (TLS 1.3) | Separate (TLS 1.3) | Integrated in QUIC |
| **Multiplexing** | ❌ No (1 request per connection) | ✅ Yes (stream-level) | ✅ Yes (stream-level) |
| **Head-of-line blocking** | ❌ Connection-level | ❌ TCP-level (across streams) | ✅ Stream-level only |
| **Connection setup** | TCP handshake + TLS handshake | TCP + TLS + SETTINGS | 0-RTT or 1-RTT |
| **Congestion control** | TCP (kernel) | TCP (kernel) | QUIC (user-space) |

## Port Isolation

Caddy serves each protocol on a dedicated port to prevent ALPN ambiguity:

```mermaid
graph LR
    h2load_11["h2load\n--alpn-list=http/1.1"] -->|":8443 TCP"| C1["Caddy\nservers :8443\nprotocols h1"]
    h2load_2["h2load\n--alpn-list=h2"] -->|":8444 TCP"| C2["Caddy\nservers :8444\nprotocols h2"]
    h2load_3["h2load\n--h3"] -->|":8445 UDP"| C3["Caddy\nservers :8445\nprotocols h3"]
    
    C1 & C2 & C3 -->|"plain HTTP"| B["Backend :3000"]
    
    style C1 fill:#ffebee,stroke:#c62828
    style C2 fill:#e3f2fd,stroke:#1565c0
    style C3 fill:#e8f5e9,stroke:#2e7d32
```

| Protocol | Caddy Port | Transport | h2load Flag |
| --- | --- | --- | --- |
| HTTP/1.1 | `:8443` | TCP | `--alpn-list=http/1.1` |
| HTTP/2 | `:8444` | TCP | `--alpn-list=h2` |
| HTTP/3 | `:8445` | QUIC/UDP | `--h3` |

## Caddyfile Configuration

```caddy
{
    servers :8443 {
        protocols h1
    }
    servers :8444 {
        protocols h2
    }
    servers :8445 {
        protocols h3
    }
}

(tls13) {
    tls internal {
        protocols tls1.3
    }
}

caddy:8443 {
    import tls13
    reverse_proxy backend:3000
}

caddy:8444 {
    import tls13
    reverse_proxy backend:3000
}

caddy:8445 {
    import tls13
    reverse_proxy backend:3000
}
```

All three listeners use `tls internal` (Caddy's built-in CA) with TLS 1.3, and all reverse-proxy to the same backend over plain HTTP internally.

## h2load Build Chain

The h2load binary is compiled from source with HTTP/3 support via a multi-stage Docker build:

```mermaid
flowchart LR
    A["nghttp3 v1.18.0\n(HTTP/3 framing)"] --> C["nghttp2 v1.70.0\n+ h2load binary"]
    B["ngtcp2 v1.25.0\n(QUIC transport)\n+ OpenSSL 3.5"] --> C
    C --> D["Runtime image\n(debian:trixie-slim)"]

    style A fill:#e8f5e9
    style B fill:#e3f2fd
    style C fill:#fff3e0
    style D fill:#f3e5f5
```

{% hint style="info" %}
**Why build from source?** The nghttp2 package in most distro repositories does not include HTTP/3 support. Building from source with `--enable-http3` and linking against ngtcp2 + nghttp3 is the only way to get all three protocols in a single `h2load` binary.
{% endhint %}

## Load Parameters

| Parameter | Value | Notes |
| --- | --- | --- |
| Connections (`-c`) | 1 per container | 10 total (10 containers) |
| Streams (`-m`) | 6 | HTTP/1.1 ignores this (1 stream per connection) |
| Threads (`-t`) | 1 | One thread per container |
| Duration (`--duration`) | 80 seconds | Covers all three phases |
