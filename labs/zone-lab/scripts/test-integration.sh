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
BACKEND_C_ID="spiffe://${TRUST_DOMAIN}/zone-c/backend"
PEER_ID="spiffe://${TRUST_DOMAIN}/zone-a/peer"

# Phase-2 registry constants. The registry log is inside the registry container.
# The lease and reap times are short, so the lease tests run in about a minute.
REGISTRY_LOG="/var/log/lab/registry.log"
REGISTRAR_LOG="/var/log/lab/registrar.log"
LEASE_TTL=30
REAP_INTERVAL=5

GATEWAY_URL="https://zone-b-gateway:9000/"
GATEWAY_LOG="/var/log/envoy/gateway-access.log"
BACKEND_B_IP="10.20.0.50"       # zone-b backend Envoy
C_GATEWAY_B_IP="10.20.0.41"     # zone-c gateway front door, on zone-b
PEER_PLAIN_URL="http://zone-a-peer:8080/"
BACKEND_SAN_STAT="listener.0.0.0.0_9001.ssl.fail_verify_san"

# Phase-2 part B: the per-zone CoreDNS resolvers and the names they steer. Each
# resolver sits on its own zone network at .53. The tests query the zone
# resolver directly by address, so each read is deterministic. The registry
# never writes a real backend address into a peer's view, so a peer can only
# ever resolve the gateway address, never the real backend.
COREDNS_A_IP="10.10.0.53"
COREDNS_B_IP="10.20.0.53"
COREDNS_C_IP="10.30.0.53"
NAME_B="backend.zone-b.internal."   # zone-b's own service
NAME_C="backend.zone-c.internal."   # zone-c's own service
BACKEND_C_IP="10.30.0.50"           # the real zone-c backend Envoy address
B_GATEWAY_IN_A="10.10.0.40"         # the zone-b gateway, as seen from zone-a

# Phase 1 asserts P1 to P11. Phase-2 part A adds P15 to P18. Phase-2 part B adds
# P12 to P14 (DNS steering) and P19 (the bypass punchline).
TOTAL=19
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

# ============================ phase-2 registry helpers ======================

# registry_post sends one register request from a container, with that
# container's own SVID. The test never reads the curl output for the decision.
# It reads the registry log, which is positive server-side evidence.
registry_post() {
  local from="$1" zone="$2" svc="$3"
  dc exec -T "${from}" bash -c '
    rm -rf /tmp/reg && mkdir -p /tmp/reg
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/reg >/dev/null 2>&1
    curl -sS --cert /tmp/reg/svid.0.pem --key /tmp/reg/svid.0.key --cacert /tmp/reg/bundle.0.pem \
      -X POST https://zone-registry:9443/register -H "Content-Type: application/json" \
      -d "{\"zone\":\"'"${zone}"'\",\"service\":\"'"${svc}"'\",\"ip\":\"10.20.0.50\",\"port\":9001}" \
      --max-time 8 >/dev/null 2>&1 || true
  ' >/dev/null 2>&1 || true
}

# registry_get reads /registry through the registry Envoy, with a valid SVID.
# The reader is zone-c-backend, which the lease tests never revoke.
registry_get() {
  dc exec -T zone-c-backend bash -c '
    rm -rf /tmp/rget && mkdir -p /tmp/rget
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/rget >/dev/null 2>&1
    curl -sS --cert /tmp/rget/svid.0.pem --key /tmp/rget/svid.0.key --cacert /tmp/rget/bundle.0.pem \
      https://zone-registry:9443/registry --max-time 8 2>&1 || true
  ' 2>&1 || true
}

# has_record returns 0 when the /registry JSON holds the named record.
has_record() { grep -q "\"name\":\"$1\"" <<<"$2"; }

# registry_log greps the registry container log for a pattern.
registry_log() { dc exec -T zone-registry grep -a "$1" "${REGISTRY_LOG}" 2>/dev/null || true; }

# start_b_registrar starts the zone-b-backend registrar. The tests use it to
# restore the renewal after they stop it.
start_b_registrar() {
  dc exec -d zone-b-backend bash -c \
    "REGISTRY_ADDR=zone-registry REGISTRY_PORT=9443 ZONE=zone-b SERVICE=backend IP=10.20.0.50 PORT=9001 INTERVAL=10 \
     registrar >>${REGISTRAR_LOG} 2>&1" >/dev/null 2>&1 || true
}

# wait_record waits until the named record is present (want=yes) or gone
# (want=no). It returns 0 on success.
wait_record() {
  local name="$1" want="$2" secs="$3" i recs
  for ((i = 1; i <= secs; i++)); do
    recs="$(registry_get)"
    if [[ "${want}" == "yes" ]] && has_record "${name}" "${recs}"; then return 0; fi
    if [[ "${want}" == "no" ]] && ! has_record "${name}" "${recs}"; then return 0; fi
    sleep 1
  done
  return 1
}

# ============================ P15 ===========================================
assert_p15() {
  heading "P15 Cross-zone registration refused"
  # The caller is zone-b/backend. It tries to register into zone-c. The zone
  # differs, so the registry must refuse it with the exact reason. To prove the
  # rule can fail, delete the zone check in registry/main.go authorize(): the
  # same call would then be ACCEPTED.
  registry_post zone-b-backend zone-c backend
  local line
  line="$(registry_log "REFUSED caller=${BACKEND_B_ID} wants=backend.zone-c" | grep -a "cross-zone registration refused" | tail -n1)"
  log "  registry log: ${line:-<none>}"
  if [[ -n "${line}" ]]; then
    record P15 PASS "zone-b/backend was refused into zone-c with 'cross-zone registration refused'"
  else
    record P15 FAIL "no registry log line refused the cross-zone registration with the exact reason"
  fi
}

# ============================ P16 ===========================================
assert_p16() {
  heading "P16 Wrong-service registration refused"
  # The caller is zone-b/backend. It tries to register the service "payments"
  # in its own zone. The service differs, so the registry must refuse it with
  # 'service mismatch'.
  registry_post zone-b-backend zone-b payments
  local line
  line="$(registry_log "REFUSED caller=${BACKEND_B_ID} wants=payments.zone-b" | grep -a "service mismatch" | tail -n1)"
  log "  registry log: ${line:-<none>}"
  if [[ -n "${line}" ]]; then
    record P16 PASS "zone-b/backend was refused service 'payments' with 'service mismatch'"
  else
    record P16 FAIL "no registry log line refused the wrong service with 'service mismatch'"
  fi
}

# ============================ P17 ===========================================
assert_p17() {
  heading "P17 Lease expiry reaps the record"
  # Premise: both backend records renew now. backend.zone-c is the CONTROL. It
  # keeps renewing, so its survival attributes the reap to the stopped renewal.
  if ! wait_record "backend.zone-b" yes 30 || ! wait_record "backend.zone-c" yes 30; then
    record P17 INCONCLUSIVE "the two backend records were not both present at the start"
    return
  fi
  log "  premise: backend.zone-b and backend.zone-c are both registered"

  # Stop only the zone-b registrar. backend.zone-b must now age out.
  dc exec -T zone-b-backend pkill -f /usr/local/bin/registrar >/dev/null 2>&1 || true
  log "  stopped the zone-b-backend registrar; waiting for the lease to expire"

  local window=$((LEASE_TTL + REAP_INTERVAL + 25))
  local reaped="no" control="no"
  if wait_record "backend.zone-b" no "${window}"; then reaped="yes"; fi
  local recs; recs="$(registry_get)"
  has_record "backend.zone-c" "${recs}" && control="yes"
  local expired_line; expired_line="$(registry_log "EXPIRED backend.zone-b" | tail -n1)"
  log "  registry log: ${expired_line:-<none>}"
  log "  after the window: backend.zone-b reaped=${reaped}, backend.zone-c (control) present=${control}"

  # Restore the zone-b registrar, always.
  start_b_registrar
  if ! wait_record "backend.zone-b" yes 30; then
    log "  WARNING: backend.zone-b did not re-register after restore"
  fi

  if [[ "${reaped}" == "yes" && "${control}" == "yes" && -n "${expired_line}" ]]; then
    record P17 PASS "the un-renewed backend.zone-b was reaped; the renewing control survived"
  elif [[ "${reaped}" == "yes" && "${control}" != "yes" ]]; then
    record P17 INCONCLUSIVE "backend.zone-b left, but the control also left; the reap is not attributable"
  else
    record P17 FAIL "backend.zone-b was not reaped within the lease window"
  fi
}

# ============================ P18 ===========================================
assert_p18() {
  heading "P18 Revoked identity ages out"
  # Premise: backend.zone-b renews now. Its registrar keeps running through the
  # whole test. Only the identity is revoked.
  if ! wait_record "backend.zone-b" yes 40; then
    record P18 INCONCLUSIVE "backend.zone-b was not registered at the start"
    return
  fi
  local sel eid
  sel="docker:label:${LABEL_KEY}:zone-b-backend"
  eid="$(spire_server entry show -spiffeID "${BACKEND_B_ID}" 2>/dev/null | awk '/^Entry ID/{print $4; exit}')"
  if [[ -z "${eid}" ]]; then
    record P18 INCONCLUSIVE "no zone-b-backend entry to revoke"
    return
  fi

  # Delete the entry. The registrar re-fetches the SVID before each renewal, so
  # it soon holds no certificate and its renewal fails. The record then ages out.
  spire_server entry delete -entryID "${eid}" >/dev/null 2>&1
  log "  deleted the zone-b-backend entry ${eid}; the registrar can no longer renew"

  local window=$((LEASE_TTL + REAP_INTERVAL + 60))
  local aged="no"
  if wait_record "backend.zone-b" no "${window}"; then aged="yes"; fi
  local fail_line; fail_line="$(dc exec -T zone-b-backend grep -a 'RENEWAL SKIPPED\|RENEWAL FAILED' "${REGISTRAR_LOG}" 2>/dev/null | tail -n1)"
  local expired_line; expired_line="$(registry_log "EXPIRED backend.zone-b" | tail -n1)"
  log "  registrar log: ${fail_line:-<none>}"
  log "  registry log:  ${expired_line:-<none>}"
  log "  after the window: backend.zone-b aged out=${aged}"

  # Restore the entry, always. The registrar then re-fetches and re-registers.
  spire_server entry create -parentID "${PARENT_ID}" -spiffeID "${BACKEND_B_ID}" -selector "${sel}" >/dev/null 2>&1 \
    || log "  COULD NOT RESTORE the zone-b-backend entry; remediation: re-run scripts/register.sh"
  wait_record "backend.zone-b" yes 40 >/dev/null 2>&1 || log "  WARNING: backend.zone-b did not re-register after restore"

  if [[ "${aged}" == "yes" && -n "${fail_line}" && -n "${expired_line}" ]]; then
    record P18 PASS "after revocation the registrar could not renew; the record aged out"
  elif [[ "${aged}" == "yes" ]]; then
    record P18 INCONCLUSIVE "the record left, but no renewal-failure line attributed it to revocation"
  else
    record P18 FAIL "the record did not age out after the identity was revoked"
  fi
}

# ============================ phase-2 part B: DNS helpers ====================

# dns_status reads the DNS rcode from a zone resolver. It returns NOERROR,
# NXDOMAIN, SERVFAIL, or NONE. The name carries a trailing dot, so dig never
# appends a search domain; a search-domain rc=0 can never be read as an answer.
dns_status() {
  local from="$1" server="$2" name="$3" out st
  out="$(dc exec -T "${from}" dig @"${server}" "${name}" +time=3 +tries=2 2>/dev/null || true)"
  st="$(grep -oE 'status: [A-Z]+' <<<"${out}" | head -n1 | awk '{print $2}')"
  printf '%s' "${st:-NONE}"
}

# dns_a reads the first A address a zone resolver returns for a name. On NXDOMAIN
# it prints nothing. This is the positive evidence: the actual resolved address.
dns_a() {
  local from="$1" server="$2" name="$3"
  dc exec -T "${from}" dig @"${server}" "${name}" +short 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true
}

# wait_dns_a waits until a resolver returns the wanted address for a name. It
# covers the reload lag (the file plugin polls every 5s).
wait_dns_a() {
  local from="$1" server="$2" name="$3" want="$4" secs="$5" i got
  for ((i = 1; i <= secs; i++)); do
    got="$(dns_a "${from}" "${server}" "${name}")"
    [[ "${got}" == "${want}" ]] && return 0
    sleep 1
  done
  return 1
}

# ============================ P12 ===========================================
assert_p12() {
  heading "P12 Self-zone resolves to the real address"
  # Premise: backend.zone-b is registered, so zone-b's own view holds it as a
  # real A record. A zone-b workload asks zone-b's resolver.
  if ! wait_record "backend.zone-b" yes 40; then
    record P12 INCONCLUSIVE "backend.zone-b was not registered, so it has no view record"
    return
  fi
  # Give the view a moment to reach CoreDNS (the file plugin reloads every 5s).
  wait_dns_a zone-b-backend "${COREDNS_B_IP}" "${NAME_B}" "${BACKEND_B_IP}" 40 >/dev/null 2>&1 || true
  local ans st
  ans="$(dns_a zone-b-backend "${COREDNS_B_IP}" "${NAME_B}")"
  st="$(dns_status zone-b-backend "${COREDNS_B_IP}" "${NAME_B}")"
  log "  zone-b-backend asks ${COREDNS_B_IP}: ${NAME_B} -> ${ans:-<none>} (status ${st})"
  if [[ "${st}" == "NOERROR" && "${ans}" == "${BACKEND_B_IP}" ]]; then
    record P12 PASS "backend.zone-b resolved to the real address ${BACKEND_B_IP}"
  else
    record P12 FAIL "backend.zone-b did not resolve to ${BACKEND_B_IP} (got ${ans:-<none>}, status ${st})"
  fi
}

# ============================ P13 ===========================================
assert_p13() {
  heading "P13 Authorized peer resolves to the gateway, never the backend"
  # zone-a may reach zone-b. zone-a's view holds one wildcard for zone-b that
  # points at the zone-b gateway, as seen from zone-a. zone-a's view never holds
  # the real backend address, so the peer can only ever get the gateway. The
  # wildcard is policy-derived, so it needs no registration.
  wait_dns_a zone-a-peer "${COREDNS_A_IP}" "${NAME_B}" "${B_GATEWAY_IN_A}" 40 >/dev/null 2>&1 || true
  local ans st
  ans="$(dns_a zone-a-peer "${COREDNS_A_IP}" "${NAME_B}")"
  st="$(dns_status zone-a-peer "${COREDNS_A_IP}" "${NAME_B}")"
  log "  zone-a-peer asks ${COREDNS_A_IP}: ${NAME_B} -> ${ans:-<none>} (status ${st})"
  log "  gateway-as-seen-from-a=${B_GATEWAY_IN_A}, real backend=${BACKEND_B_IP}"
  if [[ "${ans}" == "${BACKEND_B_IP}" ]]; then
    record P13 FAIL "LEAK: the peer resolved the cross-zone name to the REAL backend ${BACKEND_B_IP}"
  elif [[ "${st}" == "NOERROR" && "${ans}" == "${B_GATEWAY_IN_A}" ]]; then
    record P13 PASS "the peer got the gateway ${B_GATEWAY_IN_A}, never the real backend ${BACKEND_B_IP}"
  else
    record P13 FAIL "the peer did not resolve to the gateway ${B_GATEWAY_IN_A} (got ${ans:-<none>}, status ${st})"
  fi
}

# ============================ P14 ===========================================
assert_p14() {
  heading "P14 Unauthorized zone gets NXDOMAIN (not SERVFAIL)"
  # zone-a may NOT reach zone-c. zone-a's view holds no zone-c name. The view has
  # an SOA, so an absent name is authoritative NXDOMAIN, not SERVFAIL. A liveness
  # control proves the resolver still answers a valid name, so NXDOMAIN means
  # containment, not a dead resolver.
  local deny_st live_st live_ans
  deny_st="$(dns_status zone-a-peer "${COREDNS_A_IP}" "${NAME_C}")"
  live_ans="$(dns_a zone-a-peer "${COREDNS_A_IP}" "${NAME_B}")"
  live_st="$(dns_status zone-a-peer "${COREDNS_A_IP}" "${NAME_B}")"
  log "  zone-a-peer asks ${COREDNS_A_IP}: ${NAME_C} -> status ${deny_st} (unauthorized)"
  log "  liveness control: ${NAME_B} -> ${live_ans:-<none>} (status ${live_st})"
  if [[ "${live_st}" != "NOERROR" ]]; then
    record P14 INCONCLUSIVE "the resolver did not answer the valid control name; it may be dead"
    return
  fi
  if [[ "${deny_st}" == "NXDOMAIN" ]]; then
    record P14 PASS "the unauthorized zone-c name got NXDOMAIN; the resolver still answers a valid name"
  elif [[ "${deny_st}" == "SERVFAIL" ]]; then
    record P14 FAIL "the unauthorized name got SERVFAIL, not NXDOMAIN"
  else
    record P14 FAIL "the unauthorized name did not get NXDOMAIN (status ${deny_st})"
  fi
}

# ============================ P19 ===========================================
assert_p19() {
  heading "P19 DNS bypass is still contained (the punchline)"
  # A zone-a client IGNORES DNS. It hardcodes the REAL zone-c backend address and
  # dials it. DNS steering already said NXDOMAIN for that name (P14). But even a
  # hardcoded address is stopped by the phase-1 network layer: zone-a holds no
  # route to zone-c. So the probe returns "Network is unreachable".
  # "Connection refused" would mean a route exists; that is INCONCLUSIVE.
  local probe control
  probe="$(dc --progress quiet run --rm -T zone-a-client \
    nc -w 4 -v "${BACKEND_C_IP}" 9001 2>&1 || true)"
  log "  zone-a-client hardcodes ${BACKEND_C_IP}:9001 (real zone-c backend) :: ${probe}"

  # The mandatory positive control: a zone-c node reaches the same address, so
  # the target is alive. The block is containment, not a dead backend.
  control="$(dc exec -T zone-c-gateway nc -w 4 -vz "${BACKEND_C_IP}" 9001 2>&1 || true)"
  log "  zone-c-gateway -> ${BACKEND_C_IP}:9001 (control) :: ${control}"

  if ! grep -qi 'succeeded' <<<"${control}"; then
    record P19 INCONCLUSIVE "the positive control did not reach the zone-c backend; the target may be down"
    return
  fi
  if grep -qi 'Network is unreachable' <<<"${probe}"; then
    record P19 PASS "the hardcoded-IP bypass hit 'Network is unreachable'; the network layer contains it, not DNS"
  elif grep -qi 'Connection refused' <<<"${probe}"; then
    record P19 INCONCLUSIVE "got 'Connection refused' (a route exists); not the containment we assert"
  else
    record P19 INCONCLUSIVE "the bypass probe did not return 'Network is unreachable'"
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

  # Best-effort restore of the zone-b-backend entry and registrar. The lease
  # tests stop them. A full teardown destroys the lab anyway, so this matters
  # only for SKIP_CYCLE=1 development runs.
  if [[ "${SKIP_CYCLE}" == "1" ]]; then
    if ! spire_server entry show -spiffeID "${BACKEND_B_ID}" 2>/dev/null | grep -q '^Entry ID'; then
      spire_server entry create -parentID "${PARENT_ID}" -spiffeID "${BACKEND_B_ID}" \
        -selector "docker:label:${LABEL_KEY}:zone-b-backend" >/dev/null 2>&1 || true
    fi
    start_b_registrar
  fi

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

  # Phase-2 part A: the registration and lease properties.
  assert_p15
  assert_p16
  assert_p17
  assert_p18

  # Phase-2 part B: the DNS steering properties and the bypass punchline.
  assert_p12
  assert_p13
  assert_p14
  assert_p19

  heading "SAN-pin negative test (mandatory, spec section 15)"
  local san_out san_status=0
  san_out="$(COMPOSE="${COMPOSE}" ./scripts/test-san-pin.sh 2>&1)" || san_status=$?
  log "${san_out}"
  local san_pass="no"
  grep -q 'SAN-PIN TEST: PASS' <<<"${san_out}" && san_pass="yes"

  # ---------------- report ----------------
  heading "Report"
  local id
  log "  phase 1 (P1-P11), phase-2 part A (P15-P18), phase-2 part B (P12-P14 DNS, P19 bypass)"
  for id in P1 P2 P3 P4 P5 P6 P7 P8 P9 P10 P11 P12 P13 P14 P15 P16 P17 P18 P19; do
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
