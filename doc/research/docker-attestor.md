# SPIRE docker WorkloadAttestor — research notes

Target release: SPIRE v1.15.2 (the newest 1.15.x).
All facts come from the `v1.15.2` tag, unless the text says something different.

Primary sources:

- Plugin doc: <https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_agent_workloadattestor_docker.md>
- Plugin code: <https://github.com/spiffe/spire/blob/v1.15.2/pkg/agent/plugin/workloadattestor/docker/docker_posix.go>
- Container locator code: <https://github.com/spiffe/spire/blob/v1.15.2/pkg/common/containerinfo/extract.go>
- Agent reference: <https://spiffe.io/docs/latest/deploying/spire_agent/>

---

## 1. Plugin configuration and selectors

### HCL block

The plugin needs no options for a default Docker installation. Put this block in the
`plugins { }` section of `agent.conf`:

```hcl
WorkloadAttestor "docker" {
    plugin_data {
    }
}
```

Source: <https://github.com/spiffe/spire/blob/v1.15.2/doc/plugin_agent_workloadattestor_docker.md>

The official nested-SPIRE tutorial uses the same empty block. See
<https://github.com/spiffe/spire-tutorials/blob/main/docker-compose/nested-spire/root/agent/agent.conf>

### All configuration options

| Option | Description | Default |
|---|---|---|
| `docker_socket_path` | Docker daemon socket (Unix) | `unix:///var/run/docker.sock` |
| `podman_socket_path` | Rootful Podman socket (Unix) | `unix:///run/podman/podman.sock` |
| `podman_socket_path_template` | Rootless Podman socket. It must hold one `%d` UID field | `unix:///run/user/%d/podman/podman.sock` |
| `docker_version` | Docker daemon API version | unspecified |
| `container_id_cgroup_matchers` | Patterns that find container IDs in cgroup entries (Unix) | unspecified |
| `docker_host` | Docker Engine API endpoint (Windows only) | `npipe:////./pipe/docker_engine` |
| `sigstore` | Sigstore image signature options | unspecified |
| `use_new_container_locator` | Turns on the new locator with cgroups v2 support | `true` |
| `verbose_container_locator_logs` | Logs mountinfo and cgroup data | `false` |

The Go struct confirms these HCL tags: `docker_socket_path`, `container_id_cgroup_matchers`,
`use_new_container_locator`, `verbose_container_locator_logs`, `podman_socket_path`,
`podman_socket_path_template`.

Source: <https://github.com/spiffe/spire/blob/v1.15.2/pkg/agent/plugin/workloadattestor/docker/docker_posix.go>

### Standard selectors

| Selector | Example |
|---|---|
| `docker:label:<key>:<value>` | `docker:label:com.example.name:foo` |
| `docker:env:<VAR>=<value>` | `docker:env:ENVIRONMENT=prod` |
| `docker:image_id:<name>:<tag>` | `docker:image_id:envoyproxy/envoy:contrib-v1.29.1` |
| `docker:image_config_digest:sha256:<digest>` | `docker:image_config_digest:sha256:9f86d0…` |

The plugin makes one `docker:label:` selector for each container label. It makes one
`docker:env:` selector for each environment variable. The `env` selector holds the raw
`KEY=value` string. Note the different separators: `label` uses `:` between key and value,
but `env` uses `=`.

The `image_config_digest` selector is content-addressed. It stays the same across mirrored
registries.

### Sigstore selectors

If you configure the `sigstore` block, the plugin also makes these selectors:

- `docker:image-signature:verified`
- `docker:image-attestations:verified`
- `docker:image-signature-value`
- `docker:image-signature-subject`
- `docker:image-signature-issuer`
- `docker:image-signature-log-id`
- `docker:image-signature-log-index`
- `docker:image-signature-integrated-time`
- `docker:image-signature-signed-entry-timestamp`

If `ignore_tlog` is `true`, the plugin does not make the four Rekor-bundle selectors
(`-log-id`, `-log-index`, `-integrated-time`, `-signed-entry-timestamp`).

Sigstore support left experimental status in SPIRE 1.15.0.
Source: <https://github.com/spiffe/spire/releases/tag/v1.15.0>

### Registration example

```shell
spire-server entry create \
    -parentID spiffe://example.org/host \
    -spiffeID spiffe://example.org/host/foo \
    -selector docker:label:com.example.name:foo
```

You can give more than one `-selector` flag. The workload must then match all of them.

---

## 2. Container discovery

### The two-step algorithm

The agent gets the caller PID from the Unix socket peer credentials. The plugin then reads
files below `/proc/<pid>/`. The new locator does two steps:

1. It reads `/proc/<pid>/cgroup` first. The code calls this file authoritative, because
   "the kernel controls this file and a workload cannot forge it".
2. If step 1 finds no container ID, it reads `/proc/<pid>/mountinfo`. The code marks this
   source as weaker, because "mountinfo is controlled by the workload's mount namespace and
   can be crafted to impersonate another workload".

In both files the extractor walks the path segments backwards. It looks for a 64-character
hexadecimal string. That string is the container ID.

Source: <https://github.com/spiffe/spire/blob/v1.15.2/pkg/common/containerinfo/extract.go>

The cgroup-first order is new in SPIRE 1.15.2. The release notes say "Pod and container IDs
now preferably determined from cgroup file".
Source: <https://github.com/spiffe/spire/releases/tag/v1.15.2>

### What changes under cgroups v2

Under cgroups v1 the file `/proc/<pid>/cgroup` holds the container ID in the path.

Under cgroups v2 the same file often holds only `0::/`. The kernel shows the path relative to
the reader's cgroup namespace. Docker gives each container a private cgroup namespace by
default. So the container ID disappears from that file.

Source (problem statement): <https://github.com/spiffe/spire/issues/4004>

The `mountinfo` fallback solves this. The SPIRE test fixture for cgroups v2 holds only a
`mountinfo` file, and no `cgroup` file. Its single line is:

```
2356 2355 0:30 /../0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef /sys/fs/cgroup ro,nosuid,nodev,noexec,relatime - cgroup2 cgroup rw
```

The container ID sits in field 4, the mount root. The parser reads field 4 (root) and
field 9 (filesystem type).

Sources:
<https://github.com/spiffe/spire/blob/v1.15.2/pkg/common/containerinfo/testdata/docker/v2/proc/123/mountinfo>
<https://github.com/spiffe/spire/blob/v1.15.2/pkg/common/containerinfo/mountinfo.go>

### Required configuration

For plain Docker on a cgroups v2 host, you need no extra configuration. The option
`use_new_container_locator` is already `true` by default in 1.15.2.

Do not set `container_id_cgroup_matchers` for a normal Docker setup. That option turns on the
legacy code path. The legacy path reads only `/proc/<pid>/cgroup`, so it fails under
cgroups v2. Use it only for a custom cgroup layout.

Matcher syntax uses `*` wildcards and one `<id>` capture token. Patterns are not regular
expressions. Patterns must not be ambiguous. Example:

```hcl
container_id_cgroup_matchers = [
    "/docker/<id>",
    "/my.slice/*/<id>/*"
]
```

### Debugging

Set `verbose_container_locator_logs = true`. The agent then logs the cgroup and mountinfo
data that it used. Use this option first if attestation fails.

### The /proc root is not configurable

The plugin has an unexported `rootDir` field. The code sets it to `/` and the comment says
tests use it "to use a fake /proc directory instead of the real one". No HCL tag exists for
it.

This fact is load-bearing. You cannot point the plugin at a bind-mounted `/host/proc`. The
agent must see the real host `/proc` at `/proc`.

Source: <https://github.com/spiffe/spire/blob/v1.15.2/pkg/agent/plugin/workloadattestor/docker/docker_posix.go>

### Not-a-container behaviour

If the plugin finds no container ID, it returns an empty selector set. It does not return an
error. The workload then gets no `docker:` selectors.

### Rootless Docker

The doc describes rootless **Podman** in detail. The plugin reads the cgroup path, finds a
user slice such as `/user-<uid>.slice/`, and puts that UID into
`podman_socket_path_template`.

The doc says nothing about rootless **Docker**. NOT CONFIRMED: whether rootless Docker works,
and which socket path it needs.

---

## 3. Agent in a container (Docker-outside-of-Docker)

### Short answer

Yes, the agent can run in a container. It needs three things:

1. A mount of the Docker socket.
2. The host PID namespace (`pid: "host"`).
3. A shared path for the Workload API socket.

### The Docker socket

The plugin talks to the Docker daemon API to read container labels. The default endpoint is
`unix:///var/run/docker.sock`. So the agent container must mount that socket.

The official tutorial mounts the whole directory:

```yaml
volumes:
  - /var/run/:/var/run/
```

Source: <https://github.com/spiffe/spire-tutorials/blob/main/docker-compose/nested-spire/docker-compose.yaml>

The agent process must have permission to read the socket. The official agent image runs as
root by default, so this works out of the box. If you run the agent as UID 1000, you must
give that user access to the socket group.
Source: <https://github.com/spiffe/spire/blob/v1.15.2/doc/docker_images.md>

### The host PID namespace

The agent must run with `pid: "host"` in docker compose.

Reason: the agent reads `/proc/<pid>/` of the calling process. Inside its own PID namespace
the agent cannot see the workload PID, and `/proc` shows only its own processes. The
plugin's `/proc` root is hardcoded to `/`, so a bind mount cannot replace this.

Primary evidence:

- The nested-SPIRE tutorial sets `pid: "host"` on the root agent. Its comment reads "Share
  the host pid namespace so this agent can attest the nested servers".
  <https://github.com/spiffe/spire-tutorials/blob/main/docker-compose/nested-spire/docker-compose.yaml>
- A user reported the error "could not resolve caller information" with the agent and the
  workload in separate containers. Adding `pid: host` to the agent fixed it. The report also
  says the docker attestor page does not document this need.
  <https://github.com/spiffe/spire-tutorials/issues/56>

### Does the workload container also need pid: host?

The official tutorial sets `pid: "host"` on the workload containers too. Its comment reads
"Share the host pid namespace so this server can be attested by the root agent".

NOT CONFIRMED: whether the workload side is strictly necessary. No SPIRE document explains
it. In theory the host PID namespace is a parent of the container namespace, so an agent in
the host namespace should see the workload PID anyway. Safe advice: copy the tutorial and set
`pid: "host"` on both sides. Then remove it from the workload later, and test.

### Working compose skeleton (from the tutorial)

```yaml
services:
  spire-agent:
    # Share the host pid namespace so this agent can attest the workloads
    pid: "host"
    image: ghcr.io/spiffe/spire-agent:1.15.2
    depends_on: ["spire-server"]
    volumes:
      - ./sharedSocket:/opt/spire/sockets   # Workload API socket
      - ./agent:/opt/spire/conf/agent
      - /var/run/:/var/run/                 # Docker daemon socket
    command: ["-config", "/opt/spire/conf/agent/agent.conf"]

  workload:
    pid: "host"
    image: my-workload:latest
    labels:
      - org.example.name=my-workload
    depends_on: ["spire-agent"]
    volumes:
      - ./sharedSocket:/opt/spire/sockets
```

The tutorial then registers the workload with
`-selector docker:label:org.example.name:my-workload`.

### Note on `network_mode`

The tutorial does not use `network_mode: host`. The Workload API is a Unix socket, so the
containers do not need a shared network namespace.

---

## 4. Workload API socket sharing

### The supported pattern

A shared directory that holds the socket is the documented pattern. The agent binds its
socket inside that directory. Every workload container mounts the same directory.

The nested-SPIRE tutorial does exactly this. The agent config sets:

```hcl
socket_path = "/opt/spire/sockets/workload_api.sock"
```

The compose file mounts `./sharedRootSocket:/opt/spire/sockets` on the agent and on each
consumer.

Sources:
<https://github.com/spiffe/spire-tutorials/blob/main/docker-compose/nested-spire/root/agent/agent.conf>
<https://spiffe.io/docs/latest/architecture/nested/readme/>

Important: the tutorial uses a **host bind mount**, not a docker named volume. NOT CONFIRMED:
whether SPIRE documents a named volume anywhere. A named volume behaves the same way for a
Unix socket, because both give the containers one shared directory inode.

The agent default socket path is `/tmp/spire-agent/public/api.sock`.
Source: <https://spiffe.io/docs/latest/deploying/spire_agent/>

### Pitfalls

1. **Mount the directory, never the socket file.** If you mount the socket path itself,
   docker makes an empty file or directory before the agent starts. The agent then cannot
   bind, or the workload holds a stale inode. Always mount the parent directory.

2. **Start order.** The workload can start before the agent creates the socket. The workload
   then gets "no such file or directory". `depends_on` only waits for container start, not
   for the socket. Make the workload retry its connection, or add a healthcheck.

3. **Permissions.** The agent image runs as root by default and makes a root-owned socket. A
   non-root workload may not be able to connect. The image ships `/run/spire/agent/public`
   with the right permissions for UID 1000 and GID 1000.
   Source: <https://github.com/spiffe/spire/blob/v1.15.2/doc/docker_images.md>

4. **Stale socket after restart.** A bind-mounted directory keeps the old socket file on the
   host after the agent stops. The agent removes and rebinds it at start.
   NOT CONFIRMED from a primary source.

---

## 5. Versions

| Item | Newest version | Date | Source |
|---|---|---|---|
| SPIRE | **v1.15.2** | 2026-07-09 | <https://github.com/spiffe/spire/releases> |
| go-spiffe/v2 | **v2.8.1** | 2026-06-19 | <https://github.com/spiffe/go-spiffe/releases> |
| Go | **1.26.5** (1.26 line) | 2026-07-07 | <https://go.dev/doc/devel/release> |

Notes:

- v1.15.2 is the newest SPIRE release of any line. The lab pin of 1.15.2 is already current.
- SPIRE 1.15.0 upgraded its own build to Go 1.26.3. So Go 1.26 is current and correct.
  Source: <https://github.com/spiffe/spire/releases/tag/v1.15.0>
- go-spiffe v2.8.1 came after v2.8.0 (2026-06-16) and v2.7.0 (2026-06-03). The jump from
  v2.6.0 (2025-08-21) is large. Check the changelog before you move a pin from v2.6.x.
- SPIRE 1.15.2 replaced `github.com/docker/docker` with `github.com/moby/moby` to fix CVEs.
  This is a good reason to stay on 1.15.2 or newer.
- SPIRE 1.15.1 fixed a critical `azure_imds` node attestor flaw. It does not affect this lab.
