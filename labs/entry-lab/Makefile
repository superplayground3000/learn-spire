# SPIFFE/SPIRE entry lab.
#
# Working targets:
#   make build      pull the SPIRE server image and build the lab node image,
#                   including the Go server and client binaries
#   make lab-up     start SPIRE Server + SPIRE Agent + the Go API server,
#                   attested and registered
#   make lab-down   destroy the lab, including all runtime state
#
#   make demo               run the three demos in order
#   make demo-ok            the authorized client authenticates and gets HTTP 200
#   make demo-intruder      the server denies a valid but unauthorized SVID
#                           during the TLS handshake
#   make demo-unregistered  an unregistered UID gets no SVID at all
#
#   make demo-rotation      show that SPIRE replaces the SVID of the running
#                           server workload, and that the server does not
#                           restart for it
#
#   make inspect    show the agents, the registration entries and the two
#                   X509-SVIDs with their URI SAN and their expiry
#
#   make test-integration
#                   destroy the lab, build it again, then assert the ten
#                   security properties of section 20
#
# The first demo passes when the lab allows the request. The other two pass
# when the lab denies the request.

COMPOSE ?= docker compose

.DEFAULT_GOAL := help

.PHONY: help build lab-up lab-down demo demo-ok demo-intruder demo-unregistered demo-rotation inspect test-integration

help:
	@echo 'make build      - pull/build lab images, including the Go workloads'
	@echo 'make lab-up     - start the lab: attest the agent, register the entries, run the Go API server. Idempotent. It also recovers after a node container restart.'
	@echo 'make lab-down   - stop the lab and delete runtime state'
	@echo 'make demo       - run demo-ok, demo-intruder and demo-unregistered in that order'
	@echo 'make demo-ok           - UID 10002 holds the SVID for spiffe://lab.local/client. The handshake succeeds. The server answers HTTP 200.'
	@echo 'make demo-intruder     - UID 10003 holds a valid SVID for the wrong identity. The server denies the handshake. The denial is the pass.'
	@echo 'make demo-unregistered - UID 10004 has no registration entry. The agent issues no SVID. The denial is the pass.'
	@echo 'make demo-rotation     - SPIRE replaces the SVID of the running server. The serial number changes, and the PID does not. It needs about two minutes.'
	@echo 'make inspect    - show the agents, the registration entries and the server and client X509-SVIDs. It exports the SVIDs to tmp/, which git ignores.'
	@echo 'make test-integration - CAUTION: this deletes all lab state. It builds a fresh lab. It asserts the ten security properties of section 20. It leaves the lab down.'

build:
	$(COMPOSE) pull --policy missing --ignore-buildable
	$(COMPOSE) build

lab-up: build
	$(COMPOSE) up -d
	./scripts/bootstrap.sh
	./scripts/register.sh
	./scripts/start-server.sh

lab-down:
	$(COMPOSE) down -v --remove-orphans

# --- Demos -------------------------------------------------------------------
# Each demo needs a running lab. The script stops with a clear message when the
# lab is down.

# The three demos run in one order. Make stops at the first failure. The
# recipe names the scripts directly, because prerequisites can run in parallel.
demo:
	./scripts/demo-ok.sh
	@echo ''
	./scripts/demo-intruder.sh
	@echo ''
	./scripts/demo-unregistered.sh

demo-ok:
	./scripts/demo-ok.sh

demo-intruder:
	./scripts/demo-intruder.sh

demo-unregistered:
	./scripts/demo-unregistered.sh

# --- Rotation demo (section 24, Lab 1.5) -------------------------------------
# This demo is not part of "make demo", because it needs about two minutes and
# it changes lab state while it runs. It shortens the X509-SVID lifetime of the
# server registration entry, and it restores that lifetime at the end.

demo-rotation:
	./scripts/demo-rotation.sh

# --- Inspection --------------------------------------------------------------
# The certificates and keys go to tmp/. Never commit them.

inspect:
	./scripts/inspect.sh

# --- Integration test --------------------------------------------------------
# The test runs its own full cycle: lab-down, lab-up, the assertions, lab-down.
# So it needs no running lab, and it leaves no lab behind. It exits non-zero
# when the lab does not enforce one security property or more.

test-integration:
	./scripts/test-integration.sh
