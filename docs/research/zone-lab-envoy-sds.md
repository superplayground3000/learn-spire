# Zone-lab Envoy and SDS enforcement — research notes

Findings for wayfinder ticket #39.

Primary source: `/media/hp/secondary/projects/sdn/poc/local-compose` (the sdn PoC).
Secondary source: `/media/hp/secondary/projects/sdn/poc/forwarding-gateway` (the SAN-pin test).
Local reference: `labs/docker-lab` in this repository (the shared-agent pattern).

All file paths below point into those directories, unless the text says something different.

---

## 1. The asymmetric enforcement pattern

The gateway and the backend enforce identity with different mechanisms. This is deliberate.

### Gateway: L7 RBAC, and an empty downstream validation context

The gateway authorizes with the HTTP filter `envoy.filters.http.rbac`.
The policy is `ALLOW` with one exact principal:
`spiffe://poc.zoning.local/zone-a/client`.

Source: `local-compose/conf/gateway-envoy.yaml:47-56`.

The gateway's downstream `default_validation_context` is empty (`{}`).
Chain validation against the trust bundle still applies.
A client certificate is still required (`require_client_certificate: true`).
But the SAN is not restricted in the handshake.

Source: `local-compose/conf/gateway-envoy.yaml:62-75`.

Why: auditability. A SAN matcher rejects during the TLS handshake.
A handshake rejection leaves no access-log line and no caller name.
Attack test A1 found this gap: a denied probe changed no log line
(`access-log lines: 18 -> 18`).
After the fix, a denial is a logged 403 that names the caller's SPIFFE ID.

Sources: `local-compose/05-test-attacks.sh:68-89`; `local-compose/README.md:185-206`
(the A1 section) and `local-compose/README.md:417-436` (the "Hardening" section).

### Gateway upstream: an exact SAN pin on the backend

The gateway re-originates mTLS to the backend under its own identity.
The upstream cluster pins the backend with `match_typed_subject_alt_names`,
`san_type: URI`, exact match `spiffe://poc.zoning.local/zone-b/workload`.

Source: `local-compose/conf/gateway-envoy.yaml:83-98`.

### Backend: SAN pin plus network RBAC

The backend listener carries two mechanisms:

1. A downstream SAN matcher: exact URI match on
   `spiffe://poc.zoning.local/zone-b/gateway`
   (`local-compose/conf/backend-envoy.yaml:60-64`).
2. A network filter `envoy.filters.network.rbac`, `ALLOW`, with the same
   exact principal (`local-compose/conf/backend-envoy.yaml:19-29`).

The SAN matcher rejects during the handshake, so the network RBAC filter
almost never sees a bad connection. The RBAC filter stays as defense in depth:
the Azure PoC saw a downstream SAN matcher that did not enforce, and the root
cause was never found.

Sources: `local-compose/03-test-l1-l4.sh:42-44`; `local-compose/README.md:439-464`
("A finding that contradicts the Azure result").

### Why the two sides differ

The gateway is the audit point. It parses the request, denies with a 403,
and logs the caller. The backend sits behind that audit point, so it can
reject early and cheaply in the handshake.

Source: `local-compose/README.md:419-424`.

---

## 2. The SDS wiring to the SPIRE agent socket

Every Envoy config holds one extra cluster, `spire_agent`:

- `type: STATIC`, `connect_timeout: 1s`.
- HTTP/2 through `typed_extension_protocol_options` →
  `explicit_http_config: { http2_protocol_options: {} }`.
- One endpoint: a Unix pipe, `pipe: { path: /run/spire/sockets/agent.sock }`.

Source: `local-compose/conf/gateway-envoy.yaml:99-108` and
`local-compose/conf/backend-envoy.yaml:75-84`.

Each secret has an `sds_config` block that points at this cluster:
`resource_api_version: V3`, `api_type: GRPC`, `transport_api_version: V3`,
`envoy_grpc: { cluster_name: spire_agent }`.

The secret names follow one scheme:

| Secret | Name |
|---|---|
| The workload's own certificate | The workload's SPIFFE ID, for example `spiffe://poc.zoning.local/zone-b/gateway` |
| The validation context (trust bundle) | The trust domain URI, `spiffe://poc.zoning.local` |

Sources: `local-compose/conf/gateway-envoy.yaml:65-67,73-75,88-90,96-98`;
`local-compose/conf/backend-envoy.yaml:57-59,65-67`.

---

## 3. The SPIFFE cert validator quirk: inert SAN matchers skip matching

SPIRE's SDS installs a SPIFFE custom certificate validator on the TLS context.
That validator silently discards SAN matchers that are not `URI` type.
If the resulting matcher list is empty, it skips SAN matching completely.
It does not fail closed. A misconfigured pin does not error; it stops checking.
The connection then succeeds on chain validity alone.

Source: `forwarding-gateway/README.md:148-169` ("Why the SAN-pin negative test exists");
`forwarding-gateway/03-test-san-pin.sh:1-9` (header comment).

A passing happy-path test cannot detect an inert pin. "The pin matched" and
"the pin was skipped" both look like a successful connection.

The guard is `forwarding-gateway/03-test-san-pin.sh`. Its method:

1. Confirm the baseline: forwarding works with the correct pin.
2. Repoint the pin at a SPIFFE ID the backend does not have.
3. Send a request with a unique marker in the query string.
4. Require the request to fail, and require this request's own access-log
   line to record `verify_cert_failed:_SAN_match`.
5. Restore the config, and confirm forwarding works again.

A bare failure is not proof. A network blip fails the same way. Only the
SAN-match failure reason, correlated by the marker, attributes the rejection
to the pin. Source: `forwarding-gateway/03-test-san-pin.sh:119-146`.

Zone-lab must carry an equivalent negative test. Every SAN pin needs one proof
that it can fail.

---

## 4. The admin /stats counters the tests read

Each Envoy exposes an admin listener on `127.0.0.1:9901`
(`local-compose/conf/gateway-envoy.yaml:11-13`). The tests read three counters:

| Counter | Meaning | Read by |
|---|---|---|
| `http.<stat_prefix>.rbac.denied` | The L7 RBAC filter denied a request (gateway) | `local-compose/03-test-l1-l4.sh:33-35` |
| `<stat_prefix>.rbac.denied` | The network RBAC filter denied a connection (backend) | `local-compose/03-test-l1-l4.sh:29-31` |
| `listener.0.0.0.0_<port>.ssl.fail_verify_san` | SAN verification rejected the peer's SPIFFE ID | `local-compose/03-test-l1-l4.sh:39-41` |

`ssl.fail_verify_san` is SAN-specific. A chain or trust problem increments
`ssl.fail_verify_error` instead. A missing certificate increments
`ssl.fail_verify_no_cert`. So an increment names the exact mechanism.
Source: `local-compose/README.md:120-126`.

The tests never match on client error text. The client symptom varies:
`errno 107 ENOTCONN` at the gateway, `sslv3 alert certificate unknown` at the
backend. A text match would accept any TLS failure. Instead, each test reads a
counter before and after the attempt, and requires it to move. The counters
are cumulative, so a comparison against a hardcoded zero is wrong.
Sources: `local-compose/03-test-l1-l4.sh:23-28`; `local-compose/README.md:120-126,158-162`.

---

## 5. What must change for zone-lab

### 5.1 Trust domain: `lab.local`

The sdn PoC uses `poc.zoning.local` (`local-compose/conf/server.conf:4`,
`local-compose/conf/agent.conf:7`). Zone-lab uses `lab.local`, the same trust
domain as `labs/docker-lab` (`labs/docker-lab/infra/spire/server.conf:4`).

This changes every string that carries the trust domain:

- The certificate secret names: `spiffe://lab.local/<path>`.
- The bundle secret name: `spiffe://lab.local`.
- The RBAC principals and the SAN pins.

### 5.2 One shared SPIRE agent, `docker` attestation

The sdn PoC runs one agent inside every node container, with
`WorkloadAttestor "unix"` and `unix:uid:0` selectors
(`local-compose/conf/agent.conf:14`, `local-compose/01-bootstrap-spire.sh:43-48`).
Zone-lab replaces this with the `labs/docker-lab` pattern:

- One agent container with `pid: "host"`, a read-only mount of
  `/var/run/docker.sock`, and `WorkloadAttestor "docker"`
  (`labs/docker-lab/docker-compose.yml:52-78`,
  `labs/docker-lab/infra/spire/agent.conf:51-54`).
- A shared volume carries the Workload API socket. The agent mounts it at
  `/run/spire`; each workload mounts it read-only
  (`labs/docker-lab/docker-compose.yml:17-20,74-76`).
- One registration entry per container label:
  `docker:label:spiffe.lab/workload:<name>` → `spiffe://lab.local/<name>`
  (`labs/docker-lab/scripts/register.sh:7-9,96`).

**The socket path changes.** The sdn Envoy pipe endpoint is
`/run/spire/sockets/agent.sock`. The docker-lab agent binds
`/run/spire/agent.sock` (`labs/docker-lab/infra/spire/agent.conf:14`).
The zone-lab `spire_agent` cluster must point its `pipe.path` at the shared
volume path.

**The SDS secret-name scheme still works.** The agent attests each SDS caller
by its container, not by the socket. Each Envoy container carries its own
label, so it maps to exactly one registration entry and one SVID. The Envoy
config requests that SVID by its SPIFFE ID, and the bundle by the trust
domain URI, exactly as in section 2. The agent serves a caller only the
secrets its own entries grant.

Two compose requirements follow: each Envoy container needs its own
`spiffe.lab/workload` label, and each Envoy container mounts the socket
volume read-only.

### 5.3 Envoy version pin: v1.39.0

The sdn PoC pins `envoyproxy/envoy:v1.39.0` and copies the binary into a
Debian image with a multi-stage `COPY`
(`local-compose/Dockerfile:1,16`). Zone-lab pins the same version, so the
recorded enforcement behavior stays comparable.

One v1.39.0 behavior is load-bearing for the tests: an upstream TLS failure
reason appears only in the `%UPSTREAM_TRANSPORT_FAILURE_REASON%` access-log
field. It does not appear in the response body.
The SAN-pin test greps that field for `verify_cert_failed:_SAN_match`.
Keep the field in every gateway access-log format.

Sources: `local-compose/conf/gateway-envoy.yaml:9-10,36`;
`forwarding-gateway/03-test-san-pin.sh:128,137`.

### 5.4 What stays the same

- The gateway shape: L7 RBAC, empty downstream `default_validation_context`,
  `require_client_certificate: true`, an exact upstream SAN pin.
- The backend shape: downstream SAN pin plus a network RBAC filter.
- The admin listener on `127.0.0.1:9901`. The tests cannot attribute a
  rejection without it.
- The counter-based test discipline: read before and after, never match
  client error text, and treat an unattributed failure as INCONCLUSIVE.
