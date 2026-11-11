// k6 load profile for walkthrough 12: public reads of the catalog, ramped up until the HPA has to act.
//
//   run through scripts/load-test.sh (it runs k6 in a pinned container and watches the cluster)
//
// WHY THESE REQUESTS. GET /catalog/v1/events (list) and one event are public, need no token and exercise
// the whole path: WAF -> ALB -> catalog pod -> Valkey cache (hit) or PostgreSQL (miss) -> JSON. They burn
// CPU in the catalog pods, which is what the HPA watches (target 70% of the 100m request).
// WHY ARRIVAL RATE. `ramping-arrival-rate` fixes how many requests per second ARRIVE, whatever the
// latency: when the service slows down, k6 does not slow down with it (a closed "N users" model would
// hide the overload). Stages: 1 min warm-up, ramp to the peak in 1 min, hold the peak for 4 min (long
// enough for the HPA to add pods and Karpenter to add a node), 1 min down.
// THE WAF: the web ACL blocks one IP above `waf_rate_limit` requests per 5 minutes (default 1000). A
// load test from one machine needs `TF_VAR_waf_rate_limit=200000 make up` on the load-test day; without
// it k6 reports 403s (thresholds fail on purpose: the test must say so instead of passing quietly).
import http from 'k6/http';
import { check } from 'k6';

const BASE = (__ENV.BASE_URL || '').replace(/\/$/, '');
const PEAK = Number(__ENV.PEAK_RPS || 250);

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 100,
      maxVUs: 600,
      stages: [
        { target: 30, duration: '1m' },
        { target: PEAK, duration: '1m' },
        { target: PEAK, duration: '4m' },
        { target: 10, duration: '1m' },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],     // fewer than 1% failed requests (5xx, 403 from the WAF, timeouts)
    http_req_duration: ['p(95)<800'],   // 95% under 800 ms, including the scale-out period
  },
};

export function setup() {
  if (!BASE) throw new Error('set BASE_URL, e.g. https://api.<domain>');
  const r = http.get(`${BASE}/catalog/v1/events?limit=20`);
  if (r.status !== 200) throw new Error(`catalog list answered ${r.status} before the test started`);
  const items = r.json('items') || [];
  return { ids: items.map((e) => e.id) };
}

export default function (data) {
  const list = http.get(`${BASE}/catalog/v1/events?limit=20`);
  check(list, { 'list 200': (r) => r.status === 200 });
  if (data.ids.length > 0) {
    const id = data.ids[Math.floor(Math.random() * data.ids.length)];
    const one = http.get(`${BASE}/catalog/v1/events/${id}`);
    check(one, { 'event 200': (r) => r.status === 200 });
  }
}
