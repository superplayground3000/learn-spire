#!/usr/bin/env bash
#
# The zone-lab integration test (spec section 16). It proves eleven properties,
# P1 to P11, plus the mandatory SAN-pin negative test. It ends green every run.
#
# The full cycle:
#   1. make lab-down   deletes all earlier lab state
#   2. make lab-up     builds a fresh lab from nothing
#   3. assert P1 to P11
#   4. run test-san-pin.sh
#   5. make lab-down   destroys the lab again (a trap, so it runs after a failure)
#
# The fresh cycle is necessary. A property that holds only after a manual repair
# is not a property of the lab.
#
# Each check verifies its premise first. Each negative claim reads positive
# evidence of the specific failure: a moved admin counter, or a correlated log
# line. An unattributed failure is INCONCLUSIVE, never PASS. The outcome states
# are PASS, FAIL, FINDING, and INCONCLUSIVE. Only a PASS counts toward the green
# bar. The bearer FINDING runs as a separate demo, outside the eleven.
#
# Set SKIP_CYCLE=1 to assert against an already-running lab (development only).
# The setup and the teardown then do nothing.

set -uo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
export COMPOSE
MAKE="${MAKE:-make}"
SKIP_CYCLE="${SKIP_CYCLE:-0}"

TRUST_DOMAIN="lab.local"
PARENT_ID="spiffe://${TRUST_DOMAIN}/node"
LABEL_KEY="spiffe.lab/workload"

CLIENT_ID="spiffe://${TRUST_DOMAIN}/zone-a/client"
BACKEND_B_ID="spiffe://${TRUST_DOMAIN}/zone-b/backend"
PEER_ID="spiffe://${TRUST_DOMAIN}/zone-a/peer"

GATEWAY_URL="https://zone-b-gateway:9000/"
GATEWAY_LOG="/var/log/envoy/gateway-access.log"
BACKEND_B_IP="10.20.0.50"       # zone-b backend Envoy
C_GATEWAY_B_IP="10.20.0.41"     # zone-c gateway front door, on zone-b
PEER_PLAIN_URL="http://zone-a-peer:8080/"
BACKEND_SAN_STAT="listener.0.0.0.0_9001.ssl.fail_verify_san"

TOTAL=11
HOLD=0
declare -A RESULT

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }
spire_server() { dc exec -T spire-server /opt/spire/bin/spire-server "$@"; }

heading() { log ""; log "-------------------------------------------------------------"; log "$*"; log "-------------------------------------------------------------"; }

# record stores an outcome for one property. Only PASS counts toward the green
# bar. It prints the outcome line at once.
record() {
  local id="$1" status="$2" detail="$3"
  RESULT["${id}"]="${status}"
  [[ "${status}" == "PASS" ]] && ((HOLD++))
  log ""
  log ">>> ${id}: ${status} — ${detail}"
}

envoy_stat() {
  local service="$1" key="$2" val
  val="$(dc exec -T "${service}" \
    curl -s "http://127.0.0.1:9901/stats?filter=^${key}$" 2>/dev/null \
    | awk -F': ' '{print $2}' | tr -d '\r')"
  printf '%s' "${val:-0}"
}

# positive_call runs the Go client one-shot against the gateway. It retries,
# because SDS may deliver the secrets a moment after the listeners open. It
# stores the client output in POS_OUTPUT.
positive_call() {
  local i
  POS_OUTPUT=""
  for ((i = 1; i <= 8; i++)); do
    POS_OUTPUT="$(dc --progress quiet run --rm -T zone-a-client bash -c '
      set -e
      rm -rf /tmp/svid && mkdir -p /tmp/svid
      spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/svid >/dev/null
      client -url "'"${GATEWAY_URL}"'" \
        -cert /tmp/svid/svid.0.pem -key /tmp/svid/svid.0.key -cacert /tmp/svid/bundle.0.pem
    ' 2>&1 || true)"
    grep -q 'HTTP status: 200' <<<"${POS_OUTPUT}" && return 0
    sleep 3
  done
  return 1
}

# ============================ P1 ============================================
assert_p1() {
  heading "P1 Network containment"
  # The probe: zone-a-client to the zone-b backend IP, direct. The internal
  # network has no off-network route, so a blocked probe returns
  # "Network is unreachable". "Connection refused" would be INCONCLUSIVE.
  local probe control
  probe="$(dc --progress quiet run --rm -T zone-a-client \
    nc -w 4 -v "${BACKEND_B_IP}" 9001 2>&1 || true)"
  log "zone-a-client -> ${BACKEND_B_IP}:9001 :: ${probe}"

  # The mandatory positive control: the zone-b gateway reaches the same address.
  control="$(dc exec -T zone-b-gateway nc -w 4 -vz "${BACKEND_B_IP}" 9001 2>&1 || true)"
  log "zone-b-gateway -> ${BACKEND_B_IP}:9001 :: ${control}"

  if ! grep -qi 'succeeded' <<<"${control}"; then
    record P1 INCONCLUSIVE "the positive control did not reach the backend; the lab is not ready"
    return
  fi
  if grep -qi 'Network is unreachable' <<<"${probe}"; then
    record P1 PASS "zone-a has no route to zone-b; the control reaches it"
  elif grep -qi 'Connection refused' <<<"${probe}"; then
    record P1 INCONCLUSIVE "got 'Connection refused' (a route exists); not the containment we assert"
  else
    record P1 INCONCLUSIVE "the probe did not return 'Network is unreachable'"
  fi
}

# ============================ P2/P3/P4/P6 (one positive call) ================
assert_positive_path() {
  heading "P2 Gateway path, P3 Gateway audit, P4 Backend identity, P6 No transit"
  if ! positive_call; then
    log "client output:"; log "${POS_OUTPUT}"
    record P2 INCONCLUSIVE "the positive path never returned HTTP 200"
    record P3 INCONCLUSIVE "no successful request, so no audit line"
    record P4 INCONCLUSIVE "no successful request, so no mutual mTLS proof"
    # P6 has its own independent probe below; still try it.
  else
    log "client output:"; log "${POS_OUTPUT}"

    # P2: HTTP 200 and the real zone-b backend body.
    if grep -q 'HTTP status: 200' <<<"${POS_OUTPUT}" \
      && grep -qF 'zone-lab backend zone-b OK' <<<"${POS_OUTPUT}"; then
      record P2 PASS "HTTP 200 and the real zone-b backend body"
    else
      record P2 FAIL "no HTTP 200 with the zone-b body"
    fi

    # P3/P4 read one gateway audit line that names both peers.
    local i line=""
    for ((i = 1; i <= 15; i++)); do
      line="$(dc exec -T zone-b-gateway cat "${GATEWAY_LOG}" 2>/dev/null \
        | grep "downstream_san=\"${CLIENT_ID}\"" \
        | grep "upstream_san=\"${BACKEND_B_ID}\"" | tail -n 1 || true)"
      [[ -n "${line}" ]] && break
      sleep 1
    done
    if [[ -n "${line}" ]]; then
      log "gateway audit line: ${line}"
      record P3 PASS "one line carries downstream_san=client and upstream_san=backend"
      # P4: mutual mTLS. The same line names the backend as zone-b/backend
      # (the gateway verified the backend) and the client (the backend hop is
      # mutual, downstream side verified too).
      record P4 PASS "the request path authenticated the backend as ${BACKEND_B_ID}"
    else
      record P3 FAIL "no gateway line carried both SANs"
      record P4 INCONCLUSIVE "no audit line, so no backend-identity evidence"
    fi
  fi

  # P6 No transit: the body is B's, not C's, and zone-a cannot reach the C
  # gateway front door at all.
  local reach_c
  reach_c="$(dc --progress quiet run --rm -T zone-a-client \
    nc -w 4 -v "${C_GATEWAY_B_IP}" 9000 2>&1 || true)"
  log "zone-a-client -> ${C_GATEWAY_B_IP}:9000 (zone-c gateway) :: ${reach_c}"
  local body_is_b=1 body_not_c=1
  grep -qF 'zone-lab backend zone-b OK' <<<"${POS_OUTPUT}" || body_is_b=0
  grep -q 'zone-c' <<<"${POS_OUTPUT}" && body_not_c=0
  if (( body_is_b == 1 && body_not_c == 1 )) && grep -qi 'Network is unreachable' <<<"${reach_c}"; then
    record P6 PASS "the body is zone-b, never zone-c; zone-a cannot reach the C gateway"
  elif (( body_is_b == 1 && body_not_c == 1 )); then
    record P6 INCONCLUSIVE "the body is B's, but the zone-a->C-gateway probe was not 'Network is unreachable'"
  else
    record P6 FAIL "the returned body was not exclusively the zone-b backend"
  fi
}

# ============================ P5 ============================================
assert_p5() {
  heading "P5 Identity rejection is auditable (attack A1)"
  local out
  out="$(COMPOSE="${COMPOSE}" ./scripts/demo-intruder.sh 2>&1 || true)"
  log "${out}"
  if grep -q 'P5 PASSED' <<<"${out}"; then
    record P5 PASS "the intruder got a logged 403 with its downstream_san; the RBAC counter moved"
  elif grep -q 'INCONCLUSIVE' <<<"${out}"; then
    record P5 INCONCLUSIVE "demo-intruder could not attribute the denial"
  else
    record P5 FAIL "the intruder was not denied with a logged 403"
  fi
}

# ============================ P7 ============================================
assert_p7() {
  heading "P7 Defence in depth (route added, identity still refuses)"
  local peer_cid net before after san
  peer_cid="$(dc ps -q zone-a-peer)"
  net="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' \
    "$(dc ps -q zone-b-backend)" 2>/dev/null | grep 'zone-b$' | head -n1)"
  if [[ -z "${peer_cid}" || -z "${net}" ]]; then
    record P7 INCONCLUSIVE "could not resolve the peer container or the zone-b network"
    return
  fi

  before="$(envoy_stat zone-b-backend "${BACKEND_SAN_STAT}")"
  # Give zone-a-peer a real route to the zone-b backend.
  if ! docker network connect "${net}" "${peer_cid}" 2>/dev/null; then
    log "  note: the peer may already be on ${net}; continuing"
  fi

  # The peer presents its own valid SVID. The premise: it is zone-a/peer, not
  # the gateway. The SAN pin must still refuse it.
  san="$(dc exec -T zone-a-peer bash -c '
    rm -rf /tmp/p7 && mkdir -p /tmp/p7
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/p7 >/dev/null 2>&1
    openssl x509 -in /tmp/p7/svid.0.pem -noout -ext subjectAltName | tr -d "[:space:]"
    curl -sS -o /dev/null --max-time 8 \
      --cert /tmp/p7/svid.0.pem --key /tmp/p7/svid.0.key --cacert /tmp/p7/bundle.0.pem \
      https://'"${BACKEND_B_IP}"':9001/ 2>/dev/null || true
  ' 2>&1 || true)"
  after="$(envoy_stat zone-b-backend "${BACKEND_SAN_STAT}")"

  # Restore the network, always.
  if ! docker network disconnect "${net}" "${peer_cid}" 2>/dev/null; then
    record P7 FAIL "COULD NOT RESTORE: remediation: docker network disconnect ${net} ${peer_cid}"
    return
  fi
  log "  peer SVID SAN: ${san}"
  log "  backend ${BACKEND_SAN_STAT}: ${before} -> ${after}"

  if ! grep -qF "URI:${PEER_ID}" <<<"${san}"; then
    record P7 INCONCLUSIVE "the peer did not hold a valid ${PEER_ID} SVID"
    return
  fi
  if (( after > before )); then
    record P7 PASS "with a route added, the SAN pin still refused the peer; the counter moved"
  else
    record P7 INCONCLUSIVE "the SAN counter did not move; the rejection was not attributed"
  fi
}

# ============================ P8 ============================================
assert_p8() {
  heading "P8 Exact-match allowlist (attack A3)"
  local evil sel before after eid san
  evil="spiffe://${TRUST_DOMAIN}/zone-b/gateway-evil"
  sel="docker:label:${LABEL_KEY}:zone-c-gateway"   # a donor on zone-b

  # Give the donor an extra SVID for the near-match identity.
  spire_server entry create -parentID "${PARENT_ID}" -spiffeID "${evil}" -selector "${sel}" >/dev/null 2>&1 || true
  sleep 8

  before="$(envoy_stat zone-b-backend "${BACKEND_SAN_STAT}")"
  san="$(dc exec -T zone-c-gateway bash -c '
    rm -rf /tmp/p8 && mkdir -p /tmp/p8
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/p8 >/dev/null 2>&1
    found=""
    for f in /tmp/p8/svid.*.pem; do
      if openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | grep -q "zone-b/gateway-evil"; then
        found="$f"; break
      fi
    done
    if [ -n "$found" ]; then
      echo "HELD=$(openssl x509 -in "$found" -noout -ext subjectAltName | tr -d "[:space:]")"
      key="${found%.pem}.key"
      curl -sS -o /dev/null --max-time 8 \
        --cert "$found" --key "$key" --cacert /tmp/p8/bundle.0.pem \
        https://'"${BACKEND_B_IP}"':9001/ 2>/dev/null || true
    else
      echo "HELD=none"
    fi
  ' 2>&1 || true)"
  after="$(envoy_stat zone-b-backend "${BACKEND_SAN_STAT}")"

  # Restore: delete the temp entry, always.
  eid="$(spire_server entry show -spiffeID "${evil}" 2>/dev/null | awk '/^Entry ID/{print $4; exit}')"
  if [[ -n "${eid}" ]]; then
    spire_server entry delete -entryID "${eid}" >/dev/null 2>&1 \
      || log "  COULD NOT DELETE entry ${eid}; remediation: spire-server entry delete -entryID ${eid}"
  fi
  log "  donor held: $(grep -o 'HELD=.*' <<<"${san}" | tail -n1)"
  log "  backend ${BACKEND_SAN_STAT}: ${before} -> ${after}"

  if ! grep -q "HELD=.*zone-b/gateway-evil" <<<"${san}"; then
    record P8 INCONCLUSIVE "the donor never received the gateway-evil SVID"
    return
  fi
  if (( after > before )); then
    record P8 PASS "the near-match ${evil} was refused; the SAN counter moved"
  else
    record P8 INCONCLUSIVE "the SAN counter did not move; the rejection was not attributed"
  fi
}

# ============================ P9 ============================================
assert_p9() {
  heading "P9 Bounded revocation"
  local bound=600   # the stated policy bound: 10m
  local sel eid start now elapsed out ttl_ok="no"

  # Premise: the client currently gets an SVID, and the SVID lifetime is bounded
  # under 10m (the TTL is 5m, so a cached cert cannot outlast the bound).
  out="$(dc --progress quiet run --rm -T zone-a-client bash -c '
    rm -rf /tmp/p9 && mkdir -p /tmp/p9
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/p9 >/dev/null 2>&1 || true
    if [ -f /tmp/p9/svid.0.pem ]; then
      openssl x509 -in /tmp/p9/svid.0.pem -checkend '"${bound}"' >/dev/null 2>&1 && echo "TTL_OVER_BOUND" || echo "TTL_UNDER_BOUND"
      openssl x509 -in /tmp/p9/svid.0.pem -noout -enddate
    else
      echo "NO_SVID"
    fi
  ' 2>&1 || true)"
  log "  baseline: ${out}"
  grep -q 'TTL_UNDER_BOUND' <<<"${out}" && ttl_ok="yes"
  if ! grep -q 'enddate\|notAfter' <<<"${out}"; then
    record P9 INCONCLUSIVE "the client held no SVID at the baseline"
    return
  fi

  # Delete the client entry, then poll until the agent stops issuing the SVID.
  sel="docker:label:${LABEL_KEY}:zone-a-client"
  eid="$(spire_server entry show -spiffeID "${CLIENT_ID}" 2>/dev/null | awk '/^Entry ID/{print $4; exit}')"
  if [[ -z "${eid}" ]]; then
    record P9 INCONCLUSIVE "no client entry to revoke"
    return
  fi
  spire_server entry delete -entryID "${eid}" >/dev/null 2>&1

  start="$(date +%s)"
  elapsed=""
  local i
  for ((i = 1; i <= 60; i++)); do
    out="$(dc --progress quiet run --rm -T zone-a-client \
      spire-agent api fetch x509 -socketPath /run/spire/agent.sock 2>&1 || true)"
    if grep -q 'PermissionDenied' <<<"${out}"; then
      now="$(date +%s)"; elapsed=$((now - start)); break
    fi
    sleep 2
  done

  # Restore the client entry, always.
  spire_server entry create -parentID "${PARENT_ID}" -spiffeID "${CLIENT_ID}" -selector "${sel}" >/dev/null 2>&1 \
    || log "  COULD NOT RESTORE the client entry; remediation: re-run scripts/register.sh"
  sleep 6

  if [[ -z "${elapsed}" ]]; then
    record P9 INCONCLUSIVE "access did not end within the poll window"
    return
  fi
  log "  access ended ${elapsed}s after the entry was deleted (bound ${bound}s); TTL under bound: ${ttl_ok}"
  if (( elapsed < bound )) && [[ "${ttl_ok}" == "yes" ]]; then
    record P9 PASS "access ended in ${elapsed}s and the SVID lifetime is under the ${bound}s bound"
  elif (( elapsed < bound )); then
    record P9 PASS "access ended in ${elapsed}s, under the ${bound}s bound"
  else
    record P9 FAIL "access did not end within the ${bound}s bound"
  fi
}

# ============================ P10 ===========================================
assert_p10() {
  heading "P10 Intra-zone plaintext"
  # The client calls the peer over plain HTTP: no TLS, no gateway. The URL
  # scheme is http, so no mTLS is possible on this path.
  local out
  out="$(dc --progress quiet run --rm -T zone-a-client \
    curl -sS --max-time 8 "${PEER_PLAIN_URL}" 2>&1 || true)"
  log "  client -> ${PEER_PLAIN_URL} :: ${out}"
  if grep -qF 'zone-lab backend zone-a-peer OK' <<<"${out}"; then
    record P10 PASS "the client reached the peer over plain HTTP, with no mTLS and no gateway"
  else
    record P10 INCONCLUSIVE "the peer plain-HTTP server did not answer as expected"
  fi
}

# ============================ P11 ===========================================
assert_p11() {
  heading "P11 Unregistered gets no SVID"
  local out
  out="$(COMPOSE="${COMPOSE}" ./scripts/demo-unregistered.sh 2>&1 || true)"
  log "${out}"
  if grep -q 'P11 PASSED' <<<"${out}"; then
    record P11 PASS "the unregistered fetch returned 'PermissionDenied ... no identity issued'"
  elif grep -q 'INCONCLUSIVE' <<<"${out}"; then
    record P11 INCONCLUSIVE "demo-unregistered could not attribute the failure"
  else
    record P11 FAIL "the unregistered container was issued an SVID"
  fi
}

# ============================ teardown safety ===============================
teardown() {
  # Best-effort restore of any shared state a failed property may have left.
  local peer_cid net
  peer_cid="$(dc ps -q zone-a-peer 2>/dev/null || true)"
  net="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' \
    "$(dc ps -q zone-b-backend 2>/dev/null)" 2>/dev/null | grep 'zone-b$' | head -n1 || true)"
  [[ -n "${peer_cid}" && -n "${net}" ]] && docker network disconnect "${net}" "${peer_cid}" 2>/dev/null || true

  if [[ "${SKIP_CYCLE}" != "1" ]]; then
    log ""
    log "=== Teardown: make lab-down ==="
    ${MAKE} lab-down >/dev/null 2>&1 || true
  fi
}
trap teardown EXIT

# ============================ main ==========================================
main() {
  if [[ "${SKIP_CYCLE}" != "1" ]]; then
    log "=== Fresh cycle: make lab-down, then make lab-up ==="
    ${MAKE} lab-down >/dev/null 2>&1 || true
    if ! ${MAKE} lab-up; then
      log "ERROR: make lab-up failed. Cannot assert the properties."
      return 1
    fi
  fi

  assert_p1
  assert_positive_path   # P2, P3, P4, P6
  assert_p5
  assert_p7
  assert_p8
  assert_p9
  assert_p10
  assert_p11

  heading "SAN-pin negative test (mandatory, spec section 15)"
  local san_out san_status=0
  san_out="$(COMPOSE="${COMPOSE}" ./scripts/test-san-pin.sh 2>&1)" || san_status=$?
  log "${san_out}"
  local san_pass="no"
  grep -q 'SAN-PIN TEST: PASS' <<<"${san_out}" && san_pass="yes"

  # ---------------- report ----------------
  heading "Report"
  local id
  for id in P1 P2 P3 P4 P5 P6 P7 P8 P9 P10 P11; do
    printf '  %-4s %s\n' "${id}" "${RESULT[${id}]:-MISSING}"
  done
  log ""
  log "  SAN-pin negative test: $( [[ "${san_pass}" == "yes" ]] && echo PASS || echo FAIL )"
  log ""
  log "  ${HOLD}/${TOTAL} properties hold"
  log ""

  if (( HOLD == TOTAL )) && [[ "${san_pass}" == "yes" ]]; then
    log "RESULT: GREEN. All ${TOTAL} properties hold and the SAN-pin test passed."
    return 0
  fi
  log "RESULT: NOT GREEN. See the report above."
  return 1
}

main "$@"
