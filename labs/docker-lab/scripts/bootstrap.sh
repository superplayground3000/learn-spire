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
# The agent has its own container in this lab. The steps are the same as in
# lab 1, but each one runs in the "spire-agent" container instead of "node".
#
# Safe to run repeatedly: an already-attested agent is left alone. An agent
# that merely stopped is restarted with the identity it already has.

set -euo pipefail

cd "$(dirname "$0")/.."

# The Makefile accepts the same override, so both tools address one project.
COMPOSE="${COMPOSE:-docker compose}"

TRUST_DOMAIN="lab.local"

# SPIRE names a token-joined agent spiffe://lab.local/spire/agent/join_token/
# <token>. That name changes on every join. Also, /spire/... is a reserved
# path, so the lab must not assign it. Therefore the token carries a node
# alias: a second, stable identity for this node. The workload registration
# entries name that alias as their parent.
NODE_ALIAS_ID="spiffe://${TRUST_DOMAIN}/node"

AGENT_SOCKET="/run/spire/agent.sock"
AGENT_CONFIG="/opt/spire/conf/agent/agent.conf"
AGENT_DATA_DIR="/var/lib/spire/agent"
BUNDLE_PATH="/run/spire/bootstrap.crt"
AGENT_LOG="/var/log/lab/agent.log"

# The PID file names the one agent process this script owns. The container
# shares the host PID namespace, so a name match alone is not safe: a name
# match hits every spire-agent on the host, also the one of lab 1.
PID_FILE="/var/lib/spire/agent.pid"

# The join token waits here between "minted" and "read by the agent". The
# path is private to the agent container, and the file mode is 0600. The
# script deletes the file directly after the join.
TOKEN_FILE="/var/lib/spire/join_token"

# A slow machine can override these numbers from the environment.
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-60}"
RESTART_WAIT_ATTEMPTS="${RESTART_WAIT_ATTEMPTS:-15}"
WAIT_INTERVAL=1

log() { printf '%s\n' "$*"; }

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  ${COMPOSE} exec -T spire-server /opt/spire/bin/spire-server "$@"
}

# The agent image runs as root, so no user flag is needed here.
agent_exec() {
  ${COMPOSE} exec -T spire-agent "$@"
}

agent_is_healthy() {
  agent_exec spire-agent healthcheck -socketPath "${AGENT_SOCKET}" >/dev/null 2>&1
}

# True once the agent has completed a node attestation at least once.
agent_has_identity() {
  agent_exec test -s "${AGENT_DATA_DIR}/agent-data.json" >/dev/null 2>&1
}

# True while the process from the PID file runs and is really a spire-agent.
# The comm check protects against a stale PID that the kernel reused.
agent_process_running() {
  agent_exec bash -c '
    test -s "'"${PID_FILE}"'" || exit 1
    pid="$(cat "'"${PID_FILE}"'")"
    test "$(cat /proc/${pid}/comm 2>/dev/null)" = "spire-agent"
  ' >/dev/null 2>&1
}

signal_agent() {
  agent_exec bash -c 'kill '"$1"' "$(cat "'"${PID_FILE}"'")"' >/dev/null 2>&1 || true
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
  # The agent must trust the server's CA before it attests. Without that,
  # an attacker can intercept the very first connection. The bundle is
  # public material. The lab still delivers it at runtime and commits no
  # copy, so the running server stays the only source of trust.
  spire_server bundle show -format pem \
    | agent_exec tee "${BUNDLE_PATH}" >/dev/null
  log "trust bundle written to spire-agent:${BUNDLE_PATH}"
}

# Stops the owned agent process and waits until it is really gone. A
# replacement must never overlap with it on the socket or the data
# directory. Also removes the PID file and a possible stale token file.
stop_agent() {
  if agent_process_running; then
    signal_agent -TERM
    local i
    for ((i = 1; i <= 10; i++)); do
      agent_process_running || break
      sleep "${WAIT_INTERVAL}"
    done
    if agent_process_running; then
      signal_agent -KILL
      sleep 1
      if agent_process_running; then
        log "ERROR: the old agent process does not stop"
        return 1
      fi
    fi
  fi
  agent_exec rm -f "${PID_FILE}" "${TOKEN_FILE}" >/dev/null 2>&1 || true
}

# Starts the agent in the background inside its container. If the token file
# is absent, the agent re-uses the identity in its data directory.
#
# The agent runs as root for two reasons. It reads /proc entries of workload
# processes, and it opens the Docker socket.
launch_agent() {
  local token="$1"

  # Never leave two agents fighting over one socket. The explicit return
  # matters: this function often runs inside an "if", where "set -e" does
  # not stop a failed command.
  stop_agent || return 1

  # The token goes into a root-only file inside the agent container. It
  # never appears in a log line, in a repository file, or on a command
  # line. A command line is public on the host through /proc.
  if [[ -n "${token}" ]]; then
    printf '%s\n' "${token}" \
      | agent_exec bash -c 'umask 077; cat > "'"${TOKEN_FILE}"'"'
  fi

  agent_exec bash -c '
    args=(run -config "'"${AGENT_CONFIG}"'")
    if [ -s "'"${TOKEN_FILE}"'" ]; then
      args+=(-joinTokenFile "'"${TOKEN_FILE}"'")
    fi
    nohup spire-agent "${args[@]}" >>"'"${AGENT_LOG}"'" 2>&1 &
    echo $! > "'"${PID_FILE}"'"
  '
}

remove_token_file() {
  agent_exec rm -f "${TOKEN_FILE}" >/dev/null 2>&1 || true
}

join_with_new_token() {
  local join_token result=0

  # One token, one join. Between the two commands it lives in this variable
  # and in the protected token file: never in a log, never in the repo.
  join_token="$(spire_server token generate -spiffeID "${NODE_ALIAS_ID}" \
    | awk '/^Token:/ { print $2 }')"
  if [[ -z "${join_token}" ]]; then
    log "ERROR: could not parse a join token from 'spire-server token generate'"
    return 1
  fi
  log "join token generated, node alias ${NODE_ALIAS_ID} (token not shown)"

  launch_agent "${join_token}" || { remove_token_file; return 1; }
  wait_for_agent || result=1
  remove_token_file
  return "${result}"
}

attest_agent() {
  if agent_has_identity; then
    log "the agent already holds an identity, restarting it without a new token"
    launch_agent "" || return 1
    wait_for_agent "${RESTART_WAIT_ATTEMPTS}" && return 0

    # A still-running agent after the short wait means a slow start, not a
    # dead identity. Give it the full window before any destructive step.
    if agent_process_running; then
      wait_for_agent && return 0
    fi

    # The restarted agent gave up. Its stored SVID has expired, and a
    # join_token agent cannot re-attest. It has to join again as a brand
    # new node. Stop it fully before its state is deleted.
    log "stored identity is no longer usable, joining again from scratch"
    # Delete the state only after the old process is proven gone.
    stop_agent || return 1
    agent_exec rm -rf "${AGENT_DATA_DIR}"
    agent_exec mkdir -p "${AGENT_DATA_DIR}"
  fi

  join_with_new_token
}

main() {
  if ! wait_for_server; then
    log "ERROR: SPIRE Server did not become healthy in $((WAIT_ATTEMPTS * WAIT_INTERVAL))s"
    ${COMPOSE} logs --tail 40 spire-server
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
    agent_exec tail -n 40 "${AGENT_LOG}" || true
    return 1
  fi
  log "SPIRE Agent attested"
}

main "$@"
