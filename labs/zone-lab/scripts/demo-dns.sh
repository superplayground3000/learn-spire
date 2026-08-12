#!/usr/bin/env bash
#
# A DNS resolution walk-through (phase 2, part B). It shows the DNS steering:
#   1. a zone resolves its own service to the real address (P12),
#   2. an authorized peer resolves the cross-zone name to the GATEWAY, never the
#      real backend (P13),
#   3. an unauthorized zone gets NXDOMAIN, not SERVFAIL (P14),
#   4. a client that ignores DNS and hardcodes the real address is still stopped
#      by the phase-1 network layer (P19, the punchline).
#
# DNS is steering, not enforcement. The CoreDNS resolvers only read the views the
# registry renders. The phase-1 network and identity layers enforce.
#
# Run "make lab-up" first. This demo asserts nothing; it illustrates the path.

set -uo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
dc() { ${COMPOSE} "$@"; }
log() { printf '%s\n' "$*"; }

COREDNS_A_IP="10.10.0.53"
COREDNS_B_IP="10.20.0.53"
COREDNS_C_IP="10.30.0.53"
NAME_B="backend.zone-b.internal."
NAME_C="backend.zone-c.internal."
BACKEND_B_IP="10.20.0.50"
BACKEND_C_IP="10.30.0.50"
B_GATEWAY_IN_A="10.10.0.40"

# dig_from runs dig inside a zone container against that zone's resolver.
dig_from() {
  local from="$1" server="$2" name="$3"
  dc exec -T "${from}" dig @"${server}" "${name}" +time=3 +tries=2 2>/dev/null || true
}

log "=== 1. P12: zone-b asks its own resolver for its own service ==="
log "    zone-b-backend -> ${COREDNS_B_IP} : ${NAME_B} (expect the real ${BACKEND_B_IP})"
dig_from zone-b-backend "${COREDNS_B_IP}" "${NAME_B}" | grep -E 'status:|IN[[:space:]]+A' || true

log ""
log "=== 2. P13: zone-a (authorized to reach zone-b) asks for the zone-b backend ==="
log "    zone-a-peer -> ${COREDNS_A_IP} : ${NAME_B}"
log "    expect the GATEWAY ${B_GATEWAY_IN_A}, NEVER the real backend ${BACKEND_B_IP}"
dig_from zone-a-peer "${COREDNS_A_IP}" "${NAME_B}" | grep -E 'status:|IN[[:space:]]+A' || true

log ""
log "=== 3. P14: zone-a asks for a zone-c name it is NOT authorized to reach ==="
log "    zone-a-peer -> ${COREDNS_A_IP} : ${NAME_C} (expect NXDOMAIN, not SERVFAIL)"
dig_from zone-a-peer "${COREDNS_A_IP}" "${NAME_C}" | grep -E 'status:' || true
log "    liveness control: the same resolver still answers a valid name"
dig_from zone-a-peer "${COREDNS_A_IP}" "${NAME_B}" | grep -E 'status:' || true

log ""
log "=== 4. P19: a client ignores DNS and hardcodes the real zone-c backend ==="
log "    zone-a-client -> ${BACKEND_C_IP}:9001 (expect 'Network is unreachable')"
dc --progress quiet run --rm -T zone-a-client nc -w 4 -v "${BACKEND_C_IP}" 9001 2>&1 || true
log "    DNS steered the client away (NXDOMAIN above). The network layer stops it"
log "    even when the client ignores DNS. DNS is steering, not enforcement."
