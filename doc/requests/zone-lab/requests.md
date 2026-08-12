# Zone-lab — Phase 1 Design and Implementation Plan

## 1. Objective

Build `labs/zone-lab`, phase 1. The lab teaches one idea. The enforcement
point moves out of the application code and into Envoy.

Lab 1 and Lab 2 put the identity check inside the Go program. The go-spiffe
library authorized the peer SPIFFE ID. Zone-lab keeps the same trust domain and
the same SPIRE mechanism. It changes who enforces. Envoy now terminates mTLS,
authorizes the caller, and re-originates mTLS to the next hop. The Go apps carry
no identity code.

The lab must make these facts obvious:

1. Three security zones exist. Zone A reaches Zone B. Zone B reaches Zone C.
   Zone A cannot reach Zone C.
2. Network isolation and identity enforcement are two separate layers. Each
   layer holds on its own.
3. A gateway authorizes the caller at Layer 7 and logs the decision.
4. A backend pins the caller SPIFFE ID and rejects an unknown peer early.
5. The apps hold no TLS certificates and no go-spiffe code. Envoy gets every
   identity over SDS from the shared SPIRE agent socket.
6. An X.509 SVID is a bearer credential. A stolen SVID still works. Short TTLs
   and memory-only keys reduce the risk. The identity layer does not stop it.

This document locks phase 1. Phases 2 and 3 stay at the architecture level. Do
not implement them here.

---

## 2. Scope

Implement only phase 1:

```text
Three security zones (A, B, C) with internal Docker networks
One control network for the SPIRE server and agent
One shared SPIRE agent with docker:label attestation
Ten workload containers
Two Envoy gateways (zone-b-gateway, zone-c-gateway)
Two Envoy backends (zone-b-backend, zone-c-backend)
Plain-HTTP Go server and client apps (no go-spiffe)
SDS wiring from every Envoy to the shared agent socket
The eleven green properties P1 to P11
The FINDING and INCONCLUSIVE outcome states
The SAN-pin negative test
The bearer, latency, and rotation demos (outside the green bar)
```

Do NOT add:

```text
Phase 2: DNS steering, the registry API, the lease mechanism
Phase 3: the control panel UI
CoreDNS views
Federation or multiple trust domains
The Azure PoC port
Scaling or memory-per-entry measurements
```

Those belong to later work.

---

## 3. Relation to the series

Zone-lab extends the series. It breaks delta discipline on purpose. The teaching
axis is the enforcement point, not the attestation input.

The series conventions stay:

- The lab lives in one directory, `labs/zone-lab/`.
- The trust domain is `lab.local`.
- The bootstrap pins the trust bundle. `insecure_bootstrap` stays forbidden.
- `make test-integration` ends green.
- The README follows ASD-STE100 Simplified Technical English.
- The demos tell a clear before/after story against Lab 1 and Lab 2.

This lab overturns the entry-lab spec exclusion of Envoy. The exclusion applies
to Lab 1 only. Zone-lab needs Envoy to move the enforcement point.

One lab directory grows across three phases. Phase 1 ends with a green
`make test-integration`.

---

## 4. Lab environment

Use Docker with the compose plugin. The interface is a Makefile:

```bash
make build
make lab-up
make test-integration
make demo
make inspect
make lab-down
```

The lab needs no Go toolchain on the host. The Docker build compiles the two Go
binaries. The lab needs Envoy v1.39.0 and SPIRE 1.15.2. Both come from pinned
images.

---

## 5. Trust domain

Use one trust domain:

```text
lab.local
```

Every workload identity belongs to `spiffe://lab.local`. The bundle secret name
is the trust domain URI, `spiffe://lab.local`.

---

## 6. SPIFFE identities and the container cast

Create ten containers. The docker label key is `spiffe.lab/workload`, the same
key as Lab 2. The node alias is `spiffe://lab.local/node`. The agent attests
with a join token, so the agent needs no label.

| Container | Networks | Label `spiffe.lab/workload` | SPIFFE ID |
| --- | --- | --- | --- |
| spire-server | control | — | — |
| spire-agent | control | — | node alias `spiffe://lab.local/node` |
| zone-a-client | zone-a | zone-a-client | spiffe://lab.local/zone-a/client |
| zone-a-intruder | zone-a | zone-a-intruder | spiffe://lab.local/zone-a/intruder |
| zone-a-peer | zone-a | zone-a-peer | spiffe://lab.local/zone-a/peer |
| zone-a-unregistered | zone-a | (no entry) | none |
| zone-b-gateway | zone-a + zone-b | zone-b-gateway | spiffe://lab.local/zone-b/gateway |
| zone-b-backend | zone-b | zone-b-backend | spiffe://lab.local/zone-b/backend |
| zone-c-gateway | zone-b + zone-c | zone-c-gateway | spiffe://lab.local/zone-c/gateway |
| zone-c-backend | zone-c | zone-c-backend | spiffe://lab.local/zone-c/backend |

Roles:

- `backend` is the serving workload per zone. The name is `backend`, not
  `server`. It matches the gateway/backend pair. It avoids confusion with the
  app code.
- `client` is the authorized caller in Zone A.
- `intruder` holds a valid SVID that is not on the gateway allowlist.
- `unregistered` has no entry. `spire-agent api fetch x509` must return
  `PermissionDenied ... no identity issued`.
- `peer` is the intra-zone plaintext target. The client calls it over plain
  HTTP. This proves mTLS happens only at the zone boundary.

Zone A holds no gateway and no backend. Nothing calls into Zone A in phase 1.

**Trap 3 — the flat label maps to a nested path.** The label value
`zone-b-gateway` maps to the SPIFFE ID `spiffe://lab.local/zone-b/gateway`. The
register script must not assume the SPIFFE path equals the label value. The map
is explicit.

---

## 7. Target architecture

### 7.1 Networks

Create one control network and three zone networks.

| Network | Type | Subnet | Members |
| --- | --- | --- | --- |
| control | bridge | default | spire-server, spire-agent |
| zone-a | internal | 10.10.0.0/24 | zone-a workloads, zone-b-gateway |
| zone-b | internal | 10.20.0.0/24 | zone-b-backend, zone-b-gateway, zone-c-gateway |
| zone-c | internal | 10.30.0.0/24 | zone-c-backend, zone-c-gateway |

`internal: true` removes the off-network default route. A blocked cross-zone
probe then returns "Network is unreachable", not "Connection refused". This
difference is load-bearing for property P1.

The spike uses `172.30.10.0/24` and `172.30.20.0/24`. The real lab uses the
topology subnets `10.10.0.0/24`, `10.20.0.0/24`, and `10.30.0.0/24`. Use fixed
IP addresses so the Envoy upstream clusters can name a stable backend address.

### 7.2 The shared SPIRE agent

Run one SPIRE agent, in the Lab 2 style:

- The agent container uses `pid: "host"` and a read-only mount of
  `/var/run/docker.sock`. The docker attestor queries the Docker daemon.
- The agent serves the Workload API on a socket in the `spire-agent-socket`
  volume at `/run/spire/agent.sock`.
- Every workload mounts that volume read-only at `/run/spire`.

The socket does not cross networks. A shared mount does not break zone isolation.
The README must state this.

**Trap 4 — a workload needs no control network.** The socket volume alone
carries the Workload API. Do not add a workload to the control network "to be
safe". That would break the isolation claim. Only the server and the agent sit
on the control network.

### 7.3 Gateway placement encodes the policy

The policy is A to B, B to C, and A not to C. The dual-homing states it in the
topology:

- `zone-b-gateway` sits on `zone-a` and `zone-b`. Zone A reaches the B front
  door.
- `zone-c-gateway` sits on `zone-b` and `zone-c`. Zone B reaches the C front
  door. Zone A cannot reach Zone C at all.

A backend sits on its zone network only. A client reaches a backend through the
zone gateway, never directly.

### 7.4 The request path

```text
zone-a-client
  spiffe://lab.local/zone-a/client
        │  mTLS on zone-a
        ▼
zone-b-gateway  (L7 RBAC allows zone-a/client)
  spiffe://lab.local/zone-b/gateway
        │  mTLS on zone-b, upstream SAN pin
        ▼
zone-b-backend  (SAN pin + network RBAC allow zone-b/gateway)
  spiffe://lab.local/zone-b/backend
```

Zone B reaches Zone C through `zone-c-gateway` and `zone-c-backend`, the same
shape.

---

## 8. SPIRE server configuration

Create `infra/spire/server.conf`.

Requirements:

```hcl
trust_domain = "lab.local"
bind_address = "0.0.0.0"
bind_port    = "8081"

data_dir  = "/var/lib/spire/server"
log_level = "DEBUG"

ca_ttl                = "24h"
default_x509_svid_ttl = "5m"
```

Plugins:

```text
DataStore  "sql"        (sqlite3)
NodeAttestor "join_token"
KeyManager "disk"
```

The `default_x509_svid_ttl` is 5m from the start. There is no CRL. The TTL is
the worst-case containment window after a revocation. Property P9 measures this
window. One config carries the value. The README carries the reason.

Do not configure Kubernetes plugins.

---

## 9. SPIRE agent configuration

Create `infra/spire/agent.conf`.

Requirements:

```hcl
trust_domain = "lab.local"
server_address = "spire-server"
server_port    = "8081"

socket_path       = "/run/spire/agent.sock"
trust_bundle_path = "/run/spire/bootstrap.crt"
```

Plugins:

```text
NodeAttestor  "join_token"
KeyManager    "disk"
WorkloadAttestor "docker"
```

The docker attestor produces `docker:label:<key>:<value>` selectors. Keep
`plugin_data {}` empty. An empty block is correct for cgroups v2. Do not set
`container_id_cgroup_matchers`. That turns on the legacy path.

Only the agent talks to the server. A workload never learns the server address.
A workload reaches the agent socket on the shared volume.

---

## 10. Agent bootstrap

Automate this sequence in `scripts/bootstrap.sh`:

1. Start the SPIRE server. Wait until `spire-server healthcheck` succeeds.
2. Copy the trust bundle from the server into the agent at
   `/run/spire/bootstrap.crt`. Deliver it at runtime. Commit no copy.
3. Generate a one-time join token, aliased to `spiffe://lab.local/node`.
4. Write the token into a root-only file inside the agent container. Keep the
   token off the command line. The command line is public through `/proc`.
5. Start the agent with `-joinTokenFile`.
6. Wait until the agent serves the Workload API.
7. Delete the token file.

Do not commit the token into Git. The bootstrap must be idempotent. An
already-healthy agent stays untouched.

`insecure_bootstrap` stays forbidden. The bootstrap always pins the bundle.

---

## 11. Registration entries

Create the entries in `scripts/register.sh`. Each entry maps a container label
to a SPIFFE ID:

```text
docker:label:spiffe.lab/workload:zone-a-client   -> spiffe://lab.local/zone-a/client
docker:label:spiffe.lab/workload:zone-a-intruder -> spiffe://lab.local/zone-a/intruder
docker:label:spiffe.lab/workload:zone-a-peer     -> spiffe://lab.local/zone-a/peer
docker:label:spiffe.lab/workload:zone-b-gateway  -> spiffe://lab.local/zone-b/gateway   (+ DNS SAN)
docker:label:spiffe.lab/workload:zone-b-backend  -> spiffe://lab.local/zone-b/backend
docker:label:spiffe.lab/workload:zone-c-gateway  -> spiffe://lab.local/zone-c/gateway   (+ DNS SAN)
docker:label:spiffe.lab/workload:zone-c-backend  -> spiffe://lab.local/zone-c/backend
```

The parent ID for every entry is the node alias `spiffe://lab.local/node`.

`zone-a-unregistered` gets no entry, on purpose.

**Trap 2 — the flag is `-dns`, not `-dnsName`.** A gateway SVID needs a DNS SAN.
The client uses curl, and curl checks the hostname. A SPIFFE SVID carries only a
URI SAN by default. Add `-dns zone-b-gateway` to the `zone-b-gateway` entry, and
`-dns zone-c-gateway` to the `zone-c-gateway` entry. Then a curl to
`https://zone-b-gateway:9000` verifies the chain and the hostname. Without the
DNS SAN, curl fails with a name-mismatch error, and a fall back to `--insecure`
weakens the proof.

The register step is the entry sync barrier. A new entry reaches the agent on
its next sync. The script waits until a probe confirms the entries are live.
The register step is idempotent. It leaves an existing entry alone.

---

## 12. The apps

The apps are plain-HTTP Go programs. They hold no go-spiffe code. They hold no
TLS certificates. Envoy handles all mTLS.

### 12.1 The backend app

Create `cmd/backend/main.go`. It is a trivial HTTP server. It listens on
`127.0.0.1:8080`. Envoy fronts it on the zone network. It returns a body that
names the zone, for example `zone-lab backend zone-b OK`. The body must differ
per zone, so property P6 can prove which backend answered.

### 12.2 The client app

Create `cmd/client/main.go`. It is a plain HTTP client. It calls the gateway
with mTLS material that Envoy or curl provides. The demo scripts drive it.

The apps keep the before/after teaching contrast. In Lab 1 and Lab 2, the Go
code authorized the peer. Here the Go code holds nothing. Envoy authorizes.

The before/after contrast is a core teaching asset. Keep the app code small and
plain.

---

## 13. The Envoy enforcement pattern

Every Envoy runs v1.39.0. Build it with a multi-stage `COPY` from
`envoyproxy/envoy:v1.39.0` into a Debian base. The enforcement is asymmetric,
by design.

### 13.1 The gateway

The gateway authorizes with the HTTP filter `envoy.filters.http.rbac`. The
policy is `ALLOW` with one exact principal.

- `zone-b-gateway` allows only `spiffe://lab.local/zone-a/client`.
- `zone-c-gateway` allows only `spiffe://lab.local/zone-b/backend`.

The gateway downstream keeps `require_client_certificate: true` and an empty
`default_validation_context: {}`. Chain validation still applies. A client
certificate is still required. The SAN is not restricted in the handshake.

Why: auditability. A SAN matcher rejects during the handshake. A handshake
rejection leaves no access-log line and no caller name. The L7 RBAC filter runs
after the request is parsed. So a denial is a logged 403 that names the caller.
This is the audit trail for attack test A1, property P5.

The gateway re-originates mTLS upstream under its own identity. The upstream
cluster pins the backend SPIFFE ID with `match_typed_subject_alt_names`,
`san_type: URI`, exact match.

- `zone-b-gateway` pins `spiffe://lab.local/zone-b/backend`.
- `zone-c-gateway` pins `spiffe://lab.local/zone-c/backend`.

### 13.2 The backend

The backend listener carries two mechanisms:

1. A downstream SAN matcher: exact URI match on the gateway SPIFFE ID.
2. A network filter `envoy.filters.network.rbac`, `ALLOW`, with the same exact
   principal.

- `zone-b-backend` accepts only `spiffe://lab.local/zone-b/gateway`.
- `zone-c-backend` accepts only `spiffe://lab.local/zone-c/gateway`.

The SAN matcher rejects during the handshake. So the network RBAC filter almost
never sees a bad connection. The RBAC filter stays as defense in depth.

### 13.3 The two sides differ, on purpose

The gateway is the audit point. It parses the request, denies with a 403, and
logs the caller. The backend sits behind that audit point, so it rejects early
and cheaply in the handshake.

### 13.4 SDS wiring

Every Envoy holds one extra cluster, `spire_agent`:

- `type: STATIC`, `connect_timeout: 1s`.
- HTTP/2 through `typed_extension_protocol_options` with
  `explicit_http_config: { http2_protocol_options: {} }`.
- One endpoint: a Unix pipe, `pipe: { path: /run/spire/agent.sock }`.

The socket path is `/run/spire/agent.sock`, the docker-lab path. This is not the
sdn PoC path `/run/spire/sockets/agent.sock`.

Each secret has an `sds_config` that points at this cluster with
`resource_api_version: V3`, `api_type: GRPC`, `transport_api_version: V3`, and
`envoy_grpc: { cluster_name: spire_agent }`.

The secret names follow one scheme:

| Secret | Name |
| --- | --- |
| The workload certificate | The workload SPIFFE ID, for example `spiffe://lab.local/zone-b/gateway` |
| The validation context (trust bundle) | The trust domain URI, `spiffe://lab.local` |

The agent attests each SDS caller by its container. Each Envoy container carries
its own label, so it maps to one entry and one SVID. The agent serves a caller
only the secrets its entries grant.

### 13.5 The access log

Keep `%UPSTREAM_TRANSPORT_FAILURE_REASON%` in every gateway access-log format.
Envoy v1.39.0 puts the upstream TLS failure reason only in that field. The
SAN-pin negative test greps that field.

The gateway access-log line must carry `%DOWNSTREAM_PEER_URI_SAN%` and
`%UPSTREAM_PEER_URI_SAN%`. Property P3 reads both from one line.

### 13.6 The admin listener

Every Envoy exposes an admin listener on `127.0.0.1:9901`. The tests read
counters from it. A test cannot attribute a rejection without it.

The tests read these counters before and after an attempt:

| Counter | Meaning |
| --- | --- |
| `http.<stat_prefix>.rbac.denied` | The L7 RBAC filter denied a request (gateway) |
| `<stat_prefix>.rbac.denied` | The network RBAC filter denied a connection (backend) |
| `listener.0.0.0.0_<port>.ssl.fail_verify_san` | SAN verification rejected the peer |

The counters are cumulative. A test compares before against after. A comparison
against a hardcoded zero is wrong. A test never matches client error text. The
client symptom varies. A text match would accept any TLS failure.

---

## 14. The SDS secret name in stat keys

**Trap 1 — Envoy rewrites the SDS secret name in stat keys.** The `://` becomes
`_`. The `/` stays. So the certificate stat key for the B gateway is:

```text
sds.spiffe_lab.local/zone-b/gateway.update_success
```

The bundle stat key is:

```text
sds.spiffe_lab.local.update_success
```

A test that greps the raw SPIFFE ID with `://` finds nothing and reports a false
FAIL. The lab tests must grep the sanitized name.

---

## 15. The SAN-pin negative test (mandatory)

The spike does not carry this test. The research requires it. The SPIFFE
validator silently drops a non-URI SAN matcher. An empty matcher list skips SAN
matching. It does not fail closed. A misconfigured pin does not error; it stops
checking. A happy-path test cannot detect an inert pin. "The pin matched" and
"the pin was skipped" both look like a success.

Add `scripts/test-san-pin.sh` (or an equivalent step inside test-integration).
The method:

1. Confirm the baseline. Forwarding works with the correct pin.
2. Repoint one pin at a SPIFFE ID the backend does not have.
3. Send a request with a unique marker in the query string.
4. Require the request to fail. Require this request access-log line to record
   `verify_cert_failed:_SAN_match`.
5. Restore the config. Confirm forwarding works again.

A bare failure is not proof. A network blip fails the same way. Only the
SAN-match failure reason, correlated by the marker, attributes the rejection to
the pin. Every SAN pin needs one proof that it can fail.

The lab has two SAN pins on the request path: the gateway upstream pin and the
backend downstream pin. The test targets at least the backend downstream pin,
the pin that guards the backend identity. State the target pin in the test
header.

---

## 16. The property list

`make test-integration` proves eleven properties. It ends green every run. Each
check verifies the premise first. Each negative claim needs positive evidence of
the specific failure.

- **P1 Network containment** — Zone A to the Zone B backend, direct, returns
  "Network is unreachable". A mandatory positive control: the Zone B gateway
  reaches the same address. "Connection refused" is INCONCLUSIVE, not PASS.
- **P2 Gateway path works** — Zone A through the Zone B gateway returns HTTP 200
  and the real backend body.
- **P3 Gateway audit** — one gateway access-log line carries both
  `downstream_san` (zone-a/client) and `upstream_san` (zone-b/backend).
- **P4 Backend identity verified** — the client authenticates the backend as
  `spiffe://lab.local/zone-b/backend`. mTLS is mutual.
- **P5 Identity rejection is auditable** — the intruder to the gateway returns a
  logged 403 with the intruder `downstream_san`. This is sdn A1.
- **P6 No transit** — Zone A cannot make the Zone B gateway relay to Zone C. The
  returned body is B's, not C's.
- **P7 Defence in depth** — join Zone A to the `zone-b` network to give it a
  real route. Confirm the identity layer still refuses. A stats counter moves.
  Restore the network after. Fail loudly if the restore cannot be confirmed.
- **P8 Exact-match allowlist** — `spiffe://lab.local/zone-b/gateway-evil` is
  refused. This is sdn A3.
- **P9 Bounded revocation** — after the client entry is deleted, access ends
  within the TTL bound. The assertion is "window < a stated policy bound", for
  example 10m.
- **P10 Intra-zone plaintext** — the client calls `zone-a/peer` over plain HTTP,
  with no mTLS and no gateway.
- **P11 Unregistered gets no SVID** — a container with no entry gets
  `PermissionDenied ... no identity issued`.

Each property is a testable assertion. Each reads a counter or a log line for
positive evidence. Each treats an unattributed failure as INCONCLUSIVE.

The SAN-pin negative test from section 15 runs inside test-integration or beside
it. It must be green before test-integration reports PASS.

---

## 17. Outcome states

The series PASS/FAIL grows two states, from sdn:

- **FINDING** — a real, expected limitation. The bearer-credential test is a
  FINDING.
- **INCONCLUSIVE** — the probe did not reach the thing under test. A "Connection
  refused" in P1 is INCONCLUSIVE, not PASS.

`test-integration` still needs every property green to pass. A FINDING demo runs
outside the green count.

---

## 18. The bearer-credential FINDING

The stolen-SVID test is ACCEPTED (HTTP 200). An X.509 SVID is a bearer
credential. It cannot be a "must be denied" property. It is a standalone FINDING
demo, `make demo-bearer`, outside the green count. This is sdn A2.

The README states the limitation and the mitigations: memory-only keys and short
TTLs, not the identity layer.

---

## 19. TTL policy

`default_x509_svid_ttl` is 5m from the start. There is no CRL. The TTL is the
worst-case containment window after a revocation. Property P9 asserts the
window is under a stated policy bound. One config carries the value. The README
carries the reason.

---

## 20. The demos and measurements

### 20.1 Latency demo

`make demo-latency` measures the gateway-hop p50/p99 overhead. It is a teaching
number. It is NOT part of the green bar.

### 20.2 Rotation demo

`make demo-rotation` proves rotation through Envoy SDS. A held connection sees
the certificate serial change while the connection stays up. It is outside the
green bar.

The teaching contrast is explicit. Lab 1 rotates through the go-spiffe
X509Source in app code. Zone-lab rotates through Envoy, which re-fetches over
SDS.

### 20.3 Scaling

Scaling (memory per entry, sdn T10) is OUT of phase 1.

---

## 21. Make targets

Provide these targets:

```text
make build             build the workload image and the Envoy image
make lab-up            start the always-up set, bootstrap, and register
make test-integration  assert P1 to P11 and the SAN-pin negative test
make demo              run the positive path
make demo-intruder     P5: the intruder gets a logged 403
make demo-unregistered P11: a container with no entry gets no SVID
make demo-bearer       the bearer-credential FINDING
make demo-latency      the gateway-hop overhead number
make demo-rotation     the SDS rotation demo
make inspect           show agents, entries, SVIDs, and Envoy secrets
make lab-down          destroy the lab and all runtime state
```

`make test-integration` deletes all lab state, builds a fresh lab, asserts every
property, and leaves the lab down. It uses the same report format as Lab 2.

---

## 22. Compose profiles

- **Always up**: spire-server, spire-agent, zone-b-gateway, zone-b-backend,
  zone-c-gateway, zone-c-backend, zone-a-peer.
- **One-shot** (`demo` profile), run with `docker compose run --rm`:
  zone-a-client, zone-a-intruder, zone-a-unregistered.

`make lab-up` starts the always-up set. It completes bootstrap and registration.

---

## 23. Inspect command

Implement `make inspect`. It shows:

```text
the attested agents        (spire-server agent list)
the registration entries   (spire-server entry show)
the workload SVIDs         (a fetch, exported to tmp/svid/)
the Envoy secrets          (each admin :9901 config_dump and the sds stats)
```

Prefer the official SPIRE CLI. A temporary exported SVID lives only under a
gitignored `tmp/` directory. Never commit a private key.

---

## 24. Repository layout

Target structure:

```text
labs/zone-lab/
├── README.md
├── Makefile
├── go.mod
├── go.sum
├── cmd/
│   ├── backend/
│   │   └── main.go
│   └── client/
│       └── main.go
├── infra/
│   └── spire/
│       ├── server.conf
│       └── agent.conf
├── conf/
│   ├── zone-b-gateway-envoy.yaml
│   ├── zone-b-backend-envoy.yaml
│   ├── zone-c-gateway-envoy.yaml
│   └── zone-c-backend-envoy.yaml
├── scripts/
│   ├── bootstrap.sh
│   ├── register.sh
│   ├── start-servers.sh
│   ├── inspect.sh
│   ├── demo.sh
│   ├── demo-intruder.sh
│   ├── demo-unregistered.sh
│   ├── demo-bearer.sh
│   ├── demo-latency.sh
│   ├── demo-rotation.sh
│   ├── test-integration.sh
│   └── test-san-pin.sh
├── docker/
│   └── Dockerfile
├── docker-compose.yml
└── tmp/
    └── .gitkeep
```

`tmp/` is gitignored, except `.gitkeep`.

The four Envoy configs may share a base. Keep one file per Envoy for clarity.
The gateway configs differ in the allowlist principal, the upstream pin, and the
DNS SAN target. The backend configs differ in the SAN pin and the RBAC
principal.

---

## 25. README requirements

The README is part of the deliverable. Assume the reader finished Lab 1 and
Lab 2. Do not repeat the SPIFFE ID, the X509-SVID, the Workload API, or mTLS
basics. Show the delta only.

Cover this order:

```text
1.  The one idea: the enforcement point moves from app code to Envoy.
2.  The before/after contrast against Lab 1 and Lab 2.
3.  The three zones and the A-B-C policy.
4.  The two layers: network isolation and identity enforcement.
5.  Why a shared socket volume does not break zone isolation.
6.  The gateway: L7 RBAC, empty downstream validation, the audit line.
7.  The backend: the SAN pin plus network RBAC, defense in depth.
8.  SDS: how Envoy gets its SVID and the bundle from the agent socket.
9.  The bearer-credential FINDING and its mitigations.
10. The TTL: why 5m is the revocation containment window.
11. The property list P1 to P11, and the FINDING and INCONCLUSIVE states.
```

Include real transcripts from a real run. Trim them as Lab 2 does. State the
tested versions in the prerequisites: SPIRE 1.15.2, Envoy v1.39.0, the Docker
compose floor.

The README carries the four spike traps as taught facts, in the notes:

1. The SDS secret name in stat keys: `://` becomes `_`, `/` stays.
2. The registration flag is `-dns`, and the gateway needs a DNS SAN.
3. The flat label maps to a nested SPIFFE path.
4. A workload needs no control network; the socket volume carries identity.

---

## 26. Security constraints

The repository MUST NOT contain:

```text
static application private keys
static application certificates
hardcoded join tokens
API keys, passwords, or shared secrets
```

Do not fake SPIFFE with a hand-made OpenSSL certificate. Every identity comes
from SPIRE through SDS or the Workload API.

Do not disable peer validation to make a demo work. Do not set
`InsecureSkipVerify` or an inert SAN matcher to pass a test. The SAN-pin
negative test guards against an inert matcher.

`insecure_bootstrap` stays forbidden. The bootstrap always pins the bundle.

---

## 27. Logging

Use readable logs. The gateway access log names the caller and the upstream on
each request. The backend access log names the caller. A demo prints the SPIFFE
IDs it expects, then the result.

Do not log private keys, join tokens, or raw credential material.

---

## 28. Definition of Done

Phase 1 is complete when a new developer runs:

```bash
git clone https://github.com/superplayground3000/learn-spire.git
cd learn-spire/labs/zone-lab

make lab-up
make test-integration
make demo
make demo-bearer
make demo-latency
make demo-rotation
make inspect
make lab-down
```

and observes:

- `make test-integration` ends green. It proves P1 to P11 and the SAN-pin
  negative test.
- The positive path returns HTTP 200 with both SANs logged.
- The intruder gets a logged 403.
- The unregistered container gets no SVID.
- Zone A cannot reach Zone C.
- The bearer demo shows the FINDING, with the mitigations stated.
- The apps hold zero go-spiffe code and zero TLS certificates.

---

## 29. Implementation order

Build in this order. Each step ends with a check.

```text
1.  Scaffold: the file tree, the Go apps, the Dockerfile, the compose file,
    the four Envoy configs, and server.conf and agent.conf.
    Update CONTEXT.md in this step.

2.  Bootstrap and attestation: bootstrap.sh, the join-token flow, the pinned
    bundle, and lab-up to an attested agent.

3.  Register and the request path: register.sh with the label-to-path map and
    the DNS SANs, start-servers.sh, the two gateways, the two backends, and
    demo (the positive path, HTTP 200 with both SANs).

4.  The negative demos and inspect: demo-intruder, demo-unregistered,
    demo-bearer, and inspect.

5.  The property tests: test-integration.sh with P1 to P11, plus the SAN-pin
    negative test and the sanitized SDS stat-key grep.

6.  The delta README and the demos: demo-latency, demo-rotation, and the
    delta-only README with real transcripts.
```

Do not start a step before the earlier step ends green.

---

## 30. CONTEXT.md glossary update

The CONTEXT.md glossary update lands in the first PR slice. Two changes:

1. The term "Ten security properties" becomes an attestation-series term. It
   describes the fixed ten-property list that Labs 1 to 3 prove. Zone-lab
   defines its own eleven-property list (P1 to P11), so the glossary must not
   imply every lab proves the same ten.

2. Add the zone-lab terms:

- **Zone**: one internal Docker network with a single trust boundary. A workload
  in a zone reaches another zone only through a gateway.
- **Gateway**: an Envoy proxy that dual-homes two zones. It authorizes the
  caller at Layer 7, logs the decision, and re-originates mTLS to the backend.
- **Backend**: the serving Envoy plus a plain-HTTP app in a zone. It pins the
  gateway SPIFFE ID and rejects an unknown peer early.
- **Enforcement point**: the place that checks identity. Labs 1 and 2 enforce in
  the app code. Zone-lab moves the enforcement point to Envoy.
- **Bearer credential**: a credential that works for whoever holds it. An X.509
  SVID is one. A stolen SVID still works. Short TTLs and memory-only keys reduce
  the risk.
- **Revocation window**: the worst-case time from a revoked entry to the end of
  access. There is no CRL, so the SVID TTL bounds this window.
```
