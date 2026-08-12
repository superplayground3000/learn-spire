#!/usr/bin/env bash
#
# Starts the backend app and both Envoys, then runs the three spike proofs:
#   Proof 1: client -> gateway -> backend works over mTLS (HTTP 200, real body).
#   Proof 2: a direct client -> backend probe gets "Network is unreachable".
#   Proof 3: Envoy loads its cert and the trust bundle over SDS (admin stats).
#
# The script prints one PASS or FAIL line per proof with the evidence.

set -uo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
GW="zone-b-gateway"
BE="zone-b-backend"
CL="zone-a-client"
BACKEND_IP="172.30.20.50"

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }

fail=0

log "=== Starting the backend app on 127.0.0.1:8080 ==="
dc exec -T "${BE}" bash -c 'echo "zone-lab-spike backend OK" > /opt/www/index.html'
dc exec -d "${BE}" bash -c 'cd /opt/www && python3 -m http.server 8080 --bind 127.0.0.1 > /var/log/lab/app.log 2>&1'

log "=== Starting the backend Envoy on :9001 ==="
dc exec -d "${BE}" bash -c 'envoy -c /etc/envoy/backend-envoy.yaml --log-path /var/log/envoy/backend.log'

log "=== Starting the gateway Envoy on :9000 ==="
dc exec -d "${GW}" bash -c 'envoy -c /etc/envoy/gateway-envoy.yaml --log-path /var/log/envoy/gateway.log'

log "=== Waiting for the Envoy listeners ==="
for c in "${BE}:9001" "${GW}:9000"; do
  name="${c%:*}"; port="${c#*:}"
  for i in $(seq 1 30); do
    if dc exec -T "${name}" bash -c "ss -tln | grep -q ':${port} '"; then
      log "  ${name} listening on ${port}"; break
    fi
    [ "$i" -eq 30 ] && { log "  FAIL ${name} never listened on ${port}"; fail=1; }
    sleep 1
  done
done

# Give SDS a moment to deliver the secrets to both Envoys.
sleep 3

log ""
log "=== Client fetches its SVID as files from the shared agent socket ==="
dc exec -T "${CL}" bash -c '
  rm -rf /tmp/svid && mkdir -p /tmp/svid
  spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/svid
  echo "--- files ---"; ls -1 /tmp/svid
'

log ""
log "############################################################"
log "# PROOF 1: client -> gateway -> backend over mTLS"
log "############################################################"
P1="$(dc exec -T "${CL}" bash -c '
  curl -sS -w "\nHTTP_CODE=%{http_code}\n" \
    --cert /tmp/svid/svid.0.pem \
    --key  /tmp/svid/svid.0.key \
    --cacert /tmp/svid/bundle.0.pem \
    https://zone-b-gateway:9000/ 2>&1
')"
log "${P1}"
if echo "${P1}" | grep -q "HTTP_CODE=200" && echo "${P1}" | grep -q "zone-lab-spike backend OK"; then
  log "PROOF 1: PASS"
else
  log "PROOF 1: FAIL"; fail=1
fi

log ""
log "############################################################"
log "# PROOF 2: direct client -> backend is unreachable"
log "############################################################"
P2="$(dc exec -T "${CL}" bash -c "curl -sS -v --max-time 5 https://${BACKEND_IP}:9001/ 2>&1 || true")"
log "${P2}"
if echo "${P2}" | grep -qi "Network is unreachable"; then
  log "PROOF 2: PASS"
else
  log "PROOF 2: FAIL (expected 'Network is unreachable')"; fail=1
fi

log ""
log "############################################################"
log "# PROOF 3: Envoy loaded cert + bundle over SDS (admin stats)"
log "############################################################"
log "--- gateway SDS update_success counters ---"
# NOTE: Envoy sanitizes the SDS secret name in stat keys: "://" becomes "_",
# but "/" stays. So the cert stat is sds.spiffe_lab.local/zone-b/gateway.* and
# the bundle stat is sds.spiffe_lab.local.* . The grep must match those.
P3="$(dc exec -T "${GW}" bash -c 'curl -s 127.0.0.1:9901/stats | grep -E "sds\..*update_success|sds\..*update_rejected"')"
log "${P3}"
log "--- gateway secret_state (config_dump names + last_updated) ---"
dc exec -T "${GW}" bash -c 'curl -s 127.0.0.1:9901/config_dump?resource=dynamic_active_secrets 2>/dev/null | grep -E "\"name\"|last_updated" | head -20' || true
gw_cert="$(echo "${P3}" | grep 'zone-b/gateway.update_success' | grep -oE '[0-9]+$' | head -1)"
gw_bundle="$(echo "${P3}" | grep -E 'sds\.spiffe_lab\.local\.update_success' | grep -oE '[0-9]+$' | head -1)"
if [[ "${gw_cert:-0}" -ge 1 && "${gw_bundle:-0}" -ge 1 ]]; then
  log "PROOF 3: PASS (cert update_success=${gw_cert}, bundle update_success=${gw_bundle})"
else
  log "PROOF 3: FAIL (cert=${gw_cert:-0} bundle=${gw_bundle:-0})"; fail=1
fi

log ""
if [ "${fail}" -eq 0 ]; then
  log "ALL PROOFS PASS"
else
  log "SOME PROOFS FAILED"
fi
exit "${fail}"
