'use strict';

/**
 * Application under test: one static endpoint, GET /api/data, that always
 * returns the same fixed-size JSON body. No database, no I/O and no
 * randomness, so application time is constant and the transport protocol is
 * the only variable across the experiment.
 */

const express = require('express');

const PORT = Number(process.env.PORT ?? 3000);
const HOST = '0.0.0.0';
const ITEM_COUNT = 8;

// Why a fixed 8192-byte (8 KiB) body?
// The body size must be constant so only the transport protocol varies between
// runs (Proposal section 3.3.2). 8 KiB is a middle ground:
//   - larger than one TCP segment (MSS ~1460 B) and one QUIC datagram
//     (~1200 B), so each response spans several packets and the multiplexing /
//     head-of-line-blocking differences between HTTP/1.1, HTTP/2 and HTTP/3
//     become observable;
//   - small enough not to saturate the slow scenarios (S4 = 1.6 Mbps,
//     S5 = 10 Mbps), so results reflect protocol behaviour, not link bandwidth.
const PAYLOAD_BYTES = 8192;

// Build the telemetry document once, then pad it to exactly PAYLOAD_BYTES.
function buildPayload() {
  const items = Array.from({ length: ITEM_COUNT }, (_, index) => {
    const id = index + 1;
    return {
      id,
      name: `Sensor-${String(id).padStart(4, '0')}`,
      category: 'telemetry',
      status: 'active',
      value: Number((20 + id * 1.25).toFixed(2)),
      unit: 'celsius',
      recordedAt: `2026-01-01T00:${String(id).padStart(2, '0')}:00.000Z`,
      location: { lat: -6.2088, lon: 106.8456 },
      tags: ['alpha', 'beta', 'gamma'],
      readings: [1.0, 2.0, 3.0, 4.0, 5.0],
    };
  });

  const payload = {
    meta: { resource: 'telemetry-items', version: '1.0.0', count: ITEM_COUNT, padding: '' },
    items,
  };

  const padded = JSON.stringify(payload);
  const missing = PAYLOAD_BYTES - Buffer.byteLength(padded, 'utf8');
  if (missing < 0) throw new Error(`payload exceeds ${PAYLOAD_BYTES} bytes`);
  if (missing === 0) return padded;

  payload.meta.padding = 'x'.repeat(missing);
  return JSON.stringify(payload);
}

const PAYLOAD = buildPayload();
const PAYLOAD_SIZE = Buffer.byteLength(PAYLOAD, 'utf8');

const app = express();

// Disable etag so responses never become 304s, keeping success/error counts stable.
app.disable('x-powered-by');
app.set('etag', false);

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', payloadBytes: PAYLOAD_SIZE });
});

app.get('/api/data', (_req, res) => {
  res.set('Content-Type', 'application/json; charset=utf-8');
  res.set('Cache-Control', 'no-store');
  res.send(PAYLOAD);
});

app.use((_req, res) => {
  res.status(404).json({ error: 'not_found' });
});

app.listen(PORT, HOST, () => {
  console.log(`[backend] listening on http://${HOST}:${PORT} | payloadBytes=${PAYLOAD_SIZE} items=${ITEM_COUNT}`);
});
