#!/usr/bin/env bash
# Rebuild the 5 analytics-free OnlyOffice editors and stage them under dist/apps/.
#
# Clones web-apps at the exact 9.4.0 base commit, applies analytics-removal.patch
# (upstream commit 48dcc5c, "[all] removed Analytic module sources"), and runs the
# grunt build inside a node:20 container — producing editor `code.js` bundles with
# the Google Analytics module and all trackEvent() calls removed.
#
# Output: dist/apps/<editor>/main/ for document/spreadsheet/presentation/pdf/visio.
# These are pure JS/HTML (architecture-independent) and are consumed by dist/Dockerfile.
#
# Run natively (do NOT run under QEMU emulation — the grunt build is CPU-heavy).
set -euo pipefail
cd "$(dirname "$0")"

BASE_COMMIT=1993a6d89731af0fcb5129ebf0ee380076fea5a9   # release/v9.4.0 tip the patch targets
EDITORS="documenteditor spreadsheeteditor presentationeditor pdfeditor visioeditor"

# 1. Clone web-apps and apply the analytics-removal patch.
if [ ! -d web-apps/.git ]; then
  git clone --branch release/v9.4.0 https://github.com/ONLYOFFICE/web-apps.git web-apps
fi
git -C web-apps fetch --depth 1 origin "$BASE_COMMIT" 2>/dev/null || true
git -C web-apps checkout -f "$BASE_COMMIT"
git -C web-apps reset --hard "$BASE_COMMIT"
git -C web-apps apply --whitespace=nowarn ../analytics-removal.patch
echo "Patch applied at base $BASE_COMMIT."

# 2. Build the editor bundles in a clean node:20 container.
#    --omit=dev avoids phantomjs (test-only dep, no arm64 binary).
#    --force skips the cosmetic imagemin step (PNG optimizer ships x86-only binary).
docker run --rm -v "$PWD/web-apps":/web-apps -w /web-apps/build node:20-bookworm bash -lc "
  set -e
  [ -d node_modules ] || npm ci --omit=dev --no-audit --no-fund
  for ED in $EDITORS; do
    ./node_modules/.bin/grunt --force init-build-\$ED deploy-app-main
  done
"

# 3. Stage the built editors as the Docker build context.
rm -rf dist/apps
mkdir -p dist/apps
for ED in $EDITORS; do
  cp -R "web-apps/deploy/web-apps/apps/$ED" "dist/apps/$ED"
done

echo "Done. Built editors:"
for ED in $EDITORS; do
  f="dist/apps/$ED/main/code.js"
  echo "  $ED: $(du -h "$f" | cut -f1)  trackEvent=$(grep -c trackEvent "$f" || true)"
done
echo "Next: build the image with dist/Dockerfile (see README)."
