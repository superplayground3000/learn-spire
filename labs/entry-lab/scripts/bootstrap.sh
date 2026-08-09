#!/usr/bin/env bash
#
# Brings the SPIRE agent from "nothing" to "attested", in the order SPIFFE
# describes node attestation:
#
#   1. wait for the server to answer
#   2. give the agent the trust bundle, so it can verify the server
#   3. mint a one-time join token, aliased to a stable node identity
#   4. start the agent with that token
#   5. wait until the agent serves the Workload API
#
# Safe to run repeatedly: an already-attested agent is left alone, and an agent
# that merely stopped is restarted with the identity it already has.

set -euo pipefail

cd "$(dirname "$0")/.."

TRUST_DOMAIN="lab.local"

# SPIRE names an agent that joined with a token
# spiffe://lab.local/spire/agent/join_token/<token>, which changes on every
# join, and /spire/... is a reserved path we may not assign ourselves. So the
# token also carries a node alias: a second, stable identity for this node that
# workload registration entries can name as their parent.
NODE_ALIAS_ID="spiffe://${TRUST_DOMAIN}/node"

AGENT_SOCKET="/run/spire/agent.sock"
AGENT_CONFIG="/opt/spire/conf/agent/agent.conf"
AGENT_DATA_DIR="/var/lib/spire/agent"
BUNDLE_PATH="/run/spire/bootstrap.crt"
AGENT_LOG="/var/log/lab/agent.log"

WAIT_ATTEMPTS=60
RESTART_WAIT_ATTEMPTS=15
WAIT_INTERVAL=1

log() { printf '%s\n' "$*"; }

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  docker compose exec -T spire-server /opt/spire/bin/spire-server "$@"
}

node_root() {
  docker compose exec -T --user 0 node "$@"
}

agent_is_healthy() {
  docker compose exec -T node \
    spire-agent healthcheck -socketPath "${AGENT_SOCKET}" >/dev/null 2>&1
}

# True once the agent has completed a node attestation at least once.
agent_has_identity() {
  node_root test -s "${AGENT_DATA_DIR}/agent-data.json" >/dev/null 2>&1
}

wait_for_server() {
  local i
  for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
    spire_server healthcheck >/dev/null 2>&1 && return 0
    sleep "${WAIT_INTERVAL}"
  done
  return 1
}

wait_for_agent() {
  local attempts="${1:-${WAIT_ATTEMPTS}}" i
  for ((i = 1; i <= attempts; i++)); do
    agent_is_healthy && return 0
    sleep "${WAIT_INTERVAL}"
  done
  return 1
}

export_trust_bundle() {
  # The agent has to trust the server's CA *before* it attests, otherwise the
  # very first connection could be intercepted. The bundle is public material,
  # but it is still delivered at runtime rather than committed, so the lab has
  # exactly one source of truth for trust: the running server.
  spire_server bundle show -format pem \
    | node_root tee "${BUNDLE_PATH}" >/dev/null
  log "trust bundle written to node:${BUNDLE_PATH}"
}

agent_process_running() {
  node_root pgrep -x spire-agent >/dev/null 2>&1
}

# Stops any running agent and waits until the process is actually gone, so a
# replacement never overlaps with it on the socket or the data directory.
stop_agent() {
  node_root pkill -x spire-agent >/dev/null 2>&1 || true
  local i
  for ((i = 1; i <= 10; i++)); do
    agent_process_running || return 0
    sleep "${WAIT_INTERVAL}"
  done
  node_root pkill -9 -x spire-agent >/dev/null 2>&1 || true
  sleep 1
}

# Starts the agent in the background inside the node. With an empty token the
# agent re-uses the identity in its data dir instead of joining again.
#
# The agent runs as root because the unix workload attestor inspects /proc
# entries belonging to other users.
launch_agent() {
  local token="$1"

  # Never leave two agents fighting over one socket.
  stop_agent

  # The token reaches the agent over stdin, so it stays out of this script's
  # output and out of the docker command line.
  printf '%s\n' "${token}" | node_root bash -c '
    read -r token || true
    args=(run -config '"${AGENT_CONFIG}"')
    if [ -n "${token}" ]; then
      args+=(-joinToken "${token}")
    fi
    nohup spire-agent "${args[@]}" >>'"${AGENT_LOG}"' 2>&1 &
    sleep 0.2
  '
}

join_with_new_token() {
  local join_token

  # One token, one join. It lives in this variable only: never a file, never a
  # log line.
  join_token="$(spire_server token generate -spiffeID "${NODE_ALIAS_ID}" \
    | awk '/^Token:/ { print $2 }')"
  if [[ -z "${join_token}" ]]; then
    log "ERROR: could not parse a join token from 'spire-server token generate'"
    return 1
  fi
  log "join token generated, node alias ${NODE_ALIAS_ID} (token not shown)"

  launch_agent "${join_token}"
}

attest_agent() {
  if agent_has_identity; then
    log "node already holds an agent identity, restarting the agent without a new token"
    launch_agent ""
    wait_for_agent "${RESTART_WAIT_ATTEMPTS}" && return 0

    # Still-running agent after the short wait means a slow start, not a dead
    # identity: give it the full window before doing anything destructive.
    if agent_process_running; then
      wait_for_agent && return 0
    fi

    # The restarted agent gave up: its stored SVID has expired, and a
    # join_token agent cannot re-attest, so it has to join again as a brand
    # new node. Make sure it is fully stopped before its state is deleted.
    log "stored identity is no longer usable, joining again from scratch"
    stop_agent
    node_root rm -rf "${AGENT_DATA_DIR}"
    node_root mkdir -p "${AGENT_DATA_DIR}"
  fi

  join_with_new_token
  wait_for_agent
}

main() {
  if ! wait_for_server; then
    log "ERROR: SPIRE Server did not become healthy in $((WAIT_ATTEMPTS * WAIT_INTERVAL))s"
    docker compose logs --tail 40 spire-server
    return 1
  fi
  log "SPIRE Server healthy"

  if agent_is_healthy; then
    log "SPIRE Agent attested (already running)"
    return 0
  fi

  export_trust_bundle

  if ! attest_agent; then
    log "ERROR: SPIRE Agent did not attest"
    node_root tail -n 40 "${AGENT_LOG}" || true
    return 1
  fi
  log "SPIRE Agent attested"
}

main "$@"
