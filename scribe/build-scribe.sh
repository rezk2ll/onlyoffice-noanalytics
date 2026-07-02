#!/usr/bin/env bash
# Build a multi-arch Scribe-patched OnlyOffice image.
#
# Assembles the overlay context — the patched sdkjs word bundle (sdk-all.js) plus
# the Scribe plugin at a pinned git ref, with the plugin's index.html cache-bust
# stamped — then hands it to ../dist/push-multiarch.sh, which builds amd64+arm64
# and pushes a single multi-arch tag (resilient to harbor.linagora.com's upload
# resets). The plugin and patch are version-locked to OnlyOffice build 9.4.0-129.
#
# The BASE_IMAGE picks the foundation:
#   • onlyoffice/documentserver:9.4.0.1                 -> stock + Scribe
#   • <registry>/twake-workplace/onlyoffice:9.4.0-noanalytics -> analytics-free + Scribe
#
# Prerequisites: docker login <registry>; arm64 emulation for the version guard:
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# Usage:
#   IMAGE=<repo:tag> BASE_IMAGE=<oo-image> ./scribe/build-scribe.sh
#
# Overridable via env: SCRIBE_REF (git tag/branch), SDK_URL, EXPECT_OO_VERSION,
# SCRIBE_REPO.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:?Set IMAGE, e.g. harbor.example.com/twake-workplace/onlyoffice:9.4.0.1-scribe-2026-06-29.14}"
BASE_IMAGE="${BASE_IMAGE:?Set BASE_IMAGE, e.g. onlyoffice/documentserver:9.4.0.1}"

SCRIBE_REPO="${SCRIBE_REPO:-https://github.com/Benibur/cozy-drive.git}"
SCRIBE_REF="${SCRIBE_REF:-scribe-2026-06-29.14}"      # plugin git tag (== SCRIBE_BUILD)
SDK_URL="${SDK_URL:-https://github.com/Benibur/sdkjs/releases/download/scribe-sdkjs-patch-9.4.0.129/scribe-sdkjs-patch-9.4.0.129.tar.gz}"
export EXPECT_OO_VERSION="${EXPECT_OO_VERSION:-9.4.0-129}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CTX="$WORK/ctx"; mkdir -p "$CTX"

# 1. Patched sdk-all.js (verify the patch is actually present before baking).
curl -fsSL "$SDK_URL" -o "$WORK/sdk.tar.gz"
mkdir -p "$WORK/sdk"; tar -xzf "$WORK/sdk.tar.gz" -C "$WORK/sdk"
cp "$(find "$WORK/sdk" -name sdk-all.js | head -1)" "$CTX/sdk-all.js"
grep -q GetInlineDrawings "$CTX/sdk-all.js" || { echo "sdk-all.js missing the patch (GetInlineDrawings)" >&2; exit 1; }
echo "sdk-all.js OK ($(wc -c <"$CTX/sdk-all.js") bytes, patch present)"

# 2. Scribe plugin at the pinned ref -> $CTX/scribe (drop stale pre-gzipped assets).
git clone --depth 1 --branch "$SCRIBE_REF" --filter=blob:none --sparse "$SCRIBE_REPO" "$WORK/repo" >/dev/null 2>&1
git -C "$WORK/repo" sparse-checkout set plugins/onlyoffice-scribe >/dev/null 2>&1
cp -a "$WORK/repo/plugins/onlyoffice-scribe" "$CTX/scribe"
find "$CTX/scribe" -name '*.gz' -delete 2>/dev/null || true

# 3. Cache-bust stamp: index.html -> code.js?v=<SCRIBE_BUILD>, so browsers re-fetch
#    on every plugin bump.
BUILD_STR="$(grep -o 'SCRIBE_BUILD *= *"[^"]*"' "$CTX/scribe/scripts/code.js" | sed 's/.*= *"//; s/".*//' | head -1 || true)"
TOKEN="$(printf '%s' "${BUILD_STR%% *}" | tr -c 'A-Za-z0-9._-' '-')"; [ -n "$TOKEN" ] || TOKEN="build"
sed -i -E "s#(src=\"scripts/code\.js)(\?v=[^\"]*)?\"#\1?v=${TOKEN}\"#" "$CTX/scribe/index.html"
echo "Scribe plugin $SCRIBE_REF, cache-bust ?v=${TOKEN}"

# 4. Dockerfile + hand off to the shared multi-arch build/push engine.
cp "$HERE/Dockerfile" "$CTX/Dockerfile"
IMAGE="$IMAGE" CONTEXT="$CTX" BASE_IMAGE="$BASE_IMAGE" EXPECT_OO_VERSION="$EXPECT_OO_VERSION" \
  "$HERE/../dist/push-multiarch.sh"
