# Multi-arch build & push

`push-multiarch.sh` builds an OnlyOffice image for `linux/amd64` + `linux/arm64`
and publishes it as one multi-arch tag. It builds the analytics-free overlay by
default, and doubles as the shared push engine for the [Scribe build](../scribe/).

## Why not a one-shot `buildx --push`

`harbor.linagora.com` resets large blob uploads (`connection reset by peer` /
HTTP 499) on the base-image layers, which kills a one-shot multi-platform push
partway through. The resets are intermittent, not a hard limit, so the script:

1. builds each arch to a per-arch tag (`:<tag>-amd64`, `:<tag>-arm64`) and
   `docker push`es it, **retrying until it converges** — each retry skips the
   layers already uploaded, so a reset just costs one more attempt;
2. stitches the two into one manifest with `docker buildx imagetools create`
   (manifests only, layers already present);
3. drops the per-arch helper tags via the Harbor API (the multi-arch index still
   references the underlying manifests).

Registries that accept the large concurrent upload work too — the retry loop
simply converges on the first attempt.

## Usage

```bash
docker login harbor.linagora.com

# analytics-free overlay (context = dist/, needs dist/apps from ../build-webapps.sh)
IMAGE=harbor.linagora.com/twake-workplace/onlyoffice:9.4.0-noanalytics \
  dist/push-multiarch.sh
```

Environment:

| var | purpose |
|-----|---------|
| `IMAGE` | target `repo:tag` (required) |
| `CONTEXT` | build context dir (default `dist/`) |
| `BASE_IMAGE` | passed as `--build-arg BASE_IMAGE` when the Dockerfile takes one |
| `EXPECT_OO_VERSION` | passed as `--build-arg EXPECT_OO_VERSION` (version guard) |

## arm64 emulation

Not needed for the analytics-free overlay (COPY-only, arch-independent). It **is**
needed when the Dockerfile has a per-arch `RUN` (the Scribe version guard does):

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

## Single-arch / local only

```bash
../build-webapps.sh
docker build -t onlyoffice-noanalytics:9.4.0-noanalytics .
docker run -d -p 80:80 onlyoffice-noanalytics:9.4.0-noanalytics   # http://localhost/
```
