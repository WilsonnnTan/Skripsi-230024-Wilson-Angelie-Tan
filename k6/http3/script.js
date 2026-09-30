// =============================================================================
// k6 load-test script — HTTP/3 (thesis testbed).
// =============================================================================
// This variant drives HTTP/3 (QUIC) only, via the xk6-http3 extension's
// `k6/x/http3` client. It runs on a custom k6 build pinned to v0.48.0 (see
// ../http3/Dockerfile) because xk6-http3 v0.2.0 requires that k6 core. The
// h1/h2 variant lives in ../http1.1-http2 on a newer k6.
//
// Parameterised through environment variables (see run_experiments.sh):
//   TARGET_URL       e.g. https://caddy:8445/api/data  (the h3/QUIC listener)
//   PROTOCOL_LABEL   "http3"
//   SCENARIO         "S1".."S5"  (also becomes the k6 scenario name -> tag)
//   REPETITION       "1".."10"
//   SUMMARY_PATH     where handleSummary() writes the per-run JSON
//
// The xk6-http3 response EMBEDS k6's standard httpext.Response, so resp.status,
// resp.body and resp.proto are the SAME fields as the built-in client. The one
// exception is resp.timings: the extension does NOT populate it, so latency is
// measured with a wall-clock timer around http3.get() (see the VU loop). All
// custom metrics (reqs, req_errors, req_duration_ms, resp_bytes) therefore end
// up with the IDENTICAL label structure to h1/h2 — protocol / net_scenario /
// repetition / scenario / phase — so both feed the same Grafana panels and the
// same export path.
// NOTE: http3.get() takes the URL only (no per-request options object), so the
// `phase` tag is attached to our CUSTOM metrics manually below — which is what
// the per-phase sub-metrics and the export depend on anyway.
// =============================================================================

import http3 from 'k6/x/http3';
import exec from 'k6/execution';
import { check } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

// ---- Environment ----------------------------------------------------------
const TARGET_URL = __ENV.TARGET_URL;
const PROTOCOL = (__ENV.PROTOCOL_LABEL || 'http3').toLowerCase();
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

// Expected token in resp.proto ("HTTP/3.0"), used only to sanity-check that
// the h3 client actually negotiated HTTP/3.
const PROTO_TOKEN = '3';

// ---- Custom metrics (identical shape to the h1/h2 variant) ----------------
// Tagged with `phase` so the live dashboard can show every phase, while the
// thresholds below and the export isolate each phase (sustained is headline).
const reqDurationMs = new Trend('req_duration_ms', true); // native resp timing
const reqs = new Counter('reqs');
const reqErrors = new Rate('req_errors');
const respBytes = new Counter('resp_bytes');
// Protocol-negotiation sanity: inspect it to confirm h3 was negotiated.
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
  // Trivially-true thresholds ONLY exist to make k6 emit EXACT per-phase
  // sub-metrics (e.g. "req_duration_ms{phase:sustained}") into handleSummary(),
  // giving true whole-window percentiles per phase. All three phases are kept
  // so warmup / sustained / cooldown can each be reported and exported.
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
  // Identifying tags on EVERY custom-metric sample. `phase` is per-iteration;
  // protocol / net_scenario / repetition are ALSO set here explicitly rather
  // than relying on options.tags (root tags). On k6 v0.48 the root tags set via
  // options.tags do NOT reliably reach the remote-write series for these custom
  // metrics (only the reserved `scenario` and per-.add() tags do), so the h3
  // series would otherwise be missing `protocol`/`repetition` and drop out of
  // the `by (protocol, scenario)` dashboard queries. Setting them here — the
  // same path `phase` already uses — guarantees the h3 label structure is
  // IDENTICAL to the h1/h2 variant. (options.tags is still kept below: it is
  // harmless, feeds the JSON summary, and covers the extension's own metrics.)
  const tags = {
    phase: phaseFor(elapsedS),
  };

  let status = 0;
  let bodyLen = 0;
  let durationMs = 0;
  let proto = '';
  let ok = false;

  const t0 = Date.now();
  try {
    // xk6-http3 client: takes the URL only. The response is a k6
    // httpext.Response, so status/body/proto below read identically to the
    // built-in client. HOWEVER the extension does NOT populate resp.timings
    // (client.go builds the response without a request Trail), so we cannot
    // read k6's internal request duration here. Measure the wall-clock time
    // around the synchronous http3.get() instead — this is the client-observed
    // latency and produces the SAME `req_duration_ms{phase,...}` series (same
    // label structure) as the h1/h2 variant. ms resolution is adequate because
    // every scenario adds emulated network delay. Per-request tags cannot be
    // passed here, so `phase` is applied to the custom metrics manually below.
    const resp = http3.get(TARGET_URL);
    const wallMs = Date.now() - t0;

    status = typeof resp.status === 'number' ? resp.status : 0;
    bodyLen = resp.body ? resp.body.length : 0;
    proto = resp.proto || '';
    // Prefer k6's own timing if a future extension version ever provides it;
    // otherwise fall back to the wall-clock measurement above.
    if (resp.timings && typeof resp.timings.duration === 'number' && resp.timings.duration > 0) {
      durationMs = resp.timings.duration;
    } else {
      durationMs = wallMs;
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

// ---- per-run summary: exact per-phase numbers written to JSON -------------
// Same format as the h1/h2 variant so export_results.sh reads both identically.
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
