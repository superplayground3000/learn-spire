#!/usr/bin/env bash
#
# The positive path: zone-a-client -> zone-b-gateway -> zone-b-backend.
#
# The client runs as a one-shot container. Its label gives it the identity
# spiffe://lab.local/zone-a/client. The client fetches its SVID as files from
# the shared agent socket, then calls the gateway with mTLS. The gateway admits
# the caller at Layer 7, re-originates mTLS to the backend, and pins the backend
# SPIFFE ID. The backend answers HTTP 200 with its zone body.
#
# The demo proves two things:
#   1. HTTP 200 with the real zone-b backend body.
#   2. One gateway access-log line carries BOTH the downstream SAN (the client)
#      and the upstream SAN (the backend). This is property P3, the audit line.
#
# The script changes no lab state. Run it repeatedly.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"

GATEWAY_SERVICE="zone-b-gateway"
CLIENT_SERVICE="zone-a-client"

CLIENT_ID="spiffe://lab.local/zone-a/client"
BACKEND_ID="spiffe://lab.local/zone-b/backend"
GATEWAY_URL="https://zone-b-gateway:9000/"
EXPECTED_BODY="zone-lab backend zone-b OK"
GATEWAY_LOG="/var/log/envoy/gateway-access.log"

AGENT_SOCKET="/run/spire/agent.sock"
PROOF_ATTEMPTS=10
PROOF_INTERVAL=1

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }

agent_is_healthy() {
  dc exec -T spire-agent \
    spire-agent healthcheck -socketPath "${AGENT_SOCKET}" >/dev/null 2>&1
}

gateway_listening() {
  dc exec -T "${GATEWAY_SERVICE}" bash -c "ss -tln | grep -q ':9000 '" >/dev/null 2>&1
}

require_lab_up() {
  if ! agent_is_healthy; then
    log "ERROR: the SPIRE agent is not healthy. Run 'make lab-up' first."
    return 1
  fi
  if ! gateway_listening; then
    log "ERROR: the zone-b gateway is not listening. Run 'make lab-up' first."
    return 1
  fi
}

narrate() {
  log "The client container carries the label spiffe.lab/workload=zone-a-client."
  log "SPIRE issues it an X509-SVID for ${CLIENT_ID}."
  log "The client calls ${GATEWAY_URL} with mTLS."
  log "The gateway admits ${CLIENT_ID} at Layer 7."
  log "The gateway re-originates mTLS and pins ${BACKEND_ID}."
  log "So the backend must answer HTTP 200."
  log ""
}

# run_client starts a one-shot client container. It fetches the client SVID from
# the shared socket, then calls the gateway with the Go client app. Compose
# applies the service label, so the agent attests the container by that label.
run_client() {
  dc --progress quiet run --rm -T "${CLIENT_SERVICE}" bash -c '
    set -e
    rm -rf /tmp/svid && mkdir -p /tmp/svid
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/svid >/dev/null
    client -url "'"${GATEWAY_URL}"'" \
      -cert /tmp/svid/svid.0.pem \
      -key  /tmp/svid/svid.0.key \
      -cacert /tmp/svid/bundle.0.pem
  '
}

# wait_for_audit_line polls the gateway access log for one line that carries
# both the client downstream SAN and the backend upstream SAN. The caller then
# shows the same line. It stores the line in AUDIT_LINE.
wait_for_audit_line() {
  local i lines
  AUDIT_LINE=""
  for ((i = 1; i <= PROOF_ATTEMPTS; i++)); do
    lines="$(dc exec -T "${GATEWAY_SERVICE}" cat "${GATEWAY_LOG}" 2>/dev/null || true)"
    if AUDIT_LINE="$(grep "downstream_san=\"${CLIENT_ID}\"" <<<"${lines}" \
      | grep "upstream_san=\"${BACKEND_ID}\"" | tail -n 1)" \
      && [[ -n "${AUDIT_LINE}" ]]; then
      return 0
    fi
    ((i < PROOF_ATTEMPTS)) && sleep "${PROOF_INTERVAL}"
  done
  return 1
}

main() {
  require_lab_up || return 1
  narrate

  local client_output="" client_status=0
  client_output="$(run_client 2>&1)" || client_status=$?

  log "client output:"
  log "${client_output}"
  log ""

  if ((client_status != 0)); then
    log "ERROR: the client stopped with status ${client_status}."
    return 1
  fi

  # The client-side proof: HTTP 200 and the real zone-b backend body.
  if ! grep -qx 'HTTP status: 200' <<<"${client_output}"; then
    log "ERROR: the client did not report HTTP status 200"
    return 1
  fi
  if ! grep -qF "${EXPECTED_BODY}" <<<"${client_output}"; then
    log "ERROR: the response body did not name the zone-b backend"
    return 1
  fi

  # The gateway-side proof: one access-log line names both peers.
  if ! wait_for_audit_line; then
    log "ERROR: the gateway logged no line with both SANs"
    dc exec -T "${GATEWAY_SERVICE}" cat "${GATEWAY_LOG}" 2>/dev/null | tail -n 5 || true
    return 1
  fi

  log "gateway audit line:"
  log "${AUDIT_LINE}"
  log ""
  log "client SPIFFE ID:  ${CLIENT_ID}"
  log "backend SPIFFE ID: ${BACKEND_ID}"
  log "HTTP status: 200"
  log "Positive path PASSED: the gateway authorized the caller and logged both SANs."
}

main "$@"
