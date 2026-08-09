#!/usr/bin/env bash
#
# This script runs the successful authentication demo.
#
# The client runs under UID 10002. The unix workload attestor reports
# unix:uid:10002. A registration entry maps that selector to
# spiffe://lab.local/client, so SPIRE issues the matching X509-SVID.
#
# The client authorizes only spiffe://lab.local/server. The server authorizes
# only spiffe://lab.local/client. Each side proves its identity with a private
# key that stays inside the workload. No file holds a shared secret.
#
# The script exits 0 only when all of these are true:
#   - the client gets the identity spiffe://lab.local/client
#   - the client authenticates the server as spiffe://lab.local/server
#   - the handshake succeeds and the server answers HTTP 200
#   - the server log names the same client identity
#
# The script is safe to run repeatedly. It changes no lab state.

set -euo pipefail

cd "$(dirname "$0")/.."

CLIENT_UID=10002
CLIENT_ID="spiffe://lab.local/client"
SERVER_ID="spiffe://lab.local/server"

SERVER_UID=10001
SERVER_LOG="/var/log/lab/server.log"
AGENT_SOCKET="/run/spire/agent.sock"

# The server writes its request line before it writes the response body, but
# the two processes are independent. Wait some seconds for that log line.
PROOF_ATTEMPTS=10
PROOF_INTERVAL=1

log() { printf '%s\n' "$*"; }

node_root() {
  docker compose exec -T --user 0 node "$@"
}

agent_is_healthy() {
  docker compose exec -T node \
    spire-agent healthcheck -socketPath "${AGENT_SOCKET}" >/dev/null 2>&1
}

server_running() {
  node_root pgrep -x -u "${SERVER_UID}" server >/dev/null 2>&1
}

require_lab_up() {
  if ! agent_is_healthy || ! server_running; then
    log "ERROR: the lab is not running. Run 'make lab-up' first."
    return 1
  fi
}

# log_length counts the lines already in the server log. The demo reads only
# the lines that come after this mark.
log_length() {
  node_root bash -c "wc -l <'${SERVER_LOG}' 2>/dev/null || echo 0" | tr -cd '0-9'
}

new_server_log() {
  local from="$1"
  node_root bash -c "tail -n +$((from + 1)) '${SERVER_LOG}' 2>/dev/null" || true
}

# first_line prints the first line of the client output with the given prefix.
# It prints nothing when the client never wrote that line.
first_line() {
  local prefix="$1" output="$2"
  grep -m1 -- "${prefix}" <<<"${output}" || true
}

# require_line checks one line of the client transcript. The full text after
# the prefix must equal the expected value. The demo already showed the
# transcript, so this function prints only an error.
require_line() {
  local prefix="$1" expected="$2" output="$3"
  local line
  line="$(first_line "^${prefix}" "${output}")"
  if [[ "${line#"${prefix}"}" != "${expected}" ]]; then
    log "ERROR: expected '${prefix}${expected}' in the client output"
    return 1
  fi
}

wait_for_request_log() {
  local from="$1" i
  for ((i = 1; i <= PROOF_ATTEMPTS; i++)); do
    if new_server_log "${from}" \
      | grep -q "GET /hello from authenticated client: ${CLIENT_ID}"; then
      return 0
    fi
    if ((i < PROOF_ATTEMPTS)); then
      sleep "${PROOF_INTERVAL}"
    fi
  done
  return 1
}

narrate() {
  log "The client runs under UID ${CLIENT_UID}."
  log "SPIRE issues it an X509-SVID for ${CLIENT_ID}."
  log "The client accepts only ${SERVER_ID}."
  log "The server accepts only ${CLIENT_ID}."
  log "So the mTLS handshake must succeed."
  log "The handler must answer."
  log ""
}

main() {
  require_lab_up || return 1

  narrate

  local log_start
  log_start="$(log_length)"

  # The client writes its transcript to standard error, so the demo reads both
  # streams. Success is the expected result, so a failure stops the demo.
  local client_output="" client_status=0
  client_output="$(docker compose exec -T --user "${CLIENT_UID}" node client 2>&1)" \
    || client_status=$?

  log "client output:"
  log "${client_output}"
  log ""

  if ((client_status != 0)); then
    log "ERROR: the client stopped with status ${client_status}. The lab is broken."
    return 1
  fi

  # These three lines are the proof on the client side. The first shows the
  # identity that SPIRE gave the client. The second shows the identity that the
  # server proved during the handshake. The third shows the answer.
  require_line 'client SPIFFE ID: ' "${CLIENT_ID}" "${client_output}" || return 1
  require_line 'authenticated server: ' "${SERVER_ID}" "${client_output}" || return 1
  require_line 'HTTP status: ' "200" "${client_output}" || return 1

  if ! grep -qx 'mTLS handshake: SUCCESS' <<<"${client_output}"; then
    log "ERROR: the client reported no successful handshake"
    return 1
  fi

  # The client alone shows only its own view. The server log names the client
  # identity that the server authenticated, so it proves both directions.
  if ! wait_for_request_log "${log_start}"; then
    log "ERROR: the server logged no request from ${CLIENT_ID}"
    new_server_log "${log_start}"
    return 1
  fi
  local proof_line
  proof_line="$(new_server_log "${log_start}" | grep -m1 'GET /hello' || true)"
  log "server log: ${proof_line}"

  log ""
  log "client SPIFFE ID: ${CLIENT_ID}"
  log "server SPIFFE ID: ${SERVER_ID}"
  log "mTLS handshake: SUCCESS"
  log "HTTP status: 200"
  log "Lab test PASSED: two workloads authenticated each other with SPIFFE identities."
}

main "$@"
