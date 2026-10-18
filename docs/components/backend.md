# Backend (Express API)

The backend is the **application under test** — a minimal Node.js Express server that serves a fixed-size JSON payload. It is intentionally simple: no database, no file I/O, no randomness. This ensures that **application processing time is constant** and the transport protocol is the only variable across experiments.

## Endpoint

| Method | Path | Response |
| --- | --- | --- |
| `GET` | `/api/data` | Fixed 8,192-byte JSON payload |
| `GET` | `/health` | `{"status":"ok","payloadBytes":8192}` |

## Payload Design

The response body is a JSON document containing 8 sensor telemetry items, padded to exactly **8,192 bytes** (8 KiB):

```json
{
  "meta": {
    "resource": "telemetry-items",
    "version": "1.0.0",
    "count": 8,
    "padding": "xxxxxx..."
  },
  "items": [
    {
      "id": 1,
      "name": "Sensor-0001",
      "category": "telemetry",
      "status": "active",
      "value": 21.25,
      "unit": "celsius",
      "recordedAt": "2026-01-01T00:01:00.000Z",
      "location": { "lat": -6.2088, "lon": 106.8456 },
      "tags": ["alpha", "beta", "gamma"],
      "readings": [1.0, 2.0, 3.0, 4.0, 5.0]
    }
    // ... 7 more items
  ]
}
```

### Why 8 KiB?

- **Larger than one TCP segment** (MSS ≈ 1,460 bytes) and one QUIC datagram (~1,200 bytes), so each response spans multiple packets. This makes multiplexing and head-of-line-blocking differences between protocols observable.
- **Small enough not to saturate** the slowest scenarios (S4 = 1.6 Mbps), so results reflect protocol behavior, not link bandwidth limits.

## Anti-Caching

The backend explicitly disables response caching to ensure every request is measured:

- `Cache-Control: no-store` on every response
- `etag: false` in Express settings (prevents 304 Not Modified)
- `x-powered-by` header disabled

## Dockerfile

```dockerfile
FROM node:24

ENV NODE_ENV=production PORT=3000

WORKDIR /app
RUN corepack enable && corepack prepare pnpm@11 --activate

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile

COPY src ./src
EXPOSE 3000
USER node
CMD ["node", "src/server.js"]
```

## Key Design Decisions

| Decision | Rationale |
| --- | --- |
| Fixed payload built at startup | Eliminates per-request JSON serialization variance |
| No middleware (no logging, no CORS) | Minimizes server-side processing noise |
| Single endpoint | Keeps the application layer as thin as possible |
| `node:24` base image | Latest Node.js LTS for consistent V8 behavior |
