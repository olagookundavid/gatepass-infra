#!/usr/bin/env bash
# Empty the cluster of everything that created AWS resources OUTSIDE Terraform, so that the
# layers can be destroyed without leaving costs behind. `make down` runs this first.
#
# WHY IT EXISTS. Terraform knows about the VPC, the cluster and the IAM roles. It does NOT know
# about the load balancer the load balancer controller built for an Ingress, or the EC2 nodes
# Karpenter launched: those were created later, from inside the cluster. If the cluster and
# the VPC are destroyed while they exist, the VPC delete fails on the leftover network
# interfaces and security groups, and the instances and the ALB keep billing. The fix is to
# make the controllers delete their own creations first, in this order:
#
#   1. root application   deleted WITHOUT cascade, so the child applications keep running and
#                         Argo CD stops re-creating things we delete in the next steps; then the
#                         ApplicationSet is deleted too (it would re-create the workload apps)
#   2. workload apps      (project `apps`) cascade-deleted while the controller is alive: their
#                         Ingresses disappear and the load balancer controller deletes the ALB
#   3. wait for the ALBs  to be gone from AWS
#   4. cluster-config     cascade-deleted: the Karpenter NodePools go, Karpenter drains and
#                         terminates its nodes
#   5. wait for the nodes (NodeClaims) to be gone, deleting PodDisruptionBudgets meanwhile (a half-drained
#                         cluster would otherwise deadlock on them)
#   6. every other app    cascade-deleted (the controllers themselves, no longer needed),
#                         except `platform-argocd` (Argo CD itself) and `projects`
#   7. projects           deleted last (its finalizer would otherwise hang the argocd namespace)
# Afterwards `terraform destroy` of layer 25 only has the Argo CD installation itself to remove.
#
# Safe to run twice and when there is nothing to drain (no cluster, no Argo CD). Read-only
# when the cluster does not exist. Needs: kubectl, aws, AWS_PROFILE and AWS_REGION exported.
set -euo pipefail

CLUSTER="${CLUSTER:-gatepass-dev}"
REGION="${AWS_REGION:-us-east-1}"
k() { kubectl --context "$CLUSTER" "$@"; }

# delete_app <name> <timeout>: delete an Argo CD application. An application that is still RUNNING a sync
# operation does not get deleted: it waits for the operation (for example "waiting for completion of
# hook batch/Job/data-bootstrap" although the Job had long finished; seen 2026-11-09 and on 2026-11-07).
# So any in-flight operation is cleared first.
delete_app() {
  k -n argocd patch application "$1" --type json -p '[{"op":"remove","path":"/operation"}]' >/dev/null 2>&1 || true
  k -n argocd delete application "$1" --wait=true --timeout="${2:-300s}"
}

# force_delete_app <name>: the last resort for the step-6 applications (controllers and platform jobs,
# whose objects live only inside the cluster that is about to be destroyed). The cascade deletion of an
# application can hang forever on a stale "operation running" status although nothing is running (seen on
# data-bootstrap, 2026-11-09: "5 objects remaining for deletion" and no object ever asked to go). Drop the
# application's finalizer (so Argo CD stops waiting) and delete the namespace it owned. NEVER use this
# for the workload applications of step 2: their Ingresses must be deleted by the controller, or the
# load balancer is orphaned in AWS.
force_delete_app() {
  local ns
  ns="$(k -n argocd get application "$1" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true)"
  echo "!! force-deleting application $1 (namespace ${ns:-?})"
  k -n argocd patch application "$1" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  k -n argocd delete application "$1" --wait=false >/dev/null 2>&1 || true
  if [[ -n "$ns" && "$ns" != "argocd" && "$ns" != "kube-system" ]]; then
    # Objects with controller finalizers (ExternalSecrets) would keep the namespace Terminating.
    for r in $(k -n "$ns" get externalsecrets.external-secrets.io -o name 2>/dev/null || true); do
      k -n "$ns" patch "$r" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done
    k delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
  fi
}

# wait_until <description> <seconds> <command...>: run the command every 10 s until it succeeds.
wait_until() {
  local what="$1" limit="$2"
  shift 2
  local end=$((SECONDS + limit))
  until "$@"; do
    if ((SECONDS > end)); then
      echo "!! timed out after ${limit}s waiting for: ${what}" >&2
      return 1
    fi
    sleep 10
  done
}

no_load_balancers() {
  [[ -z "$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerArn' --output text)" ]]
}

no_nodeclaims() {
  [[ -z "$(k get nodeclaims.karpenter.sh -o name 2>/dev/null || true)" ]]
}

# Same check, but first delete every PodDisruptionBudget. WHY (seen on 2026-11-07, the first teardown
# with the observability stack running): Karpenter drains a node by EVICTING its pods. When the first
# node is drained, its pods cannot be rescheduled (the node pool is being deleted, so no new nodes),
# so a deployment such as the OTel gateway ends up with 1 of 2 replicas healthy, its budget
# (minAvailable 1) then allows 0 more evictions and the drain waits forever. The cluster is being
# destroyed, so the budgets protect nothing; deleting them is done on every round because the
# applications that own them still run (and self-heal) until step 6.
no_nodeclaims_releasing_pdbs() {
  k delete poddisruptionbudgets --all -A --ignore-not-found >/dev/null 2>&1 || true
  no_nodeclaims
}

# Application names whose spec.project equals $1.
apps_in_project() {
  k -n argocd get applications.argoproj.io \
    -o jsonpath="{range .items[?(@.spec.project==\"$1\")]}{.metadata.name}{\"\\n\"}{end}"
}

if ! k get namespace argocd >/dev/null 2>&1; then
  echo "== drain: no reachable cluster '${CLUSTER}' with Argo CD, nothing to do"
  exit 0
fi

echo "== drain 1/6: delete the root application without cascading (children keep running)"
if k -n argocd get application root >/dev/null 2>&1; then
  k -n argocd patch application root --type merge -p '{"metadata":{"finalizers":null}}'
  k -n argocd delete application root --wait=true --timeout=120s
fi

# Stop the machinery that re-creates workload applications. Without this (seen on 2026-11-07, second
# attempt) the ApplicationSet `services` kept re-generating the skeleton application after
# cluster-config (which holds the IngressClassParams the load balancer controller needs) was gone:
# the new Ingress could never be processed, its finalizer never left, and the drain hung. The
# applications that carry an ApplicationSet (`services`, `platform-ingresses-set`) are removed WITHOUT cascade (their only content is the ApplicationSet), then
# the ApplicationSet itself is deleted: its generated applications carry the resources finalizer, so
# their Ingresses (and ALBs) are deleted while the controllers are still alive.
echo "== drain 1b/6: stop the ApplicationSet so it cannot re-create workload applications"
# Both applications that carry an ApplicationSet: `services` (the workloads) and
# `platform-ingresses-set` (the Ingresses of Argo CD and Grafana, Phase 6b).
for carrier in services platform-ingresses-set; do
  if k -n argocd get application "$carrier" >/dev/null 2>&1; then
    k -n argocd patch application "$carrier" --type merge -p '{"metadata":{"finalizers":null}}'
    k -n argocd delete application "$carrier" --wait=true --timeout=120s
  fi
done
k -n argocd delete applicationsets.argoproj.io --all --wait=true --timeout=300s || true

echo "== drain 2/6: delete workload applications (their Ingresses and load balancers go)"
for app in $(apps_in_project apps); do
  k -n argocd delete application "$app" --wait=true --timeout=300s
done

echo "== drain 3/6: wait until AWS has no load balancers"
wait_until "load balancers to disappear" 600 no_load_balancers

# PodDisruptionBudgets can deadlock the drain (see no_nodeclaims_releasing_pdbs): Karpenter removes a node
# by EVICTING its pods WHILE `delete application cluster-config` below is still waiting, so deleting the
# budgets only in the later wait loop is too late (seen again on 2026-11-09: cluster-config hung for
# 600 s on the OTel gateway's budget, 1 of 2 replicas healthy). A background loop deletes them every
# 10 s for the whole window of steps 4 and 5; the cluster is being destroyed, so they protect nothing.
pdb_breaker() { while true; do k delete poddisruptionbudgets --all -A --ignore-not-found >/dev/null 2>&1 || true; sleep 10; done; }
pdb_breaker &
PDB_BREAKER_PID=$!
trap 'kill "$PDB_BREAKER_PID" 2>/dev/null || true' EXIT

echo "== drain 4/6: delete cluster-config (Karpenter node pools; Karpenter removes its nodes)"
if k -n argocd get application cluster-config >/dev/null 2>&1; then
  k -n argocd delete application cluster-config --wait=true --timeout=600s
fi

echo "== drain 5/6: wait until Karpenter has no nodes left"
wait_until "Karpenter nodes to disappear" 900 no_nodeclaims_releasing_pdbs

kill "$PDB_BREAKER_PID" 2>/dev/null || true   # the nodes are gone; the budgets are no longer in the way
echo "== drain 6/6: delete the remaining applications except Argo CD itself and the projects"
# `projects` stays until last: deleting the AppProjects first could stop Argo CD from deleting
# the applications that still name them.
# Two applications are deleted AFTER all the others, in this order (seen on 2026-11-07, third and fourth
# attempt):
#   observability-config  it owns the namespaces. Deleted early, the namespaces vanish while
#                         otel-agent and the other collectors still self-heal into them; their sync
#                         keeps failing ("namespace not found") and their own deletion never finishes.
#   external-secrets      the ExternalSecret objects (owned by observability-config and others) carry a
#                         cleanup finalizer that only this operator removes, so it must outlive them.
last_apps=" observability-config external-secrets "
for app in $(k -n argocd get applications.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  [[ "$app" == "platform-argocd" || "$app" == "projects" || "$last_apps" == *" $app "* ]] && continue
  delete_app "$app" 120s || force_delete_app "$app"
done
for app in observability-config external-secrets; do
  if k -n argocd get application "$app" >/dev/null 2>&1; then
    delete_app "$app" 120s || force_delete_app "$app"
  fi
done

# Last: the `projects` application itself. It carries Argo CD's cleanup finalizer; if it were left,
# Terraform would remove Argo CD first and the finalizer could never run, so the namespace would
# hang in Terminating (seen on the first full teardown, 2026-11-06). Nothing needs the projects
# any more: every other application is gone.
if k -n argocd get application projects >/dev/null 2>&1; then
  k -n argocd delete application projects --wait=true --timeout=300s
fi

# Last: release the finalizers that Argo CD put on its HOOK resources. A hook (a Helm hook, or a Job such
# as data-bootstrap) carries `argocd.argoproj.io/hook-finalizer` until Argo CD finishes with it. Argo CD
# itself is removed by Terraform next, so nobody could ever clear it, and the `argocd` and
# `data-bootstrap` namespaces stayed Terminating, hanging `terraform destroy` of 25-gitops-bootstrap for
# 5 minutes and failing it (2026-11-09). Nothing runs any more, so releasing them is safe.
echo "== drain 7/7: release the Argo CD hook finalizers"
for kind in jobs.batch pods roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io serviceaccounts configmaps secrets; do
  k get "$kind" -A -o json 2>/dev/null | python3 -c '
import json, sys
FIN = "argocd.argoproj.io/hook-finalizer"
for it in json.load(sys.stdin).get("items", []):
    if FIN in (it["metadata"].get("finalizers") or []):
        print(it["metadata"].get("namespace", ""), it["metadata"]["name"])' | while read -r ns name; do
    echo "   releasing ${kind} ${ns}/${name}"
    k -n "$ns" patch "$kind" "$name" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
done

echo "== drain done"
