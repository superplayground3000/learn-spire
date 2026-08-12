# Zone-lab (phase 1)

This lab moves the enforcement point. Lab 1 and Lab 2 put the identity check
inside the Go program. The go-spiffe library authorized the peer. Zone-lab keeps
the same trust domain and the same SPIRE mechanism. It changes who enforces.
Envoy now terminates mTLS, authorizes the caller, and re-originates mTLS to the
next hop. The Go apps carry no identity code.

This README shows the delta only. It assumes you finished Lab 1 and Lab 2. It
does not repeat the SPIFFE ID, the X.509-SVID, the Workload API, or mTLS basics.

## Prerequisites

- Docker Engine with the Compose plugin. Tested on Docker 29.3, Compose v5.1.
- SPIRE 1.15.2 and Envoy v1.39.0. Both come from pinned images. The Docker build
  compiles the two Go binaries, so the host needs no Go toolchain.
- One lab runs at a time. The subnets are fixed. Run `make lab-down` before you
  re-up.

```bash
make lab-up            # start the lab, attest the agent, register, start servers
make test-integration  # assert P1 to P11 and the SAN-pin negative test
make demo              # the positive path
make lab-down          # destroy the lab and all runtime state
```

## 1. The one idea: the enforcement point moves to Envoy

In Lab 1 and Lab 2, the Go server called the go-spiffe library and authorized the
peer SPIFFE ID. Here the Go apps hold no TLS certificate and no go-spiffe code.
Envoy does every check. Each Envoy gets its SVID and the trust bundle over SDS
from the shared SPIRE agent socket.

## 2. The before/after contrast

| | Lab 1 and Lab 2 | Zone-lab |
| --- | --- | --- |
| Who terminates mTLS | the Go app (go-spiffe) | Envoy |
| Who authorizes the peer | the Go app | Envoy (RBAC and SAN pin) |
| Where the SVID lives | the app process | Envoy, over SDS |
| App identity code | yes | none |

The app stays small and plain. This contrast is the core teaching asset.

## 3. The three zones and the A-B-C policy

Three security zones exist. Zone A reaches Zone B. Zone B reaches Zone C. Zone A
cannot reach Zone C.

```
zone-a-client ──mTLS──▶ zone-b-gateway ──mTLS──▶ zone-b-backend
 (zone-a/client)        (zone-b/gateway)          (zone-b/backend)
                              │
                              └── zone-c-gateway ──▶ zone-c-backend  (B reaches C)
```

The topology encodes the policy. `zone-b-gateway` sits on zone-a and zone-b.
`zone-c-gateway` sits on zone-b and zone-c. Zone A holds no route to zone-c, so
Zone A cannot reach Zone C at all.

## 4. Two layers: network isolation and identity enforcement

The lab keeps two separate layers. Each layer holds on its own.

- **Network isolation.** The three zone networks use `internal: true`. An
  internal network has no off-network route. A blocked cross-zone probe returns
  "Network is unreachable", not "Connection refused". This difference is
  load-bearing for property P1.
- **Identity enforcement.** Envoy authorizes the caller by SPIFFE ID. Property P7
  proves this layer holds even after you add a route. The SAN pin still refuses
  the peer.

## 5. Why a shared socket volume does not break zone isolation

One SPIRE agent serves the Workload API on a socket in a shared volume. Every
workload mounts that volume read-only at `/run/spire`. The socket does not cross
a network. A shared mount is not a route. Only the server and the agent sit on
the control network. A workload gets its identity through the socket, with no
route to the server.

## 6. The gateway: L7 RBAC, empty downstream validation, the audit line

The gateway authorizes with the HTTP filter `envoy.filters.http.rbac`. The policy
is `ALLOW` with one exact principal. `zone-b-gateway` allows only
`spiffe://lab.local/zone-a/client`.

The gateway downstream keeps `require_client_certificate: true` and an empty
`default_validation_context: {}`. Chain validation still applies. A client
certificate is still required. The SAN is not restricted in the handshake.

Why: **auditability.** A SAN matcher rejects during the handshake. A handshake
rejection leaves no access-log line and no caller name. The L7 RBAC filter runs
after the request is parsed. So a denial is a logged 403 that names the caller.
This is the audit trail for property P5.

```
$ make demo-intruder
premise OK: the intruder holds a valid SVID (URI:spiffe://lab.local/zone-a/intruder)
the gateway answered HTTP 403
L7 RBAC counter moved: http.gateway.rbac.denied 0 -> 1
gateway audit line:
[...] "GET / HTTP/1.1" 403 - downstream_san="spiffe://lab.local/zone-a/intruder" upstream_san="-"
P5 PASSED: the gateway denied the intruder with a logged 403 that names it.
```

The positive path shows one line with both SANs (property P3):

```
$ make demo
client output:
HTTP status: 200
body: zone-lab backend zone-b OK
gateway audit line:
[...] "GET / HTTP/1.1" 200 - downstream_san="spiffe://lab.local/zone-a/client" \
      upstream_san="spiffe://lab.local/zone-b/backend" upstream_tls_fail="-"
```

## 7. The backend: the SAN pin plus network RBAC, defense in depth

The backend listener carries two mechanisms:

1. A downstream SAN matcher. It is an exact URI match on the gateway SPIFFE ID.
2. A network filter `envoy.filters.network.rbac`, `ALLOW`, with the same exact
   principal.

`zone-b-backend` accepts only `spiffe://lab.local/zone-b/gateway`. The SAN
matcher rejects a bad peer during the handshake. So the network RBAC filter
almost never sees a bad connection. The RBAC filter stays as defense in depth.

The gateway is the audit point. The backend sits behind it, so the backend
rejects early and cheaply in the handshake. The two sides differ on purpose.

## 8. SDS: how Envoy gets its SVID and the bundle

Every Envoy holds one extra cluster, `spire_agent`. It is a static cluster with
HTTP/2 to a Unix pipe at `/run/spire/agent.sock`. Each secret has an `sds_config`
that points at this cluster. The secret names follow one scheme:

| Secret | Name |
| --- | --- |
| The workload certificate | the workload SPIFFE ID, e.g. `spiffe://lab.local/zone-b/gateway` |
| The validation context | the trust domain URI, `spiffe://lab.local` |

The agent attests each SDS caller by its container label. So each Envoy maps to
one entry and one SVID. `make inspect` shows the SDS state per Envoy:

```
zone-b-gateway:
  sds.spiffe_lab.local.update_success: 1
  sds.spiffe_lab.local/zone-b/gateway.update_success: 1
```

## 9. The bearer-credential FINDING and its mitigations

An X.509 SVID is a bearer credential. A stolen SVID still works. The identity
layer does not stop it. This is a FINDING, not a "must be denied" property.

```
$ make demo-bearer
the donor zone-c-gateway now holds the stolen SVID: ...URI:spiffe://lab.local/zone-b/gateway
backend reply through the stolen SVID:
zone-lab backend zone-b OK
FINDING CONFIRMED: the backend ACCEPTED the stolen SVID (HTTP 200 body).
```

The demo copies the `zone-b/gateway` SVID into `zone-c-gateway`, a different
container on zone-b. It presents the stolen SVID to the zone-b backend with
openssl s_client. It disables no peer validation. The backend still checks the
chain and the SAN. The stolen SVID passes both, because a bearer credential works
for whoever holds it.

**Mitigations (stated, not enforced by identity):** memory-only private keys and
a short SVID TTL (5m). They shrink the theft window. They do not remove the
bearer property.

## 10. The TTL: why 5m is the revocation containment window

`default_x509_svid_ttl` is 5m from the start. There is no CRL. So the SVID TTL
bounds the worst-case time from a revoked entry to the end of access. Property P9
deletes the client entry, then polls. Access ends fast (a few seconds, one agent
sync), and any cached SVID cannot outlast the 5m TTL. Both facts stay under the
stated 10m policy bound.

Rotation runs through Envoy SDS, not the app. Lab 1 rotates through the go-spiffe
X509Source in app code. Here Envoy re-fetches the rotated SVID over SDS, with no
restart and no dropped connection:

```
$ make demo-rotation
backend leaf serial T0: C24FC417F0279F878B8CE4EA91B7B7EC
backend leaf serial T1: 4A106D7E18D50105F96ED174F2D6C042  (after 75s)
ROTATION OBSERVED: the backend leaf serial changed.
  the held connection was: still open
```

## 11. The property list and the outcome states

`make test-integration` proves eleven properties. It runs a full cycle
(lab-down, lab-up, assert, lab-down). It ends green every run. Each check
verifies its premise first, and reads positive evidence of the specific result.

| ID | Property | Positive evidence |
| --- | --- | --- |
| P1 | Network containment | zone-a probe "Network is unreachable"; the gateway control reaches the same address |
| P2 | Gateway path works | HTTP 200 and the real zone-b body |
| P3 | Gateway audit | one log line with both SANs |
| P4 | Backend identity verified | the audit line names `zone-b/backend` upstream |
| P5 | Rejection is auditable | a logged 403 and `http.gateway.rbac.denied` moves |
| P6 | No transit | the body is B's, not C's; zone-a cannot reach the C gateway |
| P7 | Defense in depth | add a route; the backend SAN counter moves; the peer is refused |
| P8 | Exact-match allowlist | `zone-b/gateway-evil` is refused; the SAN counter moves |
| P9 | Bounded revocation | access ends fast; the SVID lifetime is under the 10m bound |
| P10 | Intra-zone plaintext | the client reaches the peer over plain HTTP |
| P11 | Unregistered gets no SVID | `PermissionDenied ... no identity issued` |

The series PASS/FAIL grows two states:

- **FINDING** — a real, expected limitation. The bearer demo is a FINDING. It
  runs outside the green count.
- **INCONCLUSIVE** — the probe did not reach the thing under test. A "Connection
  refused" in P1 is INCONCLUSIVE, not PASS.

```
$ make test-integration
  P1   PASS
  P2   PASS
  ...
  P11  PASS
  SAN-pin negative test: PASS
  11/11 properties hold
RESULT: GREEN. All 11 properties hold and the SAN-pin test passed.
```

### The SAN-pin negative test (mandatory)

A SPIFFE validator silently drops a bad SAN matcher. A misconfigured pin does not
error; it stops checking. A happy-path test cannot tell "the pin matched" from
"the pin was skipped". So every SAN pin needs one proof that it can fail.

The request path has two SAN pins. `test-san-pin.sh` targets both:

- The **gateway upstream pin** names the backend identity. Repoint it, and the
  gateway access-log line for the marked request records
  `verify_cert_failed:_SAN_match`. Only the peer that runs the SAN check logs
  this reason, so the gateway logs it.
- The **backend downstream pin** guards the backend identity. Repoint it, and the
  backend counter `listener.0.0.0.0_9001.ssl.fail_verify_san` moves. A handshake
  abort writes no backend access-log line, so the counter is the evidence.

A bare failure is not proof. A network blip fails the same way. Only the
SAN-match reason, or the moved SAN counter, correlated by a query marker,
attributes the rejection to the pin.

## Notes: the four spike traps, as taught facts

1. **The SDS secret name in stat keys.** Envoy rewrites the SDS secret name.
   `://` becomes `_`. `/` stays. So the B-gateway certificate stat key is
   `sds.spiffe_lab.local/zone-b/gateway.update_success`. A grep for the raw
   `://` finds nothing and reports a false FAIL. The tests grep the sanitized
   name.
2. **The registration flag is `-dns`, not `-dnsName`.** A gateway SVID needs a
   DNS SAN. curl checks the hostname. A SPIFFE SVID carries only a URI SAN by
   default. `register.sh` adds `-dns zone-b-gateway`, so curl verifies the chain
   and the hostname without `--insecure`.
3. **The flat label maps to a nested SPIFFE path.** The label value
   `zone-b-gateway` maps to `spiffe://lab.local/zone-b/gateway`. The register
   script never assumes the SPIFFE path equals the label value. The map is
   explicit.
4. **A workload needs no control network.** The socket volume carries the
   Workload API. Do not add a workload to the control network "to be safe". That
   would break the isolation claim.

### One more, found in this lab

A single-file bind mount does not track a host edit. If you `sed -i` a mounted
Envoy config on the host, the container keeps the old file. So `test-san-pin.sh`
writes the broken config inside the container, then starts Envoy with it. The
restore points Envoy back at the canonical config path.
