#!/usr/bin/env bash
#
# This script runs the unauthorized client demo.
#
# The intruder runs the same client binary as the client. Only the container
# label is different: spiffe.lab/workload=intruder. The docker workload
# attestor reports docker:label:spiffe.lab/workload:intruder. A registration
# entry maps that selector to spiffe://lab.local/intruder, so SPIRE issues a
# fully valid X509-SVID.
#
# The server authorizes only spiffe://lab.local/client. The mTLS handshake
# fails, and the HTTP handler never runs. The demo shows that a valid identity
# is not an authorized identity.
#
# The denial is the pass. The script exits 0 when the handshake fails for the
# right reason. The script exits 1 when the request succeeds, because a success
# means a broken lab. The script also exits 1 when the run fails for another
# reason, because such a run proves nothing.
#
# You can run this script repeatedly. The script changes no lab state.

set -euo pipefail

cd "$(dirname "$0")/.."

# The Makefile and the other scripts accept the same override, so all tools
# address one project.
COMPOSE="${COMPOSE:-docker compose}"

INTRUDER_SERVICE="intruder"
SERVER_SERVICE="server"

INTRUDER_LABEL="spiffe.lab/workload=intruder"
INTRUDER_ID="spiffe://lab.local/intruder"
AUTHORIZED_ID="spiffe://lab.local/client"

# The Go TLS stack reports the alert of the server with this text. Only this
# error proves a refused handshake. A connection error is a different failure.
TLS_ALERT="remote error: tls: bad certificate"

# The server names the rejected SPIFFE ID in its handshake error.
DENIAL_TEXT="unexpected ID \"${INTRUDER_ID}\""

AGENT_SOCKET="/run/spire/agent.sock"

# The server writes its handshake error after it sends the TLS alert. The
# client can return first, so wait some seconds for that log line.
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

# mark_time prints the current time with nanoseconds. The demo reads only the
# server log lines after this mark. A time mark survives a container
# replacement, and repeated demos in one second stay separate.
mark_time() {
  date -u +%Y-%m-%dT%H:%M:%S.%NZ
}

# read_log_since prints the server log lines after the mark. A failed read is
# a real error. The caller must not treat it as an empty log.
read_log_since() {
  ${COMPOSE} logs --no-log-prefix --since "$1" "${SERVER_SERVICE}"
}

# run_intruder starts an intruder container for this demo alone. "--rm" deletes
# the container after the run. The quiet progress keeps the compose status
# lines out of the transcript. Compose still reports its own errors. The flag
# needs Compose v2.19 or later.
run_intruder() {
  ${COMPOSE} --progress quiet run --rm "${INTRUDER_SERVICE}"
}

# first_line prints the first line of the client output with the given prefix.
# It prints nothing when the client never wrote that line.
first_line() {
  local prefix="$1" output="$2"
  grep -m1 -- "${prefix}" <<<"${output}" || true
}

wait_for_denial_log() {
  local since="$1" i lines
  for ((i = 1; i <= PROOF_ATTEMPTS; i++)); do
    if ! lines="$(read_log_since "${since}" 2>&1)"; then
      log "ERROR: cannot read the log of the ${SERVER_SERVICE} service"
      log "${lines}"
      return 1
    fi
    # -F keeps the dots in the SPIFFE ID literal. Plain grep reads the full
    # input, so pipefail sees no broken pipe.
    if grep -F "${DENIAL_TEXT}" >/dev/null <<<"${lines}"; then
      return 0
    fi
    if ((i < PROOF_ATTEMPTS)); then
      sleep "${PROOF_INTERVAL}"
    fi
  done
  return 1
}

narrate() {
  log "The intruder container carries the label ${INTRUDER_LABEL}."
  log "It runs the same binary and the same image as the client."
  log "SPIRE issues it a valid X509-SVID for ${INTRUDER_ID}."
  log "The server authorizes only ${AUTHORIZED_ID}."
  log "So the mTLS handshake must fail."
  log "The handler must never run."
  log ""
}

main() {
  require_lab_up || return 1

  narrate

  local mark
  mark="$(mark_time)"

  # The client writes its transcript to standard error, so the demo reads both
  # streams. A failure is the expected result, so keep the exit status.
  local intruder_output="" intruder_status=0
  intruder_output="$(run_intruder 2>&1)" || intruder_status=$?

  log "intruder output:"
  log "${intruder_output}"
  log ""

  # Proof 1. The identity line shows that SPIRE gave the intruder a real SVID.
  # Without this line, the demo shows a Workload API failure. That is a
  # different test, and it proves nothing about authorization.
  local id_line observed_id
  id_line="$(first_line '^client SPIFFE ID: ' "${intruder_output}")"
  observed_id="${id_line##* }"
  if [[ "${observed_id}" != "${INTRUDER_ID}" ]]; then
    log "ERROR: the intruder got no SVID for ${INTRUDER_ID}"
    return 1
  fi
  log "intruder SPIFFE ID: ${observed_id}"

  # Proof 2. The client must stop with a failure.
  if ((intruder_status == 0)); then
    log "ERROR: the server accepted the intruder. The lab is broken."
    return 1
  fi

  local failure_line
  failure_line="$(first_line '^client failed: ' "${intruder_output}")"
  if [[ -z "${failure_line}" ]]; then
    log "ERROR: the client stopped without a failure line"
    return 1
  fi
  # The server refuses the certificate during the handshake. Another error
  # names another cause, for example an unreachable server.
  if ! grep -F "${TLS_ALERT}" >/dev/null <<<"${failure_line}"; then
    log "ERROR: the client failed for the wrong reason. The demo proves nothing."
    log "expected: ${TLS_ALERT}"
    return 1
  fi
  log "${failure_line}"

  # Proof 3. The client alone cannot prove why the handshake failed. The
  # server log names the rejected SPIFFE ID, so it gives the real reason.
  if ! wait_for_denial_log "${mark}"; then
    log "ERROR: the server logged no rejection of ${INTRUDER_ID}"
    read_log_since "${mark}" 2>&1 || true
    return 1
  fi
  # One strict read serves the display and proof 4. A failed read is an
  # error, never an empty display.
  local lines
  if ! lines="$(read_log_since "${mark}" 2>&1)"; then
    log "ERROR: cannot read the log of the ${SERVER_SERVICE} service"
    log "${lines}"
    return 1
  fi
  local proof_line
  proof_line="$(grep -m1 -F 'unexpected ID' <<<"${lines}" || true)"
  log "server log: ${proof_line}"

  # Proof 4. The HTTP handler must never run. The server writes one line for
  # each served request, so a request line in this window breaks the rule.
  if grep -F 'GET /hello' >/dev/null <<<"${lines}"; then
    log "ERROR: the server ran the handler for the intruder. The lab is broken."
    log "${lines}"
    return 1
  fi
  log "the server served no GET /hello during this demo"

  log ""
  log "intruder SPIFFE ID: ${INTRUDER_ID} (a valid SVID)"
  log "mTLS handshake: DENIED"
  log "Lab test PASSED: a valid identity is not an authorized identity."
}

main "$@"
