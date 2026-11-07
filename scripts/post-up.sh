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
# THE FIX HERE: set every webhook's caBundle to the CA stored in the Secret (the one the controller
# actually serves), then ask Argo CD to retry the applications that failed in the meantime.
# Idempotent and safe to run twice; does nothing without a cluster.
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

echo "== post-up 2/3: make the webhook caBundle equal to the CA in the Secret"
ca="$(k -n kube-system get secret aws-load-balancer-tls -o jsonpath='{.data.ca\.crt}')"
for kind in mutatingwebhookconfiguration validatingwebhookconfiguration; do
  count="$(k get "$kind" aws-load-balancer-webhook -o jsonpath='{.webhooks[*].name}' | wc -w | tr -d ' ')"
  patch="$(python3 -c "import json,sys; print(json.dumps([{'op':'replace','path':'/webhooks/%d/clientConfig/caBundle' % i,'value':sys.argv[1]} for i in range(int(sys.argv[2]))]))" "$ca" "$count")"
  k patch "$kind" aws-load-balancer-webhook --type json -p "$patch" >/dev/null
  echo "   $kind: $count webhooks set"
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
