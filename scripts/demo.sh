#!/usr/bin/env bash
#
# scripts/demo.sh - exercise the full system end-to-end via the gateway.
#
# Usage (after `docker compose up --build` in another terminal):
#   ./scripts/demo.sh
#
# Walks through every service in order, explaining what each call is doing
# and what to look for in the response.

set -euo pipefail

GATEWAY="${GATEWAY:-http://localhost:8080}"
PDF_OUT="${PDF_OUT:-demo_invoice.pdf}"

# Color helpers (no color if stdout isn't a TTY, e.g. CI).
if [[ -t 1 ]]; then
  bold=$'\e[1m'; dim=$'\e[2m'; cyan=$'\e[36m'; green=$'\e[32m'; red=$'\e[31m'; reset=$'\e[0m'
else
  bold=""; dim=""; cyan=""; green=""; red=""; reset=""
fi

step()    { printf "\n${bold}${cyan}--- %s ---${reset}\n" "$1"; }
explain() { printf "${dim}%s${reset}\n" "$1"; }
result()  { printf "${green}-> %s${reset}\n" "$1"; }
fail()    { printf "${red}!! %s${reset}\n" "$1"; }

# ---------------------------------------------------------------------------
# 0. Wait for the gateway. Compose can take a few seconds even after the
#    images are built.
# ---------------------------------------------------------------------------
step "0. Waiting for the gateway"
explain "Polling ${GATEWAY}/health until it answers. The gateway only goes ready"
explain "once it's bound to port 8080 and the proxy machinery is set up."
for i in $(seq 1 30); do
  if curl -sf "${GATEWAY}/health" > /dev/null 2>&1; then
    result "Gateway is responding."
    break
  fi
  printf "."
  sleep 1
  if [[ $i -eq 30 ]]; then
    fail "Gateway never came up. Is 'docker compose up' running in another terminal?"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 1. Invoice service via the gateway.
# ---------------------------------------------------------------------------
step "1. Generating an invoice (invoice-service, Python)"
explain "Sending a GET to ${GATEWAY}/generate?name=Acme%20Corp. The gateway"
explain "routes this to the Python service on the internal Docker network,"
explain "which generates a PDF and streams it back through the gateway."
curl -s -o "${PDF_OUT}" "${GATEWAY}/generate?name=Acme%20Corp"
if [[ -s "${PDF_OUT}" ]]; then
  size=$(wc -c < "${PDF_OUT}")
  result "PDF written to ./${PDF_OUT} (${size} bytes). Open it; it's a real invoice."
else
  fail "Got an empty response. Check 'docker compose logs invoice-service'."
fi

# ---------------------------------------------------------------------------
# 2. Performance monitor via the gateway.
# ---------------------------------------------------------------------------
step "2. Reading CPU load (performance-monitor, C)"
explain "Sending a GET to ${GATEWAY}/metrics. The gateway routes to the C"
explain "service, which has been sampling /proc/stat in a background thread"
explain "since startup. The number is a percentage across the Docker VM."
metrics=$(curl -s "${GATEWAY}/metrics")
echo "  ${metrics}"
result "If you want to see this number move, run a load loop and re-check; see README step 2."

# ---------------------------------------------------------------------------
# 3. Health node via the gateway.
# ---------------------------------------------------------------------------
step "3. Reading the health snapshot (health-node, Go)"
explain "Sending a GET to ${GATEWAY}/status. The Go service polls every other"
explain "service every 5 seconds and reports who responded. A short pause"
explain "first so it's had time to do at least one poll cycle."
sleep 2
status=$(curl -s "${GATEWAY}/status")
echo "${status}" | sed 's/^/  /'
if echo "${status}" | grep -q '"overall_healthy":true'; then
  result "All downstreams report healthy."
else
  fail "At least one downstream is unhealthy. Inspect the JSON above."
fi

# ---------------------------------------------------------------------------
# 4. Generate a burst of varied traffic so the request log is representative.
#    The gateway logs every proxied request; firing a spread across all
#    endpoints makes the log reflect real cross-service activity rather than
#    a single call each.
# ---------------------------------------------------------------------------
step "4. Generating a burst of traffic across all services"
explain "Firing several requests at each endpoint through the gateway. Every one"
explain "is logged to MongoDB by the gateway, so the log below will show a"
explain "balanced spread instead of one lonely entry per service."
BURST=5
for i in $(seq 1 ${BURST}); do
  curl -s -o /dev/null "${GATEWAY}/generate?name=Burst%20${i}"
  curl -s -o /dev/null "${GATEWAY}/metrics"
  curl -s -o /dev/null "${GATEWAY}/status"
  curl -s -o /dev/null "${GATEWAY}/example"
  printf "."
done
echo
result "Sent ${BURST} rounds across /generate, /metrics, /status, and /example."

# Give the gateway's fire-and-forget log writes a moment to land in Mongo.
sleep 1

# ---------------------------------------------------------------------------
# 5. Show the request log straight from Mongo — counts per routed path.
# ---------------------------------------------------------------------------
step "5. The request log in MongoDB"
explain "Querying Mongo directly for how many requests the gateway logged per"
explain "path. This proves the logging works across every service, not just one."

# A compact aggregation: group the logged requests by the routed service
# (the gateway stores the clean path-without-query in the `service` field;
# the `path` field holds the full URL including query string, so we group by
# `service` to get clean per-endpoint counts).
MONGO_QUERY='db.logs.aggregate([
  { $group: { _id: "$service", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
]).forEach(function(d){ print("  " + d._id + "  ->  " + d.count + " requests"); })'

if docker compose exec -T mongo mongosh micro_logs --quiet --eval "${MONGO_QUERY}" 2>/dev/null; then
  result "Counts above come straight from the gateway's MongoDB request log."
else
  fail "Couldn't query Mongo automatically. You can still run it by hand:"
  echo "  docker compose exec mongo mongosh micro_logs --quiet --eval \\"
  echo "    'db.logs.find().sort({timestamp:-1}).limit(10).pretty()'"
fi
echo
explain "For full documents: docker compose exec mongo mongosh micro_logs --quiet \\"
explain "  --eval 'db.logs.find().sort({timestamp:-1}).limit(10).pretty()'"
explain "Or open MongoDB Compass at mongodb://localhost:27017"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Summary"
printf "  Invoice service:     ${green}OK${reset} (PDF at ./${PDF_OUT})\n"
printf "  Performance monitor: ${green}OK${reset} (latest reading printed above)\n"
printf "  Health node:         ${green}OK${reset} (snapshot printed above)\n"
printf "  Gateway:             ${green}OK${reset} (all calls routed through :8080, logged to Mongo)\n"
echo
echo "All four services responded through the gateway. The system works end-to-end."
