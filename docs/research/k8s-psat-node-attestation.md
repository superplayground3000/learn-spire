# Research: k8s_psat node attestation and the parent ID story

Issue: #27. Target: SPIRE 1.15.2, kind, trust domain `lab.local`.

Lab 2 attests the agent with a one-time `join_token`. Lab 3 runs on
Kubernetes and attests the agent with `k8s_psat`. The agent mounts a
projected service account token (PSAT). The server validates that token
with the Kubernetes TokenReview API. This document lists what changes.

## 1. Server plugin configuration

Lab 2 → Lab 3: `NodeAttestor "join_token" { plugin_data {} }` becomes a
`NodeAttestor "k8s_psat"` block with a `clusters` map.

The v1.15.2 server plugin has these options
([source](https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_server_nodeattestor_k8s_psat.md)):

- `clusters`: a map of authorized clusters. The key is a cluster name
  that the operator chooses. Each value is a block with the options
  below.
- `service_account_allow_list`: required, per cluster. A list of
  allowed service accounts, in the form `<namespace>:<service-account>`.
  Example: `["spire:spire-agent"]`.
- `audience`: the audience the token must carry. The default is
  `["spire-server"]`.
- `kube_config_file`: a kubeconfig path for out-of-cluster servers.
  When it is empty, the server uses the in-cluster config. The lab
  server runs in-cluster, so the lab leaves it empty.
- `allowed_node_label_keys`: node label keys that become selectors.
- `allowed_pod_label_keys`: pod label keys that become selectors.

Sample from the plugin document, adapted only in names:

```hcl
NodeAttestor "k8s_psat" {
    plugin_data {
        clusters = {
            "lab-cluster" = {
                service_account_allow_list = ["spire:spire-agent"]
            }
        }
    }
}
```

The agent plugin has two options
([source](https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_agent_nodeattestor_k8s_psat.md)):

- `cluster`: required. It must equal a key of the server's `clusters`
  map.
- `token_path`: the token file path. The default is
  `/var/run/secrets/tokens/spire-agent`.

## 2. RBAC and the projected token volume

Lab 2 → Lab 3: lab 2 needs no platform permissions. Lab 3 gives the
server Kubernetes API permissions and gives the agent a projected token.

The server plugin document requires these rules
([source](https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_server_nodeattestor_k8s_psat.md)):

```yaml
rules:
- apiGroups: [""]
  resources: ["pods", "nodes"]
  verbs: ["get"]
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
```

The quickstart binds these rules to the `spire-server` service account
with a ClusterRole named `spire-server-trust-role` and a matching
ClusterRoleBinding
([source](https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/server-cluster-role.yaml)).
TokenReview validates the PSAT. The `pods` and `nodes` reads resolve the
pod, the node name, and the node UID.

The quickstart DaemonSet declares the projected token volume like this
([source](https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/agent-daemonset.yaml)):

```yaml
volumes:
  - name: spire-token
    projected:
      sources:
      - serviceAccountToken:
          path: spire-agent
          expirationSeconds: 7200
          audience: spire-server
```

The container mounts it at the agent plugin's default path:

```yaml
volumeMounts:
  - name: spire-token
    mountPath: /var/run/secrets/tokens
```

The `audience` value must match the server's `audience` option. The
kubelet rotates the token before it expires, so no operator mints
anything. The quickstart also gives the agent a ClusterRole with `get`
on `pods`, `nodes`, and `nodes/proxy`
([source](https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/agent-cluster-role.yaml)).
That role serves the `k8s` workload attestor, not node attestation.

## 3. The agent SPIFFE ID after PSAT attestation

Lab 2 → Lab 3: `spiffe://lab.local/spire/agent/join_token/<token>`
becomes `spiffe://lab.local/spire/agent/k8s_psat/<cluster>/<node-uid>`.

The server plugin document gives the shape
([source](https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_server_nodeattestor_k8s_psat.md)):

```
spiffe://<trust_domain>/spire/agent/k8s_psat/<cluster>/<node_UID>
```

For the lab: `spiffe://lab.local/spire/agent/k8s_psat/lab-cluster/<node-uid>`.
The node UID is stable while the kind node exists. If you delete and
recreate the kind cluster, the UID changes. The join-token ID changed on
every join; the PSAT ID only changes with the node.

The plugin also emits selectors for the attested agent: `k8s_psat:cluster`,
`k8s_psat:agent_ns`, `k8s_psat:agent_sa`, `k8s_psat:agent_pod_name`,
`k8s_psat:agent_pod_uid`, `k8s_psat:agent_node_ip`,
`k8s_psat:agent_node_name`, `k8s_psat:agent_node_uid`, and the two
label selectors.

## 4. The parent ID story for workload entries

Lab 2 → Lab 3: the alias `spiffe://lab.local/node` stays. Only the way
the lab creates it changes.

Two parent ID options exist:

- (a) Direct agent ID. Workload entries name
  `spiffe://lab.local/spire/agent/k8s_psat/lab-cluster/<node-uid>` as
  parent. This couples every entry to one node UID. A cluster rebuild
  breaks every entry. The lab rejects this option.
- (b) A node alias. One node registration entry maps an alias ID to all
  agents that match its selectors. Workload entries name the alias as
  parent. This is what the labs already do, and what the quickstart does
  ([source](https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/create-node-registration-entry.sh)).

In lab 2, `spire-server token generate -spiffeID spiffe://lab.local/node`
creates the alias implicitly. The alias binds to one token, so
`bootstrap.sh` recreates it on every join. In lab 3, one explicit node
entry replaces that step. The `-node` flag marks the entry as a node
entry: "If set, this entry will be applied to matching nodes rather than
workloads"
([source](https://github.com/spiffe/spire/blob/v1.15.2/doc/spire_server.md)).

The lab command:

```sh
spire-server entry create -node \
    -spiffeID spiffe://lab.local/node \
    -selector k8s_psat:cluster:lab-cluster \
    -selector k8s_psat:agent_ns:spire \
    -selector k8s_psat:agent_sa:spire-agent
```

The `k8s_psat:cluster:lab-cluster` selector alone is sufficient on a
single-node kind cluster. The two extra selectors follow the quickstart
and pin the alias to the agent's namespace and service account. An agent
receives the alias when its selectors are a superset of the entry's
selectors. The entry is created once and survives agent restarts, node
re-attestation, and cluster rebuilds. Workload entries keep
`-parentID spiffe://lab.local/node` unchanged from lab 2.

## 5. Trust bundle bootstrap

Lab 2 → Lab 3: the `bootstrap.sh` copy step
(`spire-server bundle show | tee bootstrap.crt`) becomes a ConfigMap
that the server maintains and the agent mounts.

The quickstart does not use `insecure_bootstrap`. It uses the
`k8sbundle` Notifier plugin on the server
([source](https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/server-configmap.yaml)):

```hcl
Notifier "k8sbundle" {
    plugin_data {}
}
```

The plugin pushes the root CA certificates to a ConfigMap on every
bundle load or update
([source](https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_server_notifier_k8sbundle.md)).
The defaults are: `namespace = "spire"`, `config_map = "spire-bundle"`,
`config_map_key = "bundle.crt"`. The empty ConfigMap must exist first;
the quickstart ships it as a manifest
([source](https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/spire-bundle-configmap.yaml)).
The notifier needs a namespace-scoped Role on `configmaps` with `get`
and `patch` (the quickstart grants `patch`, `get`, `list`).

The agent mounts the `spire-bundle` ConfigMap and points
`trust_bundle_path` at it
([source](https://github.com/spiffe/spire-tutorials/blob/main/k8s/quickstart/agent-configmap.yaml)):

```hcl
trust_bundle_path = "/run/spire/bundle/bundle.crt"
```

The lab keeps its rule from lab 2: `insecure_bootstrap` stays off. The
trust chain moves from a script step to the Kubernetes API. Kubernetes
delivers ConfigMap updates to the mount, so CA rotation propagates
without a script.

## Recommended lab configuration

Cluster name: `lab-cluster`. Namespace: `spire`. Agent service account:
`spire-agent`.

Server `server.conf`, changed blocks only:

```hcl
plugins {
    NodeAttestor "k8s_psat" {
        plugin_data {
            clusters = {
                "lab-cluster" = {
                    service_account_allow_list = ["spire:spire-agent"]
                }
            }
        }
    }

    # Pushes the trust bundle into the "spire-bundle" ConfigMap.
    # Replaces the bootstrap.crt copy step of lab 2.
    Notifier "k8sbundle" {
        plugin_data {}
    }
}
```

Agent `agent.conf`, changed blocks only:

```hcl
agent {
    trust_bundle_path = "/run/spire/bundle/bundle.crt"
}

plugins {
    NodeAttestor "k8s_psat" {
        plugin_data {
            cluster = "lab-cluster"
        }
    }
}
```

DaemonSet excerpt for the token:

```yaml
volumes:
  - name: spire-token
    projected:
      sources:
      - serviceAccountToken:
          path: spire-agent
          expirationSeconds: 7200
          audience: spire-server
containers:
  - name: spire-agent
    volumeMounts:
      - name: spire-token
        mountPath: /var/run/secrets/tokens
```

Node alias entry, run once after the server starts:

```sh
kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create -node \
    -spiffeID spiffe://lab.local/node \
    -selector k8s_psat:cluster:lab-cluster \
    -selector k8s_psat:agent_ns:spire \
    -selector k8s_psat:agent_sa:spire-agent
```

What disappears from lab 2's `bootstrap.sh`: the token mint, the token
file handling, the bundle copy, and the "cannot re-attest" recovery
path. The PSAT is renewable, so a restarted agent attests again without
operator action.

## Sources

- <https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_server_nodeattestor_k8s_psat.md>
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_agent_nodeattestor_k8s_psat.md>
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_server_notifier_k8sbundle.md>
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/spire_server.md>
- <https://github.com/spiffe/spire-tutorials/tree/main/k8s/quickstart> —
  `server-configmap.yaml`, `agent-configmap.yaml`, `agent-daemonset.yaml`,
  `server-cluster-role.yaml`, `agent-cluster-role.yaml`,
  `spire-bundle-configmap.yaml`, `create-node-registration-entry.sh`
