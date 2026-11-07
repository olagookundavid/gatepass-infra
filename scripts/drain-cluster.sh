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
# `services` application is removed WITHOUT cascade (its only content is the ApplicationSet), then
# the ApplicationSet itself is deleted: its generated applications carry the resources finalizer, so
# their Ingresses (and ALBs) are deleted while the controllers are still alive.
echo "== drain 1b/6: stop the ApplicationSet so it cannot re-create workload applications"
if k -n argocd get application services >/dev/null 2>&1; then
  k -n argocd patch application services --type merge -p '{"metadata":{"finalizers":null}}'
  k -n argocd delete application services --wait=true --timeout=120s
fi
k -n argocd delete applicationsets.argoproj.io --all --wait=true --timeout=300s || true

echo "== drain 2/6: delete workload applications (their Ingresses and load balancers go)"
for app in $(apps_in_project apps); do
  k -n argocd delete application "$app" --wait=true --timeout=300s
done

echo "== drain 3/6: wait until AWS has no load balancers"
wait_until "load balancers to disappear" 600 no_load_balancers

echo "== drain 4/6: delete cluster-config (Karpenter node pools; Karpenter removes its nodes)"
if k -n argocd get application cluster-config >/dev/null 2>&1; then
  k -n argocd delete application cluster-config --wait=true --timeout=600s
fi

echo "== drain 5/6: wait until Karpenter has no nodes left"
wait_until "Karpenter nodes to disappear" 900 no_nodeclaims_releasing_pdbs

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
  k -n argocd delete application "$app" --wait=true --timeout=300s
done
for app in observability-config external-secrets; do
  if k -n argocd get application "$app" >/dev/null 2>&1; then
    k -n argocd delete application "$app" --wait=true --timeout=300s
  fi
done

# Last: the `projects` application itself. It carries Argo CD's cleanup finalizer; if it were left,
# Terraform would remove Argo CD first and the finalizer could never run, so the namespace would
# hang in Terminating (seen on the first full teardown, 2026-11-06). Nothing needs the projects
# any more: every other application is gone.
if k -n argocd get application projects >/dev/null 2>&1; then
  k -n argocd delete application projects --wait=true --timeout=300s
fi

echo "== drain done"
