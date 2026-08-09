#!/usr/bin/env bash
#
# This script shows the identity state of the running lab:
#
#   - the attested SPIRE agents
#   - the registration entries, which map a selector to a SPIFFE ID
#   - the X509-SVID of the server workload and of the client workload
#
# For each SVID the script shows the URI SAN, the validity dates, and the
# serial number. The URI SAN holds the SPIFFE ID. It is the field that makes an
# X.509 certificate an X509-SVID.
#
# To read a certificate, the script must first get one. It asks the Workload
# API for the SVID of each workload, under the UID of that workload. The agent
# writes the material inside the node. The script then copies it to tmp/ on the
# host and deletes the copy inside the node. The host has openssl, the node
# image does not.
#
# The export includes the private key of each workload. Section 15 of the
# spec permits this for study. The material stays under tmp/, which git
# ignores. Never commit it. When you are done, delete tmp/svid yourself,
# because "make lab-down" does not delete it.
#
# The script is safe to run repeatedly. It changes no lab state, and each run
# replaces the earlier export.

set -euo pipefail

cd "$(dirname "$0")/.."

AGENT_SOCKET="/run/spire/agent.sock"

# "<uid> <workload>", where the workload name is also the last path segment of
# its SPIFFE ID.
WORKLOADS=(
  "10001 server"
  "10002 client"
)

# The node holds the export only while the script copies it out. The parent
# /var/lib is root-owned, so no other UID can pre-create or swap this path.
# A path under the shared /tmp does not give that guarantee.
NODE_EXPORT_DIR="/var/lib/lab-inspect"

# The host keeps the export under the gitignored tmp/ directory.
HOST_EXPORT_DIR="tmp/svid"

# The agent writes these three files for each SVID.
SVID_CERT="svid.0.pem"
SVID_KEY="svid.0.key"

FETCH_TIMEOUT=10s

log() { printf '%s\n' "$*"; }

heading() {
  log ""
  log "=== $* ==="
}

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  docker compose exec -T spire-server /opt/spire/bin/spire-server "$@"
}

node_root() {
  docker compose exec -T --user 0 node "$@"
}

agent_is_healthy() {
  docker compose exec -T node \
    spire-agent healthcheck -socketPath "${AGENT_SOCKET}" >/dev/null 2>&1
}

require_lab_up() {
  if ! agent_is_healthy || ! spire_server healthcheck >/dev/null 2>&1; then
    log "ERROR: the lab is not running. Run 'make lab-up' first."
    return 1
  fi
}

require_openssl() {
  if ! command -v openssl >/dev/null 2>&1; then
    log "ERROR: this script needs openssl on the host to read the certificates."
    return 1
  fi
}

# clean_node deletes all exported material inside the node. The script calls
# it after a good run and after a failure. If the material remains, the
# function says so. It stays silent when the node itself is gone.
clean_node() {
  node_root rm -rf "${NODE_EXPORT_DIR}" >/dev/null 2>&1 || true
  if node_root test -e "${NODE_EXPORT_DIR}" >/dev/null 2>&1; then
    log "WARNING: cannot delete ${NODE_EXPORT_DIR} inside the node. Delete it yourself."
  fi
}

# export_svid asks the Workload API for the SVID of one workload and copies the
# files to the host. The agent answers with the identity of the calling UID, so
# the UID selects which SVID the script gets.
export_svid() {
  local uid="$1" workload="$2"
  local node_dir="${NODE_EXPORT_DIR}/${workload}"
  local host_dir="${HOST_EXPORT_DIR}/${workload}"

  # Root makes the directory and gives it to the workload UID. Then only that
  # UID can read its own key. If this protection fails, the export must not
  # start.
  if ! node_root bash -c \
    "rm -rf '${node_dir}' && mkdir -p '${node_dir}' && chown ${uid} '${node_dir}' && chmod 0700 '${node_dir}'"; then
    log "ERROR: cannot prepare a protected export directory for ${workload}"
    return 1
  fi

  # "-write ." writes the certificate, the key, and the trust bundle into the
  # working directory. The script discards the normal output, because it
  # prints the certificate fields itself.
  if ! docker compose exec -T --user "${uid}" -w "${node_dir}" node \
    spire-agent api fetch x509 -socketPath "${AGENT_SOCKET}" \
    -timeout "${FETCH_TIMEOUT}" -write . >/dev/null 2>&1; then
    log "ERROR: the Workload API gave no X509-SVID to UID ${uid}"
    return 1
  fi

  rm -rf "${host_dir}"
  mkdir -p "${host_dir}"

  # The copy writes its progress to standard error. The script keeps that
  # text out of the report. If the copy fails, the script shows the text.
  local copy_output="" copy_status=0
  copy_output="$(docker compose cp "node:${node_dir}/." "${host_dir}/" 2>&1)" \
    || copy_status=$?
  if ((copy_status != 0)); then
    log "ERROR: cannot copy the ${workload} SVID out of the node"
    log "${copy_output}"
    return 1
  fi

  # The copy keeps the file modes of the node, but the private key must stay
  # unreadable for other users on the host too. A missing file or a symbolic
  # link means the export was tampered with, so stop.
  local file
  for file in "${SVID_CERT}" "${SVID_KEY}"; do
    if [[ -L "${host_dir}/${file}" || ! -f "${host_dir}/${file}" ]]; then
      log "ERROR: ${host_dir}/${file} is not a regular file"
      return 1
    fi
  done
  chmod 0700 "${host_dir}"
  chmod 0600 "${host_dir}/${SVID_KEY}"
}

# show_svid prints the fields that make the certificate an SVID. openssl prints
# the URI SAN as "URI:spiffe://...".
show_svid() {
  local workload="$1"
  local cert="${HOST_EXPORT_DIR}/${workload}/${SVID_CERT}"

  log "${workload} X509-SVID (${cert})"
  openssl x509 -in "${cert}" -noout \
    -subject -serial -dates -ext subjectAltName \
    | sed 's/^/  /'
}

show_agents() {
  heading "SPIRE agents"
  spire_server agent list
}

show_entries() {
  heading "Registration entries"
  spire_server entry show
}

show_svids() {
  heading "X509-SVIDs"
  log "Each SVID comes from the Workload API. The UID of the caller selects it."

  local workload_line uid workload
  for workload_line in "${WORKLOADS[@]}"; do
    read -r uid workload <<<"${workload_line}"
    log ""
    export_svid "${uid}" "${workload}" || return 1
    show_svid "${workload}" || return 1
  done
}

show_cleanup_note() {
  log ""
  log "The exported certificates, keys and trust bundles are in ${HOST_EXPORT_DIR}/."
  log "git ignores tmp/. Never commit this material."
  log "To delete it, run: rm -rf ${HOST_EXPORT_DIR}"
}

main() {
  require_lab_up || return 1
  require_openssl || return 1

  trap clean_node EXIT

  show_agents
  show_entries
  show_svids || return 1
  show_cleanup_note
}

main "$@"
