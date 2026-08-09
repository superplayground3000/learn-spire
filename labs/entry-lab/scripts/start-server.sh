#!/usr/bin/env bash
#
# This script starts the Go API server on the node, under UID 10001.
#
# The UID decides the identity. The unix workload attestor reports
# unix:uid:10001 to the SPIRE agent. A registration entry maps that selector
# to spiffe://lab.local/server. The agent then issues the matching X509-SVID.
# The binary itself contains no identity and no certificate.
#
# The script is safe to run repeatedly. It does not change a server that
# already runs and answers.

set -euo pipefail

cd "$(dirname "$0")/.."

SERVER_UID=10001
SERVER_BIN="/usr/local/bin/server"
SERVER_LOG="/var/log/lab/server.log"

# The server prints this line after the listener is open.
READY_MESSAGE="mTLS server listening on"

WAIT_ATTEMPTS=30
WAIT_INTERVAL=1

log() { printf '%s\n' "$*"; }

node_root() {
  docker compose exec -T --user 0 node "$@"
}

server_running() {
  node_root pgrep -x -u "${SERVER_UID}" server >/dev/null 2>&1
}

# log_length counts the lines already in the log. A restart must not accept
# the ready line of an earlier run.
log_length() {
  node_root bash -c "wc -l <'${SERVER_LOG}' 2>/dev/null || echo 0" | tr -cd '0-9'
}

# UID 10001 cannot make a file in /var/log/lab, so root makes it and gives it to
# the server. An existing log keeps its content.
prepare_log() {
  node_root bash -c "touch '${SERVER_LOG}' && chown ${SERVER_UID} '${SERVER_LOG}'"
}

# launch_server starts the server in the background inside the node. "exec"
# replaces the shell, so the process name stays "server" and pgrep finds it.
launch_server() {
  docker compose exec --detach --user "${SERVER_UID}" node \
    bash -c "exec ${SERVER_BIN} >>'${SERVER_LOG}' 2>&1"
}

wait_for_ready() {
  local from="$1" i
  for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
    if node_root bash -c "tail -n +$((from + 1)) '${SERVER_LOG}' 2>/dev/null" \
      | grep -q "${READY_MESSAGE}"; then
      return 0
    fi
    # A dead process cannot become ready. Give the process three checks to
    # appear. If it is gone after that, stop early. The caller shows the log.
    if ((i > 3)) && ! server_running; then
      return 1
    fi
    # Do not sleep after the last check.
    ((i < WAIT_ATTEMPTS)) && sleep "${WAIT_INTERVAL}"
  done
  return 1
}

# stop_server ends a server process that failed to become ready. The next run
# then starts from a clean state.
stop_server() {
  node_root pkill -x -u "${SERVER_UID}" server >/dev/null 2>&1 || true
}

main() {
  # A running process alone does not prove readiness. The process may still
  # wait for its SVID, or it may never have opened the port. The server
  # prints the ready line only after the listener is open, so require both.
  if server_running; then
    if wait_for_ready 0; then
      log "Server workload running (already started)"
      return 0
    fi
    log "a server process runs but is not ready, replacing it"
    stop_server
  fi

  prepare_log
  local log_start
  log_start="$(log_length)"

  launch_server

  if ! wait_for_ready "${log_start}"; then
    log "ERROR: the server workload did not become ready in $((WAIT_ATTEMPTS * WAIT_INTERVAL))s"
    node_root tail -n 20 "${SERVER_LOG}" || true
    stop_server
    return 1
  fi

  log "Server workload running"
}

main "$@"
