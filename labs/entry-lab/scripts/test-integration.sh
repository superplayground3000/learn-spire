#!/usr/bin/env bash
#
# This script is the integration test of the lab.
#
# Section 20 of the spec names ten security properties. The script asserts each
# property and prints one report line for it. The report uses the words of the
# spec, so you can compare the two directly.
#
# The script runs a full cycle:
#
#   1. "make lab-down" deletes all earlier lab state
#   2. "make lab-up"   builds the lab again from nothing
#   3. the script asserts the ten properties
#   4. "make lab-down" destroys the lab again
#
# The fresh cycle is necessary. A property that holds only after a manual
# repair is not a property of the lab.
#
# The script asserts all ten properties, also after a failure. The report then
# shows the state of each property, not only the state of the first bad one.
# The script exits 1 when one property or more do not hold.
#
# Two assertions accept a failure as the correct result. The intruder must not
# reach the server, and UID 10004 must not get an SVID. For those two the
# script also checks the class of the failure. A broken container or a bad
# socket also stops the client, but it proves nothing about the security rules.
#
# CAUTION: the script destroys the lab. Do not run it while you use the lab.

set -euo pipefail

cd "$(dirname "$0")/.."

MAKE="${MAKE:-make}"

TRUST_DOMAIN="lab.local"

# Every workload entry hangs off the node alias that bootstrap.sh pinned to the
# agent. The assertions look for the entries under that parent.
PARENT_ID="spiffe://${TRUST_DOMAIN}/node"

SERVER_ID="spiffe://${TRUST_DOMAIN}/server"
CLIENT_ID="spiffe://${TRUST_DOMAIN}/client"
INTRUDER_ID="spiffe://${TRUST_DOMAIN}/intruder"

SERVER_UID=10001
CLIENT_UID=10002
INTRUDER_UID=10003
UNREGISTERED_UID=10004

SERVER_LOG="/var/log/lab/server.log"
AGENT_SOCKET="/run/spire/agent.sock"

FETCH_TIMEOUT=10s

# The server writes its log line after the TLS layer answers the client. The
# client can return first, so wait some seconds for that line.
PROOF_ATTEMPTS=10
PROOF_INTERVAL=1

# The report state. CHECKED counts the assertions, FAILED counts the bad ones.
# DIAG holds the evidence of the assertion that runs now.
CHECKED=0
FAILED=0
DIAG=""

# The results of the one authorized client run. The assertions 6, 7 and 8 all
# read this run, because one run proves all three.
CLIENT_OUTPUT=""
CLIENT_STATUS=0
CLIENT_LOG_START=0

log() { printf '%s\n' "$*"; }

heading() {
  log ""
  log "=== $* ==="
  log ""
}

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  docker compose exec -T spire-server /opt/spire/bin/spire-server "$@"
}

node_root() {
  docker compose exec -T --user 0 node "$@"
}

# log_length counts the lines already in the server log. An assertion reads
# only the lines that come after this mark, so an earlier run cannot prove a
# later one.
log_length() {
  node_root bash -c "wc -l <'${SERVER_LOG}' 2>/dev/null || echo 0" | tr -cd '0-9'
}

new_server_log() {
  local from="$1"
  node_root bash -c "tail -n +$((from + 1)) '${SERVER_LOG}' 2>/dev/null" || true
}

wait_for_log() {
  local from="$1" text="$2" i
  for ((i = 1; i <= PROOF_ATTEMPTS; i++)); do
    if new_server_log "${from}" | grep -qF -- "${text}"; then
      return 0
    fi
    if ((i < PROOF_ATTEMPTS)); then
      sleep "${PROOF_INTERVAL}"
    fi
  done
  return 1
}

# diag collects the evidence of one bad assertion. The report prints the
# evidence below the [FAIL] line.
diag() {
  DIAG="${DIAG}$*"$'\n'
}

# diag_server_log adds the log lines that the server wrote during the assertion.
# An empty log is also evidence, so the function says that too.
diag_server_log() {
  local from="$1" text
  text="$(new_server_log "${from}")"
  if [[ -z "${text}" ]]; then
    diag "the server wrote no new log line"
  else
    diag "new server log lines:"
    diag "${text}"
  fi
}

# check runs one assertion and prints one report line for it. The assertion
# returns 0 when the property holds. It writes its evidence with "diag".
check() {
  local property="$1"
  shift

  DIAG=""
  CHECKED=$((CHECKED + 1))

  if "$@"; then
    log "[PASS] ${property}"
  else
    log "[FAIL] ${property}"
    if [[ -n "${DIAG}" ]]; then
      printf '%s' "${DIAG}" | sed 's/^/  /'
    fi
    FAILED=$((FAILED + 1))
  fi
  log ""
}

# --- 1. The SPIRE server -----------------------------------------------------

assert_server_healthy() {
  local output="" status=0
  output="$(spire_server healthcheck 2>&1)" || status=$?
  if ((status != 0)); then
    diag "the SPIRE server healthcheck stopped with status ${status}"
    diag "${output}"
    return 1
  fi
  return 0
}

# --- 2. The SPIRE agent ------------------------------------------------------

# attested_agent_count reads the number from the "Found N attested agents"
# line. It prints nothing when the command fails, also on partial output.
attested_agent_count() {
  local out
  out="$(spire_server agent list 2>/dev/null)" || return 0
  awk '/^Found [0-9]+ attested agent/ { print $2 }' <<<"${out}"
}

assert_agent_attested() {
  local output="" status=0 count

  output="$(docker compose exec -T node \
    spire-agent healthcheck -socketPath "${AGENT_SOCKET}" 2>&1)" || status=$?
  if ((status != 0)); then
    diag "the SPIRE agent healthcheck stopped with status ${status}"
    diag "${output}"
    return 1
  fi

  # A healthy agent shows only that the agent process runs. Attestation is a
  # decision of the server, so only the server list proves it.
  count="$(attested_agent_count)"
  if [[ "${count}" != "1" ]]; then
    diag "The test expected 1 attested agent. The server reports '${count:-unknown}'."
    diag "$(spire_server agent list 2>&1 || true)"
    return 1
  fi
  return 0
}

# --- 3 to 5. The registration entries ----------------------------------------

# entry_count reports how many entries match the parent, the SPIFFE ID and the
# selector together. All three must match, because all three make the rule.
# It prints nothing when the command fails, also on partial output.
entry_count() {
  local spiffe_id="$1" selector="$2" out
  out="$(spire_server entry show \
    -parentID "${PARENT_ID}" \
    -spiffeID "${spiffe_id}" \
    -selector "${selector}" 2>/dev/null)" || return 0
  awk '/^Found [0-9]+ entr/ { print $2 }' <<<"${out}"
}

assert_entry() {
  local spiffe_id="$1" uid="$2"
  local selector="unix:uid:${uid}" count

  count="$(entry_count "${spiffe_id}" "${selector}")"
  if [[ "${count}" != "1" ]]; then
    diag "The test expected 1 entry for ${selector} -> ${spiffe_id}. It found '${count:-unknown}'."
    diag "$(spire_server entry show -selector "${selector}" 2>&1 || true)"
    return 1
  fi
  return 0
}

# --- 6 to 8. The authorized client -------------------------------------------

# run_authorized_client runs the client one time under UID 10002. It marks the
# server log first, so the later assertion reads only the new lines. An
# unreadable log mark must stop the assertion. An empty mark counts as zero in
# arithmetic, and an earlier log line can then prove a later run.
run_authorized_client() {
  CLIENT_LOG_START="$(log_length)"
  if [[ ! "${CLIENT_LOG_START}" =~ ^[0-9]+$ ]]; then
    diag "The test cannot read the length of the server log."
    return 1
  fi
  CLIENT_OUTPUT=""
  CLIENT_STATUS=0
  # The client writes its transcript to standard error, so read both streams.
  CLIENT_OUTPUT="$(docker compose exec -T --user "${CLIENT_UID}" node client 2>&1)" \
    || CLIENT_STATUS=$?
}

assert_client_succeeds() {
  run_authorized_client || return 1

  if ((CLIENT_STATUS != 0)); then
    diag "the client stopped with status ${CLIENT_STATUS}"
    diag "${CLIENT_OUTPUT}"
    return 1
  fi
  if ! grep -qxF -- "HTTP status: 200" <<<"${CLIENT_OUTPUT}"; then
    diag "the client reported no 'HTTP status: 200'"
    diag "${CLIENT_OUTPUT}"
    return 1
  fi
  return 0
}

assert_server_verified_by_client() {
  # The line must agree fully. A different trust domain or a different path is
  # a different identity.
  if ! grep -qxF -- "authenticated server: ${SERVER_ID}" <<<"${CLIENT_OUTPUT}"; then
    diag "the client did not authenticate the server as ${SERVER_ID}"
    diag "${CLIENT_OUTPUT}"
    return 1
  fi
  return 0
}

assert_client_verified_by_server() {
  # The client alone shows only its own view. The server log names the client
  # identity that the server authenticated, so it proves the other direction.
  local wanted="GET /hello from authenticated client: ${CLIENT_ID}"

  if ! wait_for_log "${CLIENT_LOG_START}" "${wanted}"; then
    diag "the server log has no line '${wanted}'"
    diag_server_log "${CLIENT_LOG_START}"
    return 1
  fi
  return 0
}

# --- 9. The intruder ---------------------------------------------------------

assert_intruder_denied() {
  local log_start output="" status=0
  log_start="$(log_length)"
  if [[ ! "${log_start}" =~ ^[0-9]+$ ]]; then
    diag "The test cannot read the length of the server log."
    return 1
  fi

  output="$(docker compose exec -T --user "${INTRUDER_UID}" node client 2>&1)" \
    || status=$?

  if ((status == 0)); then
    diag "the server accepted the intruder"
    diag "${output}"
    return 1
  fi

  # Only a TLS error proves an authorization failure. A missing SVID, a name
  # that does not resolve, or a refused connection is a broken lab.
  if ! grep -qF -- 'remote error: tls:' <<<"${output}"; then
    diag "the client stopped, but not with a TLS error"
    diag "${output}"
    return 1
  fi

  # The client cannot show why the handshake failed. The server log names the
  # identity that it refused, so it gives the real reason.
  local denial="unexpected ID \"${INTRUDER_ID}\""
  if ! wait_for_log "${log_start}" "${denial}"; then
    diag "the server log has no line with ${denial}"
    diag_server_log "${log_start}"
    return 1
  fi

  # Section 13 requires that the HTTP handler never runs. The server writes one
  # line for each served request, so a new request line breaks the rule.
  if new_server_log "${log_start}" | grep -qF -- 'GET /hello'; then
    diag "the server ran the handler for the intruder"
    diag_server_log "${log_start}"
    return 1
  fi
  return 0
}

# --- 10. The unregistered workload -------------------------------------------

assert_no_svid_for_unregistered() {
  local output="" status=0

  output="$(docker compose exec -T --user "${UNREGISTERED_UID}" node \
    spire-agent api fetch x509 -socketPath "${AGENT_SOCKET}" \
    -timeout "${FETCH_TIMEOUT}" 2>&1)" || status=$?

  if ((status == 0)); then
    diag "the agent issued an SVID to UID ${UNREGISTERED_UID}"
    diag "${output}"
    return 1
  fi

  # Only the PermissionDenied class proves "no entry for this workload". A
  # docker failure, a socket error, or a timeout proves nothing.
  if ! grep -q 'PermissionDenied.*no identity issued' <<<"${output}"; then
    diag "the fetch failed for the wrong reason"
    diag "${output}"
    return 1
  fi
  return 0
}

# --- The cycle ---------------------------------------------------------------

setup_lab() {
  heading "Phase 1: build a fresh lab"
  log "The test deletes all earlier lab state first."
  log "Then it builds the lab again."
  log "It asserts the properties against the new lab."
  log ""

  if ! "${MAKE}" lab-down; then
    log "ERROR: 'make lab-down' failed. The test cannot start."
    return 1
  fi
  if ! "${MAKE}" lab-up; then
    log "ERROR: 'make lab-up' failed. The test has no lab to assert against."
    return 1
  fi
}

teardown_lab() {
  heading "Phase 3: destroy the lab"
  "${MAKE}" lab-down
}

# on_exit destroys the lab and sets the final exit status. A failed teardown
# turns a clean test into a failure, because the test promises a clean host.
on_exit() {
  local code=$?
  if ! teardown_lab; then
    log "CAUTION: Run 'make lab-down' again. Some lab state can remain."
    if ((code == 0)); then
      code=1
    fi
  fi
  exit "${code}"
}

main() {
  # The teardown runs also after a failure, so the test always leaves the host
  # clean. The report holds the evidence, because it comes first.
  trap on_exit EXIT

  setup_lab || return 1

  heading "Phase 2: assert the ten security properties of section 20"

  check "SPIRE server becomes healthy" assert_server_healthy
  check "SPIRE agent becomes attested" assert_agent_attested
  check "server registration entry exists" assert_entry "${SERVER_ID}" "${SERVER_UID}"
  check "client registration entry exists" assert_entry "${CLIENT_ID}" "${CLIENT_UID}"
  check "intruder registration entry exists" assert_entry "${INTRUDER_ID}" "${INTRUDER_UID}"
  check "authorized client → server succeeds" assert_client_succeeds
  check "server identity is verified by client" assert_server_verified_by_client
  check "client identity is verified by server" assert_client_verified_by_server
  check "intruder → server fails TLS authorization" assert_intruder_denied
  check "UID 10004 cannot obtain an SVID" assert_no_svid_for_unregistered

  log "$((CHECKED - FAILED))/${CHECKED} properties hold"

  if ((FAILED != 0)); then
    log "Integration test FAILED: the lab does not enforce all security properties."
    return 1
  fi
  log "Integration test PASSED: the lab enforces all security properties."
}

main "$@"
