#!/usr/bin/env bash
#
# Creates the eight workload registration entries. An entry maps a container
# label to a SPIFFE ID:
#
#   zone-a-client   -> spiffe://lab.local/zone-a/client
#   zone-a-intruder -> spiffe://lab.local/zone-a/intruder
#   zone-a-peer     -> spiffe://lab.local/zone-a/peer
#   zone-b-gateway  -> spiffe://lab.local/zone-b/gateway   (+ DNS SAN)
#   zone-b-backend  -> spiffe://lab.local/zone-b/backend
#   zone-c-gateway  -> spiffe://lab.local/zone-c/gateway   (+ DNS SAN)
#   zone-c-backend  -> spiffe://lab.local/zone-c/backend
#   zone-registry   -> spiffe://lab.local/mgmt/registry    (+ DNS SAN)
#
# Trap 3: the label is flat, but the SPIFFE path is nested. The map is explicit;
# the script never assumes the SPIFFE path equals the label value.
#
# Trap 2: the gateway entries get a DNS SAN with the "-dns" flag, not "-dnsName".
# The client curl or the Go client then verifies the gateway hostname.
#
# zone-a-unregistered gets no entry, on purpose. Safe to run twice: an existing
# entry is left alone.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
TRUST_DOMAIN="lab.local"
LABEL_KEY="spiffe.lab/workload"
PARENT_ID="spiffe://${TRUST_DOMAIN}/node"

# The barrier waits until the server reports this many entries.
EXPECTED_ENTRIES=8
SYNC_ATTEMPTS="${SYNC_ATTEMPTS:-30}"

log() { printf '%s\n' "$*"; }
spire_server() { ${COMPOSE} exec -T spire-server /opt/spire/bin/spire-server "$@"; }

# label value | SPIFFE path | optional DNS SAN
# The SPIFFE path is NOT the label value: the label is flat (zone-b-gateway) but
# the SPIFFE ID is nested (zone-b/gateway).
ENTRIES=(
  "zone-a-client|zone-a/client|"
  "zone-a-intruder|zone-a/intruder|"
  "zone-a-peer|zone-a/peer|"
  "zone-b-gateway|zone-b/gateway|zone-b-gateway"
  "zone-b-backend|zone-b/backend|"
  "zone-c-gateway|zone-c/gateway|zone-c-gateway"
  "zone-c-backend|zone-c/backend|"
  "zone-registry|mgmt/registry|zone-registry"
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

# entry_count prints the number of entries the server holds.
entry_count() {
  spire_server entry show 2>/dev/null | grep -c '^Entry ID' || true
}

# wait_for_sync is the entry sync barrier. A new entry reaches the agent on its
# next sync. The barrier waits until the server confirms the full set, then
# gives the agent one sync interval to catch up.
wait_for_sync() {
  local i count
  for ((i = 1; i <= SYNC_ATTEMPTS; i++)); do
    count="$(entry_count)"
    if [[ "${count}" -ge "${EXPECTED_ENTRIES}" ]]; then
      log "server holds ${count} entries"
      # The agent syncs on a short interval. Give it a moment to receive them.
      sleep 5
      return 0
    fi
    sleep 1
  done
  log "ERROR: the server never reached ${EXPECTED_ENTRIES} entries (last ${count})"
  return 1
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

  wait_for_sync || return 1
  log "Registration entries present and synced"
}

main "$@"
