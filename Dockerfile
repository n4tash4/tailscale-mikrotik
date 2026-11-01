# DUAL-ARCH BUILD
# ---------------
# This Dockerfile builds for TWO MikroTik CPU families from one source tree.
# build.sh drives it twice, once per arch, passing the build args below:
#
#   arm32v5 (soft-float)  — hAP ax S / hEX Refresh (MediaTek EN7562CT).
#                           The container runtime SIGILLs on ARMv7/hard-float,
#                           so Go must target GOARM=5 and the runtime base must
#                           be a soft-float (arm32v5) Debian port.
#   arm64   (ARMv8)        — RB5009 (Marvell Armada A72 / Cortex-A72) and other
#                           aarch64 boards. No GOARM / soft-float concern.
#
# Build args (with arm32v5 defaults so a bare `docker build` keeps old behaviour):
#   TARGETPLATFORM_GOARCH   Go GOARCH        (arm | arm64)
#   TARGETPLATFORM_GOARM    Go GOARM         (5 for arm32v5; empty for arm64)
#   RUNTIME_BASE            runtime base img (arm32v5/... | arm64v8/...)
############################################################################

# RUNTIME_BASE must be declared BEFORE the first FROM to be usable in a later
# FROM line (a "global" build arg). Declaring it only inside the runtime stage
# leaves it out of scope for that stage's FROM and buildx fails with
# "base name (${RUNTIME_BASE}) should not be blank". The default keeps the
# original arm32v5 behaviour; the runtime stage re-declares a bare ARG to pull
# this value into its scope.
ARG RUNTIME_BASE=arm32v5/debian:bookworm-slim

# Build stage runs on the native build host (BUILDPLATFORM) and cross-compiles
# to the target arch via GOARCH/GOARM below. This avoids needing an arm/v5
# variant of the golang image (which doesn't exist) and is much faster since
# it runs natively rather than under emulation.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build-env

WORKDIR /go/src/tailscale

COPY tailscale/go.mod tailscale/go.sum ./
RUN go mod download

# Pre-build some stuff before the following COPY line invalidates the Docker cache.
RUN go install \
    github.com/aws/aws-sdk-go-v2/aws \
    github.com/aws/aws-sdk-go-v2/config \
    gvisor.dev/gvisor/pkg/tcpip/adapters/gonet \
    gvisor.dev/gvisor/pkg/tcpip/stack \
    golang.org/x/crypto/ssh \
    golang.org/x/crypto/acme \
    github.com/coder/websocket \
    github.com/mdlayher/netlink

COPY tailscale/. .

# see build.sh
ARG VERSION_LONG=""
ENV VERSION_LONG=$VERSION_LONG
ARG VERSION_SHORT=""
ENV VERSION_SHORT=$VERSION_SHORT
ARG VERSION_GIT_HASH=""
ENV VERSION_GIT_HASH=$VERSION_GIT_HASH

# Per-arch Go build target. Defaults keep the original arm32v5 behaviour so a
# plain `docker build` (no build.sh) still produces an arm32v5 image.
#
# Why GOARM must be forced explicitly for arm32v5:
#   Tailscale's build tooling defaults GOARM to 5 (see tool/gocross/autoflags.go)
#   only when it isn't already "set". Process env vars alone were being
#   overridden; `go env -w` makes it stick unambiguously. MikroTik's container
#   runtime on the EN7562CT (hAP ax S / hEX Refresh) only supports arm32v5
#   soft-float despite the Cortex-A7 CPU — ARMv7 or hard-float binaries SIGILL.
#
# For arm64 there is no GOARM concept; build.sh passes TARGETPLATFORM_GOARM=""
# and GOARCH=arm64, which produces a standard ARMv8 binary.
ARG TARGETPLATFORM_GOARCH=arm
ARG TARGETPLATFORM_GOARM=5
RUN go env -w GOOS=linux GOARCH=${TARGETPLATFORM_GOARCH} GOTOOLCHAIN=local && \
    if [ -n "${TARGETPLATFORM_GOARM}" ]; then go env -w GOARM=${TARGETPLATFORM_GOARM}; fi

RUN go install -ldflags="-w -s\
      -X tailscale.com/version.Long=$VERSION_LONG \
      -X tailscale.com/version.Short=$VERSION_SHORT \
      -X tailscale.com/version.GitCommit=$VERSION_GIT_HASH" \
      -v ./cmd/tailscale ./cmd/tailscaled

# When cross-compiling (build host arch != target), Go writes to
# /go/bin/${GOOS}_${GOARCH}/. Normalise to /go/bin/ so the COPY below is simple.
# Covers both linux_arm (arm32) and linux_arm64 output dirs.
RUN if [ -d /go/bin/linux_arm ]; then mv /go/bin/linux_arm/* /go/bin/; fi; \
    if [ -d /go/bin/linux_arm64 ]; then mv /go/bin/linux_arm64/* /go/bin/; fi

# Runtime stage. The base image is arch-specific and supplied by build.sh:
#   arm32v5/debian:bookworm-slim   (soft-float — see note above)
#   arm64v8/debian:bookworm-slim   (ARMv8)
# The Alpine armv7 image links against ld-musl-armhf (hard-float) whose binaries
# SIGILL on the arm32 MikroTik runtime; Debian's arm32v5 port is soft-float and
# compatible. arm64 has no such caveat.
# Bare re-declaration brings the global RUNTIME_BASE (declared before the first
# FROM) into this stage's scope so it can be used in the FROM below.
ARG RUNTIME_BASE
FROM ${RUNTIME_BASE}

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates iptables iproute2 bash openssh-server curl jq busybox && \
    rm -rf /var/lib/apt/lists/*

# Use iptables-legacy for compatibility with the container runtime
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy || true; \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

# SSH host keys are generated at container startup (see tailscale.sh) rather
# than build time — generating RSA keys under arm/v5 QEMU emulation is
# unreliable, and per-container keys are better practice anyway.
RUN mkdir -p /var/run/sshd

COPY --from=build-env /go/bin/tailscale /usr/local/bin/
COPY --from=build-env /go/bin/tailscaled /usr/local/bin/
COPY sshd_config /etc/ssh/
COPY tailscale.sh /usr/local/bin

# Read-only JSON status endpoint (busybox httpd CGI, port 8088). Consumed by
# the RouterOS ts-primary script to gate the BGP export of 100.64.0.0/10.
COPY ts-status.cgi /www/cgi-bin/status
RUN chmod 0755 /www/cgi-bin/status

# Build-time smoke test: proves busybox httpd has CGI support and the CGI
# renders valid, fail-closed JSON when tailscaled is not running.
RUN busybox httpd -f -u nobody -p 127.0.0.1:18088 -h /www & pid=$!; sleep 1; \
    out=$(curl -fsS http://127.0.0.1:18088/cgi-bin/status) && \
    echo "status smoke test: $out" && \
    echo "$out" | jq -e '.schema == 1 and .gate.primary == false' >/dev/null; \
    rc=$?; kill "$pid"; exit $rc

EXPOSE 8088

EXPOSE 22
CMD ["/usr/local/bin/tailscale.sh"]
