// =============================================================================
// k6 load-test script — HTTP/1.1 vs HTTP/2 vs HTTP/3 thesis testbed.
// =============================================================================
// One script drives ALL 3 protocols x 5 scenarios x 10 repetitions. Everything
// is parameterised through environment variables (see run_experiments.sh):
//
//   TARGET_URL       e.g. https://caddy:8443/api/data
//   PROTOCOL_LABEL   "http1.1" | "http2" | "http3"
//   SCENARIO         "S1".."S5"  (also becomes the k6 scenario name -> tag)
//   REPETITION       "1".."10"
//   SUMMARY_PATH     where handleSummary() writes the per-run JSON
//
// Load profile (methodology): 0->20 VUs / 10 s, hold 20 VUs / 60 s,
// 20->0 VUs / 10 s. Every request is tagged with its phase so only the
// steady-state (sustained) window is used for the reported numbers.
//
// HTTP/3 comes from the xk6-http3 extension. Its response object EMBEDS k6's
// standard httpext.Response, so `resp.status`, `resp.body`, `resp.proto` and
// `resp.timings.duration` are the SAME fields as the built-in http client —
// which is why h1/h2/h3 share ONE code path and ONE set of metrics.
// =============================================================================

import http from 'k6/http';
import http3 from 'k6/x/http3';
import exec from 'k6/execution';
import { check } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

// ---- Environment ----------------------------------------------------------
const TARGET_URL = __ENV.TARGET_URL;
const PROTOCOL = (__ENV.PROTOCOL_LABEL || 'unknown').toLowerCase();
const SCENARIO = __ENV.SCENARIO || 'S0';
const REPETITION = __ENV.REPETITION || '0';
const SUMMARY_PATH = __ENV.SUMMARY_PATH || '/results/raw/summary.json';

if (!TARGET_URL) {
  throw new Error('TARGET_URL environment variable is required');
}

// ---- Phase boundaries (seconds); MUST match the stages below --------------
const WARMUP_S = 10;
const SUSTAINED_S = 60;
const SUSTAINED_END_S = WARMUP_S + SUSTAINED_S; // 70 s

// Expected token in resp.proto ("HTTP/1.1", "HTTP/2.0", "HTTP/3.0"), used only
// to sanity-check that ALPN negotiated the protocol we intended to test.
const PROTO_TOKEN = { 'http1.1': '1.1', 'http2': '2', 'http3': '3' }[PROTOCOL] || '';

// ---- Custom metrics (identical for all three protocols) -------------------
// Tagged with `phase` so the live dashboard can show every phase, while the
// thresholds below and the export isolate the sustained window.
const reqDurationMs = new Trend('req_duration_ms', true); // native resp timing
const reqs = new Counter('reqs');
const reqErrors = new Rate('req_errors');
const respBytes = new Counter('resp_bytes');
// Protocol-negotiation sanity: must stay 0 for h1/h2. Inspect it for h3.
const protoMismatch = new Counter('proto_mismatch');

// ---- k6 options -----------------------------------------------------------
export const options = {
  scenarios: {
    // Naming the scenario "S1".."S5" makes k6's reserved `scenario` tag equal
    // to the network scenario automatically.
    [SCENARIO]: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: `${WARMUP_S}s`, target: 20 },   // warm-up
        { duration: `${SUSTAINED_S}s`, target: 20 }, // sustained
        { duration: `${WARMUP_S}s`, target: 0 },     // cool-down
      ],
      gracefulRampDown: '2s',
    },
  },
  // Test-wide tags on EVERY metric. `scenario` is filled by k6 from the name.
  tags: {
    protocol: PROTOCOL,
    net_scenario: SCENARIO,
    repetition: String(REPETITION),
  },
  // These thresholds never fail (the expressions are trivially true). Their
  // ONLY purpose is to make k6 emit EXACT sustained-phase sub-metrics
  // (e.g. "req_duration_ms{phase:sustained}") into the handleSummary() data,
  // giving true whole-window percentiles instead of averaged per-interval ones.
  thresholds: {
    'req_duration_ms{phase:sustained}': ['p(99)>=0'],
    'reqs{phase:sustained}': ['count>=0'],
    'req_errors{phase:sustained}': ['rate>=0'],
  },
  // Closed testbed: Caddy uses its internal CA (applies to the h3 client too).
  insecureSkipTLSVerify: true,
  // Multiplexing / connection reuse is part of what we measure.
  noConnectionReuse: false,
  // Body length is validated, so bodies must not be discarded.
  discardResponseBodies: false,
  // p(50) == med, so `med` is dropped to avoid a duplicate column.
  summaryTrendStats: ['avg', 'min', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'count'],
};

// ---- setup: capture wall-clock start for phase bucketing ------------------
export function setup() {
  return { testStart: Date.now() };
}

// Resolve the scenario start time (shared by all VUs); fall back to setup().
// Millisecond resolution is fine here: it only decides the 10 s phase buckets,
// NOT the latency measurement (which uses resp.timings.duration below).
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

// ---- main VU loop ---------------------------------------------------------
export default function (data) {
  const elapsedS = (Date.now() - resolveStart(data)) / 1000;
  const tags = { phase: phaseFor(elapsedS) };

  let status = 0;
  let bodyLen = 0;
  let durationMs = 0;
  let proto = '';
  let ok = false;

  try {
    // Both clients return a k6 httpext.Response (see header), so the fields
    // are read identically. http3.get() takes the URL only.
    const resp = PROTOCOL === 'http3'
      ? http3.get(TARGET_URL)
      : http.get(TARGET_URL, { tags: tags, timeout: '30s' });

    status = typeof resp.status === 'number' ? resp.status : 0;
    bodyLen = resp.body ? resp.body.length : 0;
    proto = resp.proto || '';
    if (resp.timings && typeof resp.timings.duration === 'number') {
      durationMs = resp.timings.duration;
    }
    ok = status >= 200 && status < 400 && bodyLen > 0;

    check(resp, {
      'status is 2xx/3xx': () => ok,
      'body is non-empty': () => bodyLen > 0,
    });
  } catch (e) {
    // Network-level failure (timeout, reset, refused): an error, and no timing
    // is recorded for a request that never completed.
    ok = false;
    status = 0;
  }

  // Protocol-negotiation sanity check — does NOT affect the error rate.
  if (PROTO_TOKEN && proto.indexOf(PROTO_TOKEN) === -1) {
    protoMismatch.add(1, tags);
  }

  reqs.add(1, tags);
  reqErrors.add(ok ? 0 : 1, tags);
  if (durationMs > 0) {
    reqDurationMs.add(durationMs, tags);
  }
  if (bodyLen > 0) {
    respBytes.add(bodyLen, tags);
  }
}

// ---- per-run summary: exact sustained numbers written to JSON -------------
// We write handleSummary() output ourselves (instead of the deprecated
// --summary-export flag) so the format is stable and always contains the
// sustained sub-metrics. export_results.sh reads client metrics straight from
// this file; Prometheus/Grafana are only for live monitoring.
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

  const line = `[k6] ${PROTOCOL}/${SCENARIO}/rep${REPETITION} sustained: `
    + `rps=${isNaN(rps) ? 'NaN' : rps.toFixed(1)} `
    + `p95=${isNaN(p95) ? 'NaN' : p95.toFixed(2)}ms `
    + `err=${isNaN(errRate) ? 'NaN' : errRate.toFixed(2)}% `
    + `proto_mismatch=${isNaN(mism) ? 0 : mism}\n`;

  const out = {};
  out[SUMMARY_PATH] = JSON.stringify(data, null, 2);
  out.stdout = line;
  return out;
}
