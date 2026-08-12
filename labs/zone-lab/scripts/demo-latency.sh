#!/usr/bin/env bash
#
# The latency demo measures the gateway-hop overhead (spec section 20.1). It is
# a teaching number. It is NOT part of the green bar.
#
# It compares two paths over a few hundred requests:
#   baseline      : inside the zone-b backend, curl to the plain app on
#                   127.0.0.1:8080. No Envoy, no mTLS.
#   through-gateway: the zone-a client, through the zone-b gateway and the zone-b
#                   backend Envoy, with mTLS on both hops.
#
# The demo prints p50 and p99 for each path, and the delta. The delta is the
# cost of the two-Envoy mTLS gateway path.
#
# The demo changes no lab state.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
N="${N:-300}"
GATEWAY_URL="https://zone-b-gateway:9000/"

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }

# percentile reads whitespace-separated milliseconds on stdin and prints the
# p50 and p99, plus the count. It sorts, then indexes.
percentiles() {
  sort -n | awk '
    { a[NR] = $1 }
    END {
      n = NR
      if (n == 0) { print "no samples"; exit }
      p50 = a[int((n * 50 + 99) / 100)]
      p99 = a[int((n * 99 + 99) / 100)]
      printf "count=%d  p50=%.1fms  p99=%.1fms  min=%.1fms  max=%.1fms\n", n, p50, p99, a[1], a[n]
    }'
}

# collect_baseline loops curl to the plain app inside the backend container.
collect_baseline() {
  dc exec -T zone-b-backend bash -c '
    for i in $(seq 1 '"${N}"'); do
      t=$(curl -s -o /dev/null -w "%{time_total}" http://127.0.0.1:8080/ 2>/dev/null || echo 0)
      awk -v t="$t" "BEGIN{printf \"%.3f\n\", t*1000}"
    done
  '
}

# collect_gateway loops curl through the gateway from a single client container.
# It fetches the SVID once, so the numbers measure the request path, not the
# container start or the SVID fetch.
collect_gateway() {
  dc --progress quiet run --rm -T zone-a-client bash -c '
    set -e
    rm -rf /tmp/svid && mkdir -p /tmp/svid
    spire-agent api fetch x509 -socketPath /run/spire/agent.sock -write /tmp/svid >/dev/null
    for i in $(seq 1 '"${N}"'); do
      t=$(curl -s -o /dev/null -w "%{time_total}" \
        --cert /tmp/svid/svid.0.pem --key /tmp/svid/svid.0.key --cacert /tmp/svid/bundle.0.pem \
        "'"${GATEWAY_URL}"'" 2>/dev/null || echo 0)
      awk -v t="$t" "BEGIN{printf \"%.3f\n\", t*1000}"
    done
  '
}

main() {
  log "Latency demo: the gateway-hop overhead over ${N} requests (teaching number)."
  log ""
  log "Measuring the baseline (plain app on loopback, no Envoy, no mTLS)..."
  local base gw
  base="$(collect_baseline | percentiles)"
  log "  baseline       : ${base}"

  log "Measuring the through-gateway path (client -> gateway -> backend, mTLS)..."
  gw="$(collect_gateway | percentiles)"
  log "  through-gateway: ${gw}"
  log ""
  log "The delta between the two p50/p99 values is the mTLS gateway-path cost."
  log "This is a teaching number. It is not part of the green bar."
}

main "$@"
