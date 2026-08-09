#!/usr/bin/env bash
#
# This script shows the identity state of the running lab:
#
#   - the attested SPIRE agents
#   - the registration entries, which map a container label to a SPIFFE ID
#   - the X509-SVID of the server workload and of the client workload
#
# For each SVID the script shows the subject, the serial number, the validity
# dates, and the URI SAN. The URI SAN holds the SPIFFE ID. It is the field that
# makes an X.509 certificate an X509-SVID.
#
# To read a certificate, the script must first get one. It asks the Workload
# API from inside a labeled container, because the label decides the identity.
# The server SVID comes from the running server container. The client SVID
# comes from a new client container, which the script deletes after the copy.
#
# The workload mounts /run/spire read-only, so the agent CLI writes the
# material to /tmp inside the container. The script then copies it to tmp/ on
# the host and deletes the copy inside the container. The host has openssl, the
# workload image does not.
#
# The export includes the private key of each workload. Section 15 of the spec
# permits this for study. The material stays under tmp/, which git ignores.
# Never commit it. When you are done, delete tmp/svid yourself, because
# "make lab-down" does not delete it.
#
# You can run this script repeatedly. The script changes no lab state, and each
# run replaces the earlier export.

set -euo pipefail

cd "$(dirname "$0")/.."

# The Makefile and the other scripts accept the same override, so all tools
# address one project.
COMPOSE="${COMPOSE:-docker compose}"

# "docker compose cp" addresses a service. It does not find a one-off run
# container, so the client step uses the docker CLI directly.
DOCKER="${DOCKER:-docker}"

SERVER_SERVICE="server"
CLIENT_SERVICE="client"

# The name of the one-off client container. The script creates it, copies from
# it, and deletes it again.
CLIENT_CONTAINER="spire-docker-lab-inspect-client"

AGENT_SOCKET="/run/spire/agent.sock"

# The workload writes the export here. The mount /run/spire is read-only, and
# /tmp is writable for the workload user. Each container has its own file
# system, so no other workload reads this path.
CONTAINER_EXPORT_DIR="/tmp/lab-inspect"

# The host keeps the export under the gitignored tmp/ directory.
HOST_EXPORT_DIR="tmp/svid"

# The agent CLI writes these three files for each SVID.
SVID_CERT="svid.0.pem"
SVID_KEY="svid.0.key"
SVID_BUNDLE="bundle.0.pem"

FETCH_TIMEOUT=10s

log() { printf '%s\n' "$*"; }

heading() {
  log ""
  log "=== $* ==="
}

# The server image is scratch-based, so every CLI call names the binary.
spire_server() {
  ${COMPOSE} exec -T spire-server /opt/spire/bin/spire-server "$@"
}

agent_is_healthy() {
  ${COMPOSE} exec -T spire-agent \
    spire-agent healthcheck -socketPath "${AGENT_SOCKET}" >/dev/null 2>&1
}

server_running() {
  ${COMPOSE} ps --status running --services 2>/dev/null \
    | grep -x "${SERVER_SERVICE}" >/dev/null
}

require_lab_up() {
  if ! agent_is_healthy || ! spire_server healthcheck >/dev/null 2>&1 \
    || ! server_running; then
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

# fetch_command prints the shell command that exports one SVID inside a
# container. "rm -rf" first makes a symbolic link attack on the path useless.
# Mode 0700 keeps the private key readable for the workload user alone.
# "-write ." writes the certificate, the key and the trust bundle into the
# working directory.
fetch_command() {
  printf '%s' "rm -rf '${CONTAINER_EXPORT_DIR}' \
&& mkdir '${CONTAINER_EXPORT_DIR}' \
&& chmod 0700 '${CONTAINER_EXPORT_DIR}' \
&& cd '${CONTAINER_EXPORT_DIR}' \
&& exec spire-agent api fetch x509 -socketPath '${AGENT_SOCKET}' \
-timeout '${FETCH_TIMEOUT}' -write ."
}

# clean_server deletes the export inside the running server container. The
# script calls it after a good run and after a failure. If the material
# remains, the function reports an error and fails.
clean_server() {
  ${COMPOSE} exec -T "${SERVER_SERVICE}" rm -rf "${CONTAINER_EXPORT_DIR}" \
    >/dev/null 2>&1 || true
  if ${COMPOSE} exec -T "${SERVER_SERVICE}" test -e "${CONTAINER_EXPORT_DIR}" \
    >/dev/null 2>&1; then
    log "ERROR: cannot delete ${CONTAINER_EXPORT_DIR} in the ${SERVER_SERVICE} container."
    log "ERROR: delete it yourself."
    return 1
  fi
}

# client_container_exists reports whether the one-off client container is
# present. A stopped container also counts.
client_container_exists() {
  ${DOCKER} inspect "${CLIENT_CONTAINER}" >/dev/null 2>&1
}

# container_label prints one label of the one-off client container. It prints
# nothing when the container or the label is absent.
container_label() {
  ${DOCKER} inspect --format "{{index .Config.Labels \"$1\"}}" \
    "${CLIENT_CONTAINER}" 2>/dev/null || true
}

# compose_project prints the compose project name of this lab. It reads the
# project label of the spire-server container.
compose_project() {
  local id
  id="$(${COMPOSE} ps -a -q spire-server 2>/dev/null | head -n 1)"
  [[ -n "${id}" ]] || return 1
  ${DOCKER} inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' \
    "${id}" 2>/dev/null
}

# clean_client deletes the one-off client container. The script deletes only a
# container that compose made for the client service of this project. A
# different container with the same name belongs to somebody else, so the
# script keeps it and fails.
clean_client() {
  client_container_exists || return 0

  if [[ "$(container_label com.docker.compose.oneoff)" != "True" \
    || "$(container_label com.docker.compose.service)" != "${CLIENT_SERVICE}" \
    || "$(container_label com.docker.compose.project)" != "$(compose_project)" ]]; then
    log "ERROR: the container ${CLIENT_CONTAINER} is not from this lab."
    log "ERROR: the script keeps it. Delete it yourself, then run this script again."
    return 1
  fi

  ${DOCKER} rm -f "${CLIENT_CONTAINER}" >/dev/null 2>&1 || true
  if client_container_exists; then
    log "ERROR: cannot delete the container ${CLIENT_CONTAINER}. Delete it yourself."
    return 1
  fi
}

# clean_all is the exit trap. It cleans with best effort. The export
# functions call the same cleanups inline, and there the result counts.
clean_all() {
  clean_server || true
  clean_client || true
}

# ensure_real_dir requires a real directory at the given path. A symbolic
# link there can redirect a later delete or copy, so it is an error. The
# function creates a missing directory.
ensure_real_dir() {
  local dir="$1"
  if [[ -L "${dir}" ]]; then
    log "ERROR: ${dir} is a symbolic link. Delete it, then run this script again."
    return 1
  fi
  if [[ -e "${dir}" && ! -d "${dir}" ]]; then
    log "ERROR: ${dir} is not a directory"
    return 1
  fi
  mkdir -p "${dir}" || return 1
}

# prepare_host_dir makes an empty export directory for one workload on the
# host. Each run replaces the material of the earlier run. The function
# checks every parent first, so a planted symbolic link cannot redirect the
# delete or the copy.
prepare_host_dir() {
  local workload="$1"
  local host_dir="${HOST_EXPORT_DIR}/${workload}"

  ensure_real_dir "tmp" || return 1
  ensure_real_dir "${HOST_EXPORT_DIR}" || return 1
  if [[ -L "${host_dir}" ]]; then
    log "ERROR: ${host_dir} is a symbolic link. Delete it, then run this script again."
    return 1
  fi

  rm -rf "${host_dir}" || return 1
  mkdir "${host_dir}" || return 1
  chmod 0700 "${host_dir}" || return 1
}

# harden_host_dir checks the copied files and sets their modes. A missing
# file or a symbolic link shows tampering, so the function stops the export.
# The private key must stay unreadable for the other users of the host. The
# final check reads the mode back, because a silent chmod failure must not
# pass.
harden_host_dir() {
  local workload="$1"
  local host_dir="${HOST_EXPORT_DIR}/${workload}"
  local file

  for file in "${SVID_CERT}" "${SVID_KEY}" "${SVID_BUNDLE}"; do
    if [[ -L "${host_dir}/${file}" || ! -f "${host_dir}/${file}" ]]; then
      log "ERROR: ${host_dir}/${file} is not a regular file"
      return 1
    fi
  done

  chmod 0600 "${host_dir}/${SVID_KEY}" || return 1
  chmod 0644 "${host_dir}/${SVID_CERT}" "${host_dir}/${SVID_BUNDLE}" || return 1

  if [[ "$(stat -c '%a' "${host_dir}/${SVID_KEY}")" != "600" ]]; then
    log "ERROR: the mode of ${host_dir}/${SVID_KEY} is not 0600"
    return 1
  fi
}

# export_server gets the SVID of the running server container. The exec runs in
# the container of the server workload, so the agent answers with the server
# identity. A new container has the same label, but the running one proves that
# the server itself holds this SVID.
export_server() {
  local host_dir="${HOST_EXPORT_DIR}/${SERVER_SERVICE}"

  local fetch_output="" fetch_status=0
  fetch_output="$(${COMPOSE} exec -T "${SERVER_SERVICE}" \
    sh -c "$(fetch_command)" 2>&1)" || fetch_status=$?
  if ((fetch_status != 0)); then
    log "ERROR: the Workload API gave no X509-SVID to the ${SERVER_SERVICE} container"
    log "${fetch_output}"
    return 1
  fi

  prepare_host_dir "${SERVER_SERVICE}" || return 1

  # The copy writes its progress to standard error. The script keeps that text
  # out of the report. If the copy fails, the script shows the text.
  local copy_output="" copy_status=0
  copy_output="$(${COMPOSE} cp \
    "${SERVER_SERVICE}:${CONTAINER_EXPORT_DIR}/." "${host_dir}/" 2>&1)" \
    || copy_status=$?
  if ((copy_status != 0)); then
    log "ERROR: cannot copy the ${SERVER_SERVICE} SVID out of the container"
    log "${copy_output}"
    return 1
  fi

  clean_server || return 1
  harden_host_dir "${SERVER_SERVICE}"
}

# export_client gets the SVID of the client workload. No client container runs,
# so the script starts one. "run --rm" deletes the files with the container, so
# this run keeps the container until the copy ends.
export_client() {
  local host_dir="${HOST_EXPORT_DIR}/${CLIENT_SERVICE}"

  clean_client || return 1
  if client_container_exists; then
    log "ERROR: the container ${CLIENT_CONTAINER} is still present"
    return 1
  fi

  local fetch_output="" fetch_status=0
  fetch_output="$(${COMPOSE} --progress quiet run -T \
    --name "${CLIENT_CONTAINER}" "${CLIENT_SERVICE}" \
    sh -c "$(fetch_command)" 2>&1)" || fetch_status=$?
  if ((fetch_status != 0)); then
    log "ERROR: the Workload API gave no X509-SVID to the ${CLIENT_SERVICE} container"
    log "${fetch_output}"
    return 1
  fi

  prepare_host_dir "${CLIENT_SERVICE}" || return 1

  local copy_output="" copy_status=0
  copy_output="$(${DOCKER} cp \
    "${CLIENT_CONTAINER}:${CONTAINER_EXPORT_DIR}/." "${host_dir}/" 2>&1)" \
    || copy_status=$?
  if ((copy_status != 0)); then
    log "ERROR: cannot copy the ${CLIENT_SERVICE} SVID out of the container"
    log "${copy_output}"
    return 1
  fi

  clean_client || return 1
  harden_host_dir "${CLIENT_SERVICE}"
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

# show_bundle prints the certificate of the trust domain. Both workloads get
# the same bundle, so the script shows it once. The bundle carries no URI SAN,
# because it identifies a certificate authority and not a workload.
show_bundle() {
  local bundle="${HOST_EXPORT_DIR}/${SERVER_SERVICE}/${SVID_BUNDLE}"

  heading "Trust bundle"
  log "Each workload gets this bundle with its SVID. It verifies the other side."
  log ""
  log "trust bundle (${bundle})"
  openssl x509 -in "${bundle}" -noout -subject -serial -dates | sed 's/^/  /'
}

show_agents() {
  heading "SPIRE agents"
  spire_server agent list
}

show_entries() {
  heading "Registration entries"
  log "Each entry maps one container label to one SPIFFE ID."
  log ""
  spire_server entry show
}

show_svids() {
  heading "X509-SVIDs"
  log "Each SVID comes from the Workload API. The container label selects it."

  log ""
  export_server || return 1
  show_svid "${SERVER_SERVICE}" || return 1

  log ""
  export_client || return 1
  show_svid "${CLIENT_SERVICE}" || return 1
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

  trap clean_all EXIT

  show_agents
  show_entries
  show_svids || return 1
  show_bundle || return 1
  show_cleanup_note
}

main "$@"
