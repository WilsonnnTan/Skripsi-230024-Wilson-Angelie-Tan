// =============================================================================
// k6 load-test script — HTTP/3 (xk6-http3, k6 v0.48.0), N CONCURRENT requests
// per VU.
// =============================================================================
// k6 JS is single-threaded per VU, so true concurrency needs an async or batch
// API from the extension. issueConcurrent() below is the ONLY place that
// touches the extension and tries, in order:
//   1. http3.batch(urls)            -> array of responses   (wall time of the
//                                      whole batch is recorded per request)
//   2. http3.asyncRequest('GET', u) -> Promise + Promise.all (per-request
//                                      wall time)
// If neither exists it throws at the first iteration with a clear message
// instead of silently falling back to sequential requests (which would break
// the "10 concurrent" design). I could not verify the xk6-http3 v0.2.0 API,
// so check the extension source / `console.log(Object.keys(http3))` and adjust
// issueConcurrent() if the names or signatures differ.
//
// Env vars: TARGET_URL, PROTOCOL_LABEL, SCENARIO, REPETITION, SUMMARY_PATH,
// and optionally CONCURRENCY (default 10).
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
const CONCURRENCY = parseInt(__ENV.CONCURRENCY || '3', 10);

if (!TARGET_URL) {
  throw new Error('TARGET_URL environment variable is required');
}

// ---- Phase boundaries (seconds); MUST match the stages below --------------
const WARMUP_S = 10;
const SUSTAINED_S = 60;
const SUSTAINED_END_S = WARMUP_S + SUSTAINED_S; // 70 s

const PROTO_TOKEN = '3';

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

// ---- The only extension-specific code: issue CONCURRENCY requests at once.
// Returns an array of { resp, wallMs, error } of length CONCURRENCY.
async function issueConcurrent() {
  if (typeof http3.batch === 'function') {
    const t0 = Date.now();
    const urls = [];
    for (let i = 0; i < CONCURRENCY; i++) urls.push(TARGET_URL);
    let resps;
    try {
      resps = await http3.batch(urls);
    } catch (e) {
      return urls.map(() => ({ resp: null, wallMs: 0, error: e }));
    }
    const wallMs = Date.now() - t0; // whole-batch time (no per-request timing)
    return resps.map((r) => ({ resp: r, wallMs: wallMs, error: null }));
  }

  if (typeof http3.asyncRequest === 'function') {
    const jobs = [];
    for (let i = 0; i < CONCURRENCY; i++) {
      const t0 = Date.now();
      jobs.push(
        http3.asyncRequest('GET', TARGET_URL).then(
          (r) => ({ resp: r, wallMs: Date.now() - t0, error: null }),
          (e) => ({ resp: null, wallMs: 0, error: e })
        )
      );
    }
    return Promise.all(jobs);
  }

  throw new Error(
    'xk6-http3 exposes neither batch() nor asyncRequest(); cannot run concurrent '
    + 'requests per VU. Available: ' + Object.keys(http3).join(', ')
  );
}

function record(tags, ok, durationMs, bodyLen, proto) {
  if (PROTO_TOKEN && proto.indexOf(PROTO_TOKEN) === -1) {
    protoMismatch.add(1, tags);
  }
  reqs.add(1, tags);
  reqErrors.add(ok ? 0 : 1, tags);
  if (durationMs > 0) reqDurationMs.add(durationMs, tags);
  if (bodyLen > 0) respBytes.add(bodyLen, tags);
}

// ---- main VU loop ---------------------------------------------------------
export default async function (data) {
  const elapsedS = (Date.now() - resolveStart(data)) / 1000;
  // Explicit tags on every custom-metric sample (see note in the original
  // script about options.tags not reaching remote-write on k6 v0.48).
  const tags = { phase: phaseFor(elapsedS) };

  const results = await issueConcurrent();

  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    if (r.error || !r.resp) {
      record(tags, false, 0, 0, '');
      continue;
    }
    const resp = r.resp;
    const status = typeof resp.status === 'number' ? resp.status : 0;
    const bodyLen = resp.body ? resp.body.length : 0;
    const proto = resp.proto || '';
    const durationMs =
      resp.timings && typeof resp.timings.duration === 'number' && resp.timings.duration > 0
        ? resp.timings.duration
        : r.wallMs;
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