# SPIRE Lab Toolchain Pins

Research date: **2026-08-08**. Every claim below is verified against a primary source
(spiffe.io, the `spiffe/spire` repo at tag `v1.15.2`, the `spiffe/go-spiffe` repo at tag
`v2.8.1`, official distro package databases) or by running the pinned binaries locally.

Lab target: trust domain `lab.local`, `join_token` node attestation, `unix` workload
attestor, agent socket `/run/spire/agent.sock`, Docker-based, Go workloads, four fixed-UID
users 10001-10004.

## Pinned versions

| Thing | Pin | Source |
|---|---|---|
| SPIRE | `v1.15.2` (released 2026-07-09) | <https://github.com/spiffe/spire/releases/tag/v1.15.2> |
| SPIRE container images | `ghcr.io/spiffe/spire-server:1.15.2`, `ghcr.io/spiffe/spire-agent:1.15.2` (no `v` prefix) | <https://spiffe.io/downloads/> |
| SPIRE release tarball | `spire-1.15.2-linux-amd64-musl.tar.gz` (static binaries) | <https://github.com/spiffe/spire/releases/download/v1.15.2/spire-1.15.2-linux-amd64-musl.tar.gz> |
| go-spiffe | `v2.8.1` (released 2026-06-19), module `github.com/spiffe/go-spiffe/v2` | <https://github.com/spiffe/go-spiffe/releases/tag/v2.8.1> |
| Go toolchain for the lab workloads | `1.26.4` (SPIRE's own pin; go-spiffe alone only needs `1.24.0`) | <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/.go-version> |
| Lab "node" base image | `debian:bookworm-slim` (Debian 12.15) | verified locally, see §3 |

Verified locally:

```
$ sha256sum spire-1.15.2-linux-amd64-musl.tar.gz
3874d07ffeb6640bafb9fe6a538de06151f155d5ed2f8e8a51f138d2f51b8105   # matches published sha256sum.txt
$ file spire-1.15.2/bin/spire-server
ELF 64-bit LSB executable, x86-64, statically linked, Go BuildID=..., stripped
$ docker run --rm -v .../bin:/b:ro debian:bookworm-slim /b/spire-server --version
1.15.2
```

---

## 1. Latest stable SPIRE release and how to get binaries/images

**`v1.15.2`**, published 2026-07-09. It is the newest non-prerelease; the five most recent
releases are `v1.15.2` (2026-07-09), `v1.15.1` (2026-05-28), `v1.14.7` (2026-05-28),
`v1.15.0` (2026-05-19), `v1.14.6` (2026-04-27), all `prerelease: false`.

### Release tarballs

The only Linux artifacts are **musl** builds — there is no glibc tarball:

```
spire-1.15.2-linux-amd64-musl.tar.gz          + _sha256sum.txt
spire-1.15.2-linux-arm64-musl.tar.gz          + _sha256sum.txt
spire-1.15.2-windows-amd64.zip                + _sha256sum.txt
spire-extras-1.15.2-linux-{amd64,arm64}-musl.tar.gz   (oidc-discovery-provider etc.)
```

**"musl" in the filename does not mean the binaries need musl at runtime.** The release
workflow runs `make build-static` and then asserts `xx-verify --static` on every binary, so
they are fully statically linked and run unmodified on a glibc distro. I confirmed this two
ways: `file` reports `statically linked`, and `spire-server --version` prints `1.15.2` when
the tarball binary is bind-mounted into `debian:bookworm-slim`. This is what makes the
Debian base image in §3 workable.

The tarball also ships `conf/server/server.conf` and `conf/agent/agent.conf` — upstream's own
minimal working configs, quoted in §4.

### Container images

`ghcr.io/spiffe/spire-server:<version>` and `ghcr.io/spiffe/spire-agent:<version>`, plus
`ghcr.io/spiffe/oidc-discovery-provider`. The push script strips the `v`, so the tag is
**`1.15.2`, not `v1.15.2`**:

```bash
version="${version#refs/tags/v}"; version="${version#v}"
OCI_IMAGES=( spire-server spire-agent oidc-discovery-provider )
registry=ghcr.io/${org_name}      # org_name defaults to "spiffe"
```

Images are signed with `cosign sign -y "${registry}/${img}@${image_digest}"`.

**The images are `scratch`-based, not distroless.** From the release `Dockerfile`:

```dockerfile
FROM --platform=${BUILDPLATFORM} scratch AS spire-base
COPY --link --from=builder --chown=root:root --chmod=755 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
WORKDIR /opt/spire

FROM spire-base AS spire-server
ARG spireuid=1000
ARG spiregid=1000
USER ${spireuid}:${spiregid}
ENTRYPOINT ["/opt/spire/bin/spire-server", "run"]

FROM spire-base AS spire-agent
ARG spireuid=0
ARG spiregid=0
USER ${spireuid}:${spiregid}
ENTRYPOINT ["/opt/spire/bin/spire-agent", "run"]
```

Verified against the pulled images:

| Image | User | Entrypoint | WorkingDir | Size |
|---|---|---|---|---|
| `ghcr.io/spiffe/spire-server:1.15.2` | `1000:1000` | `["/opt/spire/bin/spire-server","run"]` | `/opt/spire` | 212 MB |
| `ghcr.io/spiffe/spire-agent:1.15.2` | `0:0` | `["/opt/spire/bin/spire-agent","run"]` | `/opt/spire` | 88.6 MB |

`docker run --entrypoint /bin/sh ghcr.io/spiffe/spire-agent:1.15.2` fails — there is **no
shell, no `useradd`, no `setpriv`** in these images. That is the decisive constraint for §3:
the lab's node container cannot be the official agent image.

Note the agent image deliberately defaults to **root** ("The SPIRE Agent image runs as root
by default to facilitate the sharing of the agent socket in Kubernetes environments"), while
the server image runs as UID 1000.

Source URLs:

- <https://api.github.com/repos/spiffe/spire/releases/latest>
- <https://github.com/spiffe/spire/releases/tag/v1.15.2>
- <https://spiffe.io/downloads/>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/Dockerfile>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/.github/workflows/scripts/push-images.sh>

---

## 2. go-spiffe version and Go toolchain

Latest go-spiffe release is **`v2.8.1`** (2026-06-19). Recent tags: `v2.8.1`, `v2.8.0`
(2026-06-16), `v2.7.0` (2026-06-03), `v2.6.0` (2025-08-21), `v2.5.0` (2025-01-31).

**Repo layout gotcha:** at `v2.8.1` the `v2` module lives at the **repository root**, not in a
`v2/` subdirectory. `https://raw.githubusercontent.com/spiffe/go-spiffe/v2.8.1/v2/go.mod`
returns 404; the real file is at `.../v2.8.1/go.mod`.

`go.mod` at `v2.8.1`:

```go
module github.com/spiffe/go-spiffe/v2

go 1.24.0

require (
	github.com/Microsoft/go-winio v0.6.2
	github.com/go-jose/go-jose/v4 v4.1.4
	github.com/stretchr/testify v1.11.1
	google.golang.org/grpc v1.79.3
	google.golang.org/grpc/examples v0.0.0-20250407062114-b368379ef8f6
	google.golang.org/protobuf v1.36.11
)
```

No `toolchain` directive. Minimum Go for go-spiffe alone: **1.24.0**.

SPIRE `v1.15.2` `go.mod` requires **`go 1.26.4`** (no `toolchain` directive), and
`.go-version` at the same tag is `1.26.4`. SPIRE depends on `github.com/spiffe/go-spiffe/v2
v2.8.1` — the same version pinned above, so the lab workloads and SPIRE agree.

Recommendation: build the lab's Go workloads with **Go 1.26.4** (`golang:1.26.4` builder
stage) to match SPIRE exactly, even though go-spiffe alone would accept 1.24.

Source URLs:

- <https://api.github.com/repos/spiffe/go-spiffe/releases/latest>
- <https://raw.githubusercontent.com/spiffe/go-spiffe/v2.8.1/go.mod>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/go.mod>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/.go-version>

---

## 3. Base image for the lab "node" container

### Recommendation: `debian:bookworm-slim`

It is the only candidate that satisfies all three lab requirements with **zero extra
packages installed**. Verified by running each image:

| Tool | `debian:bookworm-slim` (12.15) | `debian:trixie-slim` (13) | `alpine:3.22` | `ubuntu:24.04` |
|---|---|---|---|---|
| `setpriv` | `/usr/bin/setpriv` (util-linux 2.38.1) | `/usr/bin/setpriv` | `/bin/setpriv` (**BusyBox**) | `/usr/bin/setpriv` |
| `useradd` | `/usr/sbin/useradd` | `/usr/sbin/useradd` | **missing** | `/usr/sbin/useradd` |
| `groupadd` | `/usr/sbin/groupadd` | `/usr/sbin/groupadd` | **missing** | `/usr/sbin/groupadd` |
| `adduser` | missing (Debian's is a Perl wrapper, not installed in slim) | missing | `/usr/sbin/adduser` (BusyBox) | missing |
| `su` / `runuser` | both present | present | `su` (BusyBox) | present |
| `su-exec` | n/a | n/a | `apk add su-exec` (Alpine **main** repo) | n/a |

**Why not Alpine.** Alpine ships `setpriv` but it is the **BusyBox applet**, which does not
implement `--reuid` / `--regid` / `--init-groups`:

```
$ docker run --rm alpine:3.22 setpriv --help
BusyBox v1.37.0 multi-call binary.
Usage: setpriv [OPTIONS] PROG ARGS
  -d,--dump  --nnp,--no-new-privs  --inh-caps CAP,CAP  --ambient-caps CAP,CAP
```

So Alpine needs `apk add su-exec` (or `util-linux-misc` for the real `setpriv`) **and**
`shadow` for `useradd`/`groupadd`, because BusyBox `adduser` has different flags. That is
two extra packages plus a different UID-provisioning syntax, for no benefit — the SPIRE
binaries are static, so Alpine's small libc buys nothing.

**Why not Ubuntu.** Functionally identical to Debian for this lab; Debian slim is smaller and
the SPIRE build stage already uses Debian-family conventions. Either works — pick one and
stop thinking about it.

**bookworm vs trixie.** Both have everything needed. `bookworm-slim` is the conservative
pick; nothing in the lab depends on trixie. If you prefer tracking Debian stable, `trixie-slim`
is a drop-in substitution.

### Verified provisioning pattern

This exact sequence was run inside `debian:bookworm-slim` and succeeded:

```dockerfile
FROM debian:bookworm-slim

# Fixed-UID lab users. No home dir, no login shell.
RUN set -eux; \
    for u in alice:10001 bob:10002 carol:10003 dave:10004; do \
      name="${u%%:*}"; uid="${u##*:}"; \
      groupadd -g "$uid" "$name"; \
      useradd -u "$uid" -g "$uid" -M -s /usr/sbin/nologin "$name"; \
    done

# Static SPIRE binaries from the official release tarball (see §1).
COPY --from=spire-dl /spire-1.15.2/bin/spire-agent /usr/local/bin/
```

Dropping to a lab user at runtime:

```bash
setpriv --reuid=10001 --regid=10001 --init-groups --inh-caps=-all -- /usr/local/bin/workload
# -> uid=10001(alice) gid=10001(alice) groups=10001(alice)
```

`--init-groups` is what makes the `unix` workload attestor see the right supplementary
groups; `--inh-caps=-all` drops inheritable capabilities. Both flags are util-linux-only,
which is the concrete reason Alpine's BusyBox `setpriv` is not a substitute.

Debian package provenance (`util-linux` provides `/usr/bin/setpriv`; `passwd` provides
`useradd` and `groupadd`) confirmed against packages.debian.org file lists for bookworm and
trixie.

Source URLs:

- <https://hub.docker.com/_/debian>
- <https://hub.docker.com/_/alpine>
- <https://hub.docker.com/_/ubuntu>
- <https://packages.debian.org/bookworm/amd64/util-linux/filelist>
- <https://packages.debian.org/bookworm/amd64/passwd/filelist>
- <https://packages.debian.org/trixie/amd64/util-linux/filelist>
- <https://pkgs.alpinelinux.org/packages?name=su-exec&branch=v3.22&arch=x86_64>

---

## 4. Minimal valid `server.conf` and `agent.conf`

Both files below were checked with the pinned binaries:

```
$ spire-server validate -config server.conf
SPIRE server configuration file is valid.
$ spire-agent validate -config agent.conf
SPIRE agent configuration file is valid.
```

and then actually run end-to-end (server up, agent attested via join token, workload SVID
issued to `unix:uid:1000`).

### `server.conf`

```hcl
server {
    trust_domain          = "lab.local"
    bind_address          = "0.0.0.0"
    bind_port             = "8081"
    socket_path           = "/run/spire/server/private/api.sock"
    data_dir              = "/opt/spire/data/server"
    log_level             = "DEBUG"
    ca_ttl                = "24h"
    default_x509_svid_ttl = "1h"
    default_jwt_svid_ttl  = "5m"
}

plugins {
    DataStore "sql" {
        plugin_data {
            database_type     = "sqlite3"
            connection_string = "/opt/spire/data/server/datastore.sqlite3"
        }
    }

    KeyManager "disk" {
        plugin_data {
            keys_path = "/opt/spire/data/server/keys.json"
        }
    }

    NodeAttestor "join_token" {
        plugin_data {}
    }
}
```

### `agent.conf`

```hcl
agent {
    trust_domain      = "lab.local"
    server_address    = "spire-server"
    server_port       = 8081
    socket_path       = "/run/spire/agent.sock"
    data_dir          = "/opt/spire/data/agent"
    log_level         = "DEBUG"
    trust_bundle_path = "/opt/spire/conf/agent/bootstrap.crt"
}

plugins {
    KeyManager "disk" {
        plugin_data {
            directory = "/opt/spire/data/agent"
        }
    }

    NodeAttestor "join_token" {
        plugin_data {}
    }

    WorkloadAttestor "unix" {
        plugin_data {}
    }
}
```

### Notes on required vs. defaulted fields

- **Required with no default:** server `trust_domain` and `data_dir`; agent `trust_domain`,
  `server_address`, `server_port`, and exactly one bootstrap source (see below).
- **Defaults you can omit:** `bind_address` = `0.0.0.0`, `bind_port` = `8081`,
  server `socket_path` = `/tmp/spire-server/private/api.sock`, agent `socket_path` =
  `/tmp/spire-agent/public/api.sock`, agent `data_dir` = `$PWD`, `log_level` = `INFO`.
  The lab overrides the agent socket to `/run/spire/agent.sock` as specified.
- **`ca_ttl`** defaults to `24h`; **`default_x509_svid_ttl`** to `1h`;
  **`default_jwt_svid_ttl`** to `5m`. None are required, but see §7 — `ca_ttl` and
  `default_x509_svid_ttl` are coupled and the server warns if you get the ratio wrong.
- **Plugin block syntax** is `pluginType "pluginName" { plugin_data { ... } }`.
  `plugin_data {}` (empty) is valid and is what upstream uses for `join_token`. The
  `unix` WorkloadAttestor accepts a fully empty body too — upstream's own plugin doc shows
  `WorkloadAttestor "unix" { }`.
- **KeyManager choices.** Server: `disk` (`keys_path`, a *file*) or `memory`. Agent: `disk`
  (`directory`, a *directory*) or `memory`. Note the asymmetry — the server key manager takes
  a file path and the agent's takes a directory. Use `disk` on both so restarts don't force
  re-attestation; `memory` on the agent means "must re-attest after restarts", which burns a
  one-time-use join token every restart.

### How the agent gets the trust bundle

Exactly one of three options may be set:

1. `trust_bundle_path` — read a PEM bundle from a file you copied in beforehand.
2. `trust_bundle_url` — fetch over `https://` (system trust store verifies the server), or
   over `http://` if `trust_bundle_unix_socket` is also set.
3. `insecure_bootstrap = true` — connect without authenticating the server. Upstream's own
   words: "This is not a secure configuration, because a man-in-the-middle attacker could
   control the SPIRE infrastructure. It is included because it is a useful option for
   testing and development."

For the lab, prefer option 1 and produce the file from the running server:

```bash
spire-server bundle show -socketPath /run/spire/server/private/api.sock > bootstrap.crt
# 749 bytes of PEM, verified
# -format spiffe emits a JWKS document instead; -format pem is the default
```

`insecure_bootstrap = true` is a legitimate shortcut if you want the compose file to have no
ordering dependency, and it is exactly what the shipped `conf/agent/agent.conf` does. Using
the real bundle is one extra step and teaches the correct habit.

### Upstream's shipped configs, for reference

`conf/server/server.conf` from the release tarball:

```hcl
server {
    bind_address = "127.0.0.1"
    bind_port = "8081"
    trust_domain = "example.org"
    data_dir = "./data/server"
    log_level = "DEBUG"
    ca_ttl = "168h"
    default_x509_svid_ttl = "48h"
}
plugins {
    DataStore "sql" {
        plugin_data {
            database_type = "sqlite3"
            connection_string = "./data/server/datastore.sqlite3"
        }
    }
    KeyManager "disk" { plugin_data { keys_path = "./data/server/keys.json" } }
    NodeAttestor "join_token" { plugin_data {} }
}
```

Heads-up: this shipped default (`ca_ttl = 168h`, `default_x509_svid_ttl = 48h`) actually
violates the `ca_ttl >= 6 x svid_ttl` rule from §7 and makes the server log a warning at
startup. Don't copy those two numbers.

Source URLs:

- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/spire_server.md>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/spire_agent.md>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/plugin_agent_workloadattestor_unix.md>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/plugin_agent_keymanager_disk.md>
- <https://github.com/spiffe/spire/releases/download/v1.15.2/spire-1.15.2-linux-amd64-musl.tar.gz> (ships `conf/server/server.conf`, `conf/agent/agent.conf`)

---

## 5. Join-token flow and healthchecks

### `spire-server token generate`

| Flag | Meaning | Default |
|---|---|---|
| `-socketPath` | Path to the SPIRE Server API socket | `/tmp/spire-server/private/api.sock` |
| `-spiffeID` | Additional SPIFFE ID to assign the token owner (optional) | |
| `-ttl` | **Token** TTL in seconds (how long the token stays redeemable — not the SVID TTL) | `600` |

Also accepts `-output <pretty|json>` and `-instance`, neither of which is in the doc table at
this tag.

The server derives the agent's SPIFFE ID from the token:
`spiffe://<trust_domain>/spire/agent/join_token/<token>`. The optional `-spiffeID` only adds a
human-readable alias entry.

**Scripting gotcha, verified:** without `-spiffeID`, the command writes
`Warning: Missing SPIFFE ID.` to **stdout**, not stderr, immediately after the token line:

```
$ spire-server token generate -socketPath ... -ttl 600 2>/dev/null
Token: 7d9aed8c-b33f-452b-bd53-8f5a3ab9a513
Warning: Missing SPIFFE ID.
$ spire-server token generate -socketPath ... -ttl 600 2>&1 >/dev/null
        # (stderr is empty)
```

A naive `TOKEN=$(spire-server token generate ... | sed 's/^Token: //')` swallows the warning
line into `$TOKEN` and every later command fails with
`path segment characters are limited to letters, numbers, dots, dashes, and underscores`.
Extract the token robustly:

```bash
TOKEN=$(spire-server token generate -socketPath "$SOCK" -ttl 600 \
          -spiffeID "spiffe://lab.local/node/lab" | awk '/^Token:/{print $2}')
```

Or use JSON, which has no such wart:

```bash
$ spire-server token generate -socketPath "$SOCK" -ttl 600 -output json
{"expires_at":"1786167677","value":"d94b6c17-4806-445a-b324-e63ff395142a"}
```

### Agent consuming the token

Two equivalent ways — the token is *not* configured in the plugin block:

```bash
spire-agent run -config /opt/spire/conf/agent/agent.conf -joinToken "$TOKEN"
# or -joinTokenFile /run/secrets/join_token
```

or in the `agent { }` body: `join_token = "..."` / `join_token_file = "..."`.

Upstream states the special case explicitly: "As a special case for node attestors, the join
token itself is configured by a CLI flag (`-joinToken`) or by configuring `join_token` in the
agent's main config body." The `NodeAttestor "join_token" { plugin_data {} }` block stays
empty on both sides — the server-side plugin "has no configuration options".

Tokens are one-time-use. If the agent's key material is lost (e.g. `KeyManager "memory"`,
or a wiped `data_dir`), it must re-attest and needs a **fresh** token.

### Healthchecks

```bash
spire-server healthcheck -socketPath /run/spire/server/private/api.sock
# -> "Server is healthy."   exit 0

spire-agent  healthcheck -socketPath /run/spire/agent.sock
# -> "Agent is healthy."    exit 0
```

Both accept `-shallow` (less stringent) and `-verbose`. Both exit non-zero when unhealthy —
verified: a stopped server yields `Error: server is unhealthy: unable to determine health`
with exit 1. These are the right Docker `HEALTHCHECK` commands.

There is also an optional HTTP health endpoint if you prefer that over exec probes:

```hcl
health_checks {
        listener_enabled = true
        bind_address = "localhost"
        bind_port = "8080"
        live_path = "/live"
        ready_path = "/ready"
}
```

Source URLs:

- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/spire_server.md> (`token generate`, `healthcheck`, `health_checks`)
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/spire_agent.md> (`spire-agent run` flags, `healthcheck`)
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/plugin_agent_nodeattestor_jointoken.md>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/plugin_server_nodeattestor_jointoken.md>

---

## 6. Idempotent create-or-skip for registration entries

### What actually happens on a duplicate

**The datastore is already idempotent; the CLI is not.** `BatchCreateEntry` calls
`CreateOrReturnRegistrationEntry`, documented in the source as:

```go
// CreateOrReturnRegistrationEntry stores the given registration entry. If an
// entry already exists with the same (parentID, spiffeID, selector) tuple,
// that entry is returned instead.
```

and the API layer maps that to:

```go
case existing:
    resultStatus = commonapi.CreateStatus(codes.AlreadyExists, "similar entry already exists")
```

The dedup key is the exact `(parentID, spiffeID, selector-set)` tuple — `lookupSimilarEntry`
does an `Exact` selector match and then filters out superset matches.

The CLI turns any non-OK per-entry result into a process-level failure. Verified:

```
$ spire-server entry create -parentID ... -spiffeID ... -selector unix:uid:10001 -x509SVIDTTL 120
Entry ID  : d06abff1-46e8-4727-b321-387dac400947
...
exit=0

$ spire-server entry create   # identical arguments, second time
Failed to create the following entry (code: AlreadyExists, msg: "similar entry already exists"):
Entry ID  : (none)
SPIFFE ID : spiffe://lab.local/workload/alice
...
Error: failed to create one or more entries
exit=1

$ spire-server entry count
2 registration entries     # no duplicate was created
```

So: **no duplicate row, but exit code 1 and output on stderr.** With `set -e` in an entrypoint
script this kills your container on the second start.

### Recommended pattern

`entry show` filters cleanly and returns exit 0 with `Found 0 entries` when nothing matches,
so guard on it:

```bash
ensure_entry() {
  local parent="$1" spiffe_id="$2" selector="$3" ttl="$4"
  if spire-server entry show -socketPath "$SOCK" \
       -parentID "$parent" -spiffeID "$spiffe_id" -selector "$selector" \
       -output json | grep -q '"entries":\[\]'; then
    spire-server entry create -socketPath "$SOCK" \
      -parentID "$parent" -spiffeID "$spiffe_id" -selector "$selector" \
      -x509SVIDTTL "$ttl"
  else
    echo "entry $spiffe_id already present, skipping"
  fi
}
```

Verified behaviour of the guard:

```
$ spire-server entry show -selector unix:uid:19999 -output json
{"entries":[],"next_page_token":""}
exit=0
$ spire-server entry show -selector unix:uid:10001
Found 1 entry
...
exit=0
```

If you would rather not parse output, the blunt alternative is equally correct because the
datastore protects you:

```bash
spire-server entry create ... || true    # AlreadyExists is benign; no duplicate is written
```

The downside is that it also swallows real errors (bad SPIFFE ID, server unreachable). Use
the `entry show` guard for the lab — it is explicit and its output is readable when a student
runs the script twice.

`entry show` filter flags at this tag: `-entryID`, `-parentID`, `-spiffeID`, `-selector`
(repeatable), `-downstream`, `-federatesWith`, `-socketPath`, plus an undocumented
`-output <pretty|json>`.

### On `-hint`

`spire-server entry create` **does** have `-hint` at v1.15.2 ("The entry hint, used to
disambiguate entries with the same SPIFFE ID"), confirmed from `entry create -h`. It is
**not** an upsert key and does not affect idempotency — `lookupSimilarEntry` ignores it.
Note that `-hint` is missing from the `doc/spire_server.md` flag table at this tag, along with
`-instance`, `-output`, and `-jwtSVIDIncludeJTI`; the doc table is incomplete. Trust
`entry create -h` over the markdown.

Source URLs:

- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/spire_server.md> (`entry create`, `entry show`, `entry count`, `entry delete`)
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/pkg/server/api/entry/v1/service.go>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/pkg/server/datastore/sqlstore/sqlstore.go>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/cmd/spire-server/util/util.go> (exit code 1 on error)

---

## 7. Short-TTL X509-SVID rotation demo

### Config knob names at v1.15.2

Server config (`server { }`):

| Knob | Default | Source constant |
|---|---|---|
| `default_x509_svid_ttl` | `1h` | `credtemplate.DefaultX509SVIDTTL = time.Hour` |
| `default_jwt_svid_ttl` | `5m` | `credtemplate.DefaultJWTSVIDTTL = 5 * time.Minute` |
| `ca_ttl` | `24h` | `credtemplate.DefaultX509CATTL = 24 * time.Hour` |
| `agent_ttl` | value of `default_x509_svid_ttl` | |

Per-entry flags on `spire-server entry create` / `entry update`:

- `-x509SVIDTTL <seconds>` — overrides `default_x509_svid_ttl` for that entry
- `-jwtSVIDTTL <seconds>` — overrides `default_jwt_svid_ttl` for that entry

**There is no deprecated `-ttl` on `entry create` at this release.** The full flag list from
`entry create -h` is `-admin -data -disableX509SVIDPrefetch -dns -downstream -entryExpiry
-entryID -federatesWith -hint -instance -jwtSVIDIncludeJTI -jwtSVIDTTL -node -output
-parentID -selector -socketPath -spiffeID -storeSVID -x509SVIDTTL`. (`-ttl` *does* still
exist on `token generate`, where it means the join token's redemption window — different
thing, easy to confuse.)

### The `ca_ttl` constraint: `ca_ttl >= 6 x svid_ttl`

From `pkg/server/ca/manager/manager.go`:

```go
sevenDays                  = 7 * 24 * time.Hour
activationThresholdCap     = sevenDays
activationThresholdDivisor = 6

func MaxSVIDTTL() time.Duration { return activationThresholdCap }               // 168h hard cap
func MaxSVIDTTLForCATTL(caTTL time.Duration) time.Duration {
	return min(caTTL/activationThresholdDivisor, activationThresholdCap)
}
func MinCATTLForSVIDTTL(svidTTL time.Duration) time.Duration {
	return svidTTL * activationThresholdDivisor
}
```

So an SVID TTL is "guaranteed not to be cut artificially short by a scheduled CA rotation"
only when `svid_ttl <= ca_ttl / 6`, with an absolute ceiling of 7 days.

Getting it wrong is a **warning, not an error** — `spire-server validate` still reports the
file as valid, and the warning only appears in the server's startup log. Captured verbatim
with `ca_ttl = "5m"`, `default_x509_svid_ttl = "2m"`:

```
level=warning msg="default_x509_svid_ttl is too high for the configured ca_ttl value.
SVIDs with shorter lifetimes may be issued. Please set default_x509_svid_ttl to 50s or
less, or the ca_ttl to 12m or more, to guarantee the full default_x509_svid_ttl lifetime
when CA rotations are scheduled."
```

Practical lab settings for a fast demo — keep `ca_ttl` well above `6 x` the SVID TTL so the
log stays clean and the demo isolates SVID rotation from CA rotation:

```hcl
server {
    ca_ttl                = "24h"   # >> 6 x 2m
    default_x509_svid_ttl = "2m"
    default_jwt_svid_ttl  = "1m"
}
```

### Agent-side rotation: half of lifetime, +/- 10% jitter

Documented for the `availability_target` case and implemented as the general default. From
`doc/spire_agent.md`: "To guarantee the `availability_target`, grace period (`SVID lifetime -
availability_target`) must be at least 12h. If not satisfied, the agent will rotate the SVID
by the **default rotation strategy (1/2 of lifetime)**."

`pkg/common/rotationutil/rotationutil.go` makes the jitter explicit:

```go
func halfLife(lifetime time.Duration) time.Duration { return lifetime / 2 }
func jitterHalfLifeDelta(halfLife time.Duration) time.Duration { return halfLife / 10 }

// jitter is +/- 10% of the half-life, to spread out renewals
func calculateJitteredHalfLife(lifetime time.Duration) time.Duration { ... }

func shouldRotateByHalf(ttl, lifetime time.Duration) bool {
	return ttl <= calculateJitteredHalfLife(lifetime)
}
```

`availability_target` is the only knob that changes this. If set it must be `>= 24h`, and it
only takes effect when `SVID lifetime - availability_target >= 12h` — otherwise the agent
logs "X509 SVID lifetime isn't long enough to guarantee the availability_target, falling back
to the default rotation strategy". **For a short-TTL lab demo, leave `availability_target`
unset**; at 2-minute TTLs it can never apply.

### Two behaviours the demo must account for

**(a) Certificate lifetime is TTL + 10s.** `credtemplate.NotBeforeCushion = 10 * time.Second`
backdates `notBefore` for clock skew. A `-x509SVIDTTL 120` entry produces a cert valid for
130 seconds, so the half-life trigger is computed on 130s, not 120s.

**(b) Rotation is only proactive for entries with an active Workload API subscriber.** A
one-shot `spire-agent api fetch x509` does not keep the SVID hot; the agent renews lazily and
you will see the cert change only near expiry. With a long-lived subscriber it renews on
schedule. Measured with `default_x509_svid_ttl = 2m` and a live `spire-agent api watch`:

```
Received 1 svid after  6.0s   valid 05:34:42 -> 05:36:52   (130s lifetime)
Received 1 svid after 53.2s   valid 05:35:37 -> 05:37:47
Received 1 svid after 56.0s   valid 05:36:33 -> 05:38:43
Received 1 svid after 58.7s   valid 05:37:32 -> 05:39:42
Received 1 svid after 55.2s   valid 05:38:27 -> 05:40:37
```

Renewal every 53-59s against a 130s lifetime — exactly half-life-minus-jitter. Contrast with
the same setup polled by one-shot `api fetch`, where the SVID survived ~119s of its 130s
lifetime before being replaced.

So the lab's Go workload should hold an open `workloadapi.X509Source` (which streams
`FetchX509SVID`) rather than calling fetch in a loop — that is both the realistic pattern and
the one that demonstrates rotation on a predictable schedule. Watch it live with:

```bash
spire-agent api watch -socketPath /run/spire/agent.sock
```

Source URLs:

- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/spire_server.md> (`ca_ttl`, `default_x509_svid_ttl`, `default_jwt_svid_ttl`, `agent_ttl`, `entry create` TTL flags)
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/doc/spire_agent.md#availability-target>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/pkg/server/ca/manager/manager.go>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/pkg/common/rotationutil/rotationutil.go>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/pkg/server/credtemplate/builder.go>
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/cmd/spire-server/cli/run/run.go> (ca_ttl warning text)
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/pkg/agent/manager/sync.go>
