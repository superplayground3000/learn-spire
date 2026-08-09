# The lab "node": one Linux machine that runs the SPIRE agent and, in later
# phases, several workloads under different UIDs. It is a teaching stand-in for
# a single host, not a production SPIRE deployment.
FROM debian:bookworm-slim

ARG SPIRE_VERSION=1.15.2
# musl-static release build: runs unmodified on this glibc base image.
ARG SPIRE_TARBALL=spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz
ARG SPIRE_SHA256=3874d07ffeb6640bafb9fe6a538de06151f155d5ed2f8e8a51f138d2f51b8105

# procps gives us ps/pkill: needed to replace a stale agent, and handy for
# seeing which UID a workload actually runs as.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl procps \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/${SPIRE_TARBALL} \
      https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/${SPIRE_TARBALL} \
 && echo "${SPIRE_SHA256}  /tmp/${SPIRE_TARBALL}" | sha256sum -c - \
 && mkdir -p /opt/spire/bin \
 && tar -xzf /tmp/${SPIRE_TARBALL} -C /opt/spire/bin --strip-components=2 \
      spire-${SPIRE_VERSION}/bin/spire-agent \
 && rm /tmp/${SPIRE_TARBALL} \
 && ln -s /opt/spire/bin/spire-agent /usr/local/bin/spire-agent

# The four lab identities. Only the UID matters to SPIRE: the unix workload
# attestor reports unix:uid:<n>, and a registration entry maps that to a
# SPIFFE ID. 10004 is created on purpose and will never get an entry.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin server \
 && useradd --uid 10002 --no-create-home --shell /usr/sbin/nologin client \
 && useradd --uid 10003 --no-create-home --shell /usr/sbin/nologin intruder \
 && useradd --uid 10004 --no-create-home --shell /usr/sbin/nologin unregistered

# /run/spire holds the Workload API socket and the bootstrap trust bundle.
# 0755 so any UID can connect to the socket; the agent decides who gets what.
RUN mkdir -p /run/spire /var/log/lab /var/lib/spire/agent /opt/spire/conf/agent \
 && chmod 0755 /run/spire /var/log/lab

ENV SPIFFE_ENDPOINT_SOCKET=unix:///run/spire/agent.sock

# The node just stays alive; bootstrap.sh starts the agent inside it. Compose
# runs this under docker-init (init: true), so SIGTERM stops it immediately.
CMD ["sleep", "infinity"]
