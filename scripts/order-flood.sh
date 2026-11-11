#!/usr/bin/env bash
# Walkthrough 12, step "a queue backlog scales the workers": create 50 ORDERS at once, so that 50 payment
# requests land in the orders-payments queue.
#
#   BASE_URL=https://api.<domain> scripts/order-flood.sh
#
# THE EXPERIMENT (the coach drives it; this script is only the load):
#   1. pause the payment worker:   kubectl -n gatepass-orders annotate scaledobject orders-worker \
#                                    autoscaling.keda.sh/paused-replicas=0 --overwrite     (KEDA scales it to 0)
#   2. run this script             50 holds and 50 orders (5 users x 10 each: the hold rate limit is 10 per
#                                  user per minute); the API answers 201 immediately, the payments queue fills
#   3. look at the queue           it holds about 50 messages and nobody takes them
#   4. un-pause:                   kubectl -n gatepass-orders annotate scaledobject orders-worker autoscaling.keda.sh/paused-replicas-
#   5. watch                       KEDA sees 50 messages / 5 per replica and scales the worker up to its maximum
#                                  (6); the queue drains; after the cooldown the worker scales back to 1.
# Needs: curl, jq, xargs, aws, scripts/cognito.sh (users from create-test-users).
set -euo pipefail
: "${BASE_URL:?set BASE_URL, e.g. https://api.<domain>}"
BASE_URL="${BASE_URL%/}"
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
ADMIN_TOKEN="$("$here/cognito.sh" token admin)"
date_ahead() { date -u -d "+$1 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+"$1"d +%Y-%m-%dT%H:%M:%SZ; }
api() { curl -sS -X "$2" "$BASE_URL$3" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' ${4:+--data "$4"}; }

echo "== an event with 100 tickets"
venue="$(api "$ADMIN_TOKEN" POST /catalog/v1/venues '{"name":"Flood Arena","city":"Lagos","address":"1 Example Road","capacity":500}' | jq -r .id)"
ev="$(api "$ADMIN_TOKEN" POST /catalog/v1/events "$(jq -n --arg v "$venue" --arg s "$(date_ahead 3)" --arg e "$(date_ahead 4)" \
  '{venueId:$v,title:"Flood Live",description:"scripts/order-flood.sh",startsAt:$s,endsAt:$e,ticketTypes:[{name:"General",priceCents:5000,currency:"USD",capacity:100}]}')")"
event_id="$(jq -r .id <<<"$ev")"; tt="$(jq -r '.ticketTypes[0].id' <<<"$ev")"
api "$ADMIN_TOKEN" POST "/catalog/v1/events/$event_id/publish" >/dev/null
for _ in $(seq 1 45); do
  inv="$(curl -sS "$BASE_URL/reservations/v1/events/$event_id/inventory" || true)"
  [[ "$(jq -r '.ticketTypes|length' <<<"$inv" 2>/dev/null || echo 0)" -ge 1 ]] && break; sleep 2
done

echo "== 50 holds and 50 orders (5 users x 10, 50 in parallel)"
: > "$tmp/jobs"
for u in 1 2 3 4 5; do
  t="$("$here/cognito.sh" token "load$u")"
  for _ in $(seq 1 10); do echo "$t $(uuidgen | tr 'A-Z' 'a-z') $(uuidgen | tr 'A-Z' 'a-z')" >> "$tmp/jobs"; done
done
export BASE_URL event_id tt
xargs -P 50 -L 1 sh -c '
  hold=$(curl -s -X POST "$BASE_URL/reservations/v1/holds" -H "Authorization: Bearer $0" -H "Idempotency-Key: $1" \
    -H "Content-Type: application/json" --data "{\"eventId\":\"$event_id\",\"ticketTypeId\":\"$tt\",\"quantity\":1}" | sed -n "s/.*\"holdId\":\"\([^\"]*\)\".*/\1/p")
  [ -n "$hold" ] || { echo hold-failed; exit 0; }
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$BASE_URL/orders/v1/orders" -H "Authorization: Bearer $0" \
    -H "Idempotency-Key: $2" -H "Content-Type: application/json" --data "{\"holdId\":\"$hold\"}"' < "$tmp/jobs" | sort | uniq -c
q="$(aws sqs get-queue-url --queue-name gatepass-dev-orders-payments --query QueueUrl --output text)"
echo "== payments queue now:"; aws sqs get-queue-attributes --queue-url "$q" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --query Attributes --output text
