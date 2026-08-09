#!/usr/bin/env bash
#
# This script creates the workload registration entries. An entry is the rule
# that turns "which container is this process in?" into "which SPIFFE ID does
# that process get?".
#
#   docker:label:spiffe.lab/workload:server   -> spiffe://lab.local/server
#   docker:label:spiffe.lab/workload:client   -> spiffe://lab.local/client
#   docker:label:spiffe.lab/workload:intruder -> spiffe://lab.local/intruder
#
# Compare this with lab 1, where a UID selector decided the identity. Here all
# workloads share one image and one UID. The container label alone decides.
#
# The script omits the "unregistered" label value on purpose. Access to the
# Workload API does not give an identity.
#
# Docker Compose puts its own labels on every container, for example
# com.docker.compose.project. Each one is also a selector, but the lab never
# names them. Only the lab label is part of the identity rules.
#
# You can run this script repeatedly. The script does not change an entry
# that exists.

set -euo pipefail

cd "$(dirname "$0")/.."

# The Makefile and bootstrap.sh accept the same override, so all three tools
# address one project.
COMPOSE="${COMPOSE:-docker compose}"

TRUST_DOMAIN="lab.local"

# The label key is the same for every workload. Only the value is different.
LABEL_KEY="spiffe.lab/workload"

# Each workload entry uses the node alias as its parent. bootstrap.sh binds
# this alias to the agent. The agent's own join_token ID is not usable as a
# parent. That ID changes on every join, and /spire/... is a reserved path.
PARENT_ID="spiffe://${TRUST_DOMAIN}/node"

# The label value is also the last path segment of the SPIFFE ID.
# "unregistered" is absent by design.
WORKLOADS=(
  server
  client
  intruder
)

# The proof step fetches as this workload.
PROOF_WORKLOAD="client"
PROOF_ID="spiffe://${TRUST_DOMAIN}/${PROOF_WORKLOAD}"

AGENT_SOCKET="/run/spire/agent.sock"

# On a slow machine, set this environment variable to a larger number.
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-30}"

log() { printf '%s\n' "$*"; }

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  ${COMPOSE} exec -T spire-server /opt/spire/bin/spire-server "$@"
}

# This function asks the Workload API as a labeled workload container.
# "compose run" starts a new container for each call, and the service label
# goes on it. The arguments after the service name replace the command of
# the service.
fetch_as() {
  local workload="$1" timeout="$2"
  ${COMPOSE} run --rm "${workload}" \
    spire-agent api fetch x509 -socketPath "${AGENT_SOCKET}" -timeout "${timeout}"
}

# The check matches the parent ID, the SPIFFE ID, and the selector. It then
# requires exactly one entry with exactly one selector. An entry with an
# extra selector does not match the workload, so it must not count as the
# wanted rule.
entry_exists() {
  local spiffe_id="$1" selector="$2" shown
  shown="$(spire_server entry show \
    -parentID "${PARENT_ID}" \
    -spiffeID "${spiffe_id}" \
    -selector "${selector}")" || return 1
  [[ "$(grep -c '^Entry ID' <<<"${shown}")" == "1" ]] || return 1
  [[ "$(grep -c '^Selector' <<<"${shown}")" == "1" ]] || return 1
}

# "entry create" has no upsert, and a duplicate fails the whole batch.
# Therefore the function looks first. It creates only a missing entry.
# The function prints one line per entry with its state.
ensure_entry() {
  local workload="$1"
  local spiffe_id="spiffe://${TRUST_DOMAIN}/${workload}"
  local selector="docker:label:${LABEL_KEY}:${workload}"

  local state="exists"
  if ! entry_exists "${spiffe_id}" "${selector}"; then
    spire_server entry create \
      -parentID "${PARENT_ID}" \
      -spiffeID "${spiffe_id}" \
      -selector "${selector}" >/dev/null
    state="created"
    CREATED_WORKLOADS+=("${workload}")
  fi
  log "  ${selector} -> ${spiffe_id} (${state})"
}

# A new entry reaches the agent on its next sync cycle, not immediately.
# The function waits for every entry that this run created. A wait on one
# workload alone is not enough: on a partial rerun, a cached identity can
# answer before the new entries arrive.
wait_for_propagation() {
  local workload i
  for workload in "${CREATED_WORKLOADS[@]}"; do
    for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
      fetch_as "${workload}" 2s >/dev/null 2>&1 && continue 2
      sleep 1
    done
    log "ERROR: the ${workload} entry did not reach the agent in ${WAIT_ATTEMPTS} attempts"
    return 1
  done
}

# The proof shows that the label decides the identity. The client container
# holds no certificate and no key. It asks the Workload API, and the agent
# answers with the SPIFFE ID of its label. The check requires exactly one
# identity. The Workload API can serve several SVIDs to one workload, and a
# second identity means broken entries.
prove_identity() {
  local output
  if ! output="$(fetch_as "${PROOF_WORKLOAD}" 10s 2>&1)"; then
    log "ERROR: the proof fetch as ${PROOF_WORKLOAD} failed"
    log "${output}"
    return 1
  fi

  local ids
  ids="$(awk '/^SPIFFE ID:/ { print $3 }' <<<"${output}")"
  if [[ "${ids}" != "${PROOF_ID}" ]]; then
    log "ERROR: the ${PROOF_WORKLOAD} container got '${ids//$'\n'/, }', expected exactly '${PROOF_ID}'"
    return 1
  fi
  log "label ${LABEL_KEY}=${PROOF_WORKLOAD} -> ${ids}"
}

main() {
  if ! spire_server healthcheck >/dev/null 2>&1; then
    log "ERROR: SPIRE Server is not answering. Run scripts/bootstrap.sh first."
    return 1
  fi

  CREATED_WORKLOADS=()
  local workload
  for workload in "${WORKLOADS[@]}"; do
    ensure_entry "${workload}"
  done

  wait_for_propagation || return 1

  if ((${#CREATED_WORKLOADS[@]} > 0)); then
    log "Registration entries created"
  else
    log "Registration entries already present"
  fi

  prove_identity
}

main "$@"
