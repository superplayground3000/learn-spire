#!/usr/bin/env bash
#
# Starts the serving processes inside the always-up containers:
#   - each backend container runs the Go backend app on 127.0.0.1:8080,
#   - each backend container runs its Envoy on :9001,
#   - each gateway container runs its Envoy on :9000.
#
# The script runs after bootstrap.sh and register.sh. So the agent socket
# exists and the entries are synced. Envoy then gets its SVID and the bundle
# over SDS on start.
#
# The script is idempotent. It starts a process only if that process is not
# already running.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"

WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-30}"

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }

# backend_service | envoy_config
BACKENDS=(
  "zone-b-backend|/etc/envoy/zone-b-backend-envoy.yaml"
  "zone-c-backend|/etc/envoy/zone-c-backend-envoy.yaml"
)

# gateway_service | envoy_config
GATEWAYS=(
  "zone-b-gateway|/etc/envoy/zone-b-gateway-envoy.yaml"
  "zone-c-gateway|/etc/envoy/zone-c-gateway-envoy.yaml"
)

# proc_running returns 0 when a process whose command matches the pattern runs
# in the named container.
proc_running() {
  local service="$1" pattern="$2"
  dc exec -T "${service}" pgrep -f "${pattern}" >/dev/null 2>&1
}

start_backend_app() {
  local service="$1"
  if proc_running "${service}" '/usr/local/bin/backend'; then
    log "  ${service}: backend app already running"
    return 0
  fi
  dc exec -d "${service}" bash -c 'backend >>/var/log/lab/app.log 2>&1'
  log "  ${service}: backend app started"
}

# The zone-a peer runs the same backend binary. It binds 0.0.0.0:8080, so the
# client reaches it over plain HTTP inside zone-a. The call uses no mTLS and no
# gateway (property P10). The peer holds an SVID, but this path does not use it.
start_peer_app() {
  local service="zone-a-peer"
  if proc_running "${service}" '/usr/local/bin/backend'; then
    log "  ${service}: peer app already running"
    return 0
  fi
  dc exec -d "${service}" bash -c \
    'ZONE=zone-a-peer LISTEN_ADDR=0.0.0.0:8080 backend >>/var/log/lab/app.log 2>&1'
  log "  ${service}: peer app started (plain HTTP on 0.0.0.0:8080)"
}

start_envoy() {
  local service="$1" config="$2"
  if proc_running "${service}" 'envoy -c'; then
    log "  ${service}: envoy already running"
    return 0
  fi
  dc exec -d "${service}" bash -c "envoy -c ${config} --log-path /var/log/envoy/envoy.log"
  log "  ${service}: envoy started (${config})"
}

# start_registry_app starts the Go registry on 127.0.0.1:8081. Its Envoy
# sidecar terminates mTLS and forwards to it. The env values set short lease and
# reap times, so the lease tests run quickly.
start_registry_app() {
  local service="zone-registry"
  if proc_running "${service}" '/usr/local/bin/registry'; then
    log "  ${service}: registry app already running"
    return 0
  fi
  dc exec -d "${service}" bash -c 'registry >>/var/log/lab/registry.log 2>&1'
  log "  ${service}: registry app started (plain HTTP on 127.0.0.1:8081)"
}

# start_registrar runs a registrar loop inside a backend container. The loop
# re-fetches the SVID, then renews the lease through the registry Envoy.
start_registrar() {
  local service="$1" zone="$2" svc="$3" ip="$4"
  if proc_running "${service}" '/usr/local/bin/registrar'; then
    log "  ${service}: registrar already running"
    return 0
  fi
  dc exec -d "${service}" bash -c \
    "REGISTRY_ADDR=zone-registry REGISTRY_PORT=9443 ZONE=${zone} SERVICE=${svc} IP=${ip} PORT=9001 INTERVAL=10 \
     registrar >>/var/log/lab/registrar.log 2>&1"
  log "  ${service}: registrar started (${svc}.${zone} -> ${ip})"
}

# wait_for_listener waits until the named container listens on the port.
wait_for_listener() {
  local service="$1" port="$2" i
  for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
    if dc exec -T "${service}" bash -c "ss -tln | grep -q ':${port} '"; then
      log "  ${service}: listening on ${port}"
      return 0
    fi
    sleep 1
  done
  log "  ERROR: ${service} never listened on ${port}"
  return 1
}

main() {
  local row service config

  log "=== Starting the backend apps and the backend Envoys ==="
  for row in "${BACKENDS[@]}"; do
    IFS='|' read -r service config <<<"${row}"
    start_backend_app "${service}"
    start_envoy "${service}" "${config}"
  done

  log "=== Starting the gateway Envoys ==="
  for row in "${GATEWAYS[@]}"; do
    IFS='|' read -r service config <<<"${row}"
    start_envoy "${service}" "${config}"
  done

  log "=== Starting the zone-a peer plain-HTTP server (property P10) ==="
  start_peer_app

  log "=== Starting the registry and its Envoy sidecar ==="
  start_registry_app
  start_envoy "zone-registry" "/etc/envoy/zone-registry-envoy.yaml"

  log "=== Waiting for the listeners ==="
  local fail=0
  wait_for_listener "zone-b-backend" 9001 || fail=1
  wait_for_listener "zone-c-backend" 9001 || fail=1
  wait_for_listener "zone-b-gateway" 9000 || fail=1
  wait_for_listener "zone-c-gateway" 9000 || fail=1
  wait_for_listener "zone-a-peer" 8080 || fail=1
  wait_for_listener "zone-registry" 9443 || fail=1

  if [[ "${fail}" -ne 0 ]]; then
    log "ERROR: one Envoy or more did not open its listener"
    return 1
  fi

  # Give SDS a moment to deliver the secrets to every Envoy.
  sleep 3

  # Start the registrars last. The registry Envoy must listen first, or the
  # first renewal fails and retries on the next interval.
  log "=== Starting the backend registrars (phase 2) ==="
  start_registrar "zone-b-backend" "zone-b" "backend" "10.20.0.50"
  start_registrar "zone-c-backend" "zone-c" "backend" "10.30.0.50"

  # Start the CoreDNS resolvers last of all. The registry app above already
  # rendered the view files to the registry-views volume. A CoreDNS file plugin
  # with a missing file fails to load, so the views must exist first. The "dns"
  # profile keeps these out of the plain "up -d", so this is their only start.
  log "=== Starting the per-zone CoreDNS resolvers (phase 2, part B) ==="
  dc --profile dns up -d coredns-a coredns-b coredns-c >/dev/null 2>&1 \
    && log "  coredns-a, coredns-b, coredns-c started" \
    || log "  ERROR: could not start the CoreDNS resolvers"

  log "All serving processes are up"
}

main "$@"
