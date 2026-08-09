#!/usr/bin/env bash
#
# Creates the workload registration entries: the rules that turn "which UID is
# this process?" into "which SPIFFE ID does that process get?".
#
#   unix:uid:10001 -> spiffe://lab.local/server
#   unix:uid:10002 -> spiffe://lab.local/client
#   unix:uid:10003 -> spiffe://lab.local/intruder
#
# UID 10004 is left out on purpose: reaching the Workload API is not enough to
# be handed an identity, and the unregistered demo shows exactly that.
#
# Safe to run repeatedly: an entry that already exists is left untouched.

set -euo pipefail

cd "$(dirname "$0")/.."

TRUST_DOMAIN="lab.local"

# Every workload entry hangs off the node alias that bootstrap.sh pinned to the
# agent's join token. The agent's own join_token ID is unusable as a parent: it
# is regenerated on every join and lives under the reserved /spire/... path.
PARENT_ID="spiffe://${TRUST_DOMAIN}/node"

# "<uid> <workload>", where the workload name is also the last path segment of
# its SPIFFE ID. 10004 is absent by design.
ENTRIES=(
  "10001 server"
  "10002 client"
  "10003 intruder"
)

log() { printf '%s\n' "$*"; }

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  docker compose exec -T spire-server /opt/spire/bin/spire-server "$@"
}

# The check matches the parent ID, the SPIFFE ID, and the selector. A match on
# all three means the rule is in place. Note: the check does not compare full
# selector sets, but only this script writes entries in this lab.
entry_exists() {
  local spiffe_id="$1" selector="$2"
  spire_server entry show \
    -parentID "${PARENT_ID}" \
    -spiffeID "${spiffe_id}" \
    -selector "${selector}" \
    | grep '^Entry ID' >/dev/null
}

# "entry create" has no upsert. If you give it a duplicate, it fails the whole
# batch. So look first, and create only what is missing. Prints one line per
# entry with its state.
ensure_entry() {
  local uid="$1" workload="$2"
  local spiffe_id="spiffe://${TRUST_DOMAIN}/${workload}"
  local selector="unix:uid:${uid}"

  local state="exists"
  if ! entry_exists "${spiffe_id}" "${selector}"; then
    spire_server entry create \
      -parentID "${PARENT_ID}" \
      -spiffeID "${spiffe_id}" \
      -selector "${selector}" >/dev/null
    state="created"
    CREATED_COUNT=$((CREATED_COUNT + 1))
  fi
  log "  ${selector} -> ${spiffe_id} (${state})"
}

# New entries reach the agent on its next sync cycle, not immediately. Wait
# until the agent can issue an SVID for one of them. Then the demos work
# directly after lab-up.
wait_for_propagation() {
  local i
  for ((i = 1; i <= 30; i++)); do
    docker compose exec -T --user 10001 node \
      spire-agent api fetch x509 -socketPath /run/spire/agent.sock -timeout 2s \
      >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

main() {
  if ! spire_server healthcheck >/dev/null 2>&1; then
    log "ERROR: SPIRE Server is not answering; run scripts/bootstrap.sh first"
    return 1
  fi

  CREATED_COUNT=0
  local entry uid workload
  for entry in "${ENTRIES[@]}"; do
    read -r uid workload <<<"${entry}"
    ensure_entry "${uid}" "${workload}"
  done

  if ! wait_for_propagation; then
    log "ERROR: entries did not reach the agent in 30s"
    return 1
  fi

  if ((CREATED_COUNT > 0)); then
    log "Registration entries created"
  else
    log "Registration entries already present"
  fi
}

main "$@"
