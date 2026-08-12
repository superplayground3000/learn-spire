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
An attestation-series term. It names the fixed ten-property list that the
attestation labs (Labs 1 to 3) prove. It is not a universal list. Zone-lab
defines its own eleven-property list, P1 to P11.

**Proof line**:
The last output line of registration. It comes from a real Workload API call,
not from a print of intent.

## Zone-lab language

**Zone**:
One internal Docker network with a single trust boundary. A workload in a zone
reaches another zone only through a gateway.

**Gateway**:
An Envoy proxy that dual-homes two zones. It authorizes the caller at Layer 7,
logs the decision, and re-originates mTLS to the backend.

**Backend**:
The serving Envoy plus a plain-HTTP app in a zone. It pins the gateway SPIFFE ID
and rejects an unknown peer early.

**Enforcement point**:
The place that checks identity. Labs 1 and 2 enforce in the app code. Zone-lab
moves the enforcement point to Envoy.

**Bearer credential**:
A credential that works for whoever holds it. An X.509 SVID is one. A stolen
SVID still works. Short TTLs and memory-only keys reduce the risk.

**Revocation window**:
The worst-case time from a revoked entry to the end of access. There is no CRL,
so the SVID TTL bounds this window.
