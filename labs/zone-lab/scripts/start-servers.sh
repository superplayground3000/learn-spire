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

  log "=== Waiting for the listeners ==="
  local fail=0
  wait_for_listener "zone-b-backend" 9001 || fail=1
  wait_for_listener "zone-c-backend" 9001 || fail=1
  wait_for_listener "zone-b-gateway" 9000 || fail=1
  wait_for_listener "zone-c-gateway" 9000 || fail=1
  wait_for_listener "zone-a-peer" 8080 || fail=1

  if [[ "${fail}" -ne 0 ]]; then
    log "ERROR: one Envoy or more did not open its listener"
    return 1
  fi

  # Give SDS a moment to deliver the secrets to every Envoy.
  sleep 3
  log "All serving processes are up"
}

main "$@"
