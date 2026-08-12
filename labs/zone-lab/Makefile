# Zone-lab, phase 1. The lab moves the enforcement point from the app code into
# Envoy. Three security zones, one control plane, one shared SPIRE agent.
#
# The full target set (spec section 21):
#   make build             build the workload image and the Envoy image
#   make lab-up            start the always-up set, bootstrap, and register
#   make test-integration  assert P1 to P11 and the SAN-pin negative test
#   make demo              run the positive path: HTTP 200 with both SANs logged
#   make demo-intruder     P5: the intruder gets a logged 403
#   make demo-unregistered P11: a container with no entry gets no SVID
#   make demo-bearer       the bearer-credential FINDING
#   make demo-latency      the gateway-hop overhead number
#   make demo-rotation     the SDS rotation demo
#   make inspect           show agents, entries, SVIDs, and Envoy secrets
#   make lab-down          destroy the lab and all runtime state
#
# Only one lab runs at a time, because the subnets are fixed. Always run
# "make lab-down" before you re-up.

COMPOSE ?= docker compose

# The one-shot workloads sit in the "demo" profile. The CoreDNS resolvers sit in
# the "dns" profile. The build and the teardown name both profiles, so no
# profiled service is skipped when pulling images or removing containers.
COMPOSE_ALL := $(COMPOSE) --profile demo --profile dns

.DEFAULT_GOAL := help

.PHONY: help build lab-up demo demo-intruder demo-unregistered demo-bearer \
        demo-latency demo-rotation demo-register demo-dns inspect \
        test-integration test-san-pin ui test-ui lab-down

# The control panel binds 127.0.0.1:8900 by default. UI_PORT overrides the port.
UI_PORT ?= 8900

help:
	@echo 'make build             - build the zone-lab image (SPIRE agent, Envoy, the two Go apps)'
	@echo 'make lab-up            - start the lab, attest the agent, register, start the servers'
	@echo 'make test-integration  - assert P1 to P11 and the SAN-pin negative test (full cycle)'
	@echo 'make demo              - run the positive path: HTTP 200 with both SANs logged'
	@echo 'make demo-intruder     - P5: the intruder gets a logged 403'
	@echo 'make demo-unregistered - P11: a container with no entry gets no SVID'
	@echo 'make demo-bearer       - the bearer-credential FINDING (a stolen SVID still works)'
	@echo 'make demo-latency      - the gateway-hop overhead number (teaching, not the green bar)'
	@echo 'make demo-rotation     - the SDS rotation demo (outside the green bar)'
	@echo 'make demo-register     - phase 2: a registration walk-through (accept, list, two refusals)'
	@echo 'make demo-dns          - phase 2: a DNS resolution walk-through (self, peer, NXDOMAIN, bypass)'
	@echo 'make inspect           - show agents, entries, SVIDs, and Envoy secrets'
	@echo 'make ui                - phase 3: start the host-side control panel (127.0.0.1:8900)'
	@echo 'make test-ui           - phase 3: UI smoke test (panel starts, /api/state is valid JSON)'
	@echo 'make lab-down          - stop the lab and delete all runtime state'

build:
	$(COMPOSE_ALL) pull --policy missing --ignore-buildable
	$(COMPOSE_ALL) build

# The "up" command starts the control plane and the always-up zone nodes.
# bootstrap.sh attests the agent. register.sh writes the label-to-identity
# rules. start-servers.sh starts the backend apps, the peer app, and the Envoys
# last, because each Envoy needs its entry before SDS can deliver its SVID.
lab-up: build
	$(COMPOSE) up -d
	COMPOSE="$(COMPOSE)" ./scripts/bootstrap.sh
	COMPOSE="$(COMPOSE)" ./scripts/register.sh
	COMPOSE="$(COMPOSE)" ./scripts/start-servers.sh

demo:
	COMPOSE="$(COMPOSE)" ./scripts/demo.sh

demo-intruder:
	COMPOSE="$(COMPOSE)" ./scripts/demo-intruder.sh

demo-unregistered:
	COMPOSE="$(COMPOSE)" ./scripts/demo-unregistered.sh

demo-bearer:
	COMPOSE="$(COMPOSE)" ./scripts/demo-bearer.sh

demo-latency:
	COMPOSE="$(COMPOSE)" ./scripts/demo-latency.sh

demo-rotation:
	COMPOSE="$(COMPOSE)" ./scripts/demo-rotation.sh

demo-register:
	COMPOSE="$(COMPOSE)" ./scripts/demo-register.sh

demo-dns:
	COMPOSE="$(COMPOSE)" ./scripts/demo-dns.sh

inspect:
	COMPOSE="$(COMPOSE)" ./scripts/inspect.sh

# ui starts the host-side operator console. It runs on the host with Python 3
# stdlib only, binds 127.0.0.1:8900, and shells out to docker. It is a demo and
# operator tool, not a security control. Bring the lab up first.
ui:
	COMPOSE="$(COMPOSE)" python3 ui/server.py --port $(UI_PORT)

# test-ui runs the UI smoke test against an already-running lab. It never flips
# a policy cell, and it adds no property to the nineteen-property green bar.
test-ui:
	COMPOSE="$(COMPOSE)" UI_PORT=$(UI_PORT) ./scripts/test-ui.sh

# test-integration deletes all lab state, builds a fresh lab, asserts every
# property and the SAN-pin test, and leaves the lab down (a trap on EXIT).
test-integration:
	COMPOSE="$(COMPOSE)" ./scripts/test-integration.sh

# test-san-pin asserts the SAN pins against an already-running lab. lab-up first.
test-san-pin:
	COMPOSE="$(COMPOSE)" ./scripts/test-san-pin.sh

# The teardown removes every container, including the one-shot demo workloads,
# and deletes the named volumes with the runtime state.
lab-down:
	$(COMPOSE_ALL) down -v --remove-orphans
