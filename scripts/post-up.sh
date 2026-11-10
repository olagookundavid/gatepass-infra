#!/usr/bin/env bash
# Finish a fresh cluster after `make up` applied the layers: make the load balancer controller's
# webhook certificate consistent, then re-sync whatever failed while it was not.
#
# THE PROBLEM (seen on two fresh clusters, 2026-11-06 and 2026-11-07). The aws-load-balancer-controller
# chart makes the webhook's TLS certificate at RENDER time (Helm genCA), so every render carries a
# different CA. Argo CD renders more than once during the first sync; the Secret `aws-load-balancer-tls`
# keeps the CA of one render (the application ignores its /data) while the webhook configurations end
# up with the caBundle of another. Result: every Ingress and IngressClassParams is rejected with
# "x509: certificate signed by unknown authority", so cluster-config and every service stay failed.
# After the two match, they stay matched through any number of later syncs (verified).
#
# THE FIX HERE: keep every webhook's caBundle equal to the CA stored in the Secret (the one the
# controller actually serves) until it has stayed equal for 3 minutes (a loop, because Argo CD
# re-applies the configurations during the first minutes, seen 2026-11-10), then ask Argo CD to
# retry the applications that failed in the meantime. Idempotent; does nothing without a cluster.
#
# DEV SHORTCUT (decision log): production installs cert-manager and lets it issue and rotate the
# webhook certificate (chart value enableCertManager), which removes the problem and the script.
# Needs: kubectl, python3, AWS_PROFILE/AWS_REGION exported by the caller if the context needs them.
set -euo pipefail

CLUSTER="${CLUSTER:-gatepass-dev}"
k() { kubectl --context "$CLUSTER" "$@"; }

if ! k get namespace argocd >/dev/null 2>&1; then
  echo "== post-up: no reachable cluster '${CLUSTER}', nothing to do"
  exit 0
fi

wait_until() { # <description> <seconds> <command...>
  local what="$1" limit="$2"; shift 2
  local end=$((SECONDS + limit))
  until "$@"; do
    if ((SECONDS > end)); then echo "!! timed out after ${limit}s waiting for: ${what}" >&2; return 1; fi
    sleep 5
  done
}
lbc_objects_exist() {
  k -n kube-system get secret aws-load-balancer-tls >/dev/null 2>&1 &&
    k get mutatingwebhookconfiguration aws-load-balancer-webhook >/dev/null 2>&1 &&
    k get validatingwebhookconfiguration aws-load-balancer-webhook >/dev/null 2>&1
}

echo "== post-up 1/3: wait for the load balancer controller's certificate and webhooks"
wait_until "LBC secret and webhook configurations" 900 lbc_objects_exist

echo "== post-up 2/3: keep the webhook caBundle equal to the CA in the Secret until it stays equal"
# One patch is not enough (seen 2026-11-10): Argo CD re-applied the webhook configurations AFTER a
# one-shot patch and put another render's CA back. So this reconciles: every 15 s it compares each
# webhook's caBundle with the Secret's CA and patches only a difference, and it stops after the
# configurations have needed no patch for 180 s in a row (cap: 900 s).
reconcile_ca() { # prints one line per kind it had to patch
  local ca kind count differ patch
  ca="$(k -n kube-system get secret aws-load-balancer-tls -o jsonpath='{.data.ca\.crt}')"
  for kind in mutatingwebhookconfiguration validatingwebhookconfiguration; do
    count="$(k get "$kind" aws-load-balancer-webhook -o jsonpath='{.webhooks[*].name}' | wc -w | tr -d ' ')"
    differ="$(k get "$kind" aws-load-balancer-webhook -o jsonpath='{range .webhooks[*]}{.clientConfig.caBundle}{"\n"}{end}' | grep -vxc "$ca" || true)"
    if [[ "$differ" != "0" ]]; then
      patch="$(python3 -c "import json,sys; print(json.dumps([{'op':'replace','path':'/webhooks/%d/clientConfig/caBundle' % i,'value':sys.argv[1]} for i in range(int(sys.argv[2]))]))" "$ca" "$count")"
      k patch "$kind" aws-load-balancer-webhook --type json -p "$patch" >/dev/null
      echo "   $(date +%H:%M:%S) $kind: $differ of $count webhooks differed, patched"
    fi
  done
}
end=$((SECONDS + 900)); quiet_since=$SECONDS
while ((SECONDS < end)); do
  out="$(reconcile_ca)"
  if [[ -n "$out" ]]; then echo "$out"; quiet_since=$SECONDS; fi
  if ((SECONDS - quiet_since >= 180)); then echo "   stable for 180 s"; break; fi
  sleep 15
done

echo "== post-up 3/3: retry the applications that failed while the certificate was wrong"
sleep 20
for _round in 1 2 3; do
  failed="$(k -n argocd get applications.argoproj.io -o jsonpath='{range .items[?(@.status.operationState.phase=="Failed")]}{.metadata.name}{"\n"}{end}')"
  [[ -z "$failed" ]] && break
  for app in $failed; do
    echo "   re-sync $app"
    k -n argocd patch application "$app" --type merge \
      -p '{"operation":{"initiatedBy":{"username":"post-up"},"sync":{"syncOptions":["ServerSideApply=true"]}}}' >/dev/null || true
  done
  sleep 45
done
k -n argocd get applications.argoproj.io --no-headers \
  -o custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status | grep -v "Synced *Healthy" || echo "   all applications Synced and Healthy"
echo "== post-up done"
