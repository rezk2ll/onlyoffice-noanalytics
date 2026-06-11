# OnlyOffice DocumentServer 9.4.0 — analytics removed

A custom build of the latest stable **OnlyOffice DocumentServer (`9.4.0`)** with the
Google Analytics tracking removed from the editors, by applying upstream web-apps
commit
[`48dcc5c`](https://github.com/ONLYOFFICE/web-apps/commit/48dcc5c22c8463a39c5368fcb3c55da793a915a9)
*("[all] removed Analytic module sources")*.

That commit landed on **2026-05-22**, three days *after* the `9.4.0` release
(2026-05-19), so it is **not** in the stock image — hence this overlay build.

## How it works

The official `onlyoffice/documentserver` image installs a prebuilt `.deb`, with the
editors deployed at `/var/www/onlyoffice/documentserver/web-apps/`. Instead of a
multi-hour full source build, this **overlays a patched web-apps build** onto the
official image:

1. **Patch** — `web-apps` pinned at the `9.4.0` base commit `1993a6d8`, with
   `analytics-removal.patch` applied (the upstream commit, regenerated to apply
   cleanly: 65 files, 4 insertions / 700 deletions).
2. **Build** — the 5 main editors (`document/spreadsheet/presentation/pdf/visio`)
   rebuilt via grunt inside a `node:20` container, producing analytics-free
   `code.js` bundles. `sdkjs`/`core` are unchanged and reused from the base image.
3. **Overlay** — `dist/Dockerfile`: `FROM onlyoffice/documentserver:9.4.0` +
   `COPY apps/ …/web-apps/apps/`. The overlay is pure JS/HTML, so it is
   architecture-independent → clean multi-arch (amd64 + arm64) with no emulation.

### Scope

The **5 main desktop editors** — where the Google Analytics module
(`UA-12442749-13`) and `trackEvent()` calls actually ran — are fully cleaned
(verified: 0 occurrences in the served bundles). The **mobile** and **embed**
editors are not rebuilt; they retain stock 9.4.0 behaviour. (Their analytics path
was already inert: the embed `Common.Analytics` object is never defined and
`initialize` is commented out.)

## Build & push (the part to finish on Harbor)

```bash
# 1. Rebuild the patched editor bundles into dist/apps/ (run natively, not emulated)
./build-webapps.sh

# 2. Log in to the target registry and push a multi-arch image
docker login harbor.example.com
IMAGE=harbor.example.com/onlyoffice/onlyoffice-noanalytics:9.4.0-noanalytics \
  dist/push-multiarch.sh
```

`dist/push-multiarch.sh` works with any registry (Harbor, GHCR, Docker Hub) — set
`IMAGE` accordingly. It creates a `docker-container` buildx builder if needed and
pushes a multi-arch manifest.

### Single-arch / local only

```bash
./build-webapps.sh
docker build -t onlyoffice-noanalytics:9.4.0-noanalytics dist/
docker run -d -p 80:80 onlyoffice-noanalytics:9.4.0-noanalytics   # http://localhost/
```

## Verification (already done on a local arm64 build)

- `healthcheck` returns `true`.
- All 5 served `code.js` bundles: full size, `trackEvent` / `component.Analytics` /
  `UA-12442749` = **0**, valid JS syntax. (Stock base had: doc=8, sheet=33,
  slide=35, pdf=25.)
- The Document Editor boots fully in a browser (toolbar, menus, panels) with no
  console errors.

## Repo layout

| Path | Purpose |
|------|---------|
| `analytics-removal.patch` | The analytics removal, applies onto web-apps `9.4.0` base `1993a6d8` |
| `build-webapps.sh` | Clone + patch + grunt build → `dist/apps/` |
| `dist/Dockerfile` | Overlay `apps/` onto `onlyoffice/documentserver:9.4.0` |
| `dist/push-multiarch.sh` | Build + push multi-arch image (set `IMAGE`) |

`web-apps/`, `dist/apps/`, and `node_modules/` are generated and git-ignored.
