#!/usr/bin/env bash
# Walkthrough 12, step "load": run the k6 profile against the catalog and WATCH what the platform does.
#
#   BASE_URL=https://api.<domain> scripts/load-test.sh            (needs docker and kubectl on the cluster)
#   PEAK_RPS=400 BASE_URL=... scripts/load-test.sh                 (a harder peak)
#
# WHAT IT PRODUCES. k6 runs in a container pinned by digest (no installation, no moving tag) and prints its
# own summary and thresholds. At the same time this script samples the cluster every 20 s into a table:
# catalog HPA (current/desired replicas, CPU), the number of catalog pods, and the nodes per zone and
# pool. After the run the table is the evidence for "under load the APIs scale out and Karpenter adds nodes
# in the right zones" and, a few minutes later, "and back in". It changes nothing.
# BEFORE YOU RUN: the cluster must have been brought up with TF_VAR_waf_rate_limit=200000 (see
# k6/catalog-load.js, the WAF would otherwise block this machine after 1000 requests in 5 minutes).
set -euo pipefail
: "${BASE_URL:?set BASE_URL, e.g. https://api.<domain>}"
here="$(cd "$(dirname "$0")" && pwd)"
K6_IMAGE="${K6_IMAGE:-docker.io/grafana/k6@sha256:3e4186aea62e11a45560bfc51e19eeafe82fc07ce069c78aff44b7ff893d9a5e}"
NS="${NS:-gatepass-catalog}"
APP="${APP:-catalog}"
log="$(mktemp)"; trap 'kill "$sampler" 2>/dev/null || true; rm -f "$log"' EXIT

sample() {
  while true; do
    ts="$(date +%H:%M:%S)"
    # HPA by JSONPath (the text table splits "cpu: 1%/70%" into two columns and shifts the rest).
    hpa="$(kubectl -n "$NS" get hpa "$APP" -o jsonpath='cpu={.status.currentMetrics[0].resource.current.averageUtilization}% replicas={.status.currentReplicas}->{.status.desiredReplicas}' 2>/dev/null)"
    ready="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$APP" --no-headers 2>/dev/null | awk '$3=="Running"{r++} END{print r+0}')"
    # nodes per zone and pool: custom columns keep one value per column, an empty pool label is "system".
    nodes="$(kubectl get nodes -o custom-columns='Z:.metadata.labels.topology\.kubernetes\.io/zone,P:.metadata.labels.karpenter\.sh/nodepool' --no-headers 2>/dev/null \
      | awk '{p=($2=="<none>"?"system":$2); c[$1"/"p]++} END{for(k in c) printf "%s=%d ", k, c[k]}')"
    echo "$ts  $hpa  running=$ready  nodes: $nodes" | tee -a "$log"
    sleep 20
  done
}
sample & sampler=$!

echo "== k6 against $BASE_URL (peak ${PEAK_RPS:-250} req/s), cluster samples every 20 s below"
docker run --rm -i -e BASE_URL="$BASE_URL" -e PEAK_RPS="${PEAK_RPS:-250}" "$K6_IMAGE" run - < "$here/k6/catalog-load.js" || echo "k6 exited non-zero: a threshold failed (see the summary above)"

echo "== keep watching 6 more minutes: the HPA scales IN slowly (5-minute stabilisation window)"
sleep 360
kill "$sampler" 2>/dev/null || true
echo; echo "== table of the run"; cat "$log"
