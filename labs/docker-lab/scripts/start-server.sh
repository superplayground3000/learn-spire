#!/usr/bin/env bash
#
# This script starts the Go API server as its own container.
#
# The container label decides the identity. The docker workload attestor
# reports docker:label:spiffe.lab/workload:server to the SPIRE agent. A
# registration entry maps that selector to spiffe://lab.local/server. The agent
# then issues the matching X509-SVID. The binary itself contains no identity
# and no certificate.
#
# In lab 1 a start script had to launch a process under a chosen UID. Here
# compose starts the container, and the binary runs as PID 1 in it.
#
# The service sits in the "workloads" profile. A named service enables its own
# profile, so this script needs no profile flag.
#
# You can run this script repeatedly. The script does not change a server that
# already runs and answers.

set -euo pipefail

cd "$(dirname "$0")/.."

# The Makefile and the other scripts accept the same override, so all tools
# address one project.
COMPOSE="${COMPOSE:-docker compose}"

SERVICE="server"

# The server prints this line after the listener is open.
READY_MESSAGE="mTLS server listening on"

# On a slow machine, set this environment variable to a larger number.
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-30}"
WAIT_INTERVAL=1

log() { printf '%s\n' "$*"; }

service_running() {
  ${COMPOSE} ps --status running --services 2>/dev/null \
    | grep -x "${SERVICE}" >/dev/null
}

# container_id prints the ID of the service container. It prints nothing when
# no container exists. The "-a" flag also reports a stopped container.
container_id() {
  ${COMPOSE} ps -a -q "${SERVICE}" 2>/dev/null | head -n 1
}

# container_started_at prints the start time of the current container process.
# A restart gives the container a new start time and keeps its old log. The
# time stamp separates the lines of the current process from older lines.
container_started_at() {
  local id
  id="$(container_id)"
  [[ -n "${id}" ]] || return 1
  docker inspect --format '{{.State.StartedAt}}' "${id}"
}

# read_log_since prints the log lines of the current process only. A failed
# read is a real error. The caller must not treat it as an empty log.
read_log_since() {
  ${COMPOSE} logs --no-log-prefix --since "$1" "${SERVICE}"
}

# wait_for_ready returns 0 when the current process printed the ready line.
# It returns 1 on a timeout or a dead container. It returns 2 when the log
# is not readable, so the caller can stop without a destructive step.
wait_for_ready() {
  local since="$1" i lines
  for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
    if ! lines="$(read_log_since "${since}" 2>&1)"; then
      log "ERROR: cannot read the log of the ${SERVICE} service"
      log "${lines}"
      return 2
    fi
    # Plain grep reads the full input, so pipefail sees no broken pipe.
    if grep -F "${READY_MESSAGE}" >/dev/null <<<"${lines}"; then
      # The ready line of a process that died afterwards proves nothing.
      service_running && return 0
      return 1
    fi
    # A stopped container cannot become ready. Give the container three
    # checks to appear. If it is gone after that, stop early.
    if ((i > 3)) && ! service_running; then
      return 1
    fi
    # Do not sleep after the last check.
    ((i < WAIT_ATTEMPTS)) && sleep "${WAIT_INTERVAL}"
  done
  return 1
}

# stop_service removes a container that failed to become ready. The next run
# then starts from a clean state.
stop_service() {
  ${COMPOSE} rm --stop --force "${SERVICE}" >/dev/null 2>&1 || true
}

# check_ready waits for the ready line and reports the result. The argument
# names the start time of the process under test.
check_ready() {
  local since="$1" status=0
  wait_for_ready "${since}" || status=$?
  return "${status}"
}

main() {
  local started status

  # A running container alone does not prove readiness. The server can still
  # wait for its SVID, or it can have failed to open the port. The server
  # prints the ready line only after the listener is open, so require both.
  # The start time limits the search to the current process. A restart with
  # a kept log therefore cannot pass on an old ready line.
  if service_running && started="$(container_started_at)"; then
    status=0
    check_ready "${started}" || status=$?
    if ((status == 0)); then
      log "Server workload running (already started)"
      return 0
    fi
    if ((status == 2)); then
      return 1
    fi
    log "a server container runs but is not ready, replacing it"
    stop_service
  fi

  ${COMPOSE} up -d "${SERVICE}"

  if ! started="$(container_started_at)"; then
    log "ERROR: the ${SERVICE} container did not appear"
    return 1
  fi

  status=0
  check_ready "${started}" || status=$?
  if ((status == 2)); then
    # The log is unreadable. The server itself is possibly healthy, so do
    # not remove it for an observation failure.
    return 1
  fi
  if ((status != 0)); then
    log "ERROR: the server workload did not become ready in $((WAIT_ATTEMPTS * WAIT_INTERVAL))s"
    ${COMPOSE} logs --tail 20 "${SERVICE}" || true
    stop_service
    return 1
  fi

  log "Server workload running"
}

main "$@"
