# SPIFFE/SPIRE docker-attestor lab.
#
# Lab 1 gave one identity to each UID on one host. This lab gives one identity
# to each container. The docker WorkloadAttestor reads the container label
# "spiffe.lab/workload", and a registration entry maps that label to a
# SPIFFE ID.
#
# Working targets:
#   make build              pull the SPIRE server image, then build the agent
#                           image and the workload image, including the Go
#                           binaries
#   make lab-up             start SPIRE Server and SPIRE Agent, attest the
#                           agent, register the workload entries, and start the
#                           API server
#   make demo-ok            run the authorized client and prove mutual
#                           authentication
#   make demo-intruder      run the unauthorized client and prove the denial
#   make demo-unregistered  ask for an SVID without an entry and prove the
#                           denial
#   make demo               run the three demos in order
#   make inspect            show the agents, the entries and the SVIDs
#   make test-integration   destroy the lab, build it again, then assert the
#                           ten security properties
#   make lab-down           destroy the lab, including all runtime state
#
# "make lab-up" starts one long-running workload: the API server. The other
# workload services sit in the "demo" profile, and a demo starts them for one
# run. The registration step also starts short-lived client containers. They
# prove that the label gives the identity.

COMPOSE ?= docker compose

# Both images must be built, so the build command names the profiles. A plain
# "docker compose build" skips every service in a profile.
COMPOSE_ALL := $(COMPOSE) --profile workloads --profile demo

.DEFAULT_GOAL := help

.PHONY: help build lab-up demo-ok demo-intruder demo-unregistered demo inspect test-integration lab-down

help:
	@echo 'make build             - pull/build the lab images: SPIRE server, SPIRE agent, and the Go workloads'
	@echo 'make lab-up            - start SPIRE Server and SPIRE Agent, attest the agent, register the workload entries, and start the API server. You can run this target repeatedly. It also recovers after an agent container restart.'
	@echo 'make demo-ok           - run the authorized client against the server and check the mutual authentication'
	@echo 'make demo-intruder     - run the intruder container and check that the server refuses its valid SVID'
	@echo 'make demo-unregistered - ask the Workload API from a container without an entry and check the denial'
	@echo 'make demo              - run demo-ok, demo-intruder and demo-unregistered in that order'
	@echo 'make inspect           - show the attested agents, the registration entries and the X509-SVIDs'
	@echo 'make test-integration  - CAUTION: this deletes all lab state. It builds a fresh lab. It asserts the ten security properties. It leaves the lab down.'
	@echo 'make lab-down          - stop the lab and delete runtime state'

build:
	$(COMPOSE_ALL) pull --policy missing --ignore-buildable
	$(COMPOSE_ALL) build

# The "up" command starts the control plane first: the SPIRE server and the
# SPIRE agent container. bootstrap.sh then makes the agent attest, and
# register.sh writes the label-to-identity rules. start-server.sh starts the
# API server last, because the server needs its entry before it gets an SVID.
lab-up: build
	$(COMPOSE) up -d
	COMPOSE="$(COMPOSE)" ./scripts/bootstrap.sh
	COMPOSE="$(COMPOSE)" ./scripts/register.sh
	COMPOSE="$(COMPOSE)" ./scripts/start-server.sh

# Each demo needs a running lab. It starts one workload container, and it
# deletes that container after the run.
demo-ok:
	COMPOSE="$(COMPOSE)" ./scripts/demo-ok.sh

demo-intruder:
	COMPOSE="$(COMPOSE)" ./scripts/demo-intruder.sh

demo-unregistered:
	COMPOSE="$(COMPOSE)" ./scripts/demo-unregistered.sh

# The three demos tell one story. An authorized identity passes. A valid but
# unauthorized identity fails. A workload without an entry gets no identity.
# The order is part of the story, so the recipe calls each demo in turn. Make
# stops at the first demo that fails. Prerequisites keep no order under
# "make -j", but these recipe lines do.
demo:
	$(MAKE) --no-print-directory demo-ok
	$(MAKE) --no-print-directory demo-intruder
	$(MAKE) --no-print-directory demo-unregistered

# The inspect target exports private keys to tmp/. git ignores that directory.
# Never commit the material.
inspect:
	COMPOSE="$(COMPOSE)" ./scripts/inspect.sh

# The test runs its own full cycle: lab-down, lab-up, the assertions, lab-down.
# So it needs no running lab, and it leaves no lab behind. It exits non-zero
# when the lab does not enforce one security property or more.
test-integration:
	COMPOSE="$(COMPOSE)" ./scripts/test-integration.sh

lab-down:
	$(COMPOSE_ALL) down -v --remove-orphans
