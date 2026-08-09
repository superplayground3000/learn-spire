# SPIFFE/SPIRE entry lab.
#
# Working targets:
#   make build      pull the SPIRE server image and build the lab node image
#   make lab-up     start SPIRE Server + SPIRE Agent, attested and ready
#   make lab-down   destroy the lab, including all runtime state

COMPOSE ?= docker compose

.DEFAULT_GOAL := help

.PHONY: help build lab-up lab-down demo demo-ok demo-intruder demo-unregistered inspect test-integration

help:
	@echo 'make build      - pull/build lab images'
	@echo 'make lab-up     - start the lab (idempotent; also re-attests the agent after a node container restart)'
	@echo 'make lab-down   - stop the lab and delete runtime state'

build:
	$(COMPOSE) pull --policy missing --ignore-buildable
	$(COMPOSE) build

lab-up: build
	$(COMPOSE) up -d
	./scripts/bootstrap.sh

lab-down:
	$(COMPOSE) down -v --remove-orphans

# --- Later phases -----------------------------------------------------------
# Registration entries, the Go workloads and the three demos are not part of
# this phase yet.

demo demo-ok demo-intruder demo-unregistered inspect test-integration:
	@echo 'make $@: not implemented yet'
	@exit 1
