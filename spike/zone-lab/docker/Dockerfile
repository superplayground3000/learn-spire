# THROWAWAY SPIKE image. It carries one binary set for every zone-lab node:
# the SPIRE agent, the Envoy proxy, and a few probe tools. The spike reuses one
# image for the agent, the gateway, the backend, and the client. Only the
# container label and the started process are different.
#
#   - The agent container runs the SPIRE agent.
#   - The gateway and backend containers run Envoy.
#   - The client container runs curl and the spire-agent CLI.

# The Envoy stage only gives its static binary to the runtime image.
FROM envoyproxy/envoy:v1.39.0 AS envoy

FROM debian:bookworm-slim

# The spike pins SPIRE 1.15.2, the same version as labs/docker-lab.
ARG SPIRE_VERSION=1.15.2
# The host is amd64. The musl release build is static and runs on glibc.
ARG SPIRE_TARBALL=spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz
ARG SPIRE_SHA256=3874d07ffeb6640bafb9fe6a538de06151f155d5ed2f8e8a51f138d2f51b8105

# curl and openssl make the mTLS probes. iproute2 shows the routes. procps
# gives pgrep and pkill, which the agent bootstrap needs. python3 serves the
# backend app.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl ca-certificates openssl iproute2 dnsutils netcat-openbsd procps python3 \
 && rm -rf /var/lib/apt/lists/*

# Download the SPIRE release and check the checksum. Only the agent binary
# reaches the runtime, so the image needs no build tools later.
RUN curl -fsSL -o /tmp/${SPIRE_TARBALL} \
      https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/${SPIRE_TARBALL} \
 && echo "${SPIRE_SHA256}  /tmp/${SPIRE_TARBALL}" | sha256sum -c - \
 && tar -xzf /tmp/${SPIRE_TARBALL} -C /opt --strip-components=1 \
      spire-${SPIRE_VERSION}/bin/spire-agent \
 && ln -s /opt/bin/spire-agent /usr/local/bin/spire-agent \
 && rm /tmp/${SPIRE_TARBALL} \
 && spire-agent --version

# Copy the Envoy binary from the pinned image. The debian base carries the
# libraries the binary needs, so a plain copy is enough.
COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy
RUN envoy --version >/dev/null && echo "envoy ok"

# /run/spire is the mount point of the shared socket volume. It holds the
# Workload API socket and the bootstrap trust bundle. /var/log/envoy holds the
# Envoy access log.
RUN mkdir -p /run/spire /var/log/envoy /var/log/lab /var/lib/spire/agent \
      /opt/spire/conf/agent /opt/www \
 && chmod 0755 /run/spire

# The container only stays alive. A bootstrap or a proof step starts the real
# process inside it.
CMD ["sleep", "infinity"]
