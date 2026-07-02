#!/usr/bin/env bash
# Build and push a multi-arch (amd64 + arm64) OnlyOffice image to a registry
# (Harbor, GHCR, Docker Hub, ...).
#
# By default it builds the analytics-free overlay (dist/Dockerfile + dist/apps/).
# It is also the shared build/push engine for the Scribe overlay — set CONTEXT,
# BASE_IMAGE and EXPECT_OO_VERSION to point it at another context (see
# ../scribe/build-scribe.sh).
#
# Why not a plain `buildx --push`: harbor.linagora.com resets large blob uploads
# ("connection reset by peer" / HTTP 499) on the base-image layers, which kills a
# one-shot multi-platform push. Instead we build each arch to a per-arch tag,
# `docker push` it with retry-until-converge (each retry skips already-uploaded
# layers, so an intermittent reset just costs one more attempt), then stitch the
# two into one manifest and drop the per-arch helper tags.
#
# Prerequisites:
#   - default (analytics-free) context: dist/apps/ must exist (run ../build-webapps.sh)
#   - docker login <registry>   (push rights to the target repo)
#   - arm64 emulation if the Dockerfile has per-arch RUN steps (the Scribe guard does):
#       docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# Usage:
#   IMAGE=harbor.example.com/twake-workplace/onlyoffice:9.4.0-noanalytics \
#     dist/push-multiarch.sh
#
#   # generic (used by the Scribe build):
#   IMAGE=<repo:tag> CONTEXT=<dir> BASE_IMAGE=<img> EXPECT_OO_VERSION=9.4.0-129 \
#     dist/push-multiarch.sh
set -euo pipefail

IMAGE="${IMAGE:?Set IMAGE, e.g. harbor.example.com/twake-workplace/onlyoffice:9.4.0-noanalytics}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CTX="${CONTEXT:-$HERE}"                 # default: dist/ (analytics-free overlay)
REPO="${IMAGE%:*}"; TAG="${IMAGE##*:}"

if [ "$CTX" = "$HERE" ] && [ ! -d "$HERE/apps" ]; then
  echo "dist/apps/ missing — run ./build-webapps.sh first." >&2
  exit 1
fi

BUILD_ARGS=()
[ -n "${BASE_IMAGE:-}" ]         && BUILD_ARGS+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")
[ -n "${EXPECT_OO_VERSION:-}" ]  && BUILD_ARGS+=(--build-arg "EXPECT_OO_VERSION=${EXPECT_OO_VERSION}")

# A docker-container builder is required to emit a multi-platform manifest.
docker buildx inspect oo-builder >/dev/null 2>&1 || \
  docker buildx create --name oo-builder --driver docker-container --bootstrap >/dev/null

build_arch() { # platform arch
  echo "### build $2 ($1)"
  docker buildx build --builder oo-builder --platform "$1" \
    "${BUILD_ARGS[@]}" --tag "${REPO}:${TAG}-$2" --load "$CTX"
}

push_converge() { # image
  local img="$1" i
  for i in $(seq 1 15); do
    echo "--- push $img (attempt $i) ---"
    docker push "$img" 2>&1 | grep -vE 'Waiting|Preparing|Layer already exists' | tail -4 || true
    docker manifest inspect "$img" >/dev/null 2>&1 && { echo ">>> pushed $img"; return 0; }
  done
  echo "FAILED to push $img" >&2; return 1
}

build_arch linux/amd64 amd64; push_converge "${REPO}:${TAG}-amd64"
build_arch linux/arm64 arm64; push_converge "${REPO}:${TAG}-arm64"

echo "### combine -> ${IMAGE}"
for i in $(seq 1 10); do
  docker buildx imagetools create -t "$IMAGE" "${REPO}:${TAG}-amd64" "${REPO}:${TAG}-arm64" && break
  sleep 1
done

# Drop the per-arch helper tags — Harbor keeps the underlying manifests, which
# the multi-arch index still references. Best-effort, Harbor-only.
HOST="${REPO%%/*}"
if command -v curl >/dev/null 2>&1 && \
   python3 -c "import json,sys;sys.exit(0 if '$HOST' in json.load(open('$HOME/.docker/config.json')).get('auths',{}) else 1)" 2>/dev/null; then
  AUTH=$(python3 -c "import json;print(json.load(open('$HOME/.docker/config.json'))['auths']['$HOST']['auth'])")
  PR="${REPO#*/}"; PROJ="${PR%%/*}"; RNAME="${PR#*/}"
  for s in amd64 arm64; do
    curl -s -o /dev/null -w "untag ${TAG}-${s} -> HTTP %{http_code}\n" \
      -X DELETE -H "Authorization: Basic $AUTH" \
      "https://${HOST}/api/v2.0/projects/${PROJ}/repositories/${RNAME}/artifacts/${TAG}-${s}/tags/${TAG}-${s}" || true
  done
fi

echo "Pushed multi-arch image: $IMAGE"
docker buildx imagetools inspect "$IMAGE" | grep -E 'Platform:' | grep -v unknown
