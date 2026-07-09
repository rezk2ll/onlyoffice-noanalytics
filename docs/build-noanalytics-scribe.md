# Build the “analytics-free + Scribe” image

Step-by-step runbook for producing the OnlyOffice DocumentServer image that is
**both** analytics-free **and** carries the Scribe addon — written for someone who
has never seen this repo.

The variant is built in **two stages**: first the analytics-free image (the base),
then the Scribe overlay layered on top of it. The sdkjs / forms / plugin sources are
already pinned as defaults on this branch, so you only ever pass `IMAGE` and
`BASE_IMAGE`.

| Result image | Base | Analytics | Scribe |
|--------------|------|-----------|--------|
| `onlyoffice:9.4.0-noanalytics-scribe-<build>` | analytics-free | removed | yes |

## 0. Prerequisites (Linux host)

| Tool | Why |
|------|-----|
| **Docker** (with `buildx`) | every build runs in containers |
| **git**, **curl**, **python3**, **bash** | cloning, downloading `regctl`, decoding credentials |
| Network access to **GitHub** *and* **`harbor.linagora.com`** | the scripts clone sources and push the image |
| **Harbor credentials** | to publish |

Two things to keep in mind:

- **The analytics-free base must be pushed to a registry** before the Scribe stage:
  the multi-arch Scribe build pulls its `BASE_IMAGE` from a registry, not from the
  local Docker image store. Hence the order base → Scribe.
- **`build-webapps.sh` must run natively** (it is a CPU-heavy grunt build) — do
  **not** run it under QEMU emulation.

```bash
# Log in to Harbor (the credentials are reused by the push script)
docker login harbor.linagora.com

# Install arm64 emulation: needed for the multi-arch build AND for the Scribe
# overlay's version guard (a RUN step that executes once per architecture)
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

## 1. Get the repo and check out this branch

```bash
git clone https://github.com/linagora/onlyoffice-twake.git
cd onlyoffice-twake
git checkout feat/scribe-sdkjs-from-benibur

# Confirm you are on it (the correct source defaults live here):
git branch --show-current      # -> feat/scribe-sdkjs-from-benibur
```

On this branch the sources are already the defaults:

- sdkjs: `Benibur/sdkjs@integration/scribe-oo-9.4.0.129`
- forms addon: `ONLYOFFICE/sdkjs-forms@v9.4.0.129`
- Scribe plugin: `scribe-2026-07-09.1` (`Benibur/cozy-drive`)

You do **not** pass anything for these.

## 2. Build and push the analytics-free image (the base)

```bash
# Rebuild the 5 editors with Google Analytics removed -> dist/apps/
# (self-checks trackEvent=0; fails otherwise)
./build-webapps.sh

# Multi-arch (amd64+arm64) build + chunked push to Harbor
IMAGE=harbor.linagora.com/twake-workplace/onlyoffice-noanalytics:9.4.0-noanalytics \
  dist/push-multiarch.sh
```

## 3. Layer Scribe ON TOP of that base

```bash
IMAGE=harbor.linagora.com/twake-workplace/onlyoffice:9.4.0-noanalytics-scribe-2026-07-09.1 \
BASE_IMAGE=harbor.linagora.com/twake-workplace/onlyoffice-noanalytics:9.4.0-noanalytics \
  scribe/build-scribe.sh
```

`BASE_IMAGE` (the image from stage 2) is what makes the result analytics-free.
`scribe/build-scribe.sh` layers on top of it, with no other parameter: `sdk-all.js`
(Scribe patch + forms addon) compiled from Benibur/sdkjs, plus the Scribe plugin. It
**fails** if the patch, the forms API (`AscOForm`), or the base build version are not
as expected.

**Published result:** `onlyoffice:9.4.0-noanalytics-scribe-2026-07-09.1` — analytics
removed **and** Scribe.

> The `2026-07-09.1` suffix is a free-form build label — use today's date
> (`YYYY-MM-DD.n`) to trace each rebuild.

## 4. Verify the produced image

```bash
docker run --rm -p 8091:80 -e JWT_ENABLED=false \
  harbor.linagora.com/twake-workplace/onlyoffice:9.4.0-noanalytics-scribe-2026-07-09.1

# in another terminal:
curl -s localhost:8091/healthcheck                                    # true
SDK=$(curl -s localhost:8091/sdkjs/word/sdk-all.js)
printf '%s' "$SDK" | grep -c GetInlineDrawings                        # 4   (Scribe patch)
printf '%s' "$SDK" | grep -c AscOForm                                 # 69  (forms addon)
for ED in documenteditor spreadsheeteditor presentationeditor pdfeditor visioeditor; do
  echo -n "$ED trackEvent="; curl -s "localhost:8091/web-apps/apps/$ED/main/code.js" | grep -c trackEvent
done                                                                  # all 0 (analytics removed)
curl -s -o /dev/null -w "plugin %{http_code}\n" localhost:8091/sdkjs-plugins/scribe/index.html  # 200
```

All good when: `healthcheck=true`, `GetInlineDrawings=4`, `AscOForm=69`,
`trackEvent=0` everywhere, plugin `200`.

## Quick reference

```bash
git clone https://github.com/linagora/onlyoffice-twake.git && cd onlyoffice-twake
git checkout feat/scribe-sdkjs-from-benibur
docker login harbor.linagora.com
docker run --privileged --rm tonistiigi/binfmt --install arm64

./build-webapps.sh
IMAGE=harbor.linagora.com/twake-workplace/onlyoffice-noanalytics:9.4.0-noanalytics \
  dist/push-multiarch.sh

IMAGE=harbor.linagora.com/twake-workplace/onlyoffice:9.4.0-noanalytics-scribe-2026-07-09.1 \
BASE_IMAGE=harbor.linagora.com/twake-workplace/onlyoffice-noanalytics:9.4.0-noanalytics \
  scribe/build-scribe.sh
```

## See also

- [`../README.md`](../README.md) — the image family and overlay overview
- [`../scribe/README.md`](../scribe/README.md) — Scribe overlay internals, env vars, forms addon gotcha
- [`../dist/README.md`](../dist/README.md) — the multi-arch chunked push engine
