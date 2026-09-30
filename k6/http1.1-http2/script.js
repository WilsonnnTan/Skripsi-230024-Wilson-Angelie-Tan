// =============================================================================
// k6 load-test script — HTTP/1.1 and HTTP/2, N CONCURRENT requests per VU.
// =============================================================================
// Each VU iteration fires CONCURRENCY requests at once via http.batch() and
// waits for all of them. Env vars: TARGET_URL, PROTOCOL_LABEL, SCENARIO,
// REPETITION, SUMMARY_PATH, and optionally CONCURRENCY (default 10).
//
// NOTE: k6 defaults to batchPerHost=6, which would silently cap concurrency at
// 6 requests to the single Caddy host. We raise both `batch` and `batchPerHost`.
//
// Connection behaviour (per VU, connections are never shared across VUs):
//   HTTP/1.1: each in-flight request needs its own TCP+TLS connection, so up
//             to CONCURRENCY connections per VU.
//   HTTP/2  : requests should multiplex as streams over one connection. The
//             very first batch may race and open a few extra connections
//             before the pool settles; sustained phase is unaffected.
// =============================================================================

import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

// ---- Environment ----------------------------------------------------------
const TARGET_URL = __ENV.TARGET_URL;
const PROTOCOL = (__ENV.PROTOCOL_LABEL || 'unknown').toLowerCase();
const SCENARIO = __ENV.SCENARIO || 'S0';
const REPETITION = __ENV.REPETITION || '0';
const SUMMARY_PATH = __ENV.SUMMARY_PATH || '/results/raw/summary.json';
const CONCURRENCY = parseInt(__ENV.CONCURRENCY || '3', 10);

if (!TARGET_URL) {
  throw new Error('TARGET_URL environment variable is required');
}

// ---- Phase boundaries (seconds); MUST match the stages below --------------
const WARMUP_S = 10;
const SUSTAINED_S = 60;
const SUSTAINED_END_S = WARMUP_S + SUSTAINED_S; // 70 s

const PROTO_TOKEN = { 'http1.1': '1.1', 'http2': '2' }[PROTOCOL] || '';

// ---- Custom metrics -------------------------------------------------------
const reqDurationMs = new Trend('req_duration_ms', true);
const reqs = new Counter('reqs');
const reqErrors = new Rate('req_errors');
const respBytes = new Counter('resp_bytes');
const protoMismatch = new Counter('proto_mismatch');

// ---- k6 options -----------------------------------------------------------
export const options = {
  scenarios: {
    [SCENARIO]: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: `${WARMUP_S}s`, target: 20 },
        { duration: `${SUSTAINED_S}s`, target: 20 },
        { duration: `${WARMUP_S}s`, target: 0 },
      ],
      gracefulRampDown: '2s',
    },
  },
  tags: {
    protocol: PROTOCOL,
    net_scenario: SCENARIO,
    repetition: String(REPETITION),
    concurrency: String(CONCURRENCY),
  },
  thresholds: {
    'req_duration_ms{phase:warmup}': ['p(99)>=0'],
    'req_duration_ms{phase:sustained}': ['p(99)>=0'],
    'req_duration_ms{phase:cooldown}': ['p(99)>=0'],
    'reqs{phase:warmup}': ['count>=0'],
    'reqs{phase:sustained}': ['count>=0'],
    'reqs{phase:cooldown}': ['count>=0'],
    'req_errors{phase:warmup}': ['rate>=0'],
    'req_errors{phase:sustained}': ['rate>=0'],
    'req_errors{phase:cooldown}': ['rate>=0'],
  },
  insecureSkipTLSVerify: true,
  noConnectionReuse: false,
  discardResponseBodies: false,
  // Allow all CONCURRENCY requests of a batch to run in parallel to one host.
  batch: CONCURRENCY,
  batchPerHost: CONCURRENCY,
  summaryTrendStats: ['avg', 'min', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'count'],
};

export function setup() {
  return { testStart: Date.now() };
}

function resolveStart(data) {
  try {
    const st = exec.scenario && exec.scenario.startTime;
    if (st) {
      const t = st instanceof Date ? st.getTime() : new Date(st).getTime();
      if (!isNaN(t)) return t;
    }
  } catch (e) {
    // ignore -> fallback
  }
  return data.testStart;
}

function phaseFor(elapsedS) {
  if (elapsedS < WARMUP_S) return 'warmup';
  if (elapsedS < SUSTAINED_END_S) return 'sustained';
  return 'cooldown';
}

// Record one request's outcome into the custom metrics.
function record(tags, ok, durationMs, bodyLen, proto) {
  if (PROTO_TOKEN && proto.indexOf(PROTO_TOKEN) === -1) {
    protoMismatch.add(1, tags);
  }
  reqs.add(1, tags);
  reqErrors.add(ok ? 0 : 1, tags);
  if (durationMs > 0) reqDurationMs.add(durationMs, tags);
  if (bodyLen > 0) respBytes.add(bodyLen, tags);
}

// ---- main VU loop: CONCURRENCY parallel requests per iteration ------------
export default function (data) {
  const elapsedS = (Date.now() - resolveStart(data)) / 1000;
  const tags = { phase: phaseFor(elapsedS) };

  const batchReqs = [];
  for (let i = 0; i < CONCURRENCY; i++) {
    batchReqs.push(['GET', TARGET_URL, null, { tags: tags, timeout: '30s' }]);
  }

  let responses = null;
  try {
    responses = http.batch(batchReqs);
  } catch (e) {
    // Whole batch failed: count every request as an error.
    for (let i = 0; i < CONCURRENCY; i++) record(tags, false, 0, 0, '');
    return;
  }

  for (let i = 0; i < responses.length; i++) {
    const resp = responses[i];
    const status = typeof resp.status === 'number' ? resp.status : 0;
    const bodyLen = resp.body ? resp.body.length : 0;
    const proto = resp.proto || '';
    const durationMs =
      resp.timings && typeof resp.timings.duration === 'number' ? resp.timings.duration : 0;
    const ok = status >= 200 && status < 400 && bodyLen > 0;

    check(resp, {
      'status is 2xx/3xx': () => ok,
      'body is non-empty': () => bodyLen > 0,
    });

    record(tags, ok, durationMs, bodyLen, proto);
  }
}

// ---- per-run summary ------------------------------------------------------
function statOf(data, metric, stat) {
  const m = data.metrics[metric];
  if (m && m.values && typeof m.values[stat] === 'number') return m.values[stat];
  return NaN;
}

export function handleSummary(data) {
  const dur = 'req_duration_ms{phase:sustained}';
  const p95 = statOf(data, dur, 'p(95)');
  const rps = statOf(data, 'reqs{phase:sustained}', 'count') / SUSTAINED_S;
  const errRate = statOf(data, 'req_errors{phase:sustained}', 'rate') * 100;
  const mism = statOf(data, 'proto_mismatch', 'count');

  const line = `[k6] ${PROTOCOL}/${SCENARIO}/rep${REPETITION} c=${CONCURRENCY} sustained: `
    + `rps=${isNaN(rps) ? 'NaN' : rps.toFixed(1)} `
    + `p95=${isNaN(p95) ? 'NaN' : p95.toFixed(2)}ms `
    + `err=${isNaN(errRate) ? 'NaN' : errRate.toFixed(2)}% `
    + `proto_mismatch=${isNaN(mism) ? 0 : mism}\n`;

  const out = {};
  out[SUMMARY_PATH] = JSON.stringify(data, null, 2);
  out.stdout = line;
  return out;
}