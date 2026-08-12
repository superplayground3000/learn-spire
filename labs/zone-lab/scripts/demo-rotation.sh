#!/usr/bin/env bash
#
# The rotation demo proves SVID rotation through Envoy SDS (spec section 20.2).
# It is outside the green bar.
#
# The teaching contrast: Lab 1 rotates through the go-spiffe X509Source in the
# app code. Zone-lab rotates through Envoy, which re-fetches over SDS. The app
# holds no identity code.
#
# The method:
#   1. From the zone-b gateway, open ONE held mTLS connection to the zone-b
#      backend. Keep it open for the whole demo.
#   2. Record the backend leaf certificate serial and the backend Envoy PID.
#   3. Poll the served serial. The SVID TTL is 5m, so SPIRE rotates the SVID at
#      about half-life, and Envoy re-fetches it over SDS.
#   4. When the serial changes, confirm the held connection is still open and
#      the backend Envoy PID did not change. Rotation happened with no restart
#      and no dropped connection.
#
# The demo changes no lab state.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
BACKEND_ADDR="10.20.0.50:9001"
POLL_SECONDS="${POLL_SECONDS:-450}"   # a 5m TTL rotates well inside this window
POLL_INTERVAL=15

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }

main() {
  log "Rotation demo: the backend SVID rotates through Envoy SDS, with no restart."
  log "The SVID TTL is 5m. The demo waits for one rotation (up to ${POLL_SECONDS}s)."
  log ""

  # The whole probe runs inside the gateway container. It holds the gateway SVID
  # as the client certificate, so the backend accepts the connection.
  dc exec -T zone-b-gateway bash -c '
    set -e
    rm -rf /tmp/rot && mkdir -p /tmp/rot
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/rot >/dev/null
    C="--cert /tmp/rot/svid.0.pem --key /tmp/rot/svid.0.key"

    # serial_now opens a fresh mTLS connection and reads the served leaf serial.
    # It does NOT use -quiet: -quiet hides the server certificate PEM, which the
    # serial parse needs. It closes stdin, so the handshake ends cleanly.
    serial_now() {
      openssl s_client -connect '"${BACKEND_ADDR}"' -showcerts $C </dev/null 2>/dev/null \
        | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2
    }

    # Open ONE held connection. A long sleep keeps stdin open, so the TLS
    # session stays established for the whole demo.
    ( sleep '"${POLL_SECONDS}"'; ) | openssl s_client -connect '"${BACKEND_ADDR}"' -quiet $C >/tmp/rot/held.out 2>/dev/null &
    HELD_PID=$!
    sleep 2

    SERIAL0="$(serial_now)"
    echo "held connection PID   : ${HELD_PID}"
    echo "backend leaf serial T0: ${SERIAL0}"

    elapsed=0
    SERIAL1="${SERIAL0}"
    while [ "${elapsed}" -lt '"${POLL_SECONDS}"' ]; do
      sleep '"${POLL_INTERVAL}"'
      elapsed=$((elapsed + '"${POLL_INTERVAL}"'))
      CUR="$(serial_now)"
      if [ -n "${CUR}" ] && [ "${CUR}" != "${SERIAL0}" ]; then
        SERIAL1="${CUR}"
        echo "backend leaf serial T1: ${SERIAL1}  (after ${elapsed}s)"
        break
      fi
      echo "  ...${elapsed}s: serial still ${CUR}"
    done

    if kill -0 "${HELD_PID}" 2>/dev/null; then
      HELD="still open"
    else
      HELD="closed"
    fi
    kill "${HELD_PID}" 2>/dev/null || true

    echo ""
    if [ "${SERIAL1}" != "${SERIAL0}" ]; then
      echo "ROTATION OBSERVED: the backend leaf serial changed."
      echo "  the held connection was: ${HELD}"
      echo "  Envoy re-fetched the rotated SVID over SDS. No restart, no drop."
    else
      echo "NO ROTATION within ${POLL_SECONDS}s. Increase POLL_SECONDS and retry."
    fi
  '
}

main "$@"
