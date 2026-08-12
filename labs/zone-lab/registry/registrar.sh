#!/bin/sh
# Registrar: renews this workload's lease with its own SVID.
#
# The registrar runs beside the SPIRE agent. The attestation and the rotation
# are already there, so this loop is small.
#
# Renewal is just re-registration. It takes the identical authorization path.
# There is no lighter "renew" door that skips the identity check.
#
# The loop clears its SVID files first, then re-fetches them. If the identity is
# gone, the fetch writes no files. The next renewal then has no client
# certificate, so it fails. A revoked identity ages out on its own. Revocation
# and liveness share one mechanism.
set -u
REGISTRY_ADDR="${REGISTRY_ADDR:?}"
REGISTRY_PORT="${REGISTRY_PORT:-9443}"
ZONE="${ZONE:?}"
SERVICE="${SERVICE:?}"
IP="${IP:?}"
PORT="${PORT:-9001}"
INTERVAL="${INTERVAL:-10}"
AGENT="${AGENT:-spire-agent}"
SOCK="${SOCK:-/run/spire/agent.sock}"
DIR="${DIR:-/tmp/registrar}"

mkdir -p "$DIR"

while true; do
  # Clear the old SVID first. If the identity has gone away, the fetch writes
  # nothing, so the renewal SHOULD start failing. That is the intended behavior,
  # not an error to hide.
  rm -f "$DIR/svid.0.pem" "$DIR/svid.0.key" "$DIR/bundle.0.pem"
  "$AGENT" api fetch x509 -socketPath "$SOCK" -write "$DIR/" >/dev/null 2>&1 || true

  if [ -f "$DIR/svid.0.pem" ]; then
    # The registry Envoy carries the DNS SAN "zone-registry", so --cacert plus
    # the hostname verify the server. No -k is needed.
    out=$(curl -sS --cert "$DIR/svid.0.pem" --key "$DIR/svid.0.key" --cacert "$DIR/bundle.0.pem" \
        -X POST "https://${REGISTRY_ADDR}:${REGISTRY_PORT}/register" \
        -H 'Content-Type: application/json' \
        -d "{\"zone\":\"${ZONE}\",\"service\":\"${SERVICE}\",\"ip\":\"${IP}\",\"port\":${PORT}}" \
        --max-time 8 2>&1)
    case "$out" in
      *'"accepted":true'*) echo "$(date -u +%H:%M:%S) renewed ${SERVICE}.${ZONE}" ;;
      *)                   echo "$(date -u +%H:%M:%S) RENEWAL FAILED: $(echo "$out" | tr -d '\n' | cut -c1-140)" ;;
    esac
  else
    echo "$(date -u +%H:%M:%S) RENEWAL SKIPPED: no SVID (identity revoked or agent not ready)"
  fi
  sleep "$INTERVAL"
done
