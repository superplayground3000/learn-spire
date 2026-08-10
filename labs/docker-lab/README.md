# SPIFFE/SPIRE Docker Attestation Lab

This is Lab 2 of the series. It answers one question. What happens when the
runtime property changes?

Lab 1 gave an identity to a Linux UID. This lab gives an identity to a
container label. The Go code stays the same, and the demos tell the same story.
Only the attestation input is different.

Read [Lab 1](../entry-lab/README.md) first. Lab 1 explains the SPIFFE ID, the
X509-SVID, the Workload API, mutual TLS, and rotation. This README does not
repeat those explanations. It shows the delta only.

Lab 1 ends with a sketch called "Future Lab 2: Docker label attestation". This
lab is that lab.

---

## Prerequisites

- Docker with the compose plugin, version 2.19 or later. The demo scripts use
  `--progress quiet`. An older plugin refuses that flag.
- GNU make.
- `openssl` on the host. `make inspect` reads the exported certificates with it.

The lab needs no Go toolchain. The Docker build compiles the two Go binaries.

---

## Quickstart

```bash
git clone https://github.com/superplayground3000/learn-spire.git
cd learn-spire/labs/docker-lab

make lab-up               # start SPIRE Server, attest the agent, register, run the API server
make demo-ok              # the client container authenticates and receives HTTP 200
make demo-intruder        # the intruder container holds a valid SVID, and the server denies it
make demo-unregistered    # a container without an entry receives no SVID
make demo                 # run the three demos in that order
make inspect              # show agents, registration entries, and the two X509-SVIDs
make test-integration     # rebuild the lab and assert the ten security properties
make lab-down             # delete the containers, the volumes, and the network
```

Run `make lab-up` first. The three demos and `make inspect` need a running lab.
`make lab-up` is safe to run again. `make lab-down` does not delete the exports
under `tmp/` (see the notes).

CAUTION: Do not run `make test-integration` while you use the lab. The command
deletes the lab before the test, and it leaves the lab down.

---

## What changed, and what did not

Three things changed.

| Item | Lab 1 | This lab |
| --- | --- | --- |
| Workload attestor | `unix` | `docker` |
| Runtime property | the UID of the process | the label of the container |
| Topology | one node container for the agent and all workloads | one container for each workload, and the agent alone |

Five things did not change.

The Go server and the Go client are the same programs. Only the comments and
one error text are different. The trust domain is still `lab.local`. The node
attestation still uses a one-time `join_token` and the same bootstrap sequence.
The mTLS logic still authorizes exactly one peer SPIFFE ID on each side. The
set of identities is still three, plus one workload with no entry.

That second list is the lesson of the lab. The platform decides the identity
input. The application code never sees the change.

---

## The label map

Each workload container carries the label `spiffe.lab/workload`. The value of
that label decides the identity.

| Label | Selector | SPIFFE ID |
| --- | --- | --- |
| `spiffe.lab/workload=server` | `docker:label:spiffe.lab/workload:server` | `spiffe://lab.local/server` |
| `spiffe.lab/workload=client` | `docker:label:spiffe.lab/workload:client` | `spiffe://lab.local/client` |
| `spiffe.lab/workload=intruder` | `docker:label:spiffe.lab/workload:intruder` | `spiffe://lab.local/intruder` |
| `spiffe.lab/workload=unregistered` | `docker:label:spiffe.lab/workload:unregistered` | none |

The last row is deliberate. `scripts/register.sh` creates three entries and
skips the fourth label. Access to the Workload API is not an identity.

Docker Compose adds its own labels to every container, for example
`com.docker.compose.project`. The agent reports each one as a selector. The lab
names none of them. Only `spiffe.lab/workload` is part of an identity rule.

---

## The chain, now real

Lab 1 sketched this chain. This lab runs it:

```text
container label:  spiffe.lab/workload=client
        ↓
SPIRE docker workload attestor
        ↓
docker:label:spiffe.lab/workload:client
        ↓
registration entry
        ↓
spiffe://lab.local/client
```

The registration entry is the rule in the middle. It is data in SPIRE Server,
and not code in the workload. A trimmed excerpt from a real run of
`make inspect` follows:

```text
Entry ID                : 183440e2-69e3-4f9b-a506-3ea77153ef0a
SPIFFE ID               : spiffe://lab.local/client
Parent ID               : spiffe://lab.local/node
Revision                : 0
X509-SVID TTL           : default
JWT-SVID TTL            : default
Selector                : docker:label:spiffe.lab/workload:client
```

Compare that entry with the client entry of Lab 1. One line is different:

```text
Lab 1      Selector : unix:uid:10002
This lab   Selector : docker:label:spiffe.lab/workload:client
```

The parent ID is the same node alias. `scripts/bootstrap.sh` binds that alias to
the agent, exactly as in Lab 1.

---

## One UID, four results

All four workload containers run the same image. All four run the same
unprivileged user, UID 10000. `docker/Dockerfile` creates that user once:

```dockerfile
RUN useradd --uid 10000 --no-create-home --shell /usr/sbin/nologin workload
USER workload
```

In Lab 1 the UID was the identity. Four UIDs gave four results. Here one UID
gives four results, because the UID is no longer the input. The label is.

The client and the intruder give even stronger evidence. They run the same
binary, `/usr/local/bin/client`, in the same image, under the same user. Only
the label differs, and SPIRE gives them different SPIFFE IDs. The intruder
demo proves it.

---

## How the attestor finds the calling container

A workload connects to the Workload API socket. The agent asks the kernel for
the PID of the caller. It then has to map that PID to a container.

The agent reads two files, in this order. First it reads `/proc/<pid>/cgroup`.
If that file holds no container ID, the agent reads `/proc/<pid>/mountinfo`.
Under cgroups v2 the first file often holds only `0::/`, so the second file
gives the container ID. The agent then asks the Docker daemon for the labels
of that container. It reports each label as a selector.

This is why the agent container needs the host PID namespace and the Docker
socket. The next section states the cost of that.

---

## Topology

The agent is alone in its own container. Each workload has one container of its
own. `make lab-up` leaves three containers running: the SPIRE server, the SPIRE
agent, and the API server.

```text
container: spire-server              container: spire-agent
+-----------------------+            +-----------------------------+
| SPIRE Server          |            | SPIRE Agent (root)          |
|  CA for lab.local     |<-- 8081 ---|  pid: "host"                |
|  registration entries |   attest,  |  /var/run/docker.sock (ro)  |
|  SQLite datastore     |   sign     |  /run/spire/agent.sock      |
+-----------------------+            +--------------+--------------+
                                                    |
                                     volume: spire-agent-socket
                              (each workload mounts it read-only)
                                                    |
        +-------------------+-------------------+---+---------------+
        |                   |                   |                   |
+-------+--------+ +--------+-------+ +---------+------+ +----------+---------+
| server  :8443  | | client         | | intruder       | | unregistered       |
| label=server   | | label=client   | | label=intruder | | label=unregistered |
+----------------+ +----------------+ +----------------+ +--------------------+
```

The compose service name `server` is also a network alias. So the client reaches
`https://server:8443/hello` with no host file and no DNS setup. In Lab 1 that
name pointed at the shared node container. Here it points at a real, separate
server container, and the mTLS handshake crosses a real network.

`make lab-up` starts the control plane and the API server only. The client, the
intruder, and the unregistered container use the `demo` compose profile. Each
demo starts one of them with `docker compose run --rm`, and deletes it after the
run. Compose starts a named service even when the service has a profile. It
does not start the other services of that profile.

### Security note

The agent container gets two powerful things:

- A mount of `/var/run/docker.sock`. Read-only access to that socket is still
  root-equivalent access to the host. The Docker API can start a container with
  any mount.
- `pid: "host"`. The agent container sees every process on the host.

The agent needs both, because the docker attestor reads `/proc/<pid>/` of the
caller and then queries the Docker daemon. This lab accepts that cost to teach
the attestor. A production deployment protects the agent host at the same level
as the Docker daemon itself.

The four workload containers need neither. They stay unprivileged. They run as
UID 10000. They get no Docker socket and no host PID namespace. Their mount of
the socket volume is read-only. A workload cannot delete or replace the Workload
API socket of its neighbors.

---

## Transcripts

Every transcript below comes from a real run of this lab. Each transcript
omits unrelated output.

### make lab-up

```text
COMPOSE="docker compose" ./scripts/bootstrap.sh
SPIRE Server healthy
trust bundle written to spire-agent:/run/spire/bootstrap.crt
join token generated, node alias spiffe://lab.local/node (token not shown)
SPIRE Agent attested
COMPOSE="docker compose" ./scripts/register.sh
  docker:label:spiffe.lab/workload:server -> spiffe://lab.local/server (created)
  docker:label:spiffe.lab/workload:client -> spiffe://lab.local/client (created)
  docker:label:spiffe.lab/workload:intruder -> spiffe://lab.local/intruder (created)
Registration entries created
label spiffe.lab/workload=client -> spiffe://lab.local/client
COMPOSE="docker compose" ./scripts/start-server.sh
Server workload running
```

The last line of `register.sh` is a proof, and not a message. The script starts
a labeled client container, asks the Workload API from it, and prints the answer.

### make demo-ok

```text
The client container carries the label spiffe.lab/workload=client.
SPIRE issues it an X509-SVID for spiffe://lab.local/client.
The client accepts only spiffe://lab.local/server.
The server accepts only spiffe://lab.local/client.
So the mTLS handshake must succeed.
The handler must answer.

client output:
client SPIFFE ID: spiffe://lab.local/client
connecting to server
expected server: spiffe://lab.local/server
url: https://server:8443/hello
mTLS handshake: SUCCESS
authenticated server: spiffe://lab.local/server
server certificate serial: 4A5E6ACDE0E0ED4EC293C50851B7BE3E
HTTP status: 200
body: {"message":"hello from SPIFFE server","server_id":"spiffe://lab.local/server","client_id":"spiffe://lab.local/client"}

server log: 2026/08/10 06:18:10 GET /hello from authenticated client: spiffe://lab.local/client

client SPIFFE ID: spiffe://lab.local/client
server SPIFFE ID: spiffe://lab.local/server
mTLS handshake: SUCCESS
HTTP status: 200
Lab test PASSED: two labeled containers authenticated each other with SPIFFE identities.
```

The output proves both directions. The client names the server that it
authenticated. The server log names the client that it authenticated.

### make demo-intruder

```text
intruder output:
client SPIFFE ID: spiffe://lab.local/intruder
connecting to server
expected server: spiffe://lab.local/server
url: https://server:8443/hello
client failed: request to https://server:8443/hello failed: Get "https://server:8443/hello": remote error: tls: bad certificate

intruder SPIFFE ID: spiffe://lab.local/intruder
client failed: request to https://server:8443/hello failed: Get "https://server:8443/hello": remote error: tls: bad certificate
server log: 2026/08/10 06:18:11 http: TLS handshake error from 172.22.0.5:56106: unexpected ID "spiffe://lab.local/intruder"
the server served no GET /hello during this demo

intruder SPIFFE ID: spiffe://lab.local/intruder (a valid SVID)
mTLS handshake: DENIED
Lab test PASSED: a valid identity is not an authorized identity.
```

The intruder SVID is real, and the CA of `lab.local` signed it. The server still
refuses it, because `spiffe://lab.local/intruder` is not the authorized peer. The
denial happens inside the TLS handshake. The HTTP handler never runs.

The transcript also shows the work of the label. The binary is the client
binary, and the line `client SPIFFE ID:` names `spiffe://lab.local/intruder`.
The label changed the identity of the same program.

### make demo-unregistered

```text
The container carries the label spiffe.lab/workload=unregistered.
registration entries for docker:label:spiffe.lab/workload:unregistered: 0
The container still reaches the Workload API through the socket volume.
The agent attests it and gets the selector docker:label:spiffe.lab/workload:unregistered.
No rule matches that selector, so the agent issues no SVID.

workload API error: rpc error: code = PermissionDenied desc = no identity issued

X509-SVID request: DENIED
Lab test PASSED: the Workload API grants no identity without an entry.
```

Attestation always runs. Attestation alone grants nothing. The agent attests
this container, finds no matching entry, and issues no SVID.

### make inspect

`make inspect` shows the attested agent, the four registration entries, and the
two X509-SVIDs. This is the SVID part of a real run:

```text
server X509-SVID (tmp/svid/server/svid.0.pem)
  subject=C=US, O=SPIRE
  serial=4A5E6ACDE0E0ED4EC293C50851B7BE3E
  notBefore=Aug 10 06:17:47 2026 GMT
  notAfter=Aug 10 07:17:57 2026 GMT
  X509v3 Subject Alternative Name:
      URI:spiffe://lab.local/server

client X509-SVID (tmp/svid/client/svid.0.pem)
  subject=C=US, O=SPIRE
  serial=AF8D96A3C5701A8FD437945347C4FBE1
  notBefore=Aug 10 06:17:47 2026 GMT
  notAfter=Aug 10 07:17:57 2026 GMT
  X509v3 Subject Alternative Name:
      URI:spiffe://lab.local/client
```

The server serial in this excerpt is the serial that the client saw in the
`make demo-ok` transcript above. The certificate that `inspect` exports is the
certificate that the server presented in the handshake.

---

## How the lab proves itself

`make test-integration` deletes the lab, builds it again from nothing, and then
asserts ten security properties. Lab 1 asserts the same ten properties with UID
selectors. This lab asserts them with label selectors. A trimmed report of a
real run follows:

```text
=== Phase 2: assert the ten security properties ===

[PASS] SPIRE server becomes healthy

[PASS] SPIRE agent becomes attested

[PASS] server registration entry exists

[PASS] client registration entry exists

[PASS] intruder registration entry exists

[PASS] authorized client → server succeeds

[PASS] server identity is verified by the client

[PASS] client identity is verified by the server

[PASS] intruder → server fails TLS authorization

[PASS] the unregistered label cannot obtain an SVID

10/10 properties hold
Integration test PASSED: the lab enforces all security properties.
```

The test deletes the lab again at the end. Run `make lab-up` to start it again.

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

---

## The pointer forward

The Kubernetes lab replaces the Docker metadata again:

```text
docker:label     ->    k8s namespace, service account, pod metadata
```

The registration entries change. The agent plugin changes. The Go server and the
Go client stay the same. They never ask for a UID, a label, or a pod. They ask
the Workload API for their identity, and the platform decides the answer.

That is the lesson of the whole series. The attestation input changes with the
platform. The application code does not.
