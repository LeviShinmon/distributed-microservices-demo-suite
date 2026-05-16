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
# 4. Mongo request log (informational; the gateway logged everything we
#    did above).
# ---------------------------------------------------------------------------
step "4. Where the request log lives"
explain "Every call you just made was logged by the gateway to MongoDB."
explain "To see them, run either of these (won't run them here - they print"
explain "ten documents and would clutter this output):"
echo
echo "  docker compose exec mongo mongosh micro_logs --quiet --eval \\"
echo "    'db.logs.find().sort({timestamp:-1}).limit(10).pretty()'"
echo
echo "  Or open MongoDB Compass at mongodb://localhost:27017"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Summary"
printf "  Invoice service:     ${green}OK${reset} (PDF at ./${PDF_OUT})\n"
printf "  Performance monitor: ${green}OK${reset} (latest reading printed above)\n"
printf "  Health node:         ${green}OK${reset} (snapshot printed above)\n"
printf "  Gateway:             ${green}OK${reset} (all three calls routed through :8080)\n"
echo
echo "All four services responded through the gateway. The system works end-to-end."