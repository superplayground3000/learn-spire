# SPIFFE / SPIRE Mini Lab — Design & Implementation Plan

## 1. Objective

Build a small, reproducible learning lab demonstrating the complete SPIFFE/SPIRE workload identity flow:

```text
Linux process
    ↓
Workload Attestation
    ↓
Selector
    ↓
SPIFFE ID
    ↓
X509-SVID
    ↓
SPIFFE Workload API
    ↓
mTLS
    ↓
Peer SPIFFE ID Authorization
```

The lab must make it obvious that:

1. Applications do not contain static TLS certificates.
2. Applications do not contain API keys or shared secrets.
3. SPIRE determines workload identity from runtime properties.
4. Workloads obtain short-lived X.509 identities from the Workload API.
5. Client and server authenticate each other using mTLS.
6. A workload with a valid but unauthorized SPIFFE ID must still be rejected.
7. An unregistered workload must not receive an identity.

---

# 2. Scope

Implement only:

```text
SPIRE Server
SPIRE Agent
Go API Server
Go Valid Client
Go Unauthorized Client
Unix Workload Attestation
X509-SVID
mTLS
SPIFFE ID authorization
```

Do NOT add:

```text
Kubernetes
Istio
Envoy
OPA
Vault
JWT-SVID
Federation
Multiple trust domains
HA SPIRE
Production PKI
```

Those belong in future labs.

---

# 3. Lab Environment

Use a reproducible Linux-based development environment.

Preferred interface:

```bash
make build
make lab-up
make demo
make inspect
make lab-down
```

The implementation may use Docker to provide the Linux environment, but the first lab should use the SPIRE Unix Workload Attestor rather than Docker workload selectors.

The lab container is only an educational representation of one Linux node. Do not describe it as a production SPIRE deployment architecture.

---

# 4. Trust Domain

Use:

```text
lab.local
```

All workload identities belong to:

```text
spiffe://lab.local
```

---

# 5. SPIFFE Identities

Create four identities.

## SPIRE Agent

```text
spiffe://lab.local/spire/agent
```

## Server workload

```text
spiffe://lab.local/server
```

Linux UID:

```text
10001
```

## Authorized client

```text
spiffe://lab.local/client
```

Linux UID:

```text
10002
```

## Unauthorized client

```text
spiffe://lab.local/intruder
```

Linux UID:

```text
10003
```

Also create an unregistered Linux user:

```text
UID 10004
```

This user intentionally has no SPIFFE registration entry.

---

# 6. Target Architecture

```text
                  ┌─────────────────────────┐
                  │      SPIRE Server       │
                  │                         │
                  │ Trust Domain: lab.local │
                  │ Registration Entries    │
                  │ Signing Authority       │
                  └───────────┬─────────────┘
                              │
                      Node Attestation
                        (join token)
                              │
                              ▼
                  ┌─────────────────────────┐
                  │       SPIRE Agent       │
                  │                         │
                  │ Unix Workload Attestor  │
                  │                         │
                  │ Workload API            │
                  │ /run/spire/agent.sock   │
                  └───────────┬─────────────┘
                              │
                ┌─────────────┼─────────────┐
                │             │             │
                ▼             ▼             ▼

             UID 10001     UID 10002     UID 10003
              server        client       intruder

                │             │             │
                ▼             ▼             ▼

             /server        /client      /intruder
             X509-SVID      X509-SVID    X509-SVID
```

Communication:

```text
client
spiffe://lab.local/client
        │
        │ SPIFFE mTLS
        ▼
server
spiffe://lab.local/server
```

Both sides MUST verify the peer SPIFFE ID.

---

# 7. SPIRE Server Configuration

Create:

```text
infra/spire/server.conf
```

Requirements:

```text
trust_domain = "lab.local"
bind_address = "0.0.0.0"
bind_port = "8081"

DataStore = sqlite
NodeAttestor = join_token
```

For this learning lab, local disk or memory key managers are acceptable.

Enable DEBUG or INFO logging so identity operations can be observed.

Do not configure Kubernetes plugins.

---

# 8. SPIRE Agent Configuration

Create:

```text
infra/spire/agent.conf
```

Requirements:

```text
trust_domain = "lab.local"
server_address = <spire server>
server_port = 8081

socket_path = "/run/spire/agent.sock"
```

Plugins:

```text
NodeAttestor "join_token"

WorkloadAttestor "unix"
```

The Workload API must be reachable through:

```text
unix:///run/spire/agent.sock
```

Applications should receive this via:

```bash
SPIFFE_ENDPOINT_SOCKET=unix:///run/spire/agent.sock
```

Applications must NOT know anything about SPIRE Server networking.

They communicate only with the local SPIRE Agent.

---

# 9. Agent Bootstrap

Automate the following sequence.

Start SPIRE Server.

Wait until:

```bash
spire-server healthcheck
```

succeeds.

Generate a one-time join token associated with:

```text
spiffe://lab.local/spire/agent
```

Equivalent operation:

```bash
spire-server token generate \
  -spiffeID spiffe://lab.local/spire/agent
```

Use that token to bootstrap SPIRE Agent.

Do not commit the token into Git.

The bootstrap process must be automated.

---

# 10. Registration Entries

Automatically create these registration entries.

## Server

```text
selector:
unix:uid:10001

SPIFFE ID:
spiffe://lab.local/server

parent:
spiffe://lab.local/spire/agent
```

Conceptually:

```text
IF workload.uid == 10001

THEN identity =
spiffe://lab.local/server
```

## Client

```text
selector:
unix:uid:10002

SPIFFE ID:
spiffe://lab.local/client
```

## Intruder

```text
selector:
unix:uid:10003

SPIFFE ID:
spiffe://lab.local/intruder
```

UID `10004` intentionally receives no entry.

Registration setup must be idempotent.

Running bootstrap multiple times should not create duplicate entries.

---

# 11. Go Server

Create:

```text
cmd/server/main.go
```

Use:

```text
github.com/spiffe/go-spiffe/v2
```

The server must use:

```text
workloadapi.X509Source
```

to obtain and continuously maintain its X509-SVID.

Do NOT:

```text
read cert.pem
read key.pem
mount Kubernetes secrets
generate self-signed application certificates
```

Create an mTLS HTTP server.

Listen on:

```text
:8443
```

Endpoint:

```http
GET /hello
```

Successful response:

```json
{
  "message": "hello from SPIFFE server",
  "server_id": "spiffe://lab.local/server",
  "client_id": "spiffe://lab.local/client"
}
```

The server must authorize ONLY:

```text
spiffe://lab.local/client
```

Use the go-spiffe TLS authorization helpers, conceptually:

```go
tlsconfig.AuthorizeID(
    spiffe://lab.local/client
)
```

Do not implement authorization based on:

```text
source IP
hostname
HTTP header
client-provided string
CN
```

Authorization must be based on the SPIFFE ID authenticated by the X509-SVID.

---

# 12. Go Client

Create:

```text
cmd/client/main.go
```

The client receives:

```text
spiffe://lab.local/client
```

through the Workload API.

The client must establish mTLS to the server.

The client must authorize ONLY:

```text
spiffe://lab.local/server
```

Conceptually use:

```go
tlsconfig.MTLSClientConfig(
    source,
    source,
    tlsconfig.AuthorizeID(serverID),
)
```

The client then requests:

```text
https://server:8443/hello
```

Expected result:

```text
TLS handshake successful

Authenticated server:
spiffe://lab.local/server

HTTP 200
```

---

# 13. Unauthorized Client

The same client binary should be runnable as UID:

```text
10003
```

This gives it:

```text
spiffe://lab.local/intruder
```

Important:

The intruder has a completely VALID X509-SVID.

Therefore this test must demonstrate:

```text
valid identity
≠
authorized identity
```

The server expects:

```text
spiffe://lab.local/client
```

but receives:

```text
spiffe://lab.local/intruder
```

Expected behavior:

```text
TLS handshake fails
```

The HTTP handler must never execute.

This is one of the most important demonstrations in the lab.

---

# 14. Unregistered Workload Test

Run a Workload API client as:

```text
UID 10004
```

There is no corresponding SPIRE registration entry.

Attempt to retrieve an X509-SVID.

Expected result:

```text
No identity issued
```

The test demonstrates:

```text
calling Workload API
does NOT automatically grant an identity
```

Identity requires successful workload attestation plus a matching registration entry.

---

# 15. Inspect Command

Implement:

```bash
make inspect
```

It should show:

```text
SPIRE agents
registration entries
SPIFFE IDs
server X509-SVID
client X509-SVID
certificate expiration
URI SAN
```

Prefer using official SPIRE CLI commands.

For certificate inspection, it is acceptable to temporarily export an SVID for educational inspection.

Example output should clearly expose:

```text
URI:
spiffe://lab.local/client
```

and:

```text
URI:
spiffe://lab.local/server
```

Temporary exported private keys must live only under a gitignored temporary directory.

Never commit them.

---

# 16. Demo Commands

Implement the following interface.

## Start

```bash
make lab-up
```

Expected:

```text
SPIRE Server healthy
SPIRE Agent attested
Registration entries created
Server workload running
```

## Successful authentication

```bash
make demo-ok
```

Expected:

```text
client SPIFFE ID:
spiffe://lab.local/client

server SPIFFE ID:
spiffe://lab.local/server

mTLS handshake: SUCCESS
HTTP status: 200
```

## Unauthorized identity

```bash
make demo-intruder
```

Expected:

```text
intruder SPIFFE ID:
spiffe://lab.local/intruder

mTLS handshake: DENIED
```

The command itself should treat this denial as a successful lab test.

## No workload identity

```bash
make demo-unregistered
```

Expected:

```text
UID 10004 has no matching registration entry

X509-SVID request: DENIED
```

## Inspect identities

```bash
make inspect
```

## Destroy lab

```bash
make lab-down
```

Remove runtime state so the lab can be rebuilt from zero.

---

# 17. Repository Layout

Target structure:

```text
spiffe-spire-lab/
│
├── README.md
├── Makefile
├── go.mod
├── go.sum
│
├── cmd/
│   ├── server/
│   │   └── main.go
│   │
│   └── client/
│       └── main.go
│
├── infra/
│   └── spire/
│       ├── server.conf
│       └── agent.conf
│
├── scripts/
│   ├── bootstrap.sh
│   ├── register.sh
│   ├── inspect.sh
│   ├── demo-ok.sh
│   ├── demo-intruder.sh
│   └── demo-unregistered.sh
│
├── docker/
│   └── Dockerfile
│
├── docker-compose.yml
│
└── tmp/
    └── .gitkeep
```

`tmp/` must be gitignored except `.gitkeep`.

---

# 18. README Requirements

README.md is part of the deliverable.

Assume the reader understands Docker/Linux but does NOT understand PKI or SPIFFE.

Explain the lab in this order:

```text
1. What problem are we solving?

2. What is the SPIFFE ID?

3. What does SPIRE Server do?

4. What does SPIRE Agent do?

5. What is workload attestation?

6. Why does UID 10002 receive
   spiffe://lab.local/client?

7. What is an X509-SVID?

8. What is the Workload API?

9. How does mTLS use those identities?

10. Why is intruder rejected even though its
    certificate is valid?
```

Include this mapping table:

```text
UID     SPIFFE ID
10001   spiffe://lab.local/server
10002   spiffe://lab.local/client
10003   spiffe://lab.local/intruder
10004   <none>
```

---

# 19. Security Constraints

The repository MUST NOT contain:

```text
static application private keys
static application certificates
hardcoded join tokens
API keys
passwords
shared secrets
```

Do not fake SPIFFE by manually generating certificates with OpenSSL.

All application identities must come from SPIRE through the SPIFFE Workload API.

Do not disable peer SPIFFE ID validation merely to make the demo work.

Do not use:

```go
InsecureSkipVerify: true
```

The authorized test must succeed through correct SPIFFE validation.

---

# 20. Tests

Add automated tests where practical.

At minimum provide an integration test script:

```bash
make test-integration
```

It must verify:

```text
[PASS] SPIRE server becomes healthy

[PASS] SPIRE agent becomes attested

[PASS] server registration entry exists

[PASS] client registration entry exists

[PASS] intruder registration entry exists

[PASS] authorized client → server succeeds

[PASS] server identity is verified by client

[PASS] client identity is verified by server

[PASS] intruder → server fails TLS authorization

[PASS] UID 10004 cannot obtain an SVID
```

Integration tests must fail if any of these security properties are not enforced.

---

# 21. Logging

Use readable logs.

Server startup should print:

```text
server starting
expected server SPIFFE ID:
spiffe://lab.local/server

authorized client:
spiffe://lab.local/client
```

Client should print:

```text
connecting to server

expected server:
spiffe://lab.local/server
```

Successful server request should print authenticated client SPIFFE ID.

Do not log:

```text
private keys
join tokens
raw sensitive credential material
```

---

# 22. Definition of Done

The lab is complete when a new developer can run:

```bash
git clone ...
cd spiffe-spire-lab

make lab-up
make demo-ok
make demo-intruder
make demo-unregistered
make inspect
make lab-down
```

and observe all three identity cases:

```text
CASE 1

registered +
correct SPIFFE identity
→ ALLOW


CASE 2

registered +
valid SVID +
wrong SPIFFE identity
→ DENY


CASE 3

not registered
→ NO SVID
```

The implementation must require zero manually-created application certificates.

---

# 23. Implementation Priorities

Implement in this exact order:

```text
Phase 1
SPIRE Server starts

        ↓

Phase 2
SPIRE Agent joins Server

        ↓

Phase 3
Unix UID selectors work

        ↓

Phase 4
CLI can fetch X509-SVID

        ↓

Phase 5
Go server gets its SVID

        ↓

Phase 6
Go client gets its SVID

        ↓

Phase 7
SPIFFE mTLS succeeds

        ↓

Phase 8
Wrong SPIFFE ID is rejected

        ↓

Phase 9
Unregistered workload is rejected

        ↓

Phase 10
Automate everything with Makefile
```

Do not proceed to Kubernetes or other features until all phases above work.

---

# 24. Optional Lab 1.5 — SVID Rotation

Only implement after the base lab works.

Configure a deliberately short X509-SVID lifetime suitable for a demo.

Keep client and server running.

Observe:

```text
SVID A
   ↓
expires / approaches rotation
   ↓
SPIRE provides SVID B
```

Demonstrate that the application does NOT:

```text
restart
reload cert.pem
restart container
receive a new Kubernetes Secret
```

The go-spiffe X509Source should receive the updated identity automatically.

Document certificate serial number / expiry changes.

---

# 25. Future Lab 2

Do NOT implement this now, but leave a section in README describing the next evolution.

Replace:

```text
unix:uid
```

with Docker workload attestation:

```text
docker:label
```

Example conceptual mapping:

```text
container label:

spiffe.lab/workload=client

        ↓

SPIRE Docker Workload Attestor

        ↓

docker:label:spiffe.lab/workload:client

        ↓

spiffe://lab.local/client
```

This will demonstrate that SPIFFE identity does not fundamentally depend on Linux UID.

Future Kubernetes version will then replace Docker metadata with:

```text
namespace
service account
pod metadata
```

while the Go client/server code should remain essentially unchanged.

---

# 26. Most Important Teaching Outcome

Design the code and README so that after completing the lab the reader can explain this sentence:

> The application never tells SPIRE what its identity is. SPIRE attests runtime properties of the calling workload, maps those properties through registration entries to a SPIFFE ID, and exposes the resulting short-lived cryptographic identity through the Workload API.

And this:

```text
SPIFFE ID
=
who the workload is

X509-SVID
=
cryptographic proof of that identity

SPIRE
=
system that attests and issues the identity

Workload API
=
how the application obtains the identity

mTLS
=
how two workloads prove those identities
to each other
```
