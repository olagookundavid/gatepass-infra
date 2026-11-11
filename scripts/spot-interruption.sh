#!/usr/bin/env bash
# Walkthrough 12, step "a Spot instance is reclaimed": hand Karpenter a SYNTHETIC "EC2 Spot Instance
# Interruption Warning" for one node, then watch it cordon, drain and replace that node while the golden path
# keeps passing.
#
#   BASE_URL=https://api.<domain> scripts/spot-interruption.sh             (a Spot node if one exists)
#   ANY_NODE=true BASE_URL=... scripts/spot-interruption.sh                (any Karpenter node)
#
# WHY SYNTHETIC. AWS Fault Injection Service would send the real warning, but this account has no FIS
# subscription (SubscriptionRequiredException, like Managed Grafana and GuardDuty; see the decision log).
# Karpenter listens on an SQS queue (30-platform-aws/karpenter-queue.tf) that EventBridge fills with the
# real events; we put a message of the SAME shape on it ourselves. Karpenter cannot tell the difference: it
# treats it as the two-minute warning, taints the node, starts a replacement and drains the old one
# respecting PodDisruptionBudgets. (The instance itself is not reclaimed; Karpenter terminates it.)
# Needs: kubectl, aws, jq, scripts/cognito.sh, ../gatepass-app/scripts/golden-path.sh.
set -euo pipefail
: "${BASE_URL:?set BASE_URL, e.g. https://api.<domain>}"
here="$(cd "$(dirname "$0")" && pwd)"
golden="$(cd "$here/../../gatepass-app/scripts" && pwd)/golden-path.sh"
REGION="${AWS_REGION:-us-east-1}"
sel="karpenter.sh/capacity-type=spot"; [ "${ANY_NODE:-false}" = true ] && sel="karpenter.sh/nodepool"
node="$(kubectl get nodes -l "$sel" -o jsonpath='{.items[0].metadata.name}')"
[ -n "$node" ] || { echo "no node matches $sel (no Spot node: use ANY_NODE=true)" >&2; exit 2; }
iid="$(kubectl get node "$node" -o jsonpath='{.spec.providerID}' | sed 's#.*/##')"
az="$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
acct="$(aws sts get-caller-identity --query Account --output text)"
queue="$(aws sqs get-queue-url --queue-name "gatepass-dev-karpenter" --query QueueUrl --output text)"
echo "== node $node ($iid, $az); pods on it:"; kubectl get pods -A --field-selector spec.nodeName="$node" --no-headers | awk '{print "   "$1"/"$2}' | grep -v "kube-system" | head

TOKEN="$("$here/cognito.sh" token user)"; ADMIN_TOKEN="$("$here/cognito.sh" token admin)"; export BASE_URL TOKEN ADMIN_TOKEN
( for i in 1 2 3; do "$golden" > "/tmp/spot-golden-$i.log" 2>&1 && echo "golden path $i: PASS" || echo "golden path $i: FAIL"; done ) &
loop=$!
sleep 15

msg="$(jq -n --arg id "$(uuidgen | tr A-Z a-z)" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg a "$acct" --arg r "$REGION" --arg i "$iid" --arg az "$az" \
  '{version:"0",id:$id,"detail-type":"EC2 Spot Instance Interruption Warning",source:"aws.ec2",account:$a,time:$t,region:$r,
    resources:["arn:aws:ec2:\($az):instance/\($i)"],detail:{"instance-id":$i,"instance-action":"terminate"}}')"
echo "== sending the synthetic interruption warning for $iid"
aws sqs send-message --queue-url "$queue" --message-body "$msg" --query MessageId --output text
echo "== watching the node (cordoned, then gone) and the NodeClaims"
for i in $(seq 1 30); do
  kubectl get node "$node" --no-headers 2>/dev/null | awk '{print "   "$1, $2}' || true
  kubectl get nodeclaims --no-headers 2>/dev/null | awk '{print "   claim", $1, $5}' | head -4
  kubectl get node "$node" >/dev/null 2>&1 || { echo "   node $node is gone"; break; }
  sleep 10
done
wait "$loop" || true
echo "== replacement nodes:"; kubectl get nodes -L karpenter.sh/capacity-type,topology.kubernetes.io/zone --no-headers | awk '{print "   "$1,$2,$6,$7}'
