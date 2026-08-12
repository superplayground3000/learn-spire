#!/usr/bin/env bash
#
# The UI smoke test (phase 3). It runs against an already-running lab. It starts
# the control panel, confirms the panel comes up, confirms GET /api/state returns
# valid JSON, then stops the panel.
#
# The smoke test NEVER flips a policy cell. It starts the panel with
# --no-reconcile, so it changes no enforcement state. It adds no property to the
# nineteen-property green bar; it only proves the panel starts and serves state.

set -uo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
PORT="${UI_PORT:-8901}"
GW="zone-lab-zone-b-gateway"
UI_PID=""

log() { printf '%s\n' "$*"; }

cleanup() {
  if [[ -n "${UI_PID}" ]] && kill -0 "${UI_PID}" 2>/dev/null; then
    kill "${UI_PID}" 2>/dev/null || true
    wait "${UI_PID}" 2>/dev/null || true
    log "  UI stopped (pid ${UI_PID})"
  fi
}
trap cleanup EXIT

fail() { log ""; log "SMOKE TEST: FAIL — $*"; exit 1; }

main() {
  log "=== UI smoke test ==="

  # 1. The lab must be up. The panel probes real containers.
  if ! docker inspect "${GW}" -f '{{.State.Running}}' 2>/dev/null | grep -q true; then
    fail "the lab is not running. Run 'make lab-up' first."
  fi
  log "  lab is up (${GW} running)"

  # 2. Start the panel on loopback, with no reconcile (it changes no state).
  python3 ui/server.py --port "${PORT}" --no-reconcile >/tmp/zone-lab-ui-smoke.log 2>&1 &
  UI_PID=$!
  log "  UI started (pid ${UI_PID}) on 127.0.0.1:${PORT}"

  # 3. Wait for the panel to answer.
  local up=0 i
  for ((i = 1; i <= 30; i++)); do
    if ! kill -0 "${UI_PID}" 2>/dev/null; then
      log "  --- UI log ---"; sed 's/^/    /' /tmp/zone-lab-ui-smoke.log
      fail "the UI process exited early."
    fi
    if curl -fsS "http://127.0.0.1:${PORT}/" -o /dev/null 2>/dev/null; then
      up=1; break
    fi
    sleep 1
  done
  [[ "${up}" -eq 1 ]] || fail "the UI did not come up within 30 seconds."
  log "  UI answers on http://127.0.0.1:${PORT}/"

  # 4. GET /api/state must return valid JSON with the expected top-level keys.
  local body
  body="$(curl -fsS "http://127.0.0.1:${PORT}/api/state" 2>/dev/null)" \
    || fail "GET /api/state did not answer."

  printf '%s' "${body}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("invalid JSON:", e); sys.exit(1)
for key in ("results", "networks", "running", "policy", "stats"):
    if key not in d:
        print("missing key:", key); sys.exit(1)
if not isinstance(d["results"], dict) or not d["results"]:
    print("results is empty"); sys.exit(1)
print("  /api/state returned valid JSON with %d probe results" % len(d["results"]))
' || fail "GET /api/state returned invalid or incomplete JSON."

  log ""
  log "SMOKE TEST: PASS — the panel starts and serves valid /api/state JSON."
}

main "$@"
