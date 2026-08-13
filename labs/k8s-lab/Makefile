# SPIFFE/SPIRE Kubernetes lab.
#
# Lab 2 gave one identity to each container. The docker WorkloadAttestor read a
# container label. This lab gives one identity to each pod. The k8s
# WorkloadAttestor reads the namespace and the service account of the pod, and
# a registration entry maps that pair to a SPIFFE ID.
#
# The lab runs on one kind cluster with one node. All four workload pods use
# the same image and the same UID 10000. Only the service account differs.
#
# Working targets:
#   make build              build the workload image, then pull the SPIRE
#                           server image and the SPIRE agent image
#   make lab-up             create the cluster, load the images, start SPIRE
#                           Server and SPIRE Agent, and attest the agent
#   make demo-ok            run the authorized client and prove mutual
#                           authentication
#   make demo-intruder      run the unauthorized client and prove the denial
#   make demo-unregistered  ask for an SVID without an entry and prove the
#                           denial
#   make demo               run the three demos in order
#   make inspect            show the agents, the entries and the SVIDs
#   make test-integration   destroy the lab, build it again, then assert the
#                           ten security properties
#   make lab-down           delete the cluster, including all runtime state
#
# CAUTION: some scripts are not written yet. A target that calls a missing
# script stops with "no such file".

KIND ?= kind
KUBECTL ?= kubectl
CLUSTER ?= spire-lab
KIND_NODE_IMAGE ?= kindest/node:v1.35.0

# The three images of the lab. The first one is built here. The other two come
# from the SPIRE project. bootstrap.sh loads all three into the cluster.
WORKLOAD_IMAGE ?= spire-k8s-lab-workload:1.15.2
SPIRE_SERVER_IMAGE ?= ghcr.io/spiffe/spire-server:1.15.2
SPIRE_AGENT_IMAGE ?= ghcr.io/spiffe/spire-agent:1.15.2

# Every script accepts the same overrides, so make and a hand-run script
# address one cluster and one image set.
SCRIPT_ENV := KIND="$(KIND)" KUBECTL="$(KUBECTL)" CLUSTER="$(CLUSTER)" \
	KIND_NODE_IMAGE="$(KIND_NODE_IMAGE)" \
	WORKLOAD_IMAGE="$(WORKLOAD_IMAGE)" \
	SPIRE_SERVER_IMAGE="$(SPIRE_SERVER_IMAGE)" \
	SPIRE_AGENT_IMAGE="$(SPIRE_AGENT_IMAGE)"

.DEFAULT_GOAL := help

.PHONY: help build lab-up demo-ok demo-intruder demo-unregistered demo inspect test-integration lab-down

help:
	@echo 'make build             - build the workload image and pull the SPIRE server and SPIRE agent images'
	@echo 'make lab-up            - create the kind cluster, load the images, start SPIRE Server and SPIRE Agent, and attest the agent. You can run this target repeatedly.'
	@echo 'make demo-ok           - run the authorized client against the server and check the mutual authentication'
	@echo 'make demo-intruder     - run the intruder pod and check that the server refuses its valid SVID'
	@echo 'make demo-unregistered - ask the Workload API from a pod without an entry and check the denial'
	@echo 'make demo              - run demo-ok, demo-intruder and demo-unregistered in that order'
	@echo 'make inspect           - show the attested agents, the registration entries and the X509-SVIDs'
	@echo 'make test-integration  - CAUTION: this deletes the cluster. It builds a fresh lab. It asserts the ten security properties. It leaves the lab down.'
	@echo 'make lab-down          - delete the kind cluster and all runtime state'

# This target does the Docker work only. It touches no cluster. The platform
# flag keeps all three images on one architecture, because kind loads them
# from an archive later.
build:
	docker build --platform linux/amd64 -f docker/Dockerfile -t $(WORKLOAD_IMAGE) .
	docker pull --platform linux/amd64 $(SPIRE_SERVER_IMAGE)
	docker pull --platform linux/amd64 $(SPIRE_AGENT_IMAGE)

# bootstrap.sh creates the cluster, loads the images, and brings the agent to
# "attested". The lab is not complete after that: register.sh must write the
# entries, and start-server.sh must start the API server. Both scripts come
# with the next step, and this target then calls them after bootstrap.sh.
lab-up: build
	$(SCRIPT_ENV) ./scripts/bootstrap.sh

# Each demo needs a running lab. It starts one pod, and it deletes that pod
# after the run.
demo-ok:
	$(SCRIPT_ENV) ./scripts/demo-ok.sh

demo-intruder:
	$(SCRIPT_ENV) ./scripts/demo-intruder.sh

demo-unregistered:
	$(SCRIPT_ENV) ./scripts/demo-unregistered.sh

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
	$(SCRIPT_ENV) ./scripts/inspect.sh

# The test runs its own full cycle: lab-down, lab-up, the assertions,
# lab-down. So it needs no running lab, and it leaves no lab behind. It exits
# non-zero when the lab does not enforce one security property or more.
test-integration:
	$(SCRIPT_ENV) ./scripts/test-integration.sh

# The cluster holds all state of the lab: the datastore, the CA keys and the
# agent identity. One delete removes all of it.
lab-down:
	$(KIND) delete cluster --name $(CLUSTER)
