# The build stage compiles the Go workloads and downloads the SPIRE agent.
# Only the three binaries reach the node image, so a developer needs no Go
# toolchain on the host, and the node image needs no download tools.
FROM golang:1.26 AS build

ARG SPIRE_VERSION=1.15.2
# The musl-static release build runs unmodified on the glibc node image.
ARG SPIRE_TARBALL=spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz
ARG SPIRE_SHA256=3874d07ffeb6640bafb9fe6a538de06151f155d5ed2f8e8a51f138d2f51b8105

RUN curl -fsSL -o /tmp/${SPIRE_TARBALL} \
      https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/${SPIRE_TARBALL} \
 && echo "${SPIRE_SHA256}  /tmp/${SPIRE_TARBALL}" | sha256sum -c - \
 && mkdir -p /out \
 && tar -xzf /tmp/${SPIRE_TARBALL} -C /out --strip-components=2 \
      spire-${SPIRE_VERSION}/bin/spire-agent \
 && rm /tmp/${SPIRE_TARBALL}

WORKDIR /src

# Copy the module files first. Docker then keeps the downloaded modules in a
# cached layer while only the source code changes.
COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd

# CGO_ENABLED=0 makes static Linux binaries that run on the node image.
# -trimpath keeps host paths out of the binaries, so builds stay reproducible.
RUN CGO_ENABLED=0 go build -trimpath -o /out/server ./cmd/server \
 && CGO_ENABLED=0 go build -trimpath -o /out/client ./cmd/client

# The lab "node" is one Linux machine that runs the SPIRE agent and the
# workloads under different UIDs. It is a teaching stand-in for a single host,
# not a production SPIRE deployment.
FROM debian:bookworm-slim

# procps gives us ps/pkill: the scripts replace stale processes with them, and
# ps shows which UID a workload actually runs as.
RUN apt-get update \
 && apt-get install -y --no-install-recommends procps \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/spire-agent /opt/spire/bin/spire-agent
RUN ln -s /opt/spire/bin/spire-agent /usr/local/bin/spire-agent

# These are the four lab identities. Only the UID matters to SPIRE: the unix
# workload attestor reports unix:uid:<n>, and a registration entry maps that
# to a SPIFFE ID. 10004 is created on purpose and will never get an entry.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin server \
 && useradd --uid 10002 --no-create-home --shell /usr/sbin/nologin client \
 && useradd --uid 10003 --no-create-home --shell /usr/sbin/nologin intruder \
 && useradd --uid 10004 --no-create-home --shell /usr/sbin/nologin unregistered

# /run/spire holds the Workload API socket and the bootstrap trust bundle.
# Mode 0755 lets any UID connect to the socket; the agent decides who gets
# what.
RUN mkdir -p /run/spire /var/log/lab /var/lib/spire/agent /opt/spire/conf/agent \
 && chmod 0755 /run/spire /var/log/lab

# The image receives the two workload binaries. They carry no certificate and
# no secret: each one asks the Workload API for an identity, and the UID it
# runs under decides the answer.
COPY --from=build /out/server /out/client /usr/local/bin/

ENV SPIFFE_ENDPOINT_SOCKET=unix:///run/spire/agent.sock

# The node only stays alive; bootstrap.sh starts the agent inside it. Compose
# runs this under docker-init (init: true), so SIGTERM stops it immediately.
CMD ["sleep", "infinity"]
