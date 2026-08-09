#!/usr/bin/env bash
#
# This script runs the SVID rotation demo of section 24 (Lab 1.5).
#
# The story is short:
#
#   SVID A -> approaches its expiry -> SPIRE provides SVID B
#
# The server workload keeps running through that change. It does not restart.
# It does not reload a certificate file. Nobody redeploys it. The go-spiffe
# X509Source inside the server receives each new SVID from the Workload API.
#
# The demo makes the change fast enough to watch. It shortens the X509-SVID
# lifetime of the server registration entry. The lifetime of one entry is a
# property of that entry, so server.conf stays untouched. The script puts the
# entry back to its first value before it ends, also after a failure.
#
# The script proves three facts:
#
#   1. The serial number and the expiry of the server SVID change.
#   2. The PID of the server process does not change, and the server log gets
#      no second start line.
#   3. A client request succeeds after SVID B is expired. So the server
#      presents a later certificate. An old certificate cannot explain it.
#
# The script exits 1 when one of those facts does not hold. A demo that
# reports a pass without a new serial number teaches nothing.
#
# The script exports only certificates, never a private key. Certificates are
# public. The export goes to tmp/rotation on the host, which git ignores.
#
# The demo needs about two minutes. It changes lab state while it runs, so do
# not run two copies at the same time.

set -euo pipefail

cd "$(dirname "$0")/.."

TRUST_DOMAIN="lab.local"
PARENT_ID="spiffe://${TRUST_DOMAIN}/node"
SERVER_ID="spiffe://${TRUST_DOMAIN}/server"

SERVER_UID=10001
CLIENT_UID=10002
SELECTOR="unix:uid:${SERVER_UID}"

SERVER_LOG="/var/log/lab/server.log"
AGENT_SOCKET="/run/spire/agent.sock"

# The server prints this line one time for each start. A second line in the
# demo window means a restart, and a restart destroys the proof.
START_MESSAGE="server starting"

# The short lifetime for the demo. The agent rotates an X509-SVID at half of
# its lifetime, so a new SVID arrives about 30 seconds after each issue.
#
# A per-entry lifetime has an upper limit of ca_ttl/6, and ca_ttl is 24h in
# server.conf. 60 seconds stays far below that limit.
#
# SPIRE dates each certificate 10 seconds before it issues it. That allowance
# covers a small clock difference between the machines. So the certificate
# shows a lifetime of TTL + 10 seconds.
SHORT_TTL=60
BACKDATE=10

# The agent asks the server for the entries about every 5 seconds. A changed
# entry gets a new SVID at the next sync, so the first change is quick. The
# second change waits for half of the short lifetime.
FIRST_CHANGE_TIMEOUT=90
SECOND_CHANGE_TIMEOUT=90

# The last proof waits for the expiry of SVID B. That moment comes about one
# lifetime after SPIRE issued SVID B.
EXPIRY_TIMEOUT=120

POLL_INTERVAL=5

FETCH_TIMEOUT=10s

# The node holds the export only while the script reads it. The parent
# /var/lib is root-owned, so no other UID can pre-create or swap this path.
NODE_EXPORT_DIR="/var/lib/lab-rotation"

# The host keeps the certificates under the gitignored tmp/ directory.
HOST_EXPORT_DIR="tmp/rotation"

# The agent writes this file name for the certificate chain of the SVID.
SVID_CERT="svid.0.pem"

HOST_CERT="${HOST_EXPORT_DIR}/${SVID_CERT}"

# restore_ttl uses these two values. The trap reads them, so they must exist
# before the script changes anything.
ENTRY_ID=""
ORIGINAL_TTL=0
TTL_CHANGED="no"

log() { printf '%s\n' "$*"; }

# The script reads the certificate inside a command substitution, which keeps
# the standard output. An error message must not disappear there, so it goes to
# the standard error.
log_err() { printf '%s\n' "$*" >&2; }

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

server_running() {
  node_root pgrep -x -u "${SERVER_UID}" server >/dev/null 2>&1
}

require_lab_up() {
  if ! agent_is_healthy || ! spire_server healthcheck >/dev/null 2>&1 \
    || ! server_running; then
    log "ERROR: the lab is not running. Run 'make lab-up' first."
    return 1
  fi
}

require_host_tools() {
  if ! command -v openssl >/dev/null 2>&1; then
    log "ERROR: this script needs openssl on the host to read the certificates."
    return 1
  fi
  # The last proof compares an expiry date with the time now.
  if ! date -d 'Jan 1 00:00:00 2000 GMT' +%s >/dev/null 2>&1; then
    log "ERROR: this script needs GNU date on the host to read the expiry date."
    return 1
  fi
}

# --- The registration entry --------------------------------------------------

# entry_field prints one field of the server entry. The pretty output holds one
# field for each line, in the form "Name : value".
entry_field() {
  local name="$1"
  spire_server entry show \
    -parentID "${PARENT_ID}" \
    -spiffeID "${SERVER_ID}" \
    -selector "${SELECTOR}" \
    | awk -F' *: *' -v want="${name}" '$1 == want { print $2; exit }'
}

# read_entry finds the server entry and keeps its ID and its lifetime. The demo
# must change exactly one entry, so a different count is an error.
#
# The demo writes the entry back with the same fields that register.sh used:
# the parent, the SPIFFE ID, the selector, and the lifetime. If you added other
# fields to this entry by hand, the update removes them.
read_entry() {
  local count
  count="$(spire_server entry show \
    -parentID "${PARENT_ID}" \
    -spiffeID "${SERVER_ID}" \
    -selector "${SELECTOR}" \
    | awk '/^Found [0-9]+ entr/ { print $2 }')"
  if [[ "${count}" != "1" ]]; then
    log "ERROR: expected 1 entry for ${SELECTOR}, found '${count:-unknown}'"
    return 1
  fi

  ENTRY_ID="$(entry_field 'Entry ID')"
  if [[ -z "${ENTRY_ID}" ]]; then
    log "ERROR: cannot read the ID of the server registration entry"
    return 1
  fi

  # The word "default" means that the entry takes default_x509_svid_ttl from
  # server.conf. The CLI writes that state back as the number 0. An empty or
  # strange value means a failed query. The demo must not restore a guess.
  local ttl
  ttl="$(entry_field 'X509-SVID TTL')"
  if [[ "${ttl}" == "default" ]]; then
    ORIGINAL_TTL=0
  elif [[ "${ttl}" =~ ^[0-9]+$ ]]; then
    ORIGINAL_TTL="${ttl}"
  else
    log "ERROR: cannot read the lifetime of the server entry (got '${ttl}')"
    return 1
  fi
}

# set_ttl writes one lifetime into the server entry. "entry update" replaces
# the whole record, so the call repeats the parent, the ID and the selector.
set_ttl() {
  local seconds="$1"
  spire_server entry update \
    -entryID "${ENTRY_ID}" \
    -parentID "${PARENT_ID}" \
    -spiffeID "${SERVER_ID}" \
    -selector "${SELECTOR}" \
    -x509SVIDTTL "${seconds}" >/dev/null
}

# --- The certificate of the server workload ----------------------------------

# fetch_cert asks the Workload API for the SVID of the server workload. The
# agent answers with the identity of the calling UID, so the UID selects the
# SVID. The script copies out the certificate only. The private key stays
# inside the node, and clean_node deletes it.
fetch_cert() {
  if ! node_root bash -c \
    "rm -rf '${NODE_EXPORT_DIR}' && mkdir -p '${NODE_EXPORT_DIR}' \
     && chown ${SERVER_UID} '${NODE_EXPORT_DIR}' && chmod 0700 '${NODE_EXPORT_DIR}'"; then
    log_err "ERROR: cannot prepare a protected export directory inside the node"
    return 1
  fi

  if ! docker compose exec -T --user "${SERVER_UID}" -w "${NODE_EXPORT_DIR}" node \
    spire-agent api fetch x509 -socketPath "${AGENT_SOCKET}" \
    -timeout "${FETCH_TIMEOUT}" -write . >/dev/null 2>&1; then
    log_err "ERROR: the Workload API gave no X509-SVID to UID ${SERVER_UID}"
    return 1
  fi

  mkdir -p "${HOST_EXPORT_DIR}"
  chmod 0700 "${HOST_EXPORT_DIR}"
  rm -f "${HOST_CERT}"

  local copy_output="" copy_status=0
  copy_output="$(docker compose cp \
    "node:${NODE_EXPORT_DIR}/${SVID_CERT}" "${HOST_CERT}" 2>&1)" || copy_status=$?
  if ((copy_status != 0)); then
    log_err "ERROR: cannot copy the server certificate out of the node"
    log_err "${copy_output}"
    return 1
  fi

  # A missing file or a symbolic link means the export was tampered with.
  if [[ -L "${HOST_CERT}" || ! -f "${HOST_CERT}" ]]; then
    log_err "ERROR: ${HOST_CERT} is not a regular file"
    return 1
  fi
}

cert_field() {
  openssl x509 -in "${HOST_CERT}" -noout "$1" | cut -d= -f2-
}

# snapshot prints one line for the SVID that the agent serves now:
#
#   <serial>|<notBefore>|<notAfter>
#
# A malformed or empty field means a broken export, so the function fails
# rather than let an empty serial pass as "different".
snapshot() {
  fetch_cert || return 1
  local serial start end
  serial="$(cert_field -serial)" || return 1
  start="$(cert_field -startdate)" || return 1
  end="$(cert_field -enddate)" || return 1
  if [[ ! "${serial}" =~ ^[0-9A-F]+$ || -z "${start}" || -z "${end}" ]]; then
    log_err "ERROR: the exported certificate did not parse"
    return 1
  fi
  printf '%s|%s|%s\n' "${serial}" "${start}" "${end}"
}

# normalize_serial removes leading zeros, so serials from openssl and from the
# client output compare as numbers.
normalize_serial() {
  sed 's/^0*//' <<<"$1"
}

field() {
  local index="$1" line="$2"
  cut -d'|' -f"${index}" <<<"${line}"
}

serial_of() { field 1 "$1"; }
start_of() { field 2 "$1"; }
end_of() { field 3 "$1"; }

# keep saves the certificate of one snapshot under a name that the reader can
# open later with openssl.
keep() {
  cp "${HOST_CERT}" "${HOST_EXPORT_DIR}/$1.pem"
}

# lifetime_of prints the lifetime of a snapshot in seconds.
lifetime_of() {
  local line="$1"
  echo $(( $(date -d "$(end_of "${line}")" +%s) \
    - $(date -d "$(start_of "${line}")" +%s) ))
}

show_snapshot() {
  local name="$1" line="$2"
  log "  ${name} serial   : $(serial_of "${line}")"
  log "  ${name} notBefore: $(start_of "${line}")"
  log "  ${name} notAfter : $(end_of "${line}")"
  log "  ${name} lifetime : $(lifetime_of "${line}")s"
}

# --- Waiting -----------------------------------------------------------------

# wait_for_new_serial polls the Workload API until it answers with a different
# serial number. It prints the elapsed time, so the reader sees the wait. The
# new snapshot goes to NEW_SNAPSHOT.
wait_for_new_serial() {
  local old_serial="$1" timeout="$2"
  local started elapsed line serial
  started="$(date +%s)"
  NEW_SNAPSHOT=""

  while :; do
    line="$(snapshot)" || return 1
    serial="$(serial_of "${line}")"
    elapsed=$(( $(date +%s) - started ))
    if [[ "${serial}" != "${old_serial}" ]]; then
      log "  t+${elapsed}s  new serial ${serial}"
      NEW_SNAPSHOT="${line}"
      return 0
    fi
    if ((elapsed >= timeout)); then
      log "ERROR: the serial number did not change in ${timeout}s"
      return 1
    fi
    log "  t+${elapsed}s  serial ${serial} (no change yet)"
    sleep "${POLL_INTERVAL}"
  done
}

# wait_until_expired waits for the expiry date of one snapshot to pass. After
# that moment the lab can prove that the server holds a later certificate.
wait_until_expired() {
  local line="$1"
  local end_epoch now
  end_epoch="$(date -d "$(end_of "${line}")" +%s)"

  while :; do
    now="$(date -u +%s)"
    if ((now > end_epoch)); then
      return 0
    fi
    if ((end_epoch - now > EXPIRY_TIMEOUT)); then
      log "ERROR: the expiry is more than ${EXPIRY_TIMEOUT}s away. The lifetime is wrong."
      return 1
    fi
    log "  $((end_epoch - now))s until that certificate expires"
    sleep "${POLL_INTERVAL}"
  done
}

# --- Proof of continuity -----------------------------------------------------

# presented_serial runs the client one time and prints the serial of the
# certificate that the server presented in the handshake. This is direct
# evidence from the TLS connection, not from the Workload API.
presented_serial() {
  local output="" status=0 line serial
  output="$(docker compose exec -T --user "${CLIENT_UID}" node client 2>&1)" \
    || status=$?
  if ((status != 0)); then
    log_err "ERROR: the client stopped with status ${status}"
    log_err "${output}"
    return 1
  fi
  line="$(grep -m1 '^server certificate serial: ' <<<"${output}" || true)"
  serial="$(normalize_serial "${line##* }")"
  if [[ ! "${serial}" =~ ^[0-9A-F]+$ ]]; then
    log_err "ERROR: the client did not report the presented certificate serial"
    log_err "${output}"
    return 1
  fi
  printf '%s\n' "${serial}"
}

server_pid() {
  node_root pgrep -x -u "${SERVER_UID}" server | head -1 | tr -cd '0-9'
}

# log_length counts the lines already in the server log. The demo reads only
# the lines that come after this mark.
log_length() {
  node_root bash -c "wc -l <'${SERVER_LOG}' 2>/dev/null || echo 0" | tr -cd '0-9'
}

new_server_log() {
  local from="$1"
  node_root bash -c "tail -n +$((from + 1)) '${SERVER_LOG}' 2>/dev/null" || true
}

# --- Cleanup -----------------------------------------------------------------

# clean_node deletes the exported material inside the node, including the
# private key that the fetch wrote there.
clean_node() {
  node_root rm -rf "${NODE_EXPORT_DIR}" >/dev/null 2>&1 || true
  if node_root test -e "${NODE_EXPORT_DIR}" >/dev/null 2>&1; then
    log "CAUTION: Delete ${NODE_EXPORT_DIR} inside the node yourself. It can contain a private key."
  fi
}

# restore_ttl puts the first lifetime back into the entry. The demo must leave
# the lab as it found it, also after a failure. TTL_CHANGED becomes "yes"
# before the update starts. A lost connection after a committed update then
# still causes a restore.
restore_ttl() {
  if [[ "${TTL_CHANGED}" != "yes" ]]; then
    return 0
  fi
  if ! set_ttl "${ORIGINAL_TTL}"; then
    log "ERROR: cannot restore the X509-SVID lifetime of the server entry."
    log "Run this command yourself:"
    log "  docker compose exec -T spire-server /opt/spire/bin/spire-server entry update \\"
    log "    -entryID ${ENTRY_ID} -parentID ${PARENT_ID} -spiffeID ${SERVER_ID} \\"
    log "    -selector ${SELECTOR} -x509SVIDTTL ${ORIGINAL_TTL}"
    return 1
  fi
  TTL_CHANGED="no"
  log "The script restored the server-entry lifetime (X509-SVID TTL: ${ORIGINAL_TTL})."
}

# cleanup runs one time: after a good run, after a failure, or after a signal.
# It disarms all traps first, so a second signal cannot re-enter it.
cleanup() {
  local status=$?
  trap '' EXIT INT TERM
  log ""
  if ! restore_ttl && ((status == 0)); then
    status=1
  fi
  clean_node
  exit "${status}"
}

# on_signal turns Ctrl-C or a termination into a nonzero exit. The EXIT trap
# then runs cleanup with that status.
on_signal() {
  trap '' INT TERM
  exit 130
}

# --- The demo ----------------------------------------------------------------

narrate() {
  log "The server workload runs and answers requests. It holds one X509-SVID."
  log "That SVID has a short lifetime. SPIRE replaces it before it expires."
  log ""
  log "  SVID A -> approaches its expiry -> SPIRE provides SVID B"
  log ""
  log "The server does not restart for that change. It reloads no cert.pem."
  log "Nobody restarts the container, and nobody writes a new secret."
  log "The go-spiffe X509Source watches the Workload API and takes the new SVID."
  log ""
  log "To make the change fast, the demo shortens the lifetime of the server"
  log "entry to ${SHORT_TTL} seconds. It restores the first value at the end."
  log ""
}

main() {
  require_lab_up || return 1
  require_host_tools || return 1

  narrate

  read_entry || return 1

  # The demo must restore the entry, also when the operator stops it with
  # Ctrl-C in the middle of a wait.
  trap cleanup EXIT
  trap on_signal INT TERM

  local start_pid log_start
  start_pid="$(server_pid)"
  log_start="$(log_length)"
  if [[ -z "${start_pid}" ]]; then
    log "ERROR: cannot read the PID of the server workload"
    return 1
  fi

  heading "Before the change"
  log "server process PID    : ${start_pid}"
  log "server entry ID       : ${ENTRY_ID}"
  log "server entry TTL      : ${ORIGINAL_TTL} (0 means default_x509_svid_ttl)"
  log ""

  local svid_a
  svid_a="$(snapshot)" || return 1
  keep "svid-a"
  log "SVID A, the identity that the server holds now:"
  show_snapshot "SVID A" "${svid_a}"
  log ""

  # A client run records which certificate the server PRESENTS. The Workload
  # API snapshots show what the agent serves. Only the presented serial proves
  # what the running server really uses.
  local before_serial
  before_serial="$(presented_serial)" || return 1
  log "The server presents the certificate with serial ${before_serial} now."

  heading "Shorten the lifetime of the server entry"
  log "The demo writes -x509SVIDTTL ${SHORT_TTL} into the entry."
  log "server.conf keeps its own default. Only this one entry changes."
  # The mark comes first. If the update commits and the connection then
  # fails, the cleanup still restores the entry.
  TTL_CHANGED="yes"
  set_ttl "${SHORT_TTL}" || return 1
  log "The script updated the entry."
  log ""
  log "The agent syncs the entries about every 5 seconds. The changed entry"
  log "gets a new SVID at the next sync, so SVID B arrives quickly."
  log ""

  local svid_b
  wait_for_new_serial "$(serial_of "${svid_a}")" "${FIRST_CHANGE_TIMEOUT}" || return 1
  svid_b="${NEW_SNAPSHOT}"
  keep "svid-b"
  log ""
  log "SVID B, the first replacement:"
  show_snapshot "SVID B" "${svid_b}"
  log ""
  log "The lifetime is $((SHORT_TTL + BACKDATE))s, not ${SHORT_TTL}s. SPIRE dates each certificate"
  log "${BACKDATE}s before it issues it, because the clocks can differ a little."

  heading "Wait for a rotation that only time causes"
  log "Nothing changes in the lab now. The agent rotates an X509-SVID at half"
  log "of its lifetime, so SVID C must arrive after about $((SHORT_TTL / 2))s."
  log ""

  local svid_c
  wait_for_new_serial "$(serial_of "${svid_b}")" "${SECOND_CHANGE_TIMEOUT}" || return 1
  svid_c="${NEW_SNAPSHOT}"
  keep "svid-c"
  log ""
  log "SVID C, the rotation that time alone caused:"
  show_snapshot "SVID C" "${svid_c}"

  # Three snapshots must show three different certificates.
  if [[ "$(serial_of "${svid_a}")" == "$(serial_of "${svid_c}")" ]]; then
    log "ERROR: SVID C has the serial of SVID A. The agent served an old SVID."
    return 1
  fi

  heading "Proof that the application kept running"

  # A request that succeeds after the expiry of SVID B cannot use SVID B. So
  # the server presents a later certificate, and it took that certificate
  # while it ran.
  log "The demo waits for the expiry of SVID B. A later request cannot use it."
  wait_until_expired "${svid_b}" || return 1
  log "SVID B is expired now."
  log ""

  # The presented serial is the direct evidence. An HTTP 200 alone proves
  # nothing here: SVID A lives for one hour, so the server could still
  # present A while the agent hands out B and C.
  local after_serial
  after_serial="$(presented_serial)" || {
    log "ERROR: no successful request after the rotation"
    return 1
  }
  log "The server now presents the certificate with serial ${after_serial}."
  log ""

  if [[ "${after_serial}" == "${before_serial}" ]]; then
    log "ERROR: the server still presents its first certificate. No rotation happened."
    return 1
  fi
  if [[ "${after_serial}" == "$(normalize_serial "$(serial_of "${svid_a}")")" ]]; then
    log "ERROR: the server still presents SVID A. No rotation happened."
    return 1
  fi

  local end_pid
  end_pid="$(server_pid)"
  if [[ -z "${end_pid}" ]]; then
    log "ERROR: the server workload is gone"
    return 1
  fi
  if [[ "${end_pid}" != "${start_pid}" ]]; then
    log "ERROR: the server PID changed from ${start_pid} to ${end_pid}. It restarted."
    return 1
  fi

  local restart_lines
  restart_lines="$(new_server_log "${log_start}" | grep -c "${START_MESSAGE}" || true)"
  if [[ "${restart_lines}" != "0" ]]; then
    log "ERROR: the server log got ${restart_lines} new '${START_MESSAGE}' line(s). It restarted."
    new_server_log "${log_start}"
    return 1
  fi

  heading "Section 24 report"
  log "SVID A  serial $(serial_of "${svid_a}")  notAfter $(end_of "${svid_a}")"
  log "SVID B  serial $(serial_of "${svid_b}")  notAfter $(end_of "${svid_b}")"
  log "SVID C  serial $(serial_of "${svid_c}")  notAfter $(end_of "${svid_c}")"
  log ""
  log "presented serial before the change: ${before_serial}"
  log "presented serial after the change : ${after_serial}"
  log "server process PID before: ${start_pid}"
  log "server process PID after : ${end_pid} (unchanged)"
  log "new '${START_MESSAGE}' lines in the server log: 0"
  log "client request after the expiry of SVID B: HTTP 200"
  log ""
  log "The server did not restart. It reloaded no cert.pem. Its container kept"
  log "running. It received no new secret. SPIRE replaced the identity while"
  log "the server ran, and the TLS connection proves it."
  log ""
  log "The certificates are in ${HOST_EXPORT_DIR}/. git ignores tmp/."
  log "Run this command to read one:"
  log "  openssl x509 -in ${HOST_EXPORT_DIR}/svid-a.pem -noout -text"
  log "Run this command to delete them:"
  log "  rm -rf ${HOST_EXPORT_DIR}"
  log ""
  log "Rotation demo PASSED. The presented certificate changed. The workload"
  log "continued to run."
}

main "$@"
