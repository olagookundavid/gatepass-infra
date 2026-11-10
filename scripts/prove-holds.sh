#!/usr/bin/env bash
# Proof for walkthrough 10, step G: 50 concurrent holds against an event with exactly 10 tickets.
#
#   BASE_URL=https://api.<domain> scripts/prove-holds.sh
#
# WHAT IT PROVES: reservations decrements the inventory with a DynamoDB transaction. If two
# requests could both read "1 left" and both succeed we would oversell. Here 5 users send 10 holds
# each (the limit is 10 per user per minute, so 5 users are needed for 50 requests), all at once:
# exactly 10 must answer 201 and exactly 40 must answer 409 (sold_out), and the inventory must end
# at 0, never below. Then one user sends an 11th request inside the minute and must get 429.
# Run it again while deleting a reservations pod: the numbers must not change.
#
# Needs: curl, jq, xargs, scripts/cognito.sh (users created once with create-test-users).
# Tokens stay in memory and in a mode-600 temp file; nothing secret is printed.
set -euo pipefail
: "${BASE_URL:?set BASE_URL, e.g. https://api.<domain>}"
BASE_URL="${BASE_URL%/}"
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

ADMIN_TOKEN="$("$here/cognito.sh" token admin)"
api() { # <token> <method> <path> [json]  -> body on stdout, status in $tmp/code
  curl -sS -o "$tmp/body" -w '%{http_code}' -X "$2" "$BASE_URL$3" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' ${4:+--data "$4"} > "$tmp/code"; cat "$tmp/body"; }
date_ahead() { date -u -d "+$1 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+"$1"d +%Y-%m-%dT%H:%M:%SZ; }

echo "== create and publish an event with 10 tickets"
venue="$(api "$ADMIN_TOKEN" POST /catalog/v1/venues '{"name":"Proof Arena","city":"Lagos","address":"1 Example Road","capacity":100}' | jq -r .id)"
ev="$(api "$ADMIN_TOKEN" POST /catalog/v1/events "$(jq -n --arg v "$venue" --arg s "$(date_ahead 3)" --arg e "$(date_ahead 4)" \
  '{venueId:$v,title:"Proof Live",description:"scripts/prove-holds.sh",startsAt:$s,endsAt:$e,ticketTypes:[{name:"General",priceCents:5000,currency:"USD",capacity:10}]}')")"
event_id="$(jq -r .id <<<"$ev")"; tt="$(jq -r '.ticketTypes[0].id' <<<"$ev")"
api "$ADMIN_TOKEN" POST "/catalog/v1/events/$event_id/publish" >/dev/null
for _ in $(seq 1 45); do
  inv="$(curl -sS "$BASE_URL/reservations/v1/events/$event_id/inventory" || true)"
  [[ "$(jq -r '.ticketTypes|length' <<<"$inv" 2>/dev/null || echo 0)" -ge 1 ]] && break; sleep 2
done
echo "   inventory: $(jq -r --arg t "$tt" '.ticketTypes[]|select(.ticketTypeId==$t)|.available' <<<"$inv") available"

echo "== 50 concurrent holds (5 users x 10)"
body="$(jq -nc --arg e "$event_id" --arg t "$tt" '{eventId:$e,ticketTypeId:$t,quantity:1}')"
: > "$tmp/jobs"
for u in 1 2 3 4 5; do
  t="$("$here/cognito.sh" token "load$u")"
  for _ in $(seq 1 10); do echo "$t $(uuidgen | tr 'A-Z' 'a-z')" >> "$tmp/jobs"; done
done
export BASE_URL body
xargs -P 50 -L 1 sh -c 'curl -s -o /dev/null -w "%{http_code}\n" -X POST "$BASE_URL/reservations/v1/holds" \
  -H "Authorization: Bearer $0" -H "Idempotency-Key: $1" -H "Content-Type: application/json" --data "$body"' < "$tmp/jobs" | sort | uniq -c | tee "$tmp/result"
ok="$(awk '$2==201{print $1}' "$tmp/result")"; sold="$(awk '$2==409{print $1}' "$tmp/result")"
left="$(curl -sS "$BASE_URL/reservations/v1/events/$event_id/inventory" | jq -r --arg t "$tt" '.ticketTypes[]|select(.ticketTypeId==$t)|.available')"
echo "   201 x ${ok:-0}, 409 x ${sold:-0}, available now: $left"
[[ "${ok:-0}" == 10 && "${sold:-0}" == 40 && "$left" == 0 ]] || { echo "FAIL: expected 10 x 201, 40 x 409, 0 left" >&2; exit 1; }
echo "PASS: exactly 10 holds were granted, no oversell"

echo "== rate limit: an 11th request from the same user inside the minute"
t="$("$here/cognito.sh" token load1)"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/reservations/v1/holds" -H "Authorization: Bearer $t" \
  -H "Idempotency-Key: $(uuidgen | tr 'A-Z' 'a-z')" -H 'Content-Type: application/json' --data "$body")"
echo "   status: $code (expected 429)"; [[ "$code" == 429 ]] && echo "PASS: rate limited" || { echo "FAIL" >&2; exit 1; }
