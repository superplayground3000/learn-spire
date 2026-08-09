#!/usr/bin/env bash
#
# This script runs the unregistered workload demo.
#
# The unregistered container carries the label
# spiffe.lab/workload=unregistered. It mounts the same Workload API socket as
# every other workload, so it reaches the agent. The docker workload attestor
# reports docker:label:spiffe.lab/workload:unregistered. No registration entry
# matches that selector, so the agent issues no X509-SVID.
#
# The demo shows that a call to the Workload API does not grant an identity.
# An identity needs a successful attestation and a matching registration entry.
#
# The denial is the pass. The script exits 0 when the agent refuses the
# request. The script exits 1 when the agent issues an SVID, because that means
# a broken lab. The script also exits 1 when the fetch fails for another
# reason, because such a failure proves nothing.
#
# You can run this script repeatedly. The script changes no lab state.

set -euo pipefail

cd "$(dirname "$0")/.."

# The Makefile and the other scripts accept the same override, so all tools
# address one project.
COMPOSE="${COMPOSE:-docker compose}"

UNREGISTERED_SERVICE="unregistered"

LABEL_KEY="spiffe.lab/workload"
LABEL_VALUE="unregistered"
SELECTOR="docker:label:${LABEL_KEY}:${LABEL_VALUE}"

AGENT_SOCKET="/run/spire/agent.sock"

FETCH_TIMEOUT=10s

# Only this error class proves "no entry for this workload". A docker failure,
# a socket error, or a timeout is a broken demo, not a pass.
DENIAL_PATTERN='PermissionDenied.*no identity issued'

log() { printf '%s\n' "$*"; }

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  ${COMPOSE} exec -T spire-server /opt/spire/bin/spire-server "$@"
}

agent_is_healthy() {
  ${COMPOSE} exec -T spire-agent \
    spire-agent healthcheck -socketPath "${AGENT_SOCKET}" >/dev/null 2>&1
}

require_lab_up() {
  if ! agent_is_healthy || ! spire_server healthcheck >/dev/null 2>&1; then
    log "ERROR: the lab is not running. Run 'make lab-up' first."
    return 1
  fi
}

# entry_count reports how many registration entries carry the selector. It
# prints nothing when the SPIRE Server does not answer.
entry_count() {
  spire_server entry show -selector "${SELECTOR}" 2>/dev/null \
    | awk '/^Found [0-9]+ entr/ { print $2 }' || true
}

# run_unregistered starts an unregistered container for this demo alone. The
# arguments after the service name replace the command of the service, so the
# demo shows the fetch command. "--rm" deletes the container after the run.
# The quiet progress keeps the compose status lines out of the transcript.
run_unregistered() {
  ${COMPOSE} --progress quiet run --rm "${UNREGISTERED_SERVICE}" \
    spire-agent api fetch x509 -socketPath "${AGENT_SOCKET}" \
    -timeout "${FETCH_TIMEOUT}"
}

# The premise of this demo is that no entry matches the selector. The demo
# must not run on a broken premise, so a wrong or unknown count is an error.
narrate() {
  local count
  count="$(entry_count)"
  if [[ "${count}" != "0" ]]; then
    log "ERROR: expected 0 entries for ${SELECTOR}, found '${count:-unknown}'"
    return 1
  fi

  log "The container carries the label ${LABEL_KEY}=${LABEL_VALUE}."
  log "registration entries for ${SELECTOR}: ${count}"
  log "The container still reaches the Workload API through the socket volume."
  log "The agent attests it and gets the selector ${SELECTOR}."
  log "No rule matches that selector, so the agent issues no SVID."
  log ""
}

main() {
  require_lab_up || return 1

  narrate || return 1

  # A denial is the expected result, so keep the exit status. The agent CLI
  # writes the error to standard error, so the demo reads both streams.
  local fetch_output="" fetch_status=0
  fetch_output="$(run_unregistered 2>&1)" || fetch_status=$?

  if ((fetch_status == 0)); then
    log "ERROR: the agent issued an SVID to the ${LABEL_VALUE} container. The lab is broken."
    log "${fetch_output}"
    return 1
  fi

  if ! grep -E "${DENIAL_PATTERN}" >/dev/null <<<"${fetch_output}"; then
    log "ERROR: the fetch failed for the wrong reason. The demo proves nothing."
    log "${fetch_output}"
    return 1
  fi

  log "workload API error: ${fetch_output}"

  log ""
  log "X509-SVID request: DENIED"
  log "Lab test PASSED: the Workload API grants no identity without an entry."
}

main "$@"
