#!/usr/bin/env bash
#
# Brings the one SPIRE agent from "nothing" to "attested". The steps follow the
# SPIFFE node attestation order:
#   1. wait for the server to answer
#   2. give the agent the trust bundle, so it can verify the server
#   3. mint a one-time join token, aliased to a stable node identity
#   4. start the agent with that token
#   5. wait until the agent serves the Workload API
#   6. delete the token file
#
# The script is idempotent. An already-healthy agent stays untouched. The token
# never appears on a command line, which is public through /proc on the host.
# insecure_bootstrap is not used; the bootstrap always pins the bundle.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
TRUST_DOMAIN="lab.local"

# A token-joined agent gets a name that changes on every join, and /spire/... is
# reserved. So the token carries a stable node alias. The workload entries name
# this alias as their parent.
NODE_ALIAS_ID="spiffe://${TRUST_DOMAIN}/node"

AGENT_SOCKET="/run/spire/agent.sock"
AGENT_CONFIG="/opt/spire/conf/agent/agent.conf"
BUNDLE_PATH="/run/spire/bootstrap.crt"
TOKEN_FILE="/var/lib/spire/join_token"
AGENT_LOG="/var/log/lab/agent.log"

WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-60}"

log() { printf '%s\n' "$*"; }
spire_server() { ${COMPOSE} exec -T spire-server /opt/spire/bin/spire-server "$@"; }
agent_exec() { ${COMPOSE} exec -T spire-agent "$@"; }

agent_is_healthy() {
  agent_exec spire-agent healthcheck -socketPath "${AGENT_SOCKET}" >/dev/null 2>&1
}

wait_for_server() {
  local i
  for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
    spire_server healthcheck >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

wait_for_agent() {
  local i
  for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
    agent_is_healthy && return 0
    sleep 1
  done
  return 1
}

main() {
  if ! wait_for_server; then
    log "ERROR: SPIRE Server did not become healthy"
    ${COMPOSE} logs --tail 40 spire-server
    return 1
  fi
  log "SPIRE Server healthy"

  if agent_is_healthy; then
    log "SPIRE Agent already attested"
    return 0
  fi

  # The agent must trust the server CA before it attests. The bundle is public
  # material, but the lab still delivers it at runtime and commits no copy.
  spire_server bundle show -format pem | agent_exec tee "${BUNDLE_PATH}" >/dev/null
  log "trust bundle written to spire-agent:${BUNDLE_PATH}"

  # One token, one join. The node alias gives the agent a stable parent ID.
  local join_token
  join_token="$(spire_server token generate -spiffeID "${NODE_ALIAS_ID}" \
    | awk '/^Token:/ { print $2 }')"
  if [[ -z "${join_token}" ]]; then
    log "ERROR: could not parse a join token"
    return 1
  fi
  log "join token generated, node alias ${NODE_ALIAS_ID} (token not shown)"

  # The token goes into a root-only file inside the agent container. It never
  # appears on a command line, which is public through /proc on the host.
  printf '%s\n' "${join_token}" \
    | agent_exec bash -c 'umask 077; cat > "'"${TOKEN_FILE}"'"'

  agent_exec bash -c '
    nohup spire-agent run -config "'"${AGENT_CONFIG}"'" \
      -joinTokenFile "'"${TOKEN_FILE}"'" >>"'"${AGENT_LOG}"'" 2>&1 &
    echo started
  ' >/dev/null

  if ! wait_for_agent; then
    log "ERROR: SPIRE Agent did not attest"
    agent_exec tail -n 40 "${AGENT_LOG}" || true
    return 1
  fi

  # Delete the token file. The token is single-use and now spent.
  agent_exec rm -f "${TOKEN_FILE}" >/dev/null 2>&1 || true
  log "SPIRE Agent attested"
}

main "$@"
