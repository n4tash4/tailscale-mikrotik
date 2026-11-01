#!/usr/bin/env sh
# Updates the tailscale repository and runs `docker build` for EACH MikroTik
# CPU family we deploy to, producing one container-archive tar per arch.
#
############################################################################
#
# DUAL-ARCH OUTPUT
# ----------------
# This script now builds TWO images from the one source tree:
#
#   tailscale-arm32.tar  linux/arm/v5   soft-float  -> hAP ax S / hEX Refresh
#                                                       (MediaTek EN7562CT).
#                                                       ARMv7/hard-float SIGILLs
#                                                       on that runtime, so we
#                                                       target GOARM=5 + an
#                                                       arm32v5 Debian runtime.
#   tailscale-arm64.tar  linux/arm64    ARMv8       -> RB5009 (Cortex-A72) and
#                                                       other aarch64 boards.
#
# Upload whichever tar matches the target router (see README "Which tar for
# which device"). To build only one arch, pass its name:  ./build.sh arm64
#
# Requires Docker Buildx (https://docs.docker.com/buildx/working-with-buildx/)
# and skopeo. For cross-arch builds, register QEMU once:
#   docker run --privileged --rm tonistiigi/binfmt --install all
############################################################################

TAILSCALE_VERSION=1.102.4
VERSION=0.1.40

set -eu

# ---------------------------------------------------------------------------
# Arch matrix. Each row: <name> <buildx-platform> <GOARCH> <GOARM> <runtime-base>
# GOARM is empty for arm64 (no such concept). name drives the output filename
# tailscale-<name>.tar.
# ---------------------------------------------------------------------------
build_arch() {
    _name="$1"
    _platform="$2"
    _goarch="$3"
    _goarm="$4"
    _runtime_base="$5"
    _out="tailscale-${_name}.tar"

    echo ">>> Building ${_name}  (${_platform}, GOARCH=${_goarch} GOARM=${_goarm:-none}) -> ${_out}"
    rm -f "${_out}"

    # Layer cache is ON (go.mod/go.sum + `go mod download` layers get reused).
    # --pull re-checks the base images every build, so a new golang or
    # debian:bookworm-slim (security updates) invalidates the cache below it
    # instead of a stale apt layer living forever. NO_CACHE=1 forces a clean
    # rebuild.
    # shellcheck disable=SC2086
    docker buildx build \
      --pull ${_nocache} \
      --build-arg TAILSCALE_VERSION="$TAILSCALE_VERSION" \
      --build-arg VERSION_LONG="$VERSION_LONG" \
      --build-arg VERSION_SHORT="$VERSION_SHORT" \
      --build-arg VERSION_GIT_HASH="$VERSION_GIT_HASH" \
      --build-arg TARGETPLATFORM_GOARCH="${_goarch}" \
      --build-arg TARGETPLATFORM_GOARM="${_goarm}" \
      --build-arg RUNTIME_BASE="${_runtime_base}" \
      --platform "${_platform}" \
      --load -t "ghcr.io/fluent-networks/tailscale-mikrotik:${VERSION}-${_name}" .

    # RouterOS can't run images with an empty layer twice / any duplicate layer
    # (duplicate overlayfs lowerdir -> "could not mount overlayfs root").
    # Reject them here rather than discovering it on the router.
    _layers=$(docker image inspect \
      --format '{{range .RootFS.Layers}}{{println .}}{{end}}' \
      "ghcr.io/fluent-networks/tailscale-mikrotik:${VERSION}-${_name}" | sed '/^$/d')
    _dups=$(printf '%s\n' "$_layers" | sort | uniq -d)
    if [ -n "$_dups" ]; then
        echo "ERROR: image has duplicate layers (RouterOS overlayfs will fail):" >&2
        printf '  %s\n' $_dups >&2
        exit 1
    fi
    # sha256 of an empty layer tar: fine once, but flag it so it can't creep in.
    if printf '%s\n' "$_layers" | grep -q '5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef'; then
        echo "ERROR: image has an empty layer (a RUN/COPY that changed nothing)." >&2
        exit 1
    fi
    echo ">>> Layer check OK ($(printf '%s\n' "$_layers" | wc -l | tr -d ' ') layers, no duplicates/empties)"

    skopeo copy \
      "docker-daemon:ghcr.io/fluent-networks/tailscale-mikrotik:${VERSION}-${_name}" \
      "docker-archive:${_out}"

    echo ">>> Done: ${_out}"
}

# ---------------------------------------------------------------------------
# Refresh the tailscale source once (shared by both builds).
# ---------------------------------------------------------------------------
if [ ! -d ./tailscale/.git ]
then
    git -c advice.detachedHead=false clone https://github.com/tailscale/tailscale.git --branch v$TAILSCALE_VERSION
fi

# An existing checkout is NOT automatically on TAILSCALE_VERSION (the clone
# above only runs once). Move it to the requested tag, refusing if there are
# local changes so a patched tree is never silently discarded.
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

# NO_CACHE=1 ./build.sh  -> full clean rebuild (old behaviour).
_nocache=""
if [ "${NO_CACHE:-}" = "1" ]; then _nocache="--no-cache"; fi

TS_USE_TOOLCHAIN="Y"
cd tailscale && eval $(./build_dist.sh shellvars) && cd ..

# ---------------------------------------------------------------------------
# Select which arch(es) to build. No arg = both.
# ---------------------------------------------------------------------------
TARGET="${1:-all}"

if [ "$TARGET" = "all" ] || [ "$TARGET" = "arm32" ]; then
    build_arch arm32 "linux/arm/v5" "arm"   "5" "arm32v5/debian:bookworm-slim"
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "arm64" ]; then
    build_arch arm64 "linux/arm64"  "arm64" ""  "arm64v8/debian:bookworm-slim"
fi

echo ">>> All requested builds complete."
ls -lh tailscale-*.tar 2>/dev/null || true
