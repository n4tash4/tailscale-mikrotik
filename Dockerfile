ARG RUNTIME_BASE=arm32v5/debian:bookworm-slim

FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS init-build
ARG TARGETPLATFORM_GOARCH=arm
ARG TARGETPLATFORM_GOARM=5
WORKDIR /src
COPY init/ .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETPLATFORM_GOARCH} GOARM=${TARGETPLATFORM_GOARM} GOTOOLCHAIN=local \
      go build -trimpath -ldflags="-s -w" -o /out/ts-init . && \
    go version -m /out/ts-init | grep -E 'GOARCH|GOARM'

FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build-env

WORKDIR /go/src/tailscale

COPY tailscale/go.mod tailscale/go.sum ./
RUN go mod download

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

ARG TAILSCALE_VERSION=""
RUN if [ -n "${TAILSCALE_VERSION}" ] && [ "$(cat VERSION.txt)" != "${TAILSCALE_VERSION}" ]; then \
      echo "ERROR: ./tailscale is $(cat VERSION.txt), expected ${TAILSCALE_VERSION}" >&2; exit 1; \
    fi

ARG VERSION_LONG=""
ENV VERSION_LONG=$VERSION_LONG
ARG VERSION_SHORT=""
ENV VERSION_SHORT=$VERSION_SHORT
ARG VERSION_GIT_HASH=""
ENV VERSION_GIT_HASH=$VERSION_GIT_HASH

ARG TARGETPLATFORM_GOARCH=arm
ARG TARGETPLATFORM_GOARM=5
RUN go env -w GOOS=linux GOARCH=${TARGETPLATFORM_GOARCH} GOTOOLCHAIN=local && \
    if [ -n "${TARGETPLATFORM_GOARM}" ]; then go env -w GOARM=${TARGETPLATFORM_GOARM}; fi

RUN go install -ldflags="-w -s\
      -X tailscale.com/version.Long=$VERSION_LONG \
      -X tailscale.com/version.Short=$VERSION_SHORT \
      -X tailscale.com/version.GitCommit=$VERSION_GIT_HASH" \
      -v ./cmd/tailscale ./cmd/tailscaled

RUN if [ -d /go/bin/linux_arm ]; then mv /go/bin/linux_arm/* /go/bin/; fi; \
    if [ -d /go/bin/linux_arm64 ]; then mv /go/bin/linux_arm64/* /go/bin/; fi

ARG RUNTIME_BASE
FROM ${RUNTIME_BASE} AS runtime

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates iptables iproute2 bash openssh-server curl jq busybox && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/ssh/ssh_host_*

RUN update-alternatives --set iptables /usr/sbin/iptables-legacy || true; \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

RUN mkdir -p /var/run/sshd

COPY --from=build-env /go/bin/tailscale /usr/local/bin/
COPY --from=build-env /go/bin/tailscaled /usr/local/bin/
COPY --from=init-build /out/ts-init /usr/local/sbin/ts-init
COPY sshd_config /etc/ssh/
COPY tailscale.sh /usr/local/bin

COPY --chmod=0755 ts-status.cgi /www/cgi-bin/status

RUN busybox httpd -f -u nobody -p 127.0.0.1:18088 -h /www & pid=$!; sleep 1; \
    out=$(curl -fsS http://127.0.0.1:18088/cgi-bin/status) && \
    echo "status smoke test: $out" && \
    echo "$out" | jq -e '.schema == 1 and .gate.primary == false' >/dev/null && \
    mkdir -p /usr/share/ts-status && \
    echo "$out" > /usr/share/ts-status/build-smoke-test.json; \
    rc=$?; kill "$pid"; exit $rc

EXPOSE 8088

EXPOSE 22

ENTRYPOINT ["/usr/local/sbin/ts-init", "--"]

CMD ["/usr/local/bin/tailscale.sh"]

FROM runtime AS final
ARG TAILSCALE_VERSION=""
LABEL net.tailscale.version="${TAILSCALE_VERSION}"
