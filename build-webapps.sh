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
#    We drop the cosmetic, environment-specific deploy steps so the build finishes
#    cleanly on any architecture without relying on --force (which does NOT bypass a
#    fatal abort, only soft task failures):
#      - imagemin/svgmin ship x86-only native binaries -> fatal on arm64.
#      - inline embeds the sdkjs/common startup scripts into index.html, but those
#        live outside web-apps, so it cannot run here. We keep the base image's
#        already-finalized index.html instead (see step 3), so this is moot.
docker run --rm -v "$PWD/web-apps":/web-apps -w /web-apps/build node:20-bookworm bash -lc "
  set -e
  [ -d node_modules ] || npm ci --omit=dev --no-audit --no-fund
  sed -i \"s/'imagemin', //g; s/'svgmin', //g; s/'inline', //g\" Gruntfile.js
  for ED in $EDITORS; do
    ./node_modules/.bin/grunt init-build-\$ED deploy-app-main
  done
"

# 3. Stage the built editors as the Docker build context.
rm -rf dist/apps
mkdir -p dist/apps
for ED in $EDITORS; do
  cp -R "web-apps/deploy/web-apps/apps/$ED" "dist/apps/$ED"
done

# Drop the editor HTML loaders so the overlay COPY does not clobber the base image's
# finalized ones. A web-apps-only build cannot inline the sdkjs/common startup
# scripts, so its index.html boots the editor in an unfinalized "dev" mode that
# races module loading and throws "Common.UI.Window.extend is not a function". The
# base onlyoffice/documentserver image already ships a correctly finalized
# index.html, and these loaders carry no analytics, so keeping the base ones is
# both safe and correct.
for ED in $EDITORS; do
  rm -f "dist/apps/$ED/main/index.html" "dist/apps/$ED/main/index_internal.html"
done

# 4. Gate: every editor bundle must be analytics-free, and no dev index may leak.
echo "Verifying staged editors:"
fail=0
for ED in $EDITORS; do
  f="dist/apps/$ED/main/code.js"
  te=$(grep -c trackEvent "$f" || true)
  leak="ok"; { [ -e "dist/apps/$ED/main/index.html" ] || [ -e "dist/apps/$ED/main/index_internal.html" ]; } && leak="DEV-INDEX-LEAKED"
  printf "  %-20s code.js=%-5s trackEvent=%-3s index=%s\n" "$ED" "$(du -h "$f" | cut -f1)" "$te" "$leak"
  [ "$te" = "0" ] || { echo "  FATAL: $ED code.js still contains analytics"; fail=1; }
  [ "$leak" = "ok" ] || { echo "  FATAL: $ED dev index.html not dropped"; fail=1; }
done
[ "$fail" = "0" ] || { echo "Build verification FAILED."; exit 1; }
echo "All editors analytics-free; base image's finalized index.html will be used."
echo "Next: build the image with dist/Dockerfile (see README)."
