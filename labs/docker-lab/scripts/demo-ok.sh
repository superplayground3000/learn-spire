#!/usr/bin/env bash
#
# This script runs the successful authentication demo.
#
# The client runs in its own container with the label
# spiffe.lab/workload=client. The docker workload attestor reports
# docker:label:spiffe.lab/workload:client. A registration entry maps that
# selector to spiffe://lab.local/client, so SPIRE issues the matching
# X509-SVID.
#
# The client and the server run the same image, under the same user. Only the
# label is different. The label alone gives each one its identity.
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
# You can run this script repeatedly. The script changes no lab state.

set -euo pipefail

cd "$(dirname "$0")/.."

# The Makefile and the other scripts accept the same override, so all tools
# address one project.
COMPOSE="${COMPOSE:-docker compose}"

CLIENT_SERVICE="client"
SERVER_SERVICE="server"

CLIENT_LABEL="spiffe.lab/workload=client"
CLIENT_ID="spiffe://lab.local/client"
SERVER_ID="spiffe://lab.local/server"

AGENT_SOCKET="/run/spire/agent.sock"

# The server writes its request line before it writes the response body, but
# the two containers are independent. Wait some seconds for that log line.
PROOF_ATTEMPTS=10
PROOF_INTERVAL=1

log() { printf '%s\n' "$*"; }

agent_is_healthy() {
  ${COMPOSE} exec -T spire-agent \
    spire-agent healthcheck -socketPath "${AGENT_SOCKET}" >/dev/null 2>&1
}

server_running() {
  ${COMPOSE} ps --status running --services 2>/dev/null \
    | grep -x "${SERVER_SERVICE}" >/dev/null
}

require_lab_up() {
  if ! agent_is_healthy || ! server_running; then
    log "ERROR: the lab is not running. Run 'make lab-up' first."
    return 1
  fi
}

# mark_time prints the current time with nanoseconds. The demo reads only
# the server log lines after this mark. A time mark survives a container
# replacement, and repeated demos in one second stay separate.
mark_time() {
  date -u +%Y-%m-%dT%H:%M:%S.%NZ
}

# read_log_since prints the server log lines after the mark. A failed read
# is a real error. The caller must not treat it as an empty log.
read_log_since() {
  ${COMPOSE} logs --no-log-prefix --since "$1" "${SERVER_SERVICE}"
}

# run_client starts a client container for this demo alone. "--rm" deletes the
# container after the run. The quiet progress keeps the compose status lines
# out of the transcript. Compose still reports its own errors. The flag needs
# Compose v2.19 or later.
run_client() {
  ${COMPOSE} --progress quiet run --rm "${CLIENT_SERVICE}"
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
  local since="$1" i lines
  for ((i = 1; i <= PROOF_ATTEMPTS; i++)); do
    if ! lines="$(read_log_since "${since}" 2>&1)"; then
      log "ERROR: cannot read the log of the ${SERVER_SERVICE} service"
      log "${lines}"
      return 1
    fi
    # -F keeps the dots in the SPIFFE ID literal. Plain grep reads the full
    # input, so pipefail sees no broken pipe.
    if grep -F "GET /hello from authenticated client: ${CLIENT_ID}" \
      >/dev/null <<<"${lines}"; then
      return 0
    fi
    if ((i < PROOF_ATTEMPTS)); then
      sleep "${PROOF_INTERVAL}"
    fi
  done
  return 1
}

narrate() {
  log "The client container carries the label ${CLIENT_LABEL}."
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

  local mark
  mark="$(mark_time)"

  # The client writes its transcript to standard error, so the demo reads both
  # streams. "compose run" reports the exit status of the client. Success is
  # the expected result, so a failure stops the demo.
  local client_output="" client_status=0
  client_output="$(run_client 2>&1)" || client_status=$?

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
  if ! wait_for_request_log "${mark}"; then
    log "ERROR: the server logged no request from ${CLIENT_ID}"
    read_log_since "${mark}" 2>&1 || true
    return 1
  fi
  local proof_line
  proof_line="$(read_log_since "${mark}" 2>/dev/null | grep -m1 -F 'GET /hello' || true)"
  log "server log: ${proof_line}"

  log ""
  log "client SPIFFE ID: ${CLIENT_ID}"
  log "server SPIFFE ID: ${SERVER_ID}"
  log "mTLS handshake: SUCCESS"
  log "HTTP status: 200"
  log "Lab test PASSED: two labeled containers authenticated each other with SPIFFE identities."
}

main "$@"
