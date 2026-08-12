#!/usr/bin/env bash
#
# Property P11: an unregistered container gets no SVID.
#
# The zone-a-unregistered container has no registration entry, on purpose. So
# the agent attests it, finds no matching entry, and issues no identity. A fetch
# returns "PermissionDenied ... no identity issued".
#
# The demo first asserts the premise: the server holds 0 entries for the
# unregistered label. Then it runs the fetch and checks the exact error. A
# broken socket also stops a fetch, but it proves nothing about registration.
# The error class attributes the failure to the missing entry.
#
# The demo changes no lab state. Run it repeatedly.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"

UNREG_SERVICE="zone-a-unregistered"
UNREG_LABEL="docker:label:spiffe.lab/workload:zone-a-unregistered"
AGENT_SOCKET="/run/spire/agent.sock"

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }
spire_server() { dc exec -T spire-server /opt/spire/bin/spire-server "$@"; }

main() {
  log "Property P11: an unregistered container gets no SVID."
  log ""

  # Premise: the server holds 0 entries for the unregistered label.
  local shown count
  shown="$(spire_server entry show -selector "${UNREG_LABEL}" 2>/dev/null || true)"
  count="$(grep -c '^Entry ID' <<<"${shown}" || true)"
  if [[ "${count}" != "0" ]]; then
    log "INCONCLUSIVE: the server holds ${count} entries for ${UNREG_LABEL}."
    log "  P11 needs 0 entries for this label."
    return 1
  fi
  log "premise OK: the server holds 0 entries for ${UNREG_LABEL}"

  # The fetch must fail with the exact "no identity issued" reason.
  local output="" status=0
  output="$(dc --progress quiet run --rm -T "${UNREG_SERVICE}" \
    spire-agent api fetch x509 -socketPath "${AGENT_SOCKET}" 2>&1)" || status=$?

  log ""
  log "fetch output:"
  log "${output}"
  log ""

  if (( status == 0 )); then
    log "FAIL: the fetch succeeded. The unregistered container got an SVID."
    return 1
  fi

  if ! grep -q 'PermissionDenied' <<<"${output}" \
    || ! grep -q 'no identity issued' <<<"${output}"; then
    log "INCONCLUSIVE: the fetch failed, but not with 'PermissionDenied ... no identity issued'."
    log "  A different error does not attribute the failure to the missing entry."
    return 1
  fi

  log "P11 PASSED: the fetch returned 'PermissionDenied ... no identity issued'."
}

main "$@"
