# One image carries every zone-lab node: the SPIRE agent, the Envoy proxy, the
# two Go apps, and a few probe tools. The agent, the gateways, the backends,
# the client, and the peer all use this image. Only the container label and the
# started process differ.
#
#   - The agent container runs the SPIRE agent.
#   - A gateway or a backend container runs Envoy.
#   - The backend container also runs the Go backend app on 127.0.0.1:8080.
#   - The client container runs the Go client and the spire-agent CLI.

# The Envoy stage gives only its static binary to the runtime image.
FROM envoyproxy/envoy:v1.39.0 AS envoy

# The download stage gets the SPIRE release and checks the checksum. Only the
# agent binary reaches the runtime image, so the image needs no download tools.
FROM golang:1.26 AS spire

ARG SPIRE_VERSION=1.15.2
# The host is amd64. The musl release build is static and runs on glibc.
ARG SPIRE_TARBALL=spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz
ARG SPIRE_SHA256=3874d07ffeb6640bafb9fe6a538de06151f155d5ed2f8e8a51f138d2f51b8105

RUN curl -fsSL -o /tmp/${SPIRE_TARBALL} \
      https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/${SPIRE_TARBALL} \
 && echo "${SPIRE_SHA256}  /tmp/${SPIRE_TARBALL}" | sha256sum -c - \
 && mkdir -p /out \
 && tar -xzf /tmp/${SPIRE_TARBALL} -C /out --strip-components=2 \
      spire-${SPIRE_VERSION}/bin/spire-agent \
 && rm /tmp/${SPIRE_TARBALL}

# The Go stage compiles the two apps. A developer thus needs no Go toolchain on
# the host. The apps use only the standard library.
FROM golang:1.26 AS gobuild

WORKDIR /src

# Copy the module files first. Docker then keeps the module cache in a cached
# layer while only the source code changes.
COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd

# CGO_ENABLED=0 makes static Linux binaries that run on the runtime image.
# -trimpath keeps host paths out of the binaries, so builds stay reproducible.
RUN CGO_ENABLED=0 go build -trimpath -o /out/backend ./cmd/backend \
 && CGO_ENABLED=0 go build -trimpath -o /out/client ./cmd/client

# --- The runtime image -------------------------------------------------------
FROM debian:bookworm-slim

# curl and openssl make the mTLS probes. iproute2 shows the routes. procps
# gives pgrep and pkill, which the agent bootstrap needs. netcat and dnsutils
# help the later property probes.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl ca-certificates openssl iproute2 dnsutils netcat-openbsd procps \
 && rm -rf /var/lib/apt/lists/*

COPY --from=spire /out/spire-agent /opt/spire/bin/spire-agent
RUN ln -s /opt/spire/bin/spire-agent /usr/local/bin/spire-agent

# Copy the Envoy binary from the pinned image. The debian base carries the
# libraries the binary needs, so a plain copy is enough.
COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy
RUN envoy --version >/dev/null && echo "envoy ok"

# The two Go apps carry no certificate and no secret. Envoy handles all mTLS.
COPY --from=gobuild /out/backend /out/client /usr/local/bin/

# /run/spire is the mount point of the shared socket volume. It holds the
# Workload API socket and the bootstrap trust bundle. /var/log/envoy holds the
# Envoy access log. /var/log/lab holds the agent and app logs.
RUN mkdir -p /run/spire /var/log/envoy /var/log/lab /var/lib/spire/agent \
      /opt/spire/conf/agent /opt/www \
 && chmod 0755 /run/spire

# The container only stays alive. bootstrap.sh or start-servers.sh starts the
# real process inside it.
CMD ["sleep", "infinity"]
