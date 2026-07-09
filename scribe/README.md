# Scribe-patched OnlyOffice images

Layers the Scribe editor addon onto an OnlyOffice base image:

- a patched sdkjs word bundle (`sdk-all.js` with `ApiRun.GetInlineDrawings` and
  `Api.GetSelectionScreenRect`), compiled from
  [Benibur/sdkjs](https://github.com/Benibur/sdkjs) (branch
  `integration/scribe-oo-9.4.0.129`), and
- the Scribe plugin (`sdkjs-plugins/scribe`), from
  [Benibur/cozy-drive](https://github.com/Benibur/cozy-drive).

`build-scribe.sh` clones the sdkjs source branch, builds `sdk-all.js` from it (via
the vendored `sdkjs.Dockerfile.build`, a pure-Python `build/build.py` run — no
npm/JRE), assembles the overlay context with the plugin, and hands off to
[`../dist/push-multiarch.sh`](../dist/) to build and push multi-arch. The overlay
Dockerfile is `Dockerfile`.

## Version lock

The compiled patch and plugin are locked to OnlyOffice build **`9.4.0-129`**
(the `onlyoffice/documentserver:9.4.0.1` and `:9.4.0` tags are both that build).
A `RUN` guard in the Dockerfile fails the build on any other base, because a
version-mismatched `sdk-all.js` breaks the editor. That `RUN` executes per arch,
so arm64 needs emulation:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

## Build

```bash
docker login harbor.linagora.com

# Scribe on the analytics-free base (GA removed + Scribe):
IMAGE=harbor.linagora.com/twake-workplace/onlyoffice:9.4.0-noanalytics-scribe-2026-07-09.1 \
BASE_IMAGE=harbor.linagora.com/twake-workplace/onlyoffice:9.4.0-noanalytics \
  scribe/build-scribe.sh

# Scribe on stock OnlyOffice 9.4.0.1:
IMAGE=harbor.linagora.com/twake-workplace/onlyoffice:9.4.0.1-scribe-2026-07-09.1 \
BASE_IMAGE=onlyoffice/documentserver:9.4.0.1 \
  scribe/build-scribe.sh
```

Environment:

| var | default | purpose |
|-----|---------|---------|
| `IMAGE` | (required) | target `repo:tag` |
| `BASE_IMAGE` | (required) | foundation image (build `9.4.0-129`) |
| `SCRIBE_REF` | `scribe-2026-07-09.1` | plugin git tag (equals its `SCRIBE_BUILD`) |
| `SCRIBE_REPO` | `Benibur/cozy-drive` | plugin source repo |
| `SDKJS_REF` | `integration/scribe-oo-9.4.0.129` | patched sdkjs source branch |
| `SDKJS_REPO` | `Benibur/sdkjs` | repo holding the patched sdkjs source |
| `EXPECT_OO_VERSION` | `9.4.0-129` | version-guard value |

`build-scribe.sh` verifies both patched methods are present in `sdk-all.js` before baking and
stamps the plugin's `index.html` with `code.js?v=<SCRIBE_BUILD>` so browsers
re-fetch on every plugin bump.

## Smoke test

```bash
docker run --rm -p 8090:80 -e JWT_ENABLED=false <image>
curl -s localhost:8090/healthcheck                                   # true
curl -s localhost:8090/sdkjs/word/sdk-all.js | grep -c GetInlineDrawings   # > 0
```

The plugin is served at `/sdkjs-plugins/scribe/`; OnlyOffice discovers it from the
directory alone (no registration step). On the analytics-free base the editor
bundles keep `trackEvent=0`; on the stock base they retain upstream analytics.
