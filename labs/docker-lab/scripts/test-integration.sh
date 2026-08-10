#!/usr/bin/env bash
#
# This script is the integration test of the lab.
#
# The lab makes ten security promises. The script asserts each promise and
# prints one report line for it. Lab 1 asserts the same ten promises with UID
# selectors. This lab uses container labels, so only the evidence is different.
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
# The three demo scripts carry the proofs of the properties 6 to 10. The test
# runs each demo one time and reads its transcript. A demo already knows which
# evidence proves its property, so the test does not repeat that logic.
#
# Two demos accept a failure as the correct result. The intruder must not reach
# the server, and the unregistered label must not get an SVID. Each of those
# demos also checks the class of the failure. A broken container or a bad
# socket also stops a workload, but it proves nothing about the security rules.
#
# CAUTION: the script destroys the lab. Do not run it while you use the lab.
#
# Set MAKE to "true" to assert the properties against the running lab. The
# setup and the teardown then do nothing. Use this during development only.

set -euo pipefail

cd "$(dirname "$0")/.."

MAKE="${MAKE:-make}"

# The Makefile and the other scripts accept the same override, so all tools
# address one project. The export sends the value to "make" and to the demos.
COMPOSE="${COMPOSE:-docker compose}"
export COMPOSE

TRUST_DOMAIN="lab.local"

# Every workload entry hangs off the node alias that bootstrap.sh pinned to the
# agent. The assertions look for the entries under that parent.
PARENT_ID="spiffe://${TRUST_DOMAIN}/node"

# The properties 7 and 8 name these two identities directly. The intruder
# identity stays inside demo-intruder.sh, which owns that proof.
SERVER_ID="spiffe://${TRUST_DOMAIN}/server"
CLIENT_ID="spiffe://${TRUST_DOMAIN}/client"

# The label key is the same for every workload. The label value alone decides
# the identity, so it is also the selector value and the last path segment.
LABEL_KEY="spiffe.lab/workload"

AGENT_SOCKET="/run/spire/agent.sock"

# These variables hold the report state. CHECKED counts the assertions, and
# FAILED counts the bad ones. DIAG holds the evidence of the assertion that
# runs now.
CHECKED=0
FAILED=0
DIAG=""

# These variables hold the results of one authorized demo run. The assertions
# 6, 7 and 8 all read this run, because one run proves all three.
DEMO_OK_OUTPUT=""
DEMO_OK_STATUS=0

log() { printf '%s\n' "$*"; }

heading() {
  log ""
  log "=== $* ==="
  log ""
}

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  ${COMPOSE} exec -T spire-server /opt/spire/bin/spire-server "$@"
}

# diag collects the evidence of one bad assertion. The report prints the
# evidence below the [FAIL] line.
diag() {
  DIAG="${DIAG}$*"$'\n'
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

  output="$(${COMPOSE} exec -T spire-agent \
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

# assert_entry checks the rule that maps one container label to one SPIFFE ID.
# The label value is also the last path segment of that SPIFFE ID. The rule
# must hold exactly one selector. A second selector on the entry breaks the
# "label alone decides" claim, because a workload must satisfy all selectors.
assert_entry() {
  local workload="$1"
  local spiffe_id="spiffe://${TRUST_DOMAIN}/${workload}"
  local selector="docker:label:${LABEL_KEY}:${workload}"
  local out count selectors

  if ! out="$(spire_server entry show \
    -parentID "${PARENT_ID}" \
    -spiffeID "${spiffe_id}" \
    -selector "${selector}" 2>&1)"; then
    diag "cannot read the registration entries"
    diag "${out}"
    return 1
  fi

  count="$(awk '/^Found [0-9]+ entr/ { print $2 }' <<<"${out}")"
  if [[ "${count}" != "1" ]]; then
    diag "The test expected 1 entry for ${selector} -> ${spiffe_id}. It found '${count:-unknown}'."
    diag "$(spire_server entry show -selector "${selector}" 2>&1 || true)"
    return 1
  fi

  selectors="$(grep -c '^Selector' <<<"${out}" || true)"
  if [[ "${selectors}" != "1" ]]; then
    diag "The entry must hold exactly one selector. It holds '${selectors}'."
    diag "${out}"
    return 1
  fi
  return 0
}

# --- 6 to 8. The authorized client -------------------------------------------

# run_demo_ok runs the authorized demo one time. The demo starts a client
# container, reads the answer, and reads the server log. Its transcript holds
# the evidence for the properties 6, 7 and 8.
run_demo_ok() {
  DEMO_OK_OUTPUT=""
  DEMO_OK_STATUS=0
  DEMO_OK_OUTPUT="$(./scripts/demo-ok.sh 2>&1)" || DEMO_OK_STATUS=$?
}

# The property is the successful request, not the whole demo. The evidence is
# the client's own transcript lines. A late demo failure, for example a slow
# server log, then fails property 8 and not this one.
assert_client_succeeds() {
  run_demo_ok

  if ! grep -Fx 'mTLS handshake: SUCCESS' >/dev/null <<<"${DEMO_OK_OUTPUT}" \
    || ! grep -Fx 'HTTP status: 200' >/dev/null <<<"${DEMO_OK_OUTPUT}"; then
    diag "demo-ok.sh gave no successful handshake with HTTP 200 (status ${DEMO_OK_STATUS})"
    diag "${DEMO_OK_OUTPUT}"
    return 1
  fi
  return 0
}

assert_server_verified_by_client() {
  # -Fx requires the whole line. An error message that quotes the wanted text
  # then cannot match. -F keeps the dots in the SPIFFE ID literal.
  if ! grep -Fx "authenticated server: ${SERVER_ID}" \
    >/dev/null <<<"${DEMO_OK_OUTPUT}"; then
    diag "the client did not authenticate the server as ${SERVER_ID}"
    diag "${DEMO_OK_OUTPUT}"
    return 1
  fi
  return 0
}

assert_client_verified_by_server() {
  # The client alone shows only its own view. The demo copies the server log
  # line into its transcript with the prefix "server log: ". The anchor on
  # that prefix keeps error messages out of the match. The demo exit status
  # must also be zero, because the log proof is the demo's last step.
  local wanted="GET /hello from authenticated client: ${CLIENT_ID}"

  if ((DEMO_OK_STATUS != 0)); then
    diag "demo-ok.sh stopped with status ${DEMO_OK_STATUS}"
    diag "${DEMO_OK_OUTPUT}"
    return 1
  fi
  if ! grep '^server log: ' <<<"${DEMO_OK_OUTPUT}" \
    | grep -F "${wanted}" >/dev/null; then
    diag "the demo transcript has no server log line '${wanted}'"
    diag "${DEMO_OK_OUTPUT}"
    return 1
  fi
  return 0
}

# --- 9. The intruder ---------------------------------------------------------

# The intruder demo passes only for the right reason. It requires a real SVID
# for the intruder, a TLS alert from the server, the rejected ID in the server
# log, and no served request. So its exit status alone proves the property.
assert_intruder_denied() {
  local output="" status=0
  output="$(./scripts/demo-intruder.sh 2>&1)" || status=$?
  if ((status != 0)); then
    diag "demo-intruder.sh stopped with status ${status}"
    diag "${output}"
    return 1
  fi
  return 0
}

# --- 10. The unregistered label ----------------------------------------------

# The unregistered demo also passes only for the right reason. It requires zero
# entries for the label, and it requires the PermissionDenied error class.
assert_no_svid_for_unregistered() {
  local output="" status=0
  output="$(./scripts/demo-unregistered.sh 2>&1)" || status=$?
  if ((status != 0)); then
    diag "demo-unregistered.sh stopped with status ${status}"
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

  heading "Phase 2: assert the ten security properties"

  check "SPIRE server becomes healthy" assert_server_healthy
  check "SPIRE agent becomes attested" assert_agent_attested
  check "server registration entry exists" assert_entry server
  check "client registration entry exists" assert_entry client
  check "intruder registration entry exists" assert_entry intruder
  check "authorized client → server succeeds" assert_client_succeeds
  check "server identity is verified by the client" assert_server_verified_by_client
  check "client identity is verified by the server" assert_client_verified_by_server
  check "intruder → server fails TLS authorization" assert_intruder_denied
  check "the unregistered label cannot obtain an SVID" assert_no_svid_for_unregistered

  log "$((CHECKED - FAILED))/${CHECKED} properties hold"

  if ((FAILED != 0)); then
    log "Integration test FAILED: the lab does not enforce all security properties."
    return 1
  fi
  log "Integration test PASSED: the lab enforces all security properties."
}

main "$@"
