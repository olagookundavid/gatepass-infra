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
#                         Argo CD stops re-creating things we delete in the next steps
#   2. workload apps      (project `apps`) cascade-deleted while the controller is alive: their
#                         Ingresses disappear and the load balancer controller deletes the ALB
#   3. wait for the ALBs  to be gone from AWS
#   4. cluster-config     cascade-deleted: the Karpenter NodePools go, Karpenter drains and
#                         terminates its nodes
#   5. wait for the nodes (NodeClaims) to be gone
#   6. every other app    cascade-deleted (the controllers themselves, no longer needed),
#                         except `platform-argocd` (Argo CD itself) and `projects`
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
wait_until "Karpenter nodes to disappear" 900 no_nodeclaims

echo "== drain 6/6: delete the remaining applications except Argo CD itself and the projects"
# `projects` stays until last: deleting the AppProjects first could stop Argo CD from deleting
# the applications that still name them.
for app in $(k -n argocd get applications.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  [[ "$app" == "platform-argocd" || "$app" == "projects" ]] && continue
  k -n argocd delete application "$app" --wait=true --timeout=300s
done

echo "== drain done"
