# Zone-lab spike results

Ticket: wayfinder #42.
Status: the mechanism works. All three proofs PASS.
Date of the recorded run: 2026-08-12.

This is a THROWAWAY spike. It is not the lab. It proves the core mechanism
before the phase-1 lab starts.

## What the spike proves

One SPIRE agent uses `docker:label` attestation. The agent serves the Workload
API on a socket in a shared Docker volume. The volume crosses two internal
networks. An Envoy gateway gets its X.509 SVID and the trust bundle over SDS
from that shared socket. A client reaches a backend through the gateway over
mTLS. The client has no direct route to the backend.

## Topology

- Networks: `control` (normal bridge), `zone-a` (`internal: true`),
  `zone-b` (`internal: true`).
- `spire-server`: on `control`.
- `spire-agent`: on `control`, with `pid: "host"` and `/var/run/docker.sock:ro`.
  It serves the Workload API on the shared volume at `/run/spire/agent.sock`.
- `zone-b-gateway`: Envoy, on `zone-a` and `zone-b`,
  identity `spiffe://lab.local/zone-b/gateway`.
- `zone-b-backend`: Envoy plus a small HTTP app on `127.0.0.1:8080`, on `zone-b`,
  identity `spiffe://lab.local/zone-b/backend`.
- `zone-a-client`: on `zone-a`, identity `spiffe://lab.local/zone-a/client`.

The gateway, the backend, and the client sit on internal networks. They never
reach the SPIRE server over the network. They only use the shared socket. This
is the key result: the socket volume delivers identity across the network
boundary, so the server needs no route into a zone.

## How to run

    docker compose build
    docker compose up -d
    ./scripts/bootstrap.sh    # attests the one agent (join_token, pinned bundle)
    ./scripts/register.sh     # creates the three docker:label entries
    ./scripts/run-proofs.sh   # starts Envoy, runs the three proofs
    docker compose down -v     # teardown

## The three proofs (recorded run)

### Proof 1 — client to gateway to backend over mTLS: PASS

The client fetches its SVID as files from the shared socket. It then calls the
gateway with curl and the SVID. The gateway checks the client identity with an
L7 RBAC filter. It re-originates mTLS to the backend and pins the backend SVID.

Evidence:

    HTTP_CODE=200
    zone-lab-spike backend OK

The gateway access log records the full authenticated chain:

    [2026-08-12T14:10:28.106Z] "GET / HTTP/1.1" 200 -
      downstream_san="spiffe://lab.local/zone-a/client"
      upstream_host="172.30.20.50:9001"
      upstream_san="spiffe://lab.local/zone-b/backend"
      upstream_tls_fail="-"

### Proof 2 — direct client to backend is unreachable: PASS

The client tries to reach the backend IP on zone-b directly. The client is on
zone-a only. It has no route to zone-b.

Evidence:

    *   Trying 172.30.20.50:9001...
    * Immediate connect fail for 172.30.20.50: Network is unreachable

The client routing table has one route and no default route:

    172.30.10.0/24 dev eth0 proto kernel scope link src 172.30.10.20

The error is "Network is unreachable", not "Connection refused". This is the
correct proof: there is no route, so the packet never leaves the client. A
"Connection refused" would mean a route exists but a port is closed.

### Proof 3 — Envoy loads its cert and the trust bundle over SDS: PASS

The gateway admin stats show one success for each SDS secret. The cert secret
name is the workload SPIFFE ID. The bundle secret name is the trust domain URI.

Evidence (gateway `127.0.0.1:9901/stats`):

    sds.spiffe_lab.local.update_rejected: 0
    sds.spiffe_lab.local.update_success: 1
    sds.spiffe_lab.local/zone-b/gateway.update_rejected: 0
    sds.spiffe_lab.local/zone-b/gateway.update_success: 1

The backend Envoy loads its own secrets the same way:

    sds.spiffe_lab.local.update_success: 1
    sds.spiffe_lab.local/zone-b/backend.update_success: 1

The config dump confirms the active secret names and the update time:

    "name": "spiffe://lab.local/zone-b/gateway"
    "last_updated": "2026-08-12T14:10:24.782Z"
    "name": "spiffe://lab.local"
    "last_updated": "2026-08-12T14:10:24.781Z"

## Surprises the phase-1 spec must handle

1. **Envoy changes the SDS secret name in stat keys.** The `://` becomes `_`,
   but the `/` stays. So the cert stat key is
   `sds.spiffe_lab.local/zone-b/gateway.update_success`, and the bundle stat key
   is `sds.spiffe_lab.local.update_success`. A test that greps the raw SPIFFE ID
   with `://` finds nothing and reports a false FAIL. The lab tests must grep the
   sanitized name.

2. **The registration flag is `-dns`, not `-dnsName`.** The gateway SVID needs a
   DNS SAN, because a client uses curl and curl checks the hostname. A SPIFFE
   SVID has only a URI SAN by default. Add `-dns zone-b-gateway` to the gateway
   entry. Then curl to `https://zone-b-gateway:9000` verifies the chain and the
   hostname. Without the DNS SAN, curl fails with a name-mismatch error, and the
   client must fall back to `--insecure`, which weakens the proof.

3. **The label value is flat, but the SPIFFE path is nested.** The label value
   `zone-b-gateway` maps to the SPIFFE ID `spiffe://lab.local/zone-b/gateway`.
   The registration script cannot assume the SPIFFE path equals the label value,
   unlike the `labs/docker-lab` pattern. The map must be explicit.

4. **A workload needs no `control` network and no server route.** The socket
   volume alone carries the Workload API. This is the intended result, and it is
   worth an explicit note: do not add the workloads to the control network "to be
   safe", because that would break the isolation claim.

## Notes and limits (this is a spike)

- The agent bootstrap uses `join_token` with a pinned trust bundle. It does not
  use `insecure_bootstrap`. It copies the bundle from the running server.
- The gateway keeps the full enforcement shape from the sdn PoC: L7 RBAC on the
  downstream, an empty downstream validation context, an upstream SAN pin, and a
  backend that adds a network RBAC filter plus a downstream SAN pin. For the
  spike this is more than the minimum, but it reuses a proven config, so it
  lowers risk.
- The spike does NOT carry a SAN-pin negative test. The research notes require
  one for the real lab, because an inert SAN matcher passes a happy-path test.
  The phase-1 lab must add that negative test.
- SPIRE 1.15.2. Envoy v1.39.0. Host arch amd64.
