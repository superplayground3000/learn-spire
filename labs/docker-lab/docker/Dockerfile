# This file builds the two lab images from one set of stages. The agent image
# and the workload image share the same SPIRE download, so the checksum is
# written once.
#
#   target=agent     debian + the spire-agent binary. It waits, and
#                    bootstrap.sh starts the agent inside it.
#   target=workload  debian + the Go server, the Go client and the
#                    spire-agent CLI. Every workload container uses it.

# The download stage gets the SPIRE release and checks the checksum. Only the
# binary reaches the two runtime images, so they need no download tools.
FROM golang:1.26 AS spire

ARG SPIRE_VERSION=1.15.2
# The musl-static release build runs unmodified on the glibc runtime images.
ARG SPIRE_TARBALL=spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz
ARG SPIRE_SHA256=3874d07ffeb6640bafb9fe6a538de06151f155d5ed2f8e8a51f138d2f51b8105

RUN curl -fsSL -o /tmp/${SPIRE_TARBALL} \
      https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/${SPIRE_TARBALL} \
 && echo "${SPIRE_SHA256}  /tmp/${SPIRE_TARBALL}" | sha256sum -c - \
 && mkdir -p /out \
 && tar -xzf /tmp/${SPIRE_TARBALL} -C /out --strip-components=2 \
      spire-${SPIRE_VERSION}/bin/spire-agent \
 && rm /tmp/${SPIRE_TARBALL}

# The Go stage compiles the two workloads. A developer thus needs no Go
# toolchain on the host.
FROM golang:1.26 AS gobuild

WORKDIR /src

# Copy the module files first. Docker then keeps the downloaded modules in a
# cached layer while only the source code changes.
COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd

# CGO_ENABLED=0 makes static Linux binaries that run on the runtime images.
# -trimpath keeps host paths out of the binaries, so builds stay reproducible.
RUN CGO_ENABLED=0 go build -trimpath -o /out/server ./cmd/server \
 && CGO_ENABLED=0 go build -trimpath -o /out/client ./cmd/client

# --- The agent image ---------------------------------------------------------
# The container holds the SPIRE agent alone. No workload runs in it. The
# docker workload attestor reads the labels of the other containers through
# the Docker socket, so the agent container needs no workload in it.
FROM debian:bookworm-slim AS agent

# procps gives us pgrep/pkill. bootstrap.sh replaces a stale agent with them.
RUN apt-get update \
 && apt-get install -y --no-install-recommends procps \
 && rm -rf /var/lib/apt/lists/*

COPY --from=spire /out/spire-agent /opt/spire/bin/spire-agent
RUN ln -s /opt/spire/bin/spire-agent /usr/local/bin/spire-agent

# /run/spire is the mount point of the shared socket volume. It holds the
# Workload API socket and the bootstrap trust bundle. Mode 0755 lets every
# workload container connect to the socket. The agent decides who gets what.
RUN mkdir -p /run/spire /var/log/lab /var/lib/spire/agent /opt/spire/conf/agent \
 && chmod 0755 /run/spire /var/log/lab

# The container only stays alive. bootstrap.sh starts the agent inside it.
# Compose runs this under docker-init (init: true), so SIGTERM stops it
# immediately, and no agent process is left unreaped.
CMD ["sleep", "infinity"]

# --- The workload image ------------------------------------------------------
# One image serves all four workloads. The container label decides the
# identity, so the image, the binary and the user are the same for all of them.
# Compare this with lab 1, where the UID decided the identity.
FROM debian:bookworm-slim AS workload

# The CLI lets a demo ask the Workload API directly, without the Go binaries.
COPY --from=spire /out/spire-agent /usr/local/bin/spire-agent

# The two workload binaries carry no certificate and no secret. Each one asks
# the Workload API for an identity. The label of its container decides the
# answer.
COPY --from=gobuild /out/server /out/client /usr/local/bin/

# The shared socket volume is mounted here. Docker makes the directory anyway,
# but an explicit mode keeps the two images the same.
RUN mkdir -p /run/spire && chmod 0755 /run/spire

# All four workloads run as this one unprivileged user. Compare with lab 1:
# there the UID decided the identity. Here all workloads share one UID, and
# they still receive different identities, because the label decides.
RUN useradd --uid 10000 --no-create-home --shell /usr/sbin/nologin workload
USER workload

ENV SPIFFE_ENDPOINT_SOCKET=unix:///run/spire/agent.sock

# Every workload service in docker-compose.yml gives its own command. This
# default keeps a container alive if someone starts the image by hand.
CMD ["sleep", "infinity"]
