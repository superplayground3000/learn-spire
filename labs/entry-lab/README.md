# SPIFFE/SPIRE Entry Lab

This lab shows how a program gets a cryptographic identity without a certificate
file. Two Go programs talk to each other over mutual TLS. Neither program
contains a certificate file, a key file, or an API key. A SPIRE agent gives each program an
identity, and the Linux UID of the process decides which identity it gets. The
lab also shows the two denials that matter: a valid identity that is not
authorized, and a process that gets no identity at all.

The lab needs Docker with the compose plugin, GNU make, and `openssl` on the
host. It needs no Go toolchain, because the image builds the two binaries.

---

## Quickstart

```bash
git clone https://github.com/superplayground3000/learn-spire.git
cd learn-spire/labs/entry-lab

make lab-up               # start SPIRE Server, attest the agent, register, run the API server
make demo-ok              # UID 10002 authenticates and receives HTTP 200
make demo-intruder        # UID 10003 holds a valid SVID for the wrong identity, and is denied
make demo-unregistered    # UID 10004 has no entry, and receives no SVID
make demo-rotation        # SPIRE replaces the SVID of the running server, which does not restart
make inspect              # show agents, registration entries, and the two X509-SVIDs
make test-integration     # rebuild the lab and assert the ten security properties
make lab-down             # delete the lab and all of its runtime state
```

Run `make lab-up` first. The three demos and `make inspect` need a running lab.
`make demo` runs the three demos in order.

`make lab-up` is safe to run again. A trimmed excerpt from a real first run
follows:

```text
SPIRE Server healthy
trust bundle written to node:/run/spire/bootstrap.crt
join token generated, node alias spiffe://lab.local/node (token not shown)
SPIRE Agent attested
  unix:uid:10001 -> spiffe://lab.local/server (created)
  unix:uid:10002 -> spiffe://lab.local/client (created)
  unix:uid:10003 -> spiffe://lab.local/intruder (created)
Registration entries created
Server workload running
```

CAUTION: `make test-integration` deletes the lab before it starts. Do not run it
while you use the lab. It leaves the lab down.

---

## 1. What problem are we solving?

Two services must prove to each other who they are. The common answers are a
shared secret in an environment variable, or a certificate and a key that an
operator copies into each machine. Both answers have the same three faults.

The secret is a file, so anyone who can read the file becomes the service. The
secret is long-lived, so a leak stays useful for months. The secret also gives
no process information. It proves only that the caller holds a string.

SPIFFE asks a different question. Instead of "which secret did you bring?", the
question becomes "which process are you, on which machine?". The platform
answers that question by inspection, and then issues a short-lived identity for
the answer. No operator puts a secret inside the application.

---

## 2. What is the SPIFFE ID?

A SPIFFE ID is the name of one workload. It is a URI with this shape:

```text
spiffe://<trust domain>/<path>
```

The trust domain names one identity authority. This lab uses `lab.local`, and
every identity in the lab belongs to `spiffe://lab.local`. The path names one
workload inside that domain.

This lab uses four names:

```text
spiffe://lab.local/server
spiffe://lab.local/client
spiffe://lab.local/intruder
spiffe://lab.local/node
```

A SPIFFE ID is only a name. It proves nothing on its own, in the same way that a
user name proves nothing without a password. Section 7 describes the document
that proves it.

---

## 3. What does SPIRE Server do?

SPIRE Server manages the trust domain. It does four things.

It holds the certificate authority of `lab.local`, and it signs every identity
document in the lab. It keeps the registration entries, which are the rules that
map runtime properties to a SPIFFE ID. It attests nodes, so that it knows which
machines are part of the trust domain. It answers the agents that ask for
identity documents on behalf of their workloads.

In this lab SPIRE Server runs in its own container and listens on port 8081. It
stores its data in a SQLite file and its CA key on disk, inside a Docker volume.
The configuration is `infra/spire/server.conf`. The CA lives for 24 hours, and
each workload identity lives for 1 hour.

No workload ever talks to SPIRE Server. Only the agent does.

---

## 4. What does SPIRE Agent do?

SPIRE Agent runs on the node, next to the workloads. It has two jobs.

First it proves the identity of the node to SPIRE Server. This step is node
attestation. This lab uses the `join_token` attestor: an operator mints a
one-time token on the server and gives it to the agent directly. The agent
joins once with that token, and then keeps its own identity document.

Second it serves the SPIFFE Workload API on a unix socket at
`/run/spire/agent.sock`. Any process on the node can connect to that socket. For
each caller the agent decides which identity that caller gets. It then asks the
server for the matching document, caches it, and renews it before it expires.

The configuration is `infra/spire/agent.conf`. `scripts/bootstrap.sh` starts the
agent inside the node container.

---

## 5. What is workload attestation?

Workload attestation is the step where the agent looks at the calling process
from the outside and reports what it finds.

A process connects to the Workload API socket. The process sends no token, no
password, and no name. The agent asks the kernel about the peer on the other end
of that socket. The `unix` workload attestor reports the properties that it
reads. Two of them are the user and the group of the process:

```text
unix:uid:10002
unix:gid:10002
```

These key/value pairs are selectors. The agent then reads its registration
entries and looks for entries whose selectors all match. A match produces an
identity. No match produces no identity.

The important property is negative: the process never states its own identity.
A program that claims to be the client changes nothing, because the claim is
never part of the input.

Attestation always runs, but attestation alone grants nothing. UID 10004 exists
on the node and reaches the socket like every other process. No registration
entry names UID 10004, so the agent issues nothing. A trimmed excerpt from a
real run of `make demo-unregistered` follows:

```text
UID 10004 has no matching registration entry
registration entries for unix:uid:10004: 0
The process still reaches the Workload API on the node.
The agent attests it, finds no matching entry, and issues no SVID.

workload API error: rpc error: code = PermissionDenied desc = no identity issued

X509-SVID request: DENIED
Lab test PASSED: the Workload API grants no identity without an entry.
```

---

## 6. Why does UID 10002 receive spiffe://lab.local/client?

Because one registration entry says so, and for no other reason.
`scripts/register.sh` creates three entries when the lab starts. This is the
entry for the client, trimmed from a real run of `make inspect`:

```text
Entry ID                : b89b2563-b8c5-49b6-b1a3-46a8d884e7a1
SPIFFE ID               : spiffe://lab.local/client
Parent ID               : spiffe://lab.local/node
Revision                : 0
X509-SVID TTL           : default
JWT-SVID TTL            : default
Selector                : unix:uid:10002
```

The entry is a rule. On the node `spiffe://lab.local/node`, a process with the
selector `unix:uid:10002` receives the SPIFFE ID `spiffe://lab.local/client`.

Nothing inside `cmd/client/main.go` names the client identity. The binary asks
the Workload API for "my identity" and prints the answer. The same binary runs
under UID 10003 in the intruder demo, and the answer is a different SPIFFE ID.
The UID is the input, and the registration entry is the rule.

---

## 7. What is an X509-SVID?

An X509-SVID is the document that proves a SPIFFE ID. SVID means SPIFFE
Verifiable Identity Document.

An X509-SVID is an ordinary X.509 certificate with one extra requirement: the
URI Subject Alternative Name holds the SPIFFE ID. That single field carries the
identity. The subject name carries no identity, and this lab shows the same
subject `C=US, O=SPIRE` on both certificates. The trust domain CA signs the
certificate, and the matching private key stays with the workload.

A trimmed excerpt for the two workloads, from a real run of `make inspect`,
follows:

```text
server X509-SVID (tmp/svid/server/svid.0.pem)
  subject=C=US, O=SPIRE
  serial=8DB933C168662DE2B7A0CB99069D434C
  notBefore=Aug  9 07:01:34 2026 GMT
  notAfter=Aug  9 08:01:44 2026 GMT
  X509v3 Subject Alternative Name:
      URI:spiffe://lab.local/server

client X509-SVID (tmp/svid/client/svid.0.pem)
  subject=C=US, O=SPIRE
  serial=9A3FDD02EA09323FFD4EC9A66AC71427
  notBefore=Aug  9 07:01:34 2026 GMT
  notAfter=Aug  9 08:01:44 2026 GMT
  X509v3 Subject Alternative Name:
      URI:spiffe://lab.local/client
```

The configured lifetime is one hour, and the server backdates the start a
little. The short life is deliberate. Nobody revokes these certificates.
SPIFFE replaces revocation with short lifetimes and automatic rotation.

---

## 8. What is the Workload API?

The SPIFFE Workload API is the interface between the workload and the agent. In
this lab it is a gRPC service on the unix socket `/run/spire/agent.sock`.

The API takes no credential. The caller sends no token, because the kernel
already tells the agent who the caller is. All UIDs can connect to the socket.
The agent uses workload attestation to decide which identity each caller gets.

The API returns three things: the X509-SVID, the matching private key, and the
trust bundle. The trust bundle holds the public CA certificates of the trust
domain. Each side uses it to verify the peer certificate.

The API does not return these things once. It keeps the
connection open and pushes a new document before the old one expires.

The Go code uses the `go-spiffe` v2 library:

```go
source, err := workloadapi.NewX509Source(ctx)
```

`workloadapi.NewX509Source` reads the socket address from the environment
variable `SPIFFE_ENDPOINT_SOCKET`. The node image sets that variable to
`unix:///run/spire/agent.sock`, so no path appears in the source code. The
returned `X509Source` holds the current SVID and the current trust bundle, and
it updates both while the program runs.

---

## 9. How does mTLS use those identities?

Mutual TLS means that both ends present a certificate. In this lab both ends
present the X509-SVID that the Workload API gave them. Both ends then verify
the peer certificate against the SPIRE trust bundle. The handshake also proves
that each side holds the private key of its certificate.

SPIFFE adds one step on top of normal TLS. After verification, each side reads
the URI SAN of the peer certificate and compares that SPIFFE ID with the one
it authorizes. The `go-spiffe` library performs this step:

```go
// server: present the server SVID, demand a client certificate, authorize one ID
tlsConfig := tlsconfig.MTLSServerConfig(source, source, tlsconfig.AuthorizeID(clientID))

// client: present the client SVID, authorize one server ID
tlsConfig := tlsconfig.MTLSClientConfig(source, source, tlsconfig.AuthorizeID(serverID))
```

The server authorizes `spiffe://lab.local/client` and no other peer. The
client authorizes `spiffe://lab.local/server` and no other peer. On the
client, the SPIFFE check replaces the usual host name check. So the name
`server` in the URL needs no certificate from a public CA.

A trimmed excerpt from a real run of `make demo-ok` follows:

```text
client output:
client SPIFFE ID: spiffe://lab.local/client
connecting to server
expected server: spiffe://lab.local/server
url: https://server:8443/hello
mTLS handshake: SUCCESS
authenticated server: spiffe://lab.local/server
HTTP status: 200
body: {"message":"hello from SPIFFE server","server_id":"spiffe://lab.local/server","client_id":"spiffe://lab.local/client"}

server log: 2026/08/09 07:01:58 GET /hello from authenticated client: spiffe://lab.local/client

client SPIFFE ID: spiffe://lab.local/client
server SPIFFE ID: spiffe://lab.local/server
mTLS handshake: SUCCESS
HTTP status: 200
Lab test PASSED: two workloads authenticated each other with SPIFFE identities.
```

The output proves both directions. The client names the server that it
authenticated. The server log names the client that it authenticated.

---

## 10. Why is intruder rejected even though its certificate is valid?

Because authentication and authorization are two different questions.

The intruder is the same client binary under UID 10003. Its registration entry
is real, its attestation succeeds, and SPIRE issues it a correct X509-SVID for
`spiffe://lab.local/intruder`. The trust domain CA signed that certificate, and
it is not expired. Every cryptographic test passes.

The server still denies it. `tlsconfig.AuthorizeID` authorizes exactly one
peer SPIFFE ID, and `spiffe://lab.local/intruder` is not that ID. The denial
happens inside the TLS handshake, so the connection never carries an HTTP
request. The handler never runs, and the application code makes no access
decision.

A trimmed excerpt from a real run of `make demo-intruder` follows:

```text
intruder SPIFFE ID: spiffe://lab.local/intruder
client failed: request to https://server:8443/hello failed: Get "https://server:8443/hello": remote error: tls: bad certificate
server log: 2026/08/09 07:01:58 http: TLS handshake error from 172.22.0.3:56048: unexpected ID "spiffe://lab.local/intruder"
the server served no GET /hello during this demo

mTLS handshake: DENIED
Lab test PASSED: a valid identity is not an authorized identity.
```

The client message `tls: bad certificate` is the TLS alert that the server sent.
The server log gives the real reason: `unexpected ID`. The certificate was good.
The identity was wrong.

This demo is the reason the lab has three workloads. A system that only tests
"is this certificate valid?" allows the intruder. A system that tests "which
SPIFFE ID is this?" denies it.

---

## UID to SPIFFE ID map

```text
UID     SPIFFE ID
10001   spiffe://lab.local/server
10002   spiffe://lab.local/client
10003   spiffe://lab.local/intruder
10004   <none>
```

The node image creates all four users. Only the first three have a registration
entry. UID 10004 is present on purpose, because "no entry" is a result that the
lab must show.

---

## How this lab maps to the architecture

The lab runs two containers.

The container `spire-server` runs the official SPIRE Server image and listens on
port 8081. The container `node` is a model of one Linux machine. It runs the
SPIRE agent as root, and it runs the workloads under UIDs 10001 to 10004. The
Go API server listens on port 8443 inside that container.

```text
container: spire-server                container: node
+----------------------+               +--------------------------------+
| SPIRE Server         |               | SPIRE Agent (root)             |
|  CA for lab.local    |<--- 8081 -----|  /run/spire/agent.sock         |
|  registration entries|   attest,     |                                |
|  SQLite datastore    |   sign SVIDs  |  server   UID 10001  :8443     |
+----------------------+               |  client   UID 10002            |
                                       |  intruder UID 10003            |
                                       |  (unregistered UID 10004)      |
                                       +--------------------------------+
```

CAUTION: the lab is a teaching model of one Linux node, and not a production
SPIRE deployment. A production deployment runs one agent for each machine. Its
server uses a production database and protected CA keys.

### Why all four workloads share the node

The `unix` workload attestor reads the properties of a process through the
kernel of the machine it runs on. It can only attest processes on its own node.
So the client, the intruder, and the unregistered process must live in the same
container as the agent.

That constraint has one visible effect. The client calls
`https://server:8443/hello`, and the name `server` resolves to the node
container itself, because the compose file gives that container the network
alias `server`. The client and the API server run on one machine, and the mTLS
handshake between them is still real.

### The join-token bootstrap

`scripts/bootstrap.sh` runs this sequence during `make lab-up`:

1. It waits until SPIRE Server answers its health check.
2. It copies the trust bundle from the server into the node, at
   `/run/spire/bootstrap.crt`. The agent needs that bundle before it connects,
   so that nobody can intercept the first connection.
3. It mints a one-time join token on the server, with the node alias
   `spiffe://lab.local/node`.
4. It starts the agent with that token. The token never reaches a file, a log
   line, or the repository. It is valid for one join only, so it is useless
   after the agent joins.
5. It waits until the agent answers on the Workload API socket.

The lab uses no `insecure_bootstrap`, and it commits no certificate. The running
server is the only source of trust.

### Two amendments to the original design

The design document names two details that the running lab does not use. Both
changes are deliberate.

The node alias is `spiffe://lab.local/node`, and not `spiffe://lab.local/spire/agent`.
SPIRE reserves the whole `/spire/...` path for itself and refuses to mint a
token for an ID in it.

The registration entries name `spiffe://lab.local/node` as their parent. The
identity that the agent receives from its join token looks like
`spiffe://lab.local/spire/agent/join_token/49c43414-...`, and that ID changes on
every join. A node alias is a second, stable identity for the same node, so the
workload entries can name a parent that survives a rejoin. `make inspect` shows
the alias entry next to the three workload entries:

```text
Entry ID                : 45b45936-cb08-40fa-9a6a-d76baae73241
SPIFFE ID               : spiffe://lab.local/node
Parent ID               : spiffe://lab.local/spire/agent/join_token/49c43414-92d6-4c05-9e01-18cc8d476bec
Selector                : spiffe_id:spiffe://lab.local/spire/agent/join_token/49c43414-92d6-4c05-9e01-18cc8d476bec
```

---

## How the lab proves itself

`make test-integration` deletes the lab, builds it again from nothing, and then
asserts ten security properties. A property that holds only after a manual
repair is not a property of the lab, so the test always starts from zero. A
trimmed excerpt of a real report follows:

```text
=== Phase 2: assert the ten security properties of section 20 ===

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

10/10 properties hold
Integration test PASSED: the lab enforces all security properties.
```

The test deletes the lab again at the end. Run `make lab-up` to start it again.

---

## The one sentence to remember

> The application never tells SPIRE what its identity is. SPIRE attests runtime
> properties of the calling workload, maps those properties through registration
> entries to a SPIFFE ID, and exposes the resulting short-lived cryptographic
> identity through the Workload API.

The five terms in that sentence have these meanings:

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

If you can explain that sentence and those five lines, the lab succeeded.

---

## Lab 2: Docker label attestation

This lab is now built. See [../docker-lab/](../docker-lab/).

This section describes the idea of that lab.

Lab 1 uses the Linux UID as the runtime property. That choice is easy to see and
easy to run. It also permits a wrong conclusion: that SPIFFE identity depends on
Unix users. It does not. Lab 2 replaces the selector type and keeps
everything else.

The `unix` workload attestor becomes the Docker workload attestor:

```text
unix:uid          ->    docker:label
```

The conceptual mapping becomes this chain:

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

The agent plugin, the registration entries, and the container layout change.
Each workload moves into its own container, because the Docker attestor
identifies containers, not users. The Go client and the Go server stay
essentially unchanged, because they never ask for a UID, a label, or a
container. They ask the Workload API for their identity, and the platform
decides the answer.

A Kubernetes lab comes after Lab 2. It replaces the Docker metadata again:

```text
namespace
service account
pod metadata
```

The same Go code keeps working there too. That is the lesson of the whole
series: the attestation input changes with the platform, and the application
code does not.

---

## Notes

### The tmp/ directory

`make inspect` exports the two X509-SVIDs, their private keys, and the trust
bundle to `tmp/svid/` on the host. The export exists so that you can read a real
certificate with `openssl`. Git ignores `tmp/`, and this material must never
reach a commit. `make lab-down` does not delete it. When you finish, delete it
yourself:

```bash
rm -rf tmp/svid
```

`make demo-rotation` writes certificates to `tmp/rotation/`. The certificates
contain no private keys. Delete the directory when you finish.

### SVID rotation (Lab 1.5)

The identities in this lab live for one hour. SPIRE replaces each identity
before it expires. The application continues to run. This demo shows that
change:

```bash
make demo-rotation
```

A one-hour lifetime is too long to watch. Therefore the demo uses a 60-second
lifetime. It writes `-x509SVIDTTL 60` into the server registration entry. The
lifetime belongs to one entry. `server.conf` does not change. Only the server
entry changes. The demo restores the first value at the end, also after a
failure or a Ctrl-C.

The demo then shows three certificates:

| Name | Where it comes from |
| --- | --- |
| SVID A | the identity that the server holds before the change |
| SVID B | the replacement that the shorter lifetime causes |
| SVID C | the rotation that time alone causes, at half of the lifetime |

The serial number and the expiry change for each one. The demo proves that the
same process keeps running through those changes:

- The PID of the server process does not change.
- The server log gets no second `server starting` line.
- The client prints the serial of the certificate that the server **presents**
  in the TLS handshake. That serial changes between the first request and the
  last request.

The last point is the strong one. The Workload API snapshots show what the
agent serves. The presented serial shows what the running server really uses.
The server took the new identity while it ran. It reloaded no `cert.pem`. It
restarted no container. It read no new secret. The go-spiffe `X509Source`
watches the Workload API and takes each new SVID by itself.

A trimmed excerpt from a real run follows:

```text
=== Before the change ===
server process PID    : 224
SVID A serial   : 59768A3003DC10AB060E7CBC23DCFD60
SVID A notAfter : Aug  9 08:45:47 2026 GMT

=== Shorten the lifetime of the server entry ===
  t+0s  serial 59768A3003DC10AB060E7CBC23DCFD60 (no change yet)
  t+5s  new serial D3262BD8E841A28057FD9C788D692196
SVID B notAfter : Aug  9 07:49:56 2026 GMT

=== Wait for a rotation that only time causes ===
  t+27s  new serial 739A538A947E0D0455A98FAC47EDDABA
SVID C notAfter : Aug  9 07:50:21 2026 GMT

=== Proof that the application kept running ===
SVID B is expired now.
mTLS handshake: SUCCESS
HTTP status: 200

server process PID before: 224
server process PID after : 224 (unchanged)
new 'server starting' lines in the server log: 0

Rotation demo PASSED: the SVID changed, and the workload kept running.
```

Two details in that transcript need an explanation:

1. The certificate lifetime reads 70 seconds, not 60. SPIRE dates each
   certificate 10 seconds before it issues it. That allowance covers a small
   difference between the clocks.
2. SVID B arrives in about 5 seconds, long before half of the old lifetime. The
   agent syncs the entries about every 5 seconds. A changed entry gets a new
   SVID at the next sync. Only SVID C shows the pure time-driven rotation.

The demo needs about two minutes. It keeps the three certificates in
`tmp/rotation/`, so you can read one yourself:

```bash
openssl x509 -in tmp/rotation/svid-a.pem -noout -text
```
