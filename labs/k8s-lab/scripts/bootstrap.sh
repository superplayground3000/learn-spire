#!/usr/bin/env bash
#
# Brings the lab from "no cluster" to "the SPIRE agent is attested":
#
#   1. create the kind cluster, if it is absent
#   2. load the three lab images into the cluster
#   3. apply the namespaces, the SPIRE server and the SPIRE agent
#   4. wait for a healthy server
#   5. wait for the filled trust bundle ConfigMap
#   6. wait for the attested agent
#
# Lab 2 did more work here. An operator minted a join token, and the script
# copied the trust bundle into the agent container. Both steps are gone. The
# kubelet mints a projected service account token, and the k8sbundle notifier
# fills the spire-bundle ConfigMap. The agent reads both from its own pod. The
# manifests do that work, so this script only waits for the result.
#
# Safe to run repeatedly. An existing cluster is kept. An apply of an
# unchanged manifest changes nothing.

set -euo pipefail

cd "$(dirname "$0")/.."

# The Makefile passes the same overrides, so both tools address one cluster.
KIND="${KIND:-kind}"
KUBECTL="${KUBECTL:-kubectl}"
CLUSTER="${CLUSTER:-spire-lab}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0}"

WORKLOAD_IMAGE="${WORKLOAD_IMAGE:-spire-k8s-lab-workload:1.15.2}"
SPIRE_SERVER_IMAGE="${SPIRE_SERVER_IMAGE:-ghcr.io/spiffe/spire-server:1.15.2}"
SPIRE_AGENT_IMAGE="${SPIRE_AGENT_IMAGE:-ghcr.io/spiffe/spire-agent:1.15.2}"

# Two bootstraps of one cluster must not run at the same time. When a second
# create fails, its cleanup deletes the cluster of the first. The lock makes
# the second call wait. The shell drops the lock on exit.
mkdir -p tmp
exec 9>"tmp/bootstrap-${CLUSTER}.lock"
flock 9

# kind names the context of a cluster "kind-<cluster>". Every kubectl call
# below names this context. A different current context, or a second kind
# cluster on the host, therefore stays untouched.
KUBE_CONTEXT="kind-${CLUSTER}"

SPIRE_NS="spire"
SERVER_POD="spire-server-0"

# The server image is scratch-based, so every CLI call names the binary.
SERVER_BIN="/opt/spire/bin/spire-server"

# A slow machine can override this number from the environment.
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-120}"
WAIT_INTERVAL=1

# The image archive is a scratch file. The trap deletes it, also after an
# error. tmp/ is the scratch directory of the lab, and git ignores it.
ARCHIVE=""
cleanup() {
  [[ -n "${ARCHIVE}" ]] && rm -f "${ARCHIVE}"
  return 0
}
trap cleanup EXIT

log() { printf '%s\n' "$*"; }

kube() { ${KUBECTL} --context "${KUBE_CONTEXT}" "$@"; }

spire_server() {
  kube exec -n "${SPIRE_NS}" "${SERVER_POD}" -- "${SERVER_BIN}" "$@"
}

# --- 1. the cluster ----------------------------------------------------------

cluster_exists() {
  local clusters
  clusters="$(${KIND} get clusters 2>/dev/null)" || return 1
  # A here-string, not a pipe: grep reads the full input, so pipefail sees no
  # broken pipe. -F compares the name as text, not as a pattern.
  grep -Fqx -- "${CLUSTER}" <<<"${clusters}"
}

create_cluster() {
  if cluster_exists; then
    log "kind cluster ${CLUSTER} exists"
    return 0
  fi
  log "creating the kind cluster ${CLUSTER} from ${KIND_NODE_IMAGE}"
  ${KIND} create cluster --name "${CLUSTER}" --image "${KIND_NODE_IMAGE}"
}

# The cluster can exist while its kubeconfig entry is gone, for example after
# a kubeconfig change. The export writes the entry again. It is safe when the
# entry already exists.
export_kubeconfig() {
  ${KIND} export kubeconfig --name "${CLUSTER}"
}

# --- 2. the images -----------------------------------------------------------

# The cluster runs containerd, and it has no access to the Docker images of
# the host. Each image must go in.
#
# CAUTION: "kind load docker-image" fails against the containerd image store
# with "content digest not found". All three images carry a manifest list,
# also the locally built one. The archive path below works for all of them.
#
# The load runs on every start. The workload image can change under the same
# tag, and a skip would keep old code in the cluster.
load_image() {
  local image="$1"

  mkdir -p tmp
  ARCHIVE="$(mktemp tmp/image-XXXXXX.tar)"

  log "loading ${image} into the cluster"
  docker save --platform linux/amd64 -o "${ARCHIVE}" "${image}"
  ${KIND} load image-archive "${ARCHIVE}" --name "${CLUSTER}"

  rm -f "${ARCHIVE}"
  ARCHIVE=""
}

load_images() {
  load_image "${WORKLOAD_IMAGE}"
  load_image "${SPIRE_SERVER_IMAGE}"
  load_image "${SPIRE_AGENT_IMAGE}"
}

# --- 3. the manifests --------------------------------------------------------

# 30-server.yaml stays out. The API server workload needs its registration
# entry first, so start-server.sh applies that manifest later.
apply_manifests() {
  log "applying the namespaces, the SPIRE server and the SPIRE agent"
  kube apply -f k8s/00-namespaces.yaml
  kube apply -f k8s/10-spire-server.yaml
  kube apply -f k8s/20-spire-agent.yaml
}

# --- 4. to 6. the three waits ------------------------------------------------

# wait_until calls the given command until it succeeds. It returns 1 after
# WAIT_ATTEMPTS tries.
wait_until() {
  local i
  for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
    "$@" && return 0
    sleep "${WAIT_INTERVAL}"
  done
  return 1
}

timeout_seconds() { printf '%s' "$((WAIT_ATTEMPTS * WAIT_INTERVAL))"; }

server_healthy() {
  spire_server healthcheck >/dev/null 2>&1
}

wait_for_server() {
  log "waiting for a healthy SPIRE Server ..."
  if ! wait_until server_healthy; then
    log "ERROR: SPIRE Server did not become healthy in $(timeout_seconds)s"
    log "HINT: look at the pod and its log:"
    kube get pods -n "${SPIRE_NS}" -o wide || true
    kube logs -n "${SPIRE_NS}" "${SERVER_POD}" --tail 40 || true
    return 1
  fi
  log "SPIRE Server healthy"
}

# True once the k8sbundle notifier has written the trust bundle. The manifest
# ships the ConfigMap empty, so the key itself proves the write.
bundle_filled() {
  local bundle
  bundle="$(kube get configmap spire-bundle -n "${SPIRE_NS}" \
    -o jsonpath='{.data.bundle\.crt}' 2>/dev/null)" || return 1
  [[ -n "${bundle}" ]]
}

wait_for_bundle() {
  log "waiting for the trust bundle in the spire-bundle ConfigMap ..."
  if ! wait_until bundle_filled; then
    log "ERROR: the spire-bundle ConfigMap stayed empty for $(timeout_seconds)s"
    log "HINT: the k8sbundle notifier writes this key. Check the Role"
    log "      spire-bundle-writer and the server log:"
    kube logs -n "${SPIRE_NS}" "${SERVER_POD}" --tail 40 || true
    return 1
  fi
  log "trust bundle written to the spire-bundle ConfigMap"
}

# The agent list also names the attestation type. The lab asserts it, because
# the type is the delta of this lab: k8s_psat, not join_token.
agent_attested() {
  local listing
  listing="$(spire_server agent list 2>/dev/null)" || return 1
  grep -Eq 'Attestation type[[:space:]]*:[[:space:]]*k8s_psat' <<<"${listing}"
}

wait_for_agent() {
  log "waiting for the PSAT attestation of the SPIRE Agent ..."
  if ! wait_until agent_attested; then
    log "ERROR: no agent attested with k8s_psat in $(timeout_seconds)s"
    log "HINT: the agent needs the trust bundle and its projected token."
    log "      Check the agent log:"
    kube logs -n "${SPIRE_NS}" -l app=spire-agent --tail 40 || true
    return 1
  fi
  log "SPIRE Agent attested with k8s_psat"
  spire_server agent list
}

main() {
  create_cluster
  export_kubeconfig
  load_images
  apply_manifests
  wait_for_server
  wait_for_bundle
  wait_for_agent
}

main "$@"
