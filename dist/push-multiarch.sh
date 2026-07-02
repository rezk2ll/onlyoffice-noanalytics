#!/usr/bin/env bash
# Build a multi-arch (amd64 + arm64) OnlyOffice image and push it to a registry
# using regctl chunked blob uploads.
#
# By default it builds the analytics-free overlay (dist/Dockerfile + dist/apps/).
# It is also the shared build/push engine for the Scribe overlay — set CONTEXT,
# BASE_IMAGE and EXPECT_OO_VERSION to point it at another context (see
# ../scribe/build-scribe.sh).
#
# Why regctl chunked instead of `buildx --push` / `docker push`: harbor.linagora.com
# sits behind a proxy that times out (504) on a single large blob upload, so pushing
# the ~1GB base layer in one request never completes from a CI or slow network.
# regctl uploads each blob in small PATCH chunks (default 16MB), each a short request
# well under the proxy timeout, and resumes from the last offset on failure. It also
# pushes the multi-arch index directly, so there is no per-arch tag to clean up.
#
# Prerequisites:
#   - default (analytics-free) context: dist/apps/ must exist (run ../build-webapps.sh)
#   - docker login <registry>   (the credentials are reused for regctl)
#   - arm64 emulation if the Dockerfile has per-arch RUN steps (the Scribe guard does):
#       docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# Usage:
#   IMAGE=harbor.example.com/twake-workplace/onlyoffice-noanalytics:latest \
#     dist/push-multiarch.sh
#
#   # generic (used by the Scribe build):
#   IMAGE=<repo:tag> CONTEXT=<dir> BASE_IMAGE=<img> EXPECT_OO_VERSION=9.4.0-129 \
#     dist/push-multiarch.sh
set -euo pipefail

IMAGE="${IMAGE:?Set IMAGE, e.g. harbor.example.com/twake-workplace/onlyoffice-noanalytics:latest}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CTX="${CONTEXT:-$HERE}"                    # default: dist/ (analytics-free overlay)
REGISTRY="${IMAGE%%/*}"
TAG="${IMAGE##*:}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BLOB_CHUNK="${BLOB_CHUNK:-16000000}"       # 16MB PATCH chunks: short requests, under proxy timeouts
REGCTL_VERSION="${REGCTL_VERSION:-v0.11.5}"

if [ "$CTX" = "$HERE" ] && [ ! -d "$HERE/apps" ]; then
  echo "dist/apps/ missing — run ./build-webapps.sh first." >&2
  exit 1
fi

# --- regctl (download a pinned static binary if not already on PATH) ---------
regctl="$(command -v regctl || true)"
if [ -z "$regctl" ]; then
  case "$(uname -m)" in
    x86_64) rarch=amd64 ;;
    aarch64|arm64) rarch=arm64 ;;
    *) echo "unsupported host arch $(uname -m) for regctl" >&2; exit 1 ;;
  esac
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/regctl-${REGCTL_VERSION}"
  regctl="${cache}/regctl"
  if [ ! -x "$regctl" ]; then
    mkdir -p "$cache"
    # Download to a temp path first so an interrupted download can't leave a
    # broken (but executable) binary that the next run would reuse.
    curl -fsSL "https://github.com/regclient/regclient/releases/download/${REGCTL_VERSION}/regctl-linux-${rarch}" -o "${regctl}.tmp"
    chmod +x "${regctl}.tmp"
    mv "${regctl}.tmp" "$regctl"
  fi
fi

# --- reuse the docker login credentials for regctl, then enable chunking -----
# regctl needs the credential on its own host entry (a bare `registry set` would
# otherwise shadow the docker-config credential), so log in first, then set chunks.
cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
user="$(python3 -c "import json,base64;a=json.load(open('$cfg'))['auths']['$REGISTRY']['auth'];print(base64.b64decode(a).decode().split(':',1)[0])" 2>/dev/null || true)"
if [ -n "$user" ]; then
  # --skip-check: don't let a transient registry ping abort the run; the image
  # copy below performs (and retries) the real authentication.
  python3 -c "import json,base64;a=json.load(open('$cfg'))['auths']['$REGISTRY']['auth'];import sys;sys.stdout.write(base64.b64decode(a).decode().split(':',1)[1])" \
    | "$regctl" registry login "$REGISTRY" -u "$user" --pass-stdin --skip-check >/dev/null
else
  echo "warning: no inline credentials for $REGISTRY in $cfg; assuming regctl is already authenticated." >&2
fi
"$regctl" registry set "$REGISTRY" --blob-max "$BLOB_CHUNK" --blob-chunk "$BLOB_CHUNK" >/dev/null

# --- build a multi-arch OCI layout, then push it chunked ---------------------
BUILD_ARGS=()
[ -n "${BASE_IMAGE:-}" ]        && BUILD_ARGS+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")
[ -n "${EXPECT_OO_VERSION:-}" ] && BUILD_ARGS+=(--build-arg "EXPECT_OO_VERSION=${EXPECT_OO_VERSION}")

docker buildx inspect oo-builder >/dev/null 2>&1 || \
  docker buildx create --name oo-builder --driver docker-container --bootstrap >/dev/null

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
echo "### build ${PLATFORMS} -> OCI layout"
docker buildx build --builder oo-builder --platform "$PLATFORMS" \
  "${BUILD_ARGS[@]}" --output "type=oci,dest=${work}/oci,tar=false,name=${IMAGE}" "$CTX"

echo "### push chunked (${BLOB_CHUNK}B) -> ${IMAGE}"
"$regctl" image copy "ocidir://${work}/oci:${TAG}" "$IMAGE"

echo "Pushed multi-arch image: $IMAGE"
# Confirmation only; a flaky registry read here must not fail an already-good push.
docker buildx imagetools inspect "$IMAGE" 2>/dev/null | grep -E 'Platform:' | grep -v unknown || true
