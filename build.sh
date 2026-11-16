#!/usr/bin/env sh

TAILSCALE_VERSION=1.104.4
VERSION=0.1.41
EMPTY_LAYER_SHA=5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef

set -eu

build_arch() {
    _name="$1"
    _platform="$2"
    _goarch="$3"
    _goarm="$4"
    _runtime_base="$5"
    _out="tailscale-${_name}.tar"
    shift 5
    if [ "${NO_CACHE:-}" = "1" ]; then set -- --no-cache; fi

    echo ">>> Building ${_name}  (${_platform}, GOARCH=${_goarch} GOARM=${_goarm:-none}) -> ${_out}"
    rm -f "${_out}"

    docker buildx build \
      --pull "$@" \
      --build-arg TAILSCALE_VERSION="$TAILSCALE_VERSION" \
      --build-arg VERSION_LONG="$VERSION_LONG" \
      --build-arg VERSION_SHORT="$VERSION_SHORT" \
      --build-arg VERSION_GIT_HASH="$VERSION_GIT_HASH" \
      --build-arg TARGETPLATFORM_GOARCH="${_goarch}" \
      --build-arg TARGETPLATFORM_GOARM="${_goarm}" \
      --build-arg RUNTIME_BASE="${_runtime_base}" \
      --platform "${_platform}" \
      --load -t "ghcr.io/fluent-networks/tailscale-mikrotik:${VERSION}-${_name}" .

    _layers=$(docker image inspect \
      --format '{{range .RootFS.Layers}}{{println .}}{{end}}' \
      "ghcr.io/fluent-networks/tailscale-mikrotik:${VERSION}-${_name}" | sed '/^$/d')
    _dups=$(printf '%s\n' "$_layers" | sort | uniq -d)
    if [ -n "$_dups" ]; then
        echo "ERROR: image has duplicate layers (RouterOS overlayfs will fail):" >&2
        printf '  %s\n' $_dups >&2
        exit 1
    fi
    if printf '%s\n' "$_layers" | grep -q "$EMPTY_LAYER_SHA"; then
        echo "ERROR: image has an empty layer (a RUN/COPY that changed nothing)." >&2
        exit 1
    fi
    echo ">>> Layer check OK ($(printf '%s\n' "$_layers" | wc -l | tr -d ' ') layers, no duplicates/empties)"

    skopeo copy \
      "docker-daemon:ghcr.io/fluent-networks/tailscale-mikrotik:${VERSION}-${_name}" \
      "docker-archive:${_out}"

    echo ">>> Done: ${_out}"
}

if [ ! -d ./tailscale/.git ]
then
    git -c advice.detachedHead=false clone https://github.com/tailscale/tailscale.git --branch v$TAILSCALE_VERSION
fi

_have=$(cat ./tailscale/VERSION.txt)
if [ "$_have" != "$TAILSCALE_VERSION" ]
then
    if [ -n "$(git -C ./tailscale status --porcelain)" ]; then
        echo "ERROR: ./tailscale is $_have with local changes; wanted $TAILSCALE_VERSION." >&2
        echo "       Commit/stash them, then re-run." >&2
        exit 1
    fi
    echo ">>> Moving ./tailscale from $_have to v$TAILSCALE_VERSION"
    git -C ./tailscale fetch --depth 1 origin tag "v$TAILSCALE_VERSION"
    git -C ./tailscale -c advice.detachedHead=false checkout "v$TAILSCALE_VERSION"
fi

TS_USE_TOOLCHAIN="Y"
cd tailscale && eval $(./build_dist.sh shellvars) && cd ..

TARGET="${1:-all}"

if [ "$TARGET" = "all" ] || [ "$TARGET" = "arm32" ]; then
    build_arch arm32 "linux/arm/v5" "arm"   "5" "arm32v5/debian:bookworm-slim"
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "arm64" ]; then
    build_arch arm64 "linux/arm64"  "arm64" ""  "arm64v8/debian:bookworm-slim"
fi

echo ">>> All requested builds complete."
ls -lh tailscale-*.tar 2>/dev/null || true
