#!/usr/bin/env bash
#
# The inspect command shows the running lab identity state (spec section 23):
#   1. the attested agents      (spire-server agent list)
#   2. the registration entries (spire-server entry show)
#   3. the workload SVIDs        (a fetch, exported to gitignored tmp/svid/)
#   4. the Envoy secrets         (each admin :9901 SDS stats)
#
# The command exports a temporary SVID for each always-up workload. It writes
# the files under tmp/svid/, which .gitignore excludes. It sets the key mode to
# 0600. It never commits a private key.
#
# The command changes no lab state. Run it repeatedly.

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"

SVID_DIR="tmp/svid"
AGENT_SOCKET="/run/spire/agent.sock"

# The always-up workloads. The one-shot client and intruder are not listed;
# they exist only during a demo run.
WORKLOADS=(zone-b-gateway zone-b-backend zone-c-gateway zone-c-backend zone-a-peer)

# The four Envoys expose the SDS stats on the admin listener.
ENVOYS=(zone-b-gateway zone-b-backend zone-c-gateway zone-c-backend)

log() { printf '%s\n' "$*"; }
dc() { ${COMPOSE} "$@"; }
spire_server() { dc exec -T spire-server /opt/spire/bin/spire-server "$@"; }

section() {
  log ""
  log "=============================================================="
  log "$*"
  log "=============================================================="
}

show_agents() {
  section "1. Attested agents (spire-server agent list)"
  spire_server agent list || log "  (agent list failed)"
}

show_entries() {
  section "2. Registration entries (spire-server entry show)"
  spire_server entry show || log "  (entry show failed)"
}

# export_svids fetches one SVID per workload and shows the host openssl detail.
# Trap 1 note: the SDS stat key sanitizes the SPIFFE ID; here we read the raw
# certificate, so the SPIFFE ID appears in full in the URI SAN.
export_svids() {
  section "3. Workload SVIDs (exported to ${SVID_DIR}/, keys are 0600)"
  rm -rf "${SVID_DIR}" && mkdir -p "${SVID_DIR}"

  local w dest
  for w in "${WORKLOADS[@]}"; do
    dest="${SVID_DIR}/${w}"
    mkdir -p "${dest}"
    if ! dc exec -T "${w}" bash -c '
      set -e
      rm -rf /tmp/inspect-svid && mkdir -p /tmp/inspect-svid
      spire-agent api fetch x509 -socketPath '"${AGENT_SOCKET}"' -write /tmp/inspect-svid >/dev/null 2>&1
    '; then
      log ""
      log "  ${w}: no SVID (fetch failed)"
      continue
    fi
    dc cp "${w}:/tmp/inspect-svid/svid.0.pem"   "${dest}/svid.0.pem"   >/dev/null
    dc cp "${w}:/tmp/inspect-svid/svid.0.key"   "${dest}/svid.0.key"   >/dev/null
    dc cp "${w}:/tmp/inspect-svid/bundle.0.pem" "${dest}/bundle.0.pem" >/dev/null
    dc exec -T "${w}" rm -rf /tmp/inspect-svid 2>/dev/null || true
    chmod 0600 "${dest}/svid.0.key"

    log ""
    log "  ${w}:"
    log "    URI SAN : $(openssl x509 -in "${dest}/svid.0.pem" -noout -ext subjectAltName 2>/dev/null | grep -o 'URI:[^,]*' | head -n1)"
    log "    subject : $(openssl x509 -in "${dest}/svid.0.pem" -noout -subject 2>/dev/null | sed 's/subject=//')"
    log "    serial  : $(openssl x509 -in "${dest}/svid.0.pem" -noout -serial 2>/dev/null | sed 's/serial=//')"
    log "    expires : $(openssl x509 -in "${dest}/svid.0.pem" -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
  done
}

show_envoy_secrets() {
  section "4. Envoy secrets (each admin :9901 SDS stats)"
  local e stats
  for e in "${ENVOYS[@]}"; do
    log ""
    log "  ${e}:"
    stats="$(dc exec -T "${e}" curl -s 'http://127.0.0.1:9901/stats?filter=sds' 2>/dev/null || true)"
    if [[ -z "${stats}" ]]; then
      log "    (no SDS stats; is Envoy running?)"
      continue
    fi
    # Show the update_success lines. The key sanitizes "://" to "_" (Trap 1).
    grep 'update_success' <<<"${stats}" | sed 's/^/    /' || log "    (no update_success counters)"
  done
}

main() {
  if ! spire_server healthcheck >/dev/null 2>&1; then
    log "ERROR: the SPIRE server is not answering. Run 'make lab-up' first."
    return 1
  fi
  show_agents
  show_entries
  export_svids
  show_envoy_secrets
  log ""
  log "Inspect done. The exported SVIDs live under ${SVID_DIR}/ (gitignored)."
}

main "$@"
