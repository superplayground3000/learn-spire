#!/usr/bin/env bash
#
# Property P5, attack A1: an identity rejection is auditable.
#
# The intruder holds a VALID SVID, spiffe://lab.local/zone-a/intruder. The
# gateway allowlist names only spiffe://lab.local/zone-a/client. So the gateway
# admits the request at the TLS layer, then the L7 RBAC filter denies it. The
# denial is a logged 403 that names the intruder. This is the audit trail.
#
# The demo first asserts the premise: the intruder really holds a valid SVID.
# A denial for a missing SVID would prove nothing about the allowlist. Then it
# reads two proofs:
#   1. the gateway L7 RBAC counter http.gateway.rbac.denied moves,
#   2. one gateway access-log line shows RESPONSE_CODE 403 and the intruder
#      downstream_san.
#
# The demo changes no lab state. Run it repeatedly.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"

GATEWAY_SERVICE="zone-b-gateway"
INTRUDER_SERVICE="zone-a-intruder"

INTRUDER_ID="spiffe://lab.local/zone-a/intruder"
GATEWAY_URL="https://zone-b-gateway:9000/"
GATEWAY_LOG="/var/log/envoy/gateway-access.log"
DENIED_STAT="http.gateway.rbac.denied"

PROOF_ATTEMPTS=15
PROOF_INTERVAL=1

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }

# gateway_stat prints one Envoy counter value from the admin listener.
gateway_stat() {
  local key="$1"
  dc exec -T "${GATEWAY_SERVICE}" \
    curl -s "http://127.0.0.1:9901/stats?filter=^${key}$" 2>/dev/null \
    | awk -F': ' '{print $2}' | tr -d '\r'
}

# run_intruder starts the one-shot intruder container. It fetches the intruder
# SVID, prints the SVID URI SAN as the premise, then calls the gateway and
# prints the HTTP code. It uses the same one-shot pattern as demo.sh.
run_intruder() {
  dc --progress quiet run --rm -T "${INTRUDER_SERVICE}" bash -c '
    set -e
    rm -rf /tmp/svid && mkdir -p /tmp/svid
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/svid >/dev/null
    echo "SVID_SAN=$(openssl x509 -in /tmp/svid/svid.0.pem -noout -ext subjectAltName | tr -d "[:space:]")"
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
      --cert /tmp/svid/svid.0.pem --key /tmp/svid/svid.0.key --cacert /tmp/svid/bundle.0.pem \
      "'"${GATEWAY_URL}"'" || true)
    echo "HTTP_CODE=${code}"
  '
}

# wait_for_denied_line polls the gateway log for one 403 line that names the
# intruder downstream SAN. It stores the line in DENIED_LINE.
wait_for_denied_line() {
  local i lines
  DENIED_LINE=""
  for ((i = 1; i <= PROOF_ATTEMPTS; i++)); do
    lines="$(dc exec -T "${GATEWAY_SERVICE}" cat "${GATEWAY_LOG}" 2>/dev/null || true)"
    if DENIED_LINE="$(grep "downstream_san=\"${INTRUDER_ID}\"" <<<"${lines}" \
      | grep '" 403 ' | tail -n 1)" && [[ -n "${DENIED_LINE}" ]]; then
      return 0
    fi
    ((i < PROOF_ATTEMPTS)) && sleep "${PROOF_INTERVAL}"
  done
  return 1
}

main() {
  log "Property P5 (attack A1): the intruder gets a LOGGED 403."
  log "The intruder holds a valid SVID ${INTRUDER_ID}."
  log "The gateway allowlist names only spiffe://lab.local/zone-a/client."
  log ""

  local denied_before denied_after
  denied_before="$(gateway_stat "${DENIED_STAT}")"
  denied_before="${denied_before:-0}"

  local output="" svid_san="" http_code=""
  output="$(run_intruder 2>&1)" || true
  svid_san="$(grep -o 'SVID_SAN=.*' <<<"${output}" | tail -n1 | cut -d= -f2- || true)"
  http_code="$(grep -o 'HTTP_CODE=.*' <<<"${output}" | tail -n1 | cut -d= -f2- || true)"

  # Premise: the intruder really holds a valid zone-a/intruder SVID.
  if ! grep -qF "URI:${INTRUDER_ID}" <<<"${svid_san}"; then
    log "INCONCLUSIVE: the intruder did not hold a valid ${INTRUDER_ID} SVID."
    log "  fetched SAN: ${svid_san:-<none>}"
    log "  A denial without a valid SVID proves nothing about the allowlist."
    return 1
  fi
  log "premise OK: the intruder holds a valid SVID (${svid_san})"

  # Proof 1: the request returns 403.
  if [[ "${http_code}" != "403" ]]; then
    log "FAIL: the gateway did not answer 403 (got HTTP ${http_code:-<none>})."
    return 1
  fi
  log "the gateway answered HTTP 403"

  # Proof 2: the L7 RBAC counter moved.
  denied_after="$(gateway_stat "${DENIED_STAT}")"
  denied_after="${denied_after:-0}"
  if (( denied_after <= denied_before )); then
    log "INCONCLUSIVE: ${DENIED_STAT} did not move (${denied_before} -> ${denied_after})."
    log "  The 403 was not attributed to the L7 RBAC filter."
    return 1
  fi
  log "L7 RBAC counter moved: ${DENIED_STAT} ${denied_before} -> ${denied_after}"

  # Proof 3: one access-log line names the intruder and the 403.
  if ! wait_for_denied_line; then
    log "FAIL: no gateway 403 line named ${INTRUDER_ID}."
    dc exec -T "${GATEWAY_SERVICE}" tail -n 5 "${GATEWAY_LOG}" 2>/dev/null || true
    return 1
  fi
  log ""
  log "gateway audit line:"
  log "${DENIED_LINE}"
  log ""
  log "P5 PASSED: the gateway denied the intruder with a logged 403 that names it."
}

main "$@"
