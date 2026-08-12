#!/usr/bin/env bash
#
# The SAN-pin negative test (spec section 15, MANDATORY).
#
# A SPIFFE validator silently drops a bad SAN matcher. An empty matcher list
# skips SAN matching. A misconfigured pin does not error; it stops checking. A
# happy-path test cannot tell "the pin matched" from "the pin was skipped". So
# every SAN pin needs one proof that it can FAIL for the right reason.
#
# The request path has two SAN pins. This test targets BOTH:
#
#   Target A: the GATEWAY UPSTREAM pin (it names the backend identity).
#     Repoint it to a SPIFFE ID the backend lacks. The gateway then fails to
#     verify the backend SAN. THIS request's gateway access-log line records
#     "verify_cert_failed:_SAN_match", correlated by a unique query marker.
#
#   Target B: the BACKEND DOWNSTREAM pin (it guards the backend identity).
#     Repoint it to a SPIFFE ID the caller lacks. The backend then rejects the
#     gateway during the handshake. A handshake abort writes no backend
#     access-log line, so the positive evidence is the backend counter
#     listener.0.0.0.0_9001.ssl.fail_verify_san, which moves across THIS
#     request.
#
# Why two targets: the string "verify_cert_failed:_SAN_match" appears only in
# the log of the peer that runs the SAN check. The gateway logs it (Target A).
# The backend records only a counter (Target B). Both pins get one fail proof.
#
# A bare failure is not proof. A network blip fails the same way. Only the
# SAN-match reason (Target A) or the moved SAN counter (Target B), correlated by
# the marker, attributes the rejection to the pin.
#
# The test edits no host file. The bind mount does not track a host edit. So the
# test writes the broken config inside the container, then starts Envoy with it.
# The restore points Envoy back at the canonical config path. A trap on EXIT
# restores both Envoys, even after a failure.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"

GATEWAY_SERVICE="zone-b-gateway"
BACKEND_SERVICE="zone-b-backend"
CLIENT_SERVICE="zone-a-client"

GATEWAY_CANON="/etc/envoy/zone-b-gateway-envoy.yaml"
BACKEND_CANON="/etc/envoy/zone-b-backend-envoy.yaml"
GATEWAY_BROKEN="/tmp/san-pin-gateway.yaml"
BACKEND_BROKEN="/tmp/san-pin-backend.yaml"

GATEWAY_URL="https://zone-b-gateway:9000"
GATEWAY_LOG="/var/log/envoy/gateway-access.log"
BACKEND_SAN_STAT="listener.0.0.0.0_9001.ssl.fail_verify_san"

LOG_ATTEMPTS=20
FAILED=0

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }

# envoy_stat prints one counter value from a container admin listener.
envoy_stat() {
  local service="$1" key="$2" val
  val="$(dc exec -T "${service}" \
    curl -s "http://127.0.0.1:9901/stats?filter=^${key}$" 2>/dev/null \
    | awk -F': ' '{print $2}' | tr -d '\r')"
  printf '%s' "${val:-0}"
}

# restart_envoy stops every Envoy in a container, waits for the port to free,
# then starts Envoy with the named config, and waits for the port again.
restart_envoy() {
  local service="$1" port="$2" cfg="$3" i
  dc exec -T "${service}" pkill -9 -f 'envoy' 2>/dev/null || true
  for ((i = 1; i <= 15; i++)); do
    dc exec -T "${service}" bash -c "ss -tln | grep -q ':${port} '" || break
    sleep 1
  done
  dc exec -d "${service}" bash -c "envoy -c ${cfg} --log-path /var/log/envoy/envoy.log"
  for ((i = 1; i <= 20; i++)); do
    dc exec -T "${service}" bash -c "ss -tln | grep -q ':${port} '" && return 0
    sleep 1
  done
  return 1
}

# send_marked runs a one-shot client with a unique query marker. It prints the
# HTTP code. It reuses the demo.sh one-shot pattern.
send_marked() {
  local marker="$1"
  dc --progress quiet run --rm -T "${CLIENT_SERVICE}" bash -c '
    set -e
    rm -rf /tmp/svid && mkdir -p /tmp/svid
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/svid >/dev/null
    curl -sS -o /dev/null -w "%{http_code}" --max-time 12 \
      --cert /tmp/svid/svid.0.pem --key /tmp/svid/svid.0.key --cacert /tmp/svid/bundle.0.pem \
      "'"${GATEWAY_URL}"'/?m='"${marker}"'" 2>/dev/null || true
  '
}

# gateway_line_for polls the gateway log for the line that carries the marker.
gateway_line_for() {
  local marker="$1" i line
  for ((i = 1; i <= LOG_ATTEMPTS; i++)); do
    line="$(dc exec -T "${GATEWAY_SERVICE}" grep "m=${marker}" "${GATEWAY_LOG}" 2>/dev/null | tail -n 1 || true)"
    [[ -n "${line}" ]] && { printf '%s' "${line}"; return 0; }
    sleep 1
  done
  return 1
}

restore_all() {
  log ""
  log "--- restoring both Envoys to the canonical config ---"
  if ! restart_envoy "${GATEWAY_SERVICE}" 9000 "${GATEWAY_CANON}"; then
    log "RESTORE FAILED for ${GATEWAY_SERVICE}."
    log "  Remediation: ${COMPOSE} exec -d ${GATEWAY_SERVICE} bash -c 'envoy -c ${GATEWAY_CANON} --log-path /var/log/envoy/envoy.log'"
  else
    log "  ${GATEWAY_SERVICE} restored"
  fi
  if ! restart_envoy "${BACKEND_SERVICE}" 9001 "${BACKEND_CANON}"; then
    log "RESTORE FAILED for ${BACKEND_SERVICE}."
    log "  Remediation: ${COMPOSE} exec -d ${BACKEND_SERVICE} bash -c 'envoy -c ${BACKEND_CANON} --log-path /var/log/envoy/envoy.log'"
  else
    log "  ${BACKEND_SERVICE} restored"
  fi
  # Confirm the baseline forwards again after the restore.
  local code
  code="$(send_marked RESTORECHK)"
  if [[ "${code}" == "200" ]]; then
    log "  baseline confirmed: forwarding works again (HTTP 200)"
  else
    log "  WARNING: baseline did not return 200 after restore (got ${code})"
  fi
}
trap restore_all EXIT

# ---------------------------------------------------------------------------
# Target A: the gateway upstream pin.
# ---------------------------------------------------------------------------
target_gateway_upstream() {
  log "=== Target A: the gateway UPSTREAM pin (names the backend identity) ==="

  # Baseline: the correct pin forwards.
  local code
  code="$(send_marked GWBASE)"
  if [[ "${code}" != "200" ]]; then
    log "  INCONCLUSIVE: the baseline did not return 200 (got ${code}). Lab not ready."
    FAILED=1; return 1
  fi
  log "  baseline OK: the correct upstream pin forwards (HTTP 200)"

  # Repoint the upstream pin to a SPIFFE ID the backend lacks. Write the broken
  # config inside the container, then start Envoy with it.
  dc exec -T "${GATEWAY_SERVICE}" bash -c \
    "sed 's#exact: \"spiffe://lab.local/zone-b/backend\"#exact: \"spiffe://lab.local/zone-b/backend-absent\"#' ${GATEWAY_CANON} > ${GATEWAY_BROKEN}"
  if ! restart_envoy "${GATEWAY_SERVICE}" 9000 "${GATEWAY_BROKEN}"; then
    log "  ERROR: the gateway did not restart with the broken pin."
    FAILED=1; return 1
  fi
  log "  repointed the gateway upstream pin to spiffe://lab.local/zone-b/backend-absent"

  # The marked request must fail, and THIS line must carry the SAN-match reason.
  local marker="GWBROKEN$$" http line
  http="$(send_marked "${marker}")"
  log "  marked request returned HTTP ${http} (expected a non-200)"
  if ! line="$(gateway_line_for "${marker}")"; then
    log "  FAIL: no gateway access-log line carried the marker ${marker}."
    FAILED=1; return 1
  fi
  log "  correlated gateway line:"
  log "    ${line}"
  if grep -q 'verify_cert_failed:_SAN_match' <<<"${line}"; then
    log "  PASS: the correlated line records verify_cert_failed:_SAN_match."
  else
    log "  FAIL: the correlated line lacks verify_cert_failed:_SAN_match."
    log "        A bare failure is not proof; the reason must name the SAN check."
    FAILED=1; return 1
  fi

  # Restore this target before the next one.
  dc exec -T "${GATEWAY_SERVICE}" rm -f "${GATEWAY_BROKEN}" 2>/dev/null || true
  restart_envoy "${GATEWAY_SERVICE}" 9000 "${GATEWAY_CANON}" \
    && log "  gateway upstream pin restored" \
    || { log "  ERROR restoring gateway"; FAILED=1; }
  code="$(send_marked GWAFTER)"
  [[ "${code}" == "200" ]] \
    && log "  baseline confirmed again after Target A (HTTP 200)" \
    || { log "  FAIL: baseline broken after Target A (HTTP ${code})"; FAILED=1; }
}

# ---------------------------------------------------------------------------
# Target B: the backend downstream pin.
# ---------------------------------------------------------------------------
target_backend_downstream() {
  log ""
  log "=== Target B: the backend DOWNSTREAM pin (guards the backend identity) ==="

  local code
  code="$(send_marked BEBASE)"
  if [[ "${code}" != "200" ]]; then
    log "  INCONCLUSIVE: the baseline did not return 200 (got ${code})."
    FAILED=1; return 1
  fi
  log "  baseline OK: the correct downstream pin accepts the gateway (HTTP 200)"

  # Repoint the downstream pin to a SPIFFE ID the caller (the gateway) lacks.
  dc exec -T "${BACKEND_SERVICE}" bash -c \
    "sed 's#exact: \"spiffe://lab.local/zone-b/gateway\"#exact: \"spiffe://lab.local/zone-b/gateway-absent\"#' ${BACKEND_CANON} > ${BACKEND_BROKEN}"
  if ! restart_envoy "${BACKEND_SERVICE}" 9001 "${BACKEND_BROKEN}"; then
    log "  ERROR: the backend did not restart with the broken pin."
    FAILED=1; return 1
  fi
  log "  repointed the backend downstream pin to spiffe://lab.local/zone-b/gateway-absent"

  # A handshake abort writes no backend access-log line. So read the SAN counter
  # before and after the marked request. The counter is the positive evidence.
  local before after http
  before="$(envoy_stat "${BACKEND_SERVICE}" "${BACKEND_SAN_STAT}")"
  http="$(send_marked "BEBROKEN$$")"
  after="$(envoy_stat "${BACKEND_SERVICE}" "${BACKEND_SAN_STAT}")"
  log "  marked request returned HTTP ${http} (expected a non-200)"
  log "  backend ${BACKEND_SAN_STAT}: ${before} -> ${after}"
  if [[ "${http}" != "200" ]] && (( after > before )); then
    log "  PASS: the backend SAN counter moved. The downstream pin rejected the caller."
  else
    log "  FAIL: the request succeeded or the SAN counter did not move."
    log "        The backend downstream pin did not reject the caller by SAN."
    FAILED=1; return 1
  fi

  dc exec -T "${BACKEND_SERVICE}" rm -f "${BACKEND_BROKEN}" 2>/dev/null || true
}

main() {
  log "SAN-pin negative test. Targets: the gateway upstream pin and the backend"
  log "downstream pin. Each pin gets one proof that it can fail for the right reason."
  log ""
  target_gateway_upstream || true
  target_backend_downstream || true

  # The trap restores both Envoys and confirms the baseline.
  log ""
  if (( FAILED == 0 )); then
    log "SAN-PIN TEST: PASS (both pins proved a real SAN-match failure)."
    return 0
  fi
  log "SAN-PIN TEST: FAIL (see the lines above)."
  return 1
}

main "$@"
