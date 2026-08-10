# Research: the k8s workload attestor on kind

Target: SPIRE 1.15.2, plugin `WorkloadAttestor "k8s"`, one kind node.
The plugin gets the pod ID of the caller from its cgroup membership.
It then queries the kubelet for information about the pod.
Source: [plugin doc v1.15.2][plugin-doc].

## 1. Kubelet access from the agent pod

### Port choice

The plugin can talk to the kubelet on two ports:

- `kubelet_read_only_port` — the insecure read-only port. No authentication.
- `kubelet_secure_port` — the secure port. Defaults to `10250` unless `kubelet_read_only_port` is set.

The two options are mutually exclusive ([plugin doc][plugin-doc]).
kind boots its nodes with kubeadm ([kind design doc][kind-design]).
The `KubeletConfiguration` default is `readOnlyPort: 0`, which disables the read-only service ([KubeletConfiguration types][kubelet-types]).
Thus, on kind, use the secure port.

### Authentication

The secure port accepts a bearer token or an X509 client certificate ([plugin doc][plugin-doc]).
The token method needs the kubelet flag `--authentication-token-webhook` ([plugin doc][plugin-doc]).
kubeadm configures the kubelet with webhook authentication and disables anonymous access ([kubelet authn/authz][kubelet-authn]).
The related HCL options are:

- `token_path` — path to the bearer token. Defaults to `/run/secrets/kubernetes.io/serviceaccount/token`.
- `certificate_path` and `private_key_path` — the X509 client credential pair.
- `use_anonymous_authentication` — discouraged; it needs anonymous users authorized for `nodes/proxy` ([plugin doc][plugin-doc]).

On kind, the default `token_path` is sufficient. The agent pod's service account token authenticates the call.

### Kubelet certificate verification

The plugin verifies the kubelet certificate with `kubelet_ca_path` by default.
That option defaults to the cluster CA bundle `/run/secrets/kubernetes.io/serviceaccount/ca.crt` ([plugin doc][plugin-doc]).
But kubeadm deploys a self-signed kubelet serving certificate: "By default the kubelet serving certificate deployed by kubeadm is self-signed" ([kubeadm certs doc][kubeadm-certs]).
The cluster CA cannot verify that certificate.
Thus, on kind, set `skip_kubelet_verification = true`.
The SPIRE quickstart does the same for minikube, for the same reason ([quickstart agent config][qs-configmap]).

### Kubelet address

The plugin contacts the kubelet at the node name from `node_name_env` (default `MY_NODE_NAME`) or `node_name`.
If no node name is available, it contacts `127.0.0.1`, which requires host networking ([plugin doc][plugin-doc]).
The quickstart sets `hostNetwork: true` and fills `MY_NODE_NAME` from `status.podIP` ([quickstart DaemonSet][qs-daemonset]).
Under host networking, the pod IP equals the node IP, so the agent dials the kubelet at the node IP.

### RBAC

The kubelet uses webhook authorization and asks the API server a `SubjectAccessReview` for each request.
The `/pods` endpoint maps to resource `nodes`, subresource `proxy`, verb `get` ([kubelet authn/authz][kubelet-authn]).
The quickstart binds this ClusterRole to the `spire-agent` service account ([quickstart RBAC][qs-rbac]):

```yaml
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "nodes/proxy"]
  verbs: ["get"]
```

Warning: `get` on `nodes/proxy` is not read-only.
It also authorizes command execution in any container on the node ([kubelet authn/authz][kubelet-authn]).
Grant it only to the SPIRE agent service account.

## 2. Pod resolution under kind's containerd

The agent receives the caller PID from the Unix socket peer credentials.
The plugin then extracts the pod UID and the container ID for that PID.
The extractor reads two files, in this order ([extract.go v1.15.2][extract-src]):

1. `/proc/<pid>/cgroup` — the primary, kernel-controlled source.
2. `/proc/<pid>/mountinfo` — the fallback, used when the cgroup data yields nothing.

The pod UID match pattern is `pod<uid>`, with dashes or underscores in the UID.
The systemd cgroup driver replaces dashes with underscores; the extractor reverses this ([extract.go][extract-src]).
The container ID is a 64-character hex string in the cgroup path.
The plugin then queries the kubelet `/pods` list and matches the pod UID.
If the pod is not listed yet, the plugin polls again (code defaults: 60 attempts, 500 ms interval) ([k8s.go v1.15.2][k8s-src]).

Related HCL options ([plugin doc][plugin-doc]):

- `use_new_container_locator` — enables the locator with cgroups v2 support. Defaults to `true`.
- `verbose_container_locator_logs` — logs the mountinfo and cgroup data. Defaults to `false`.
- `disable_container_selectors` — emits only pod selectors when the container is not ready.

kind-specific notes:

- kind nodes are containers; the workload cgroup paths are nested under the node container.
  The extractor searches for the `pod<uid>` token anywhere in the path, so nesting is harmless.
- kind uses containerd with the systemd cgroup driver and supports cgroups v2.
  The default locator (`use_new_container_locator = true`) handles both cgroup versions ([extract.go][extract-src]).
- The agent must see the caller PID in its own `/proc`.
  Thus the DaemonSet sets `hostPID: true` ([quickstart DaemonSet][qs-daemonset]; the hardened Helm chart does the same [here][helm-ds]).
- If attestation fails, set `verbose_container_locator_logs = true` and read the agent log.

## 3. Selectors the attestor emits

All values come from the [plugin doc v1.15.2][plugin-doc].

| Selector | Value |
|---|---|
| `k8s:ns` | The workload's namespace |
| `k8s:sa` | The workload's service account |
| `k8s:container-image` | Image or ImageID of the container that requests an SVID |
| `k8s:container-name` | Name of the workload's container |
| `k8s:node-name` | Name of the workload's node |
| `k8s:pod-label` | A label of the workload's pod |
| `k8s:pod-name` | Name of the workload's pod |
| `k8s:pod-uid` | UID of the workload's pod |
| `k8s:pod-owner` | Name of the workload's pod owner |
| `k8s:pod-owner-uid` | UID of the workload's pod owner |
| `k8s:pod-image` | Image or ImageID of any container in the pod |
| `k8s:pod-image-count` | Number of container images in the pod |
| `k8s:pod-init-image` | Image or ImageID of any init container in the pod |
| `k8s:pod-init-image-count` | Number of init container images in the pod |

If `disable_container_selectors = true`, the plugin does not emit the container selectors.

## 4. Agent DaemonSet requirements

Facts from the [quickstart DaemonSet][qs-daemonset] and the [plugin doc][plugin-doc]:

- `hostPID: true` — required. The agent reads `/proc/<pid>` of workload processes.
- `hostNetwork: true` with `dnsPolicy: ClusterFirstWithHostNet` — the quickstart pattern.
  It lets the agent reach the kubelet at the node IP or at `127.0.0.1`.
- A `hostPath` volume for the Workload API socket, for example `/run/spire/sockets` with type `DirectoryOrCreate`.
- `serviceAccountName: spire-agent`, bound to the ClusterRole from section 1.
- Env var `MY_NODE_NAME` from the downward API (`status.podIP` in the quickstart).
  The HCL option `node_name_env = "MY_NODE_NAME"` reads it.
- A projected service account token volume for the `k8s_psat` node attestor (audience `spire-server`).
- Security context: the quickstart sets none and runs the container as root.
  Root is necessary to read `/proc/<pid>` of processes that other users own.
  The hardened Helm chart also sets `hostPID: true` on its agent DaemonSet ([daemonset.yaml][helm-ds]).

There is no `KUBELET_HOST` option in SPIRE 1.15.2.
The kubelet address comes only from `node_name` / `node_name_env`, or falls back to `127.0.0.1`.

## Recommended lab configuration

Agent HCL excerpt for kind:

```hcl
WorkloadAttestor "k8s" {
  plugin_data {
    # kind (kubeadm) deploys a self-signed kubelet serving certificate.
    # The cluster CA cannot verify it, so skip verification.
    skip_kubelet_verification = true
    node_name_env = "MY_NODE_NAME"
  }
}
```

The secure port `10250` and the service account `token_path` are the defaults. Do not set them.

DaemonSet requirements list:

1. `hostPID: true`.
2. `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet`.
3. Env `MY_NODE_NAME` from `fieldRef: status.podIP`.
4. `hostPath` volume `/run/spire/sockets` (`DirectoryOrCreate`) mounted read-write.
5. `serviceAccountName: spire-agent` plus a ClusterRole with `get` on `pods`, `nodes`, `nodes/proxy`.
6. A projected service account token volume for the `k8s_psat` node attestor.
7. Run the agent container as root; do not drop that with a restrictive security context.

Registration entries for the lab match on `k8s:ns` and `k8s:sa`.
Both selectors are in the emitted set, so the locked lab decisions hold.

## Sources

- [SPIRE k8s workload attestor plugin doc, tag v1.15.2][plugin-doc]
- [SPIRE k8s attestor source, k8s.go, tag v1.15.2][k8s-src]
- [SPIRE container info extractor, extract.go, tag v1.15.2][extract-src]
- [spire-tutorials quickstart: agent DaemonSet][qs-daemonset]
- [spire-tutorials quickstart: agent RBAC][qs-rbac]
- [spire-tutorials quickstart: agent ConfigMap][qs-configmap]
- [Kubernetes: kubelet authentication/authorization][kubelet-authn]
- [Kubernetes: kubeadm certificate management (self-signed kubelet serving cert)][kubeadm-certs]
- [Kubernetes: KubeletConfiguration types (readOnlyPort default 0)][kubelet-types]
- [kind design: initial cluster bootstrap with kubeadm][kind-design]
- [SPIFFE helm-charts-hardened: agent daemonset.yaml][helm-ds]

[plugin-doc]: https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_agent_workloadattestor_k8s.md
[k8s-src]: https://github.com/spiffe/spire/blob/v1.15.2/pkg/agent/plugin/workloadattestor/k8s/k8s.go
[extract-src]: https://github.com/spiffe/spire/blob/v1.15.2/pkg/common/containerinfo/extract.go
[qs-daemonset]: https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/agent-daemonset.yaml
[qs-rbac]: https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/agent-cluster-role.yaml
[qs-configmap]: https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/agent-configmap.yaml
[kubelet-authn]: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
[kubeadm-certs]: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/#kubelet-serving-certs
[kubelet-types]: https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/kubelet/config/v1beta1/types.go
[kind-design]: https://kind.sigs.k8s.io/docs/design/initial/
[helm-ds]: https://github.com/spiffe/helm-charts-hardened/blob/main/charts/spire/charts/spire-agent/templates/daemonset.yaml
