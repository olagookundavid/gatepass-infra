#!/usr/bin/env bash
# Walkthrough 12, step "an availability zone is lost": cordon and drain every WORKLOAD node of one zone while
# the golden path runs in a loop. PASS = every golden-path run in the loop passes.
#
#   BASE_URL=https://api.<domain> scripts/az-drill.sh us-east-1b
#
# WHAT HAPPENS. Pods of the services (hard zone spread, PodDisruptionBudgets, 2+ replicas) are evicted from
# the zone one by one; the remaining zones already hold a replica of each API, so requests keep being served;
# the evicted pods are rescheduled into the other zones (Karpenter adds a node if there is no room). The
# nodes are cordoned first so nothing is scheduled back into the "failed" zone. Only nodes created by
# Karpenter are touched (label karpenter.sh/nodepool): the system nodes (Argo CD, Kyverno, CoreDNS) are a
# separate drill, because losing a zone of the control components is a different experiment (set
# INCLUDE_SYSTEM=true to include them). The script uncordons everything when it ends, also on error.
# Needs: kubectl, jq, scripts/cognito.sh, ../gatepass-app/scripts/golden-path.sh.
set -euo pipefail
zone="${1:?usage: az-drill.sh <zone, e.g. us-east-1b>}"
: "${BASE_URL:?set BASE_URL, e.g. https://api.<domain>}"
here="$(cd "$(dirname "$0")" && pwd)"
golden="$here/../../gatepass-app/scripts/golden-path.sh"
[ -x "$golden" ] || golden="$(cd "$here/../../gatepass-app/scripts" && pwd)/golden-path.sh"
sel="topology.kubernetes.io/zone=$zone"
[ "${INCLUDE_SYSTEM:-false}" = true ] || sel="$sel,karpenter.sh/nodepool"
nodes="$(kubectl get nodes -l "$sel" -o name)"
[ -n "$nodes" ] || { echo "no node matches $sel" >&2; exit 2; }
echo "== nodes of $zone to take away:"; echo "$nodes" | sed 's/^/   /'

TOKEN="$("$here/cognito.sh" token user)"; ADMIN_TOKEN="$("$here/cognito.sh" token admin)"; export BASE_URL TOKEN ADMIN_TOKEN
loop_log="$(mktemp)"; stop="$(mktemp)"; rm -f "$stop"
cleanup() { touch "$stop"; wait "$loop_pid" 2>/dev/null || true; echo "== uncordon"; for n in $nodes; do kubectl uncordon "$n" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

(
  runs=0; fails=0
  while [ ! -e "$stop" ]; do
    runs=$((runs+1))
    if "$golden" > "$loop_log.run" 2>&1; then echo "run $runs: PASS"; else fails=$((fails+1)); echo "run $runs: FAIL"; tail -5 "$loop_log.run"; fi
  done
  echo "golden path loop: $runs runs, $fails failed"
) > "$loop_log" 2>&1 &
loop_pid=$!

sleep 20
echo "== cordon"; for n in $nodes; do kubectl cordon "$n"; done
echo "== drain (PodDisruptionBudgets are respected; DaemonSets stay)"
for n in $nodes; do kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout=300s || echo "   drain of $n did not finish (a PDB blocked it?)"; done
echo "== where the service pods run now"; kubectl get pods -A -o wide --no-headers | awk '$1 ~ /^gatepass-/ {print $1, $2, $8}' | sort | head -40
echo "== let the loop run 90 s more, then stop it"; sleep 90
trap - EXIT; cleanup
echo "== result of the loop"; cat "$loop_log"; grep -q "0 failed" "$loop_log" && echo "PASS: the golden path stayed green while $zone was drained" || { echo "FAIL: see above"; exit 1; }
