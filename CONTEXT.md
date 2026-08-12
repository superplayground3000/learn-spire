# learn-spire

A lab series that teaches SPIFFE and SPIRE. Each lab changes the attestation
input and keeps the application code.

## Language

**Lab**:
One self-contained directory under `labs/` with its own code, scripts, and README.
_Avoid_: tutorial, example, exercise

**Attestation input**:
The runtime property that SPIRE reads to decide an identity. Lab 1 reads a UID,
Lab 2 reads a container label, Lab 3 reads Kubernetes metadata.
_Avoid_: identity source

**Delta discipline**:
The rule that a new lab changes the attestation input only. The Go programs, the
trust domain, the workload set, and the demos stay the same.

**Workload**:
One program that asks the Workload API for its identity. Each lab runs four:
server, client, intruder, and unregistered.
_Avoid_: service, app

**Ten security properties**:
The fixed list of assertions that `make test-integration` proves in every lab.

**Proof line**:
The last output line of registration. It comes from a real Workload API call,
not from a print of intent.
