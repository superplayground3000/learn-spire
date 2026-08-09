# SPIFFE/SPIRE entry lab.
#
# Working targets:
#   make build      pull the SPIRE server image and build the lab node image,
#                   including the Go server and client binaries
#   make lab-up     start SPIRE Server + SPIRE Agent + the Go API server,
#                   attested and registered
#   make lab-down   destroy the lab, including all runtime state
#
#   make demo-intruder      the server denies a valid but unauthorized SVID
#                           during the TLS handshake
#   make demo-unregistered  an unregistered UID gets no SVID at all
#
# Both demos pass when the lab denies the request. They fail when the lab
# allows it.

COMPOSE ?= docker compose

.DEFAULT_GOAL := help

.PHONY: help build lab-up lab-down demo demo-ok demo-intruder demo-unregistered inspect test-integration

help:
	@echo 'make build      - pull/build lab images, including the Go workloads'
	@echo 'make lab-up     - start the lab: attest the agent, register the entries, run the Go API server. Idempotent. It also recovers after a node container restart.'
	@echo 'make lab-down   - stop the lab and delete runtime state'
	@echo 'make demo-intruder     - UID 10003 holds a valid SVID for the wrong identity. The server denies the handshake. The denial is the pass.'
	@echo 'make demo-unregistered - UID 10004 has no registration entry. The agent issues no SVID. The denial is the pass.'

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

# --- Negative demos ----------------------------------------------------------
# Each demo needs a running lab. The script stops with a clear message when the
# lab is down.

demo-intruder:
	./scripts/demo-intruder.sh

demo-unregistered:
	./scripts/demo-unregistered.sh

# --- Later phases -----------------------------------------------------------
# The positive demo, inspect and the integration tests are not part of this
# phase yet. Until then, run the client by hand:
#   docker compose exec -T --user 10002 node client

demo demo-ok inspect test-integration:
	@echo 'make $@: not implemented yet'
	@exit 1
