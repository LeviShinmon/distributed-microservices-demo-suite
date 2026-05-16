#!/usr/bin/env bash
#
# scripts/demo.sh — exercise the full system end-to-end via the gateway.
#
# Usage:
#   docker compose up --build -d
#   ./scripts/demo.sh
#
# Hits every route through :8080 and prints what came back.

set -euo pipefail

GATEWAY="${GATEWAY:-http://localhost:8080}"

# Color helpers (no color if stdout isn't a TTY).
if [[ -t 1 ]]; then
  bold=$'\e[1m'; dim=$'\e[2m'; green=$'\e[32m'; red=$'\e[31m'; reset=$'\e[0m'
else
  bold=""; dim=""; green=""; red=""; reset=""
fi

step() { printf "\n${bold}== %s ==${reset}\n" "$1"; }
info() { printf "${dim}%s${reset}\n" "$1"; }

# Wait for the gateway to come up (compose can take a few seconds).
step "Waiting for gateway at ${GATEWAY}"
for i in $(seq 1 30); do
  if curl -sf "${GATEWAY}/health" > /dev/null 2>&1; then
    echo "${green}gateway is up${reset}"
    break
  fi
  printf "."
  sleep 1
  if [[ $i -eq 30 ]]; then
    echo "${red}gateway never came up — is 'docker compose up' running?${reset}"
    exit 1
  fi
done

step "Gateway health"
curl -s "${GATEWAY}/health" | sed 's/^/  /'

step "Generate a PDF through the gateway (invoice-service)"
out="$(mktemp -d)/report.pdf"
curl -s -o "${out}" "${GATEWAY}/generate?name=Adni"
info "wrote ${out} ($(wc -c <"${out}") bytes)"
file "${out}" 2>/dev/null || true

step "CPU metrics through the gateway (performance-monitor)"
curl -s "${GATEWAY}/metrics" | sed 's/^/  /'

step "Health snapshot through the gateway (health-node)"
# Give health-node a moment to complete its first poll cycle if we're fast.
sleep 1
curl -s "${GATEWAY}/status" | sed 's/^/  /'

step "Tail the gateway's request log in MongoDB"
info "(run this to see the logs the gateway wrote:)"
echo "  docker compose exec mongo mongosh micro_logs --quiet --eval 'db.logs.find().sort({timestamp:-1}).limit(5).pretty()'"

step "All four services responded through the gateway. Stack is alive."
