#!/usr/bin/env bash
#
# A registration walk-through (phase 2, part A). It shows the registry path:
#   1. a backend registers its own service and the registry accepts it,
#   2. the registry lists the record on GET /registry,
#   3. a cross-zone registration is refused (P15),
#   4. a wrong-service registration is refused (P16).
#
# The registry reads the caller identity ONLY from the XFCC header its Envoy
# sidecar sets. The request body states intent; the registry never trusts it.
#
# Run "make lab-up" first. This demo asserts nothing; it illustrates the path.

set -uo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
dc() { ${COMPOSE} "$@"; }
log() { printf '%s\n' "$*"; }

# post sends one register request from a container, with that container's SVID.
post() {
  local from="$1" zone="$2" svc="$3"
  dc exec -T "${from}" bash -c '
    rm -rf /tmp/dreg && mkdir -p /tmp/dreg
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/dreg >/dev/null 2>&1
    curl -sS --cert /tmp/dreg/svid.0.pem --key /tmp/dreg/svid.0.key --cacert /tmp/dreg/bundle.0.pem \
      -X POST https://zone-registry:9443/register -H "Content-Type: application/json" \
      -d "{\"zone\":\"'"${zone}"'\",\"service\":\"'"${svc}"'\",\"ip\":\"10.20.0.50\",\"port\":9001}" \
      --max-time 8 2>&1 || true
  ' 2>&1 || true
}

show_registry() {
  dc exec -T zone-c-backend bash -c '
    rm -rf /tmp/dget && mkdir -p /tmp/dget
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/dget >/dev/null 2>&1
    curl -sS --cert /tmp/dget/svid.0.pem --key /tmp/dget/svid.0.key --cacert /tmp/dget/bundle.0.pem \
      https://zone-registry:9443/registry --max-time 8 2>&1 || true
  ' 2>&1 || true
}

log "=== 1. zone-b/backend registers its own service (accepted) ==="
log "$(post zone-b-backend zone-b backend)"

log ""
log "=== 2. GET /registry lists the record ==="
log "$(show_registry)"

log ""
log "=== 3. zone-b/backend tries to register into zone-c (P15: refused) ==="
log "$(post zone-b-backend zone-c backend)"

log ""
log "=== 4. zone-b/backend tries to register service 'payments' (P16: refused) ==="
log "$(post zone-b-backend zone-b payments)"

log ""
log "=== Registry decisions (server-side evidence) ==="
dc exec -T zone-registry tail -n 8 /var/log/lab/registry.log 2>/dev/null || true

log ""
log "=== The rendered zone-a view (written to the shared views volume) ==="
dc exec -T zone-registry cat /views/zone-a.zone 2>/dev/null || true
