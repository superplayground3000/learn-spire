# This file builds the one lab image. Lab 2 built two images, because the
# SPIRE agent needed a container of its own. Here the official
# ghcr.io/spiffe/spire-agent image runs the agent, so only the workload image
# stays.
#
#   target=workload  debian + the Go server, the Go client and the
#                    spire-agent CLI. All four workload pods use it.

# The download stage gets the SPIRE release and checks the checksum. Only the
# binary reaches the runtime image, so it needs no download tools.
FROM golang:1.26 AS spire

ARG SPIRE_VERSION=1.15.2
# The musl-static release build runs unmodified on the glibc runtime image.
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

# CGO_ENABLED=0 makes static Linux binaries that run on the runtime image.
# -trimpath keeps host paths out of the binaries, so builds stay reproducible.
RUN CGO_ENABLED=0 go build -trimpath -o /out/server ./cmd/server \
 && CGO_ENABLED=0 go build -trimpath -o /out/client ./cmd/client

# --- The workload image ------------------------------------------------------
# One image serves all four workloads. The service account of the pod decides
# the identity, so the image, the binary and the user are the same for all of
# them. Compare this with lab 2, where the container label decided.
FROM debian:bookworm-slim AS workload

# The CLI lets a demo ask the Workload API directly, without the Go binaries.
# inspect.sh also runs it to export the SVIDs.
# CAUTION: the CLI does not read SPIFFE_ENDPOINT_SOCKET. If a script runs the
# CLI, it must pass: -socketPath /run/spire/sockets/agent.sock
COPY --from=spire /out/spire-agent /usr/local/bin/spire-agent

# The two workload binaries carry no certificate and no secret. Each one asks
# the Workload API for an identity. The service account of its pod decides the
# answer.
COPY --from=gobuild /out/server /out/client /usr/local/bin/

# The agent socket directory. Each pod mounts the host directory here
# read-only. An explicit mode keeps the image the same as in lab 2.
RUN mkdir -p /run/spire/sockets && chmod 0755 /run/spire /run/spire/sockets

# All four workloads run as this one unprivileged user. Compare with lab 1:
# there the UID decided the identity. Here all workloads share one UID, and
# they still receive different identities, because the service account decides.
RUN useradd --uid 10000 --no-create-home --shell /usr/sbin/nologin workload
USER workload

ENV SPIFFE_ENDPOINT_SOCKET=unix:///run/spire/sockets/agent.sock

# Every workload pod gives its own command. This default keeps a container
# alive if someone starts the image by hand.
CMD ["sleep", "infinity"]
