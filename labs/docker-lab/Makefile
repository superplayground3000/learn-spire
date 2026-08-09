# SPIFFE/SPIRE docker-attestor lab.
#
# Lab 1 gave one identity to each UID on one host. This lab gives one identity
# to each container. The docker WorkloadAttestor reads the container label
# "spiffe.lab/workload", and a registration entry maps that label to a
# SPIFFE ID.
#
# Working targets:
#   make build      pull the SPIRE server image, then build the agent image
#                   and the workload image, including the Go binaries
#   make lab-up     start SPIRE Server and SPIRE Agent, attest the agent, and
#                   register the workload entries
#   make lab-down   destroy the lab, including all runtime state
#
# "make lab-up" starts no long-running workload. The workload services sit in
# the "workloads" and "demo" profiles, and later steps start them. The
# registration step starts short-lived client containers. They prove that the
# label gives the identity.

COMPOSE ?= docker compose

# Both images must be built, so the build command names the profiles. A plain
# "docker compose build" skips every service in a profile.
COMPOSE_ALL := $(COMPOSE) --profile workloads --profile demo

.DEFAULT_GOAL := help

.PHONY: help build lab-up lab-down

help:
	@echo 'make build      - pull/build the lab images: SPIRE server, SPIRE agent, and the Go workloads'
	@echo 'make lab-up     - start SPIRE Server and SPIRE Agent, attest the agent, and register the workload entries. You can run this target repeatedly. It also recovers after an agent container restart.'
	@echo 'make lab-down   - stop the lab and delete runtime state'

build:
	$(COMPOSE_ALL) pull --policy missing --ignore-buildable
	$(COMPOSE_ALL) build

# The "up" command starts the control plane only: the SPIRE server and the
# SPIRE agent container. bootstrap.sh then makes the agent attest, and
# register.sh writes the label-to-identity rules.
lab-up: build
	$(COMPOSE) up -d
	COMPOSE="$(COMPOSE)" ./scripts/bootstrap.sh
	COMPOSE="$(COMPOSE)" ./scripts/register.sh

lab-down:
	$(COMPOSE_ALL) down -v --remove-orphans
