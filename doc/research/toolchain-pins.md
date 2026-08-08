# Research: SPIRE toolchain pins for the entry lab

Resolves issue #3. Researched 2026-08-08 against primary sources only (spiffe.io, github.com/spiffe/spire, github.com/spiffe/go-spiffe). All config/CLI syntax verified against the SPIRE docs **at the pinned tag `v1.15.2`**, not `main`.

## Pinned versions

| Component | Pin | Source |
|---|---|---|
| SPIRE (server + agent) | **1.15.2** (released 2026-07-09) | <https://github.com/spiffe/spire/releases/tag/v1.15.2> |
| Container images | `ghcr.io/spiffe/spire-server:1.15.2`, `ghcr.io/spiffe/spire-agent:1.15.2` | <https://spiffe.io/downloads/> |
| `github.com/spiffe/go-spiffe/v2` | **v2.8.1** (released 2026-06-19; the exact version SPIRE 1.15.2 itself depends on) | <https://github.com/spiffe/go-spiffe/releases/tag/v2.8.1> |
| Go toolchain | **1.26.x** (SPIRE 1.15.2's `go.mod` says `go 1.26.4`; go-spiffe v2.8.1 needs only `go 1.24.0`) — use `golang:1.26` for builds | go.mod files, cited below |
| Lab node base image | **`debian:bookworm-slim`** (setpriv ships in Essential `util-linux`) | packages.debian.org, cited below |

---

## 1. Latest stable SPIRE release and how to obtain it

**SPIRE v1.15.2**, published 2026-07-09, is the latest stable release.

Two official distribution channels, both suitable for a Docker lab:

- **Release tarballs** on GitHub releases. The Linux assets are musl-based static builds, so they run on any Linux base image (glibc or musl):
  - `spire-1.15.2-linux-amd64-musl.tar.gz` (+ `_sha256sum.txt`), also `linux-arm64-musl`. Each tarball contains the `spire-server` and `spire-agent` binaries.
- **Official container images** on GitHub Container Registry:

  ```sh
  docker pull ghcr.io/spiffe/spire-server:1.15.2
  docker pull ghcr.io/spiffe/spire-agent:1.15.2
  ```

  Per the repo `Dockerfile` at `v1.15.2`, both images are **`scratch`-based** (statically linked binaries, verified with `xx-verify --static`; only CA certs plus the binary). The `spire-server` image runs as UID/GID 1000 by default; `spire-agent` runs as root (UID 0) by default. Because the images are `scratch`-based, they contain no shell — for this lab (which needs users, `setpriv`, and shell scripts in one "node" container) copying the static binaries out of the tarball (or out of the image) into our own base image is the practical route.

Sources:
- <https://github.com/spiffe/spire/releases/tag/v1.15.2> (version, date, asset list)
- <https://spiffe.io/downloads/> (official image names and `docker pull` commands)
- <https://github.com/spiffe/spire/blob/v1.15.2/Dockerfile> (scratch base, static linking, default UIDs)

## 2. go-spiffe version and Go toolchain

- Latest `github.com/spiffe/go-spiffe/v2` release: **v2.8.1** (2026-06-19).
- SPIRE v1.15.2's `go.mod` requires exactly `github.com/spiffe/go-spiffe/v2 v2.8.1` — so v2.8.1 is the matching pin.
- Minimum Go, from `go.mod` at each tag (neither has a `toolchain` line):
  - go-spiffe v2.8.1: `go 1.24.0`
  - SPIRE v1.15.2: `go 1.26.4`
- Recommendation for the lab's `go.mod` and builder image: **Go 1.26** (`golang:1.26` builder stage). It satisfies both, and matches what upstream SPIRE builds with.

Sources:
- <https://github.com/spiffe/go-spiffe/releases/tag/v2.8.1>
- <https://raw.githubusercontent.com/spiffe/go-spiffe/v2.8.1/go.mod> (`module github.com/spiffe/go-spiffe/v2`, `go 1.24.0`)
- <https://raw.githubusercontent.com/spiffe/spire/v1.15.2/go.mod> (`go 1.26.4`, `github.com/spiffe/go-spiffe/v2 v2.8.1`)

## 3. Base image for the lab node container

Requirements: run Go-built binaries, create users with fixed UIDs 10001–10004, and switch UID without a full privilege-dropping framework (setpriv / su-exec).

**Recommendation: `debian:bookworm-slim`.**

Rationale:

- `setpriv` is shipped by the `util-linux` package at `/usr/bin/setpriv`, and `util-linux` is an **Essential** package in Debian — so `setpriv` is present in the slim image with no extra install. Verified for bookworm (util-linux 2.38.1) and also present in trixie if we ever bump. Usage for the lab: `setpriv --reuid=10002 --regid=10002 --init-groups /app/client`.
- `useradd` (from the Essential `passwd` package) is available for provisioning UIDs 10001–10004 in the Dockerfile.
- glibc-based, so it runs any Go binary (static or CGO-linked), and SPIRE's musl-static release binaries also run on it unmodified.

Alternatives considered:
- `alpine`: smaller, but `setpriv` is not in the base image; you must `apk add su-exec` (a third-party-maintained 0.3 package) or `util-linux-misc`. Workable, but an extra moving part for no lab benefit.
- `ubuntu`: same properties as Debian but larger; no advantage here.
- `gcr.io/distroless/*` / `scratch`: no shell, no `useradd`, no setpriv — unusable for a multi-user teaching node.

Sources:
- <https://packages.debian.org/bookworm/amd64/util-linux/filelist> (`/usr/bin/setpriv` in bookworm)
- <https://packages.debian.org/bookworm/util-linux> (Essential status)
- <https://packages.debian.org/trixie/amd64/util-linux/filelist> (`/usr/bin/setpriv` also in trixie)
- <https://pkgs.alpinelinux.org/packages?name=su-exec> (Alpine alternative)

## 4. Minimal valid server.conf and agent.conf (SPIRE 1.15.2)

Syntax verified against `doc/spire_server.md` and `doc/spire_agent.md` at tag `v1.15.2`. Plugin config uses the `plugin_data { ... }` sub-block form.

### `infra/spire/server.conf`

```hcl
server {
    bind_address = "0.0.0.0"
    bind_port    = "8081"
    trust_domain = "lab.local"
    data_dir     = "/opt/spire/data/server"
    log_level    = "DEBUG"
    ca_ttl                = "24h"   # doc default: 24h
    default_x509_svid_ttl = "1h"    # doc default: 1h
}

plugins {
    DataStore "sql" {
        plugin_data {
            database_type     = "sqlite3"
            connection_string = "/opt/spire/data/server/datastore.sqlite3"
        }
    }

    NodeAttestor "join_token" {
        plugin_data {}
    }

    KeyManager "disk" {
        plugin_data {
            keys_path = "/opt/spire/data/server/keys.json"
        }
    }
}
```

Notes (all from `doc/spire_server.md@v1.15.2`):
- `trust_domain` and `data_dir` are required; `bind_address`/`bind_port` default to `0.0.0.0`/`8081`.
- sqlite is spelled `database_type = "sqlite3"` inside `DataStore "sql"`.
- `KeyManager "memory"` (`plugin_data {}`) is the other acceptable lab choice; `disk` keeps CA keys across container restarts.
- The server's local admin API socket defaults to `/tmp/spire-server/private/api.sock` (relevant for all CLI commands below).

### `infra/spire/agent.conf`

```hcl
agent {
    data_dir       = "/opt/spire/data/agent"
    log_level      = "DEBUG"
    trust_domain   = "lab.local"
    server_address = "127.0.0.1"     # or the compose service name of the server
    server_port    = "8081"
    socket_path    = "/run/spire/agent.sock"
    trust_bundle_path = "/opt/spire/conf/agent/bootstrap.crt"
}

plugins {
    NodeAttestor "join_token" {
        plugin_data {}
    }

    KeyManager "disk" {
        plugin_data {
            directory = "/opt/spire/data/agent"
        }
    }

    WorkloadAttestor "unix" {
        plugin_data {}
    }
}
```

Notes (from `doc/spire_agent.md@v1.15.2`):
- `socket_path` default is `/tmp/spire-agent/public/api.sock`; we override to `/run/spire/agent.sock`. Workloads then use `SPIFFE_ENDPOINT_SOCKET=unix:///run/spire/agent.sock`.
- Trust bootstrap: exactly one of `trust_bundle_path`, `trust_bundle_url`, or `insecure_bootstrap` may be set. The secure lab pattern is to export the bundle at bootstrap time with `spire-server bundle show -format pem > bootstrap.crt` (the `bundle show` default format is `pem`). `insecure_bootstrap = true` is explicitly documented as "not a secure configuration".
- `WorkloadAttestor "unix"` with empty `plugin_data` yields `unix:uid:<n>` selectors as used by the lab (`unix:uid:10001` etc.).
- The join token can be supplied either as `join_token = "..."` in the `agent {}` block or the `-joinToken` CLI flag (next section); use the flag so no token ever lands in a committed file.

Sources:
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/spire_server.md>
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/spire_agent.md>

## 5. Join-token flow and healthchecks (CLI at v1.15.2)

Generate a token (docs: "Generates one node join token and creates a registration entry for it. This token can be used to bootstrap one spire-agent installation."):

```sh
spire-server token generate -spiffeID spiffe://lab.local/spire/agent
# flags: -spiffeID (optional agent alias ID), -ttl (token TTL seconds, default 600),
#        -socketPath (default /tmp/spire-server/private/api.sock)
```

Start the agent with the token:

```sh
spire-agent run -config /opt/spire/conf/agent/agent.conf -joinToken "$TOKEN"
```

Healthchecks:

```sh
spire-server healthcheck                                   # server; -socketPath default /tmp/spire-server/private/api.sock
spire-agent  healthcheck -socketPath /run/spire/agent.sock # agent; -socketPath default /tmp/spire-agent/public/api.sock
```

Both accept `-shallow` and `-verbose`. The agent healthcheck's `-socketPath` must point at our overridden Workload API socket.

Sources:
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/spire_server.md> (`token generate`, `healthcheck`)
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/spire_agent.md> (`run -joinToken`, `healthcheck`)

## 6. Idempotent registration entries (create-or-skip)

**There is no upsert in the CLI at v1.15.2.** `spire-server entry create` calls the batch-create API; the CLI treats every non-OK result (including `AlreadyExists` for a duplicate entry) as a failure and exits non-zero (`errors.New("failed to create one or more entries")` in `cmd/spire-server/cli/entry/create.go@v1.15.2`).

Recommended pattern for `register.sh` — probe with `entry show` filters, create only when absent:

```sh
ensure_entry() { # spiffe_id uid
  if spire-server entry show -spiffeID "$1" -selector "unix:uid:$2" \
       | grep -q "Entry ID"; then
    echo "entry exists: $1 (unix:uid:$2), skipping"
  else
    spire-server entry create \
      -parentID spiffe://lab.local/spire/agent \
      -spiffeID "$1" \
      -selector "unix:uid:$2"
  fi
}
ensure_entry spiffe://lab.local/server   10001
ensure_entry spiffe://lab.local/client   10002
ensure_entry spiffe://lab.local/intruder 10003
```

`entry show` filter flags at v1.15.2: `-entryID`, `-spiffeID`, `-parentID`, `-selector`, `-downstream`, `-federatesWith` (plus `-socketPath`). Filtering on both `-spiffeID` and `-selector` pins the exact entry. (Alternative: treat `entry create`'s non-zero "similar entry already exists" as success in the script — works, but masks real failures; the probe-first pattern is cleaner and is what the spec's "running bootstrap multiple times should not create duplicate entries" needs.)

Sources:
- <https://github.com/spiffe/spire/blob/v1.15.2/cmd/spire-server/cli/entry/create.go> (no AlreadyExists special-casing; non-zero exit on any failed result)
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/spire_server.md> (`entry create` / `entry show` flags)
- <https://spiffe.io/docs/latest/deploying/registering/> (official registration workflow; documents `entry update` for modifying, no upsert-on-create)

## 7. Short X509-SVID TTL for the rotation demo (Lab 1.5)

Exact knobs at v1.15.2:

- **Server-wide default:** `default_x509_svid_ttl` in the `server {}` block (default `1h`; also `default_jwt_svid_ttl`, default `5m`, unused in this lab).
- **Per-entry override:** `spire-server entry create -x509SVIDTTL <seconds>` ("A TTL, in seconds, for any X509-SVID issued as a result of this record."); `-jwtSVIDTTL` is the JWT counterpart.
- **CA TTL constraint:** the server enforces `max SVID TTL = min(ca_ttl / 6, 7d)` (`MaxSVIDTTLForCATTL` in `pkg/server/ca/manager/manager.go@v1.15.2`, `activationThresholdDivisor = 6`) and logs a warning at startup if the configured SVID TTL exceeds it ("… is too high for the configured ca_ttl value. SVIDs with shorter lifetimes may be issued …"). With the default `ca_ttl = 24h` the cap is 4h, so any short demo TTL is safe.
- **Agent rotation timing:** by default the agent rotates an X509-SVID at **1/2 of its lifetime** (`doc/spire_agent.md@v1.15.2`, `availability_target` section: "If not satisfied, the agent will rotate the SVID by the default rotation strategy (1/2 of lifetime)."). The `availability_target` knob only kicks in with a >= 12h grace period, so it is irrelevant at demo scale.

Suggested demo setting: `default_x509_svid_ttl = "5m"` (or `-x509SVIDTTL 300` on the three entries) — a running `workloadapi.X509Source` then observes a new certificate roughly every 2.5 minutes with no process restart.

Sources:
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/spire_server.md> (`default_x509_svid_ttl`, `ca_ttl`, `-x509SVIDTTL`)
- <https://github.com/spiffe/spire/blob/v1.15.2/pkg/server/ca/manager/manager.go> (ca_ttl/6 cap)
- <https://github.com/spiffe/spire/blob/v1.15.2/cmd/spire-server/cli/run/run.go> (startup TTL warnings)
- <https://github.com/spiffe/spire/blob/v1.15.2/doc/spire_agent.md> (rotation at 1/2 lifetime, `availability_target`)
