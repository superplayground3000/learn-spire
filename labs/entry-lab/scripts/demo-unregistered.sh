#!/usr/bin/env bash
#
# This script runs the unregistered workload demo.
#
# UID 10004 reaches the Workload API like every other process on the node. The
# unix workload attestor reports unix:uid:10004, and no registration entry
# matches that selector. The SPIRE agent issues no X509-SVID.
#
# The demo shows that a call to the Workload API does not grant an identity.
# An identity needs a successful attestation and a matching registration entry.
#
# The denial is the pass. The script exits 0 when the agent refuses the
# request. The script exits 1 when the agent issues an SVID, because that means
# a broken lab.
#
# The script is safe to run repeatedly. It changes no lab state.

set -euo pipefail

cd "$(dirname "$0")/.."

UNREGISTERED_UID=10004
SELECTOR="unix:uid:${UNREGISTERED_UID}"
AGENT_SOCKET="/run/spire/agent.sock"

FETCH_TIMEOUT=10s

log() { printf '%s\n' "$*"; }

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  docker compose exec -T spire-server /opt/spire/bin/spire-server "$@"
}

agent_is_healthy() {
  docker compose exec -T node \
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

# The premise of this demo is that no entry matches the selector. The demo
# must not run on a broken premise, so a wrong or unknown count is an error.
narrate() {
  local count
  count="$(entry_count)"
  if [[ "${count}" != "0" ]]; then
    log "ERROR: expected 0 entries for ${SELECTOR}, found '${count:-unknown}'"
    return 1
  fi

  log "UID ${UNREGISTERED_UID} has no matching registration entry"
  log "registration entries for ${SELECTOR}: ${count}"
  log "The process still reaches the Workload API on the node."
  log "The agent attests it, finds no matching entry, and issues no SVID."
  log ""
}

main() {
  require_lab_up || return 1

  narrate || return 1

  # A denial is the expected result, so keep the exit status. The agent CLI
  # writes the error to standard error, so the demo reads both streams.
  local fetch_output="" fetch_status=0
  fetch_output="$(docker compose exec -T --user "${UNREGISTERED_UID}" node \
    spire-agent api fetch x509 -socketPath "${AGENT_SOCKET}" \
    -timeout "${FETCH_TIMEOUT}" 2>&1)" || fetch_status=$?

  if ((fetch_status == 0)); then
    log "ERROR: the agent issued an SVID to UID ${UNREGISTERED_UID}. The lab is broken."
    log "${fetch_output}"
    return 1
  fi

  # Only the PermissionDenied class proves "no entry for this workload". A
  # docker failure, a socket error, or a timeout is a broken demo, not a pass.
  if ! grep -q 'PermissionDenied.*no identity issued' <<<"${fetch_output}"; then
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
