#!/usr/bin/env bash
#
# Creates the three workload registration entries. An entry maps a container
# label to a SPIFFE ID:
#
#   docker:label:spiffe.lab/workload:zone-b-gateway -> spiffe://lab.local/zone-b/gateway
#   docker:label:spiffe.lab/workload:zone-b-backend -> spiffe://lab.local/zone-b/backend
#   docker:label:spiffe.lab/workload:zone-a-client  -> spiffe://lab.local/zone-a/client
#
# The gateway entry also gets a DNS SAN "zone-b-gateway". The client curl then
# verifies the gateway certificate against that hostname, because a SPIFFE SVID
# carries only a URI SAN by default.
#
# Safe to run twice: an existing entry is left alone.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
TRUST_DOMAIN="lab.local"
LABEL_KEY="spiffe.lab/workload"
PARENT_ID="spiffe://${TRUST_DOMAIN}/node"

log() { printf '%s\n' "$*"; }
spire_server() { ${COMPOSE} exec -T spire-server /opt/spire/bin/spire-server "$@"; }

# label value : SPIFFE path : optional DNS SAN
# The SPIFFE path is NOT the label value here: the label is flat
# (zone-b-gateway) but the SPIFFE ID is nested (zone-b/gateway).
ENTRIES=(
  "zone-b-gateway|zone-b/gateway|zone-b-gateway"
  "zone-b-backend|zone-b/backend|"
  "zone-a-client|zone-a/client|"
)

entry_exists() {
  local spiffe_id="$1" selector="$2" shown
  shown="$(spire_server entry show -parentID "${PARENT_ID}" \
    -spiffeID "${spiffe_id}" -selector "${selector}")" || return 1
  [[ "$(grep -c '^Entry ID' <<<"${shown}")" == "1" ]]
}

ensure_entry() {
  local label="$1" path="$2" dns="$3"
  local spiffe_id="spiffe://${TRUST_DOMAIN}/${path}"
  local selector="docker:label:${LABEL_KEY}:${label}"

  if entry_exists "${spiffe_id}" "${selector}"; then
    log "  ${selector} -> ${spiffe_id} (exists)"
    return 0
  fi

  local args=(entry create -parentID "${PARENT_ID}" -spiffeID "${spiffe_id}" -selector "${selector}")
  [[ -n "${dns}" ]] && args+=(-dns "${dns}")
  spire_server "${args[@]}" >/dev/null
  log "  ${selector} -> ${spiffe_id} (created)"
}

main() {
  if ! spire_server healthcheck >/dev/null 2>&1; then
    log "ERROR: SPIRE Server is not answering. Run bootstrap.sh first."
    return 1
  fi

  local row label path dns
  for row in "${ENTRIES[@]}"; do
    IFS='|' read -r label path dns <<<"${row}"
    ensure_entry "${label}" "${path}" "${dns}"
  done

  log "Registration entries present"
  # A new entry reaches the agent on its next sync. Give it a moment.
  sleep 5
}

main "$@"
