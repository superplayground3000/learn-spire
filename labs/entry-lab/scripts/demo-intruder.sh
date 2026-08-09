#!/usr/bin/env bash
#
# This script runs the unauthorized client demo.
#
# The intruder runs the same client binary under UID 10003. The unix workload
# attestor reports unix:uid:10003. A registration entry maps that selector to
# spiffe://lab.local/intruder, so SPIRE issues a fully valid X509-SVID.
#
# The server accepts only spiffe://lab.local/client. The TLS handshake fails,
# and the HTTP handler never runs. The demo shows that a valid identity is not
# an authorized identity.
#
# The denial is the pass. The script exits 0 when the handshake fails. The
# script exits 1 when the request succeeds, because a success means a broken
# lab.
#
# The script is safe to run repeatedly. It changes no lab state.

set -euo pipefail

cd "$(dirname "$0")/.."

INTRUDER_UID=10003
INTRUDER_ID="spiffe://lab.local/intruder"
AUTHORIZED_ID="spiffe://lab.local/client"

SERVER_UID=10001
SERVER_LOG="/var/log/lab/server.log"
AGENT_SOCKET="/run/spire/agent.sock"

# The server writes its handshake error after it sends the TLS alert. The
# client can return first, so wait some seconds for that log line.
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

wait_for_denial_log() {
  local from="$1" i
  for ((i = 1; i <= PROOF_ATTEMPTS; i++)); do
    if new_server_log "${from}" | grep -q "unexpected ID \"${INTRUDER_ID}\""; then
      return 0
    fi
    if ((i < PROOF_ATTEMPTS)); then
      sleep "${PROOF_INTERVAL}"
    fi
  done
  return 1
}

narrate() {
  log "The intruder runs the same client binary under UID ${INTRUDER_UID}."
  log "SPIRE issues it a valid X509-SVID for ${INTRUDER_ID}."
  log "The server authorizes only ${AUTHORIZED_ID}."
  log "So the mTLS handshake must fail, and the handler must never run."
  log ""
}

main() {
  require_lab_up || return 1

  narrate

  local log_start
  log_start="$(log_length)"

  # The client writes its transcript to standard error, so the demo reads both
  # streams. A failure is the expected result, so keep the exit status.
  local client_output="" client_status=0
  client_output="$(docker compose exec -T --user "${INTRUDER_UID}" node client 2>&1)" \
    || client_status=$?

  # The identity line proves that SPIRE gave the intruder a real SVID.
  # Without this line, the demo shows a Workload API failure, which is a
  # different test.
  local id_line observed_id
  id_line="$(first_line '^client SPIFFE ID: ' "${client_output}")"
  observed_id="${id_line##* }"
  if [[ "${observed_id}" != "${INTRUDER_ID}" ]]; then
    log "ERROR: the intruder got no SVID for ${INTRUDER_ID}"
    log "${client_output}"
    return 1
  fi
  log "intruder SPIFFE ID: ${observed_id}"

  if ((client_status == 0)); then
    log "ERROR: the server accepted the intruder. The lab is broken."
    log "${client_output}"
    return 1
  fi

  local failure_line
  failure_line="$(first_line '^client failed: ' "${client_output}")"
  if [[ -z "${failure_line}" ]]; then
    log "ERROR: the client stopped without a failure line"
    log "${client_output}"
    return 1
  fi
  log "${failure_line}"

  # The client alone cannot prove why the handshake failed. The server log
  # names the rejected SPIFFE ID, so it gives the real reason.
  if ! wait_for_denial_log "${log_start}"; then
    log "ERROR: the server logged no rejection of ${INTRUDER_ID}"
    new_server_log "${log_start}"
    return 1
  fi
  local proof_line
  proof_line="$(new_server_log "${log_start}" | grep -m1 'unexpected ID' || true)"
  log "server log: ${proof_line}"

  # Section 13 requires that the HTTP handler never runs. The server writes
  # one line per served request, so a new request line breaks this rule.
  if new_server_log "${log_start}" | grep -q 'GET /hello'; then
    log "ERROR: the server ran the handler for the intruder. The lab is broken."
    new_server_log "${log_start}"
    return 1
  fi
  log "the server served no GET /hello during this demo"

  log ""
  log "mTLS handshake: DENIED"
  log "Lab test PASSED: a valid identity is not an authorized identity."
}

main "$@"
