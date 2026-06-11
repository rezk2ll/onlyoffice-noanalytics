#!/usr/bin/env bash
# Build and push the analytics-free OnlyOffice DocumentServer 9.4.0 image as a
# multi-arch (amd64 + arm64) manifest to a registry (Harbor, GHCR, Docker Hub, ...).
#
# The overlay (apps/) is pure JS/HTML, so both arches reuse the same files with no
# per-arch rebuild — the only per-arch work is re-basing on each platform's
# onlyoffice/documentserver:9.4.0 base layer. Fast; no QEMU emulation needed.
#
# Prerequisites:
#   - dist/apps/ must exist (run ../build-webapps.sh first)
#   - docker login <registry>   (credentials with push rights to the target repo)
#
# Usage (Harbor example):
#   docker login harbor.example.com
#   IMAGE=harbor.example.com/onlyoffice/onlyoffice-noanalytics:9.4.0-noanalytics \
#     dist/push-multiarch.sh
set -euo pipefail

IMAGE="${IMAGE:?Set IMAGE, e.g. harbor.example.com/onlyoffice/onlyoffice-noanalytics:9.4.0-noanalytics}"
cd "$(dirname "$0")"

if [ ! -d apps ]; then
  echo "dist/apps/ missing — run ./build-webapps.sh first." >&2
  exit 1
fi

# A docker-container builder is required to emit a multi-platform manifest.
if ! docker buildx inspect oo-builder >/dev/null 2>&1; then
  docker buildx create --name oo-builder --driver docker-container --bootstrap
fi

docker buildx build \
  --builder oo-builder \
  --platform linux/amd64,linux/arm64 \
  --tag "$IMAGE" \
  --push \
  .

echo "Pushed multi-arch image: $IMAGE"
docker buildx imagetools inspect "$IMAGE"
