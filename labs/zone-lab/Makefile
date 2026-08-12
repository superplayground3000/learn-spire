# Zone-lab, phase 1. The lab moves the enforcement point from the app code into
# Envoy. Three security zones, one control plane, one shared SPIRE agent.
#
# Phase-1 step 3 targets (the positive path):
#   make build     build the workload image and the Envoy image
#   make lab-up    start the always-up set, bootstrap the agent, register the
#                  entries, and start the backend apps and the Envoys
#   make demo      run the positive path: zone-a-client -> zone-b-gateway ->
#                  zone-b-backend, HTTP 200 with both SANs logged
#   make lab-down  destroy the lab and all runtime state
#
# Later steps add the negative demos, inspect, test-integration, and the extra
# demos. Only one lab runs at a time, because the subnets are fixed. Always run
# "make lab-down" before you re-up.

COMPOSE ?= docker compose

# The one-shot workloads sit in the "demo" profile. The build and the teardown
# name that profile, so no profiled service is skipped.
COMPOSE_ALL := $(COMPOSE) --profile demo

.DEFAULT_GOAL := help

.PHONY: help build lab-up demo lab-down

help:
	@echo 'make build    - build the zone-lab image (SPIRE agent, Envoy, the two Go apps)'
	@echo 'make lab-up   - start the lab, attest the agent, register the entries, start the servers'
	@echo 'make demo     - run the positive path: HTTP 200 with both SANs logged'
	@echo 'make lab-down - stop the lab and delete all runtime state'

build:
	$(COMPOSE_ALL) pull --policy missing --ignore-buildable
	$(COMPOSE_ALL) build

# The "up" command starts the control plane and the always-up zone nodes.
# bootstrap.sh attests the agent. register.sh writes the label-to-identity
# rules. start-servers.sh starts the backend apps and the Envoys last, because
# each Envoy needs its entry before SDS can deliver its SVID.
lab-up: build
	$(COMPOSE) up -d
	COMPOSE="$(COMPOSE)" ./scripts/bootstrap.sh
	COMPOSE="$(COMPOSE)" ./scripts/register.sh
	COMPOSE="$(COMPOSE)" ./scripts/start-servers.sh

demo:
	COMPOSE="$(COMPOSE)" ./scripts/demo.sh

# The teardown removes every container, including the one-shot demo workloads,
# and deletes the named volumes with the runtime state.
lab-down:
	$(COMPOSE_ALL) down -v --remove-orphans
