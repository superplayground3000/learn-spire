# Zone-lab — Phase 2 design notes (DNS steering, registry, lease)

This note locks the phase-2 architecture. It follows the decision in issue #44.
It fills the gaps that #44 left at the detail level. It is not a full spec. The
sdn PoC at `/media/hp/secondary/projects/sdn/poc/local-compose` is the reference
implementation. Phase 2 ports that design onto the phase-1 zone-lab.

## 1. Teaching frame

Phase 2 proves that DNS is steering, not a security boundary. CoreDNS cannot
enforce zoning. A client can hardcode an IP, edit `/etc/hosts`, or use DoH. So
phase 2 adds DNS and proves that a client which ignores DNS is still contained by
the phase-1 network and identity layers. That proof is the phase-2 punchline
test.

## 2. Do not regress phase 1

The eleven properties P1 to P11 must stay green. Phase 2 adds containers,
networks, and a registry. The additions must not create a data path between
zones. A zone-A workload must still not reach a zone-B backend (P1). Phase 2
extends `test-integration`; it never weakens it.

## 3. The management plane (this is the part #44 left open)

The registry needs a plane that every registering workload can reach. That plane
must not connect the zones to each other. Use the sdn design: one internal
management network per zone, and a registry that multi-homes on all three.

| Network | Type | Members |
| --- | --- | --- |
| mgmt-a | internal | zone-registry, zone-a workloads that register |
| mgmt-b | internal | zone-registry, zone-b workloads that register |
| mgmt-c | internal | zone-registry, zone-c workloads that register |

A workload on `mgmt-a` reaches the registry, which is also on `mgmt-a`. It does
not reach a zone-B workload, because that workload is on `mgmt-b`, a separate
network. The registry is the only container on more than one management network.
The data plane (`zone-a`, `zone-b`, `zone-c`) does not change. The control plane
(`control`, SPIRE server and agent) does not change.

`mgmt-*` is a management plane, not the SPIRE control plane. Phase-1 Trap 4 (a
workload needs no control network) still holds. The `control` network stays
limited to the server and the agent.

## 4. The registry (Go, behind an Envoy sidecar)

Per #44, the registry is a plain-HTTP Go program. It holds no identity code. An
Envoy sidecar in front of it terminates mTLS and passes the caller SPIFFE ID in
an `x-forwarded-client-cert` (XFCC) header. The registry reads the caller from
XFCC. This keeps the zone-lab thesis: the identity check is not in application
code, not even for the registry.

Port the logic of `registry/registry.py` (274 lines), not its transport:

- Authorize on the caller SPIFFE ID only. Take it from XFCC, not from the body.
  The body states intent; it is never evidence. Match the id against
  `^spiffe://lab.local/(?P<zone>[^/]+)/(?P<service>[^/]+)$`.
- A caller may register only its own zone and its own service. A cross-zone
  registration is refused with the reason `cross-zone registration refused`. A
  wrong-service registration is refused with the reason `service mismatch`.
- Hold a lease per record: `expires_at = now + LEASE_TTL`. Run a reaper thread.
  Re-render the views only when the record set changes, so the SOA serial does
  not bump on every reap tick.
- Endpoints: `POST /register` (also the renew path), `GET /registry`,
  `GET /views/<zone>`.
- Render one CoreDNS zone file per zone from three inputs:
  1. Registrations — a zone's own services resolve to their real addresses.
  2. Policy — each authorized peer zone gets one wildcard line. This scales with
     zones, not with services.
  3. The per-viewer gateway address — a gateway is multi-homed, so its address
     depends on which zone asks. The view hands out the address routable from the
     viewer.
- Policy comes from a `POLICY_JSON` environment variable at start. It is not an
  HTTP endpoint. An unauthenticated policy-rewrite endpoint would undermine the
  design.
- Write the rendered views to a shared `views` volume. The CoreDNS containers
  mount that volume read-only.

The registry needs its own SVID for its Envoy sidecar. Give the registry
container the label `spiffe.lab/workload=zone-registry` and the id
`spiffe://lab.local/mgmt/registry`. Register it in `register.sh` beside the
phase-1 entries.

## 5. The registrar

Port `registry/registrar.sh` (36 lines). A registrar loop renews each lease. It
re-fetches its SVID from the agent socket before every renewal. So a revoked
identity fails to renew, and its record ages out on its own. Revocation and
liveness share one mechanism.

Each backend runs a registrar for its own service. So `zone-b-backend` registers
`backend.zone-b`, and `zone-c-backend` registers `backend.zone-c`.

## 6. CoreDNS, one instance per zone

Run one CoreDNS per zone, `coredns/coredns` pinned. Each instance serves its own
zone's view file from the `views` volume. Use the `file` plugin with an SOA and
an NS, so an unauthorized name returns NXDOMAIN, not SERVFAIL. Set `reload` so a
new view reaches the resolver in a few seconds without a restart. Port the
`conf/coredns/Corefile.zone-*` files.

Each zone's workloads use that zone's CoreDNS as their resolver.

## 7. The new green properties (extend test-integration)

Number them from P12. Each verifies its premise and reads positive evidence.

- **P12 Self-zone resolves** — a zone resolves its own service to the real
  address.
- **P13 Authorized peer resolves to the gateway** — an authorized peer resolves
  the cross-zone name to the gateway address, never to the real backend address.
- **P14 Unauthorized zone gets NXDOMAIN** — an unauthorized zone gets NXDOMAIN,
  not SERVFAIL. A liveness control proves the resolver still answers a valid name.
- **P15 Cross-zone registration refused** — a caller cannot register into another
  zone. The reason string is exact.
- **P16 Wrong-service registration refused** — a caller cannot register a service
  that is not its own.
- **P17 Lease expiry reaps the record** — a record disappears after renewals
  stop. A renewing control must survive the same window, so the reap is
  attributable to the stopped renewal.
- **P18 Revoked identity ages out** — after the entry is deleted, the record ages
  out, because the registrar can no longer renew.
- **P19 DNS bypass is still contained** — a client that hardcodes the real
  backend address, ignoring DNS, is still stopped by the phase-1 network layer or
  identity layer. This is the punchline.

P1 to P11 still run and stay green. `test-integration` prints "N/19 properties
hold".

## 8. Make targets and layout

Add: `demo-register` (a registration walk-through), `demo-dns` (a resolution
walk-through), and the phase-2 assertions inside `test-integration`. Keep the
phase-1 targets. The registry code lives under `labs/zone-lab/registry/`. The
CoreDNS configs live under `labs/zone-lab/conf/coredns/`.

## 9. Security constraints

The phase-1 constraints hold. No static keys, certs, or tokens. Every identity
comes from SPIRE. The registry reads identity from XFCC, which Envoy sets from a
validated mTLS peer. State-mutating tests restore via an EXIT trap.
