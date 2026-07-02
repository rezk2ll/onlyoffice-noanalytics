# Multi-arch build & push

`push-multiarch.sh` builds an OnlyOffice image for `linux/amd64` + `linux/arm64`
and publishes it as one multi-arch tag. It builds the analytics-free overlay by
default, and doubles as the shared push engine for the [Scribe build](../scribe/).

## Why chunked uploads

`harbor.linagora.com` sits behind a proxy that times out (`504 Gateway Timeout`,
then `499`) on a single large blob upload. The base image has a ~1GB layer, and
pushing it in one request never finishes from a CI or otherwise slow network, so a
one-shot `buildx --push` (or plain `docker push`) fails partway through and retrying
just restarts the same doomed upload.

The script instead builds a multi-arch OCI layout and pushes it with
[`regctl`](https://github.com/regclient/regclient), configured to upload each blob
in small `PATCH` chunks (16MB by default). Every chunk is a short request well under
the proxy timeout, and regctl resumes from the last offset on failure. Because
regctl pushes the multi-arch index directly, there are no per-arch helper tags to
create or clean up.

`regctl` is downloaded (a pinned static binary) if it is not already on `PATH`, and
it reuses the `docker login` credentials, so no extra setup is needed.

## Usage

```bash
docker login harbor.linagora.com

# analytics-free overlay (context = dist/, needs dist/apps from ../build-webapps.sh)
IMAGE=harbor.linagora.com/twake-workplace/onlyoffice-noanalytics:latest \
  dist/push-multiarch.sh
```

Environment:

| var | purpose |
|-----|---------|
| `IMAGE` | target `repo:tag` (required) |
| `CONTEXT` | build context dir (default `dist/`) |
| `BASE_IMAGE` | passed as `--build-arg BASE_IMAGE` when the Dockerfile takes one |
| `EXPECT_OO_VERSION` | passed as `--build-arg EXPECT_OO_VERSION` (version guard) |
| `PLATFORMS` | platforms to build (default `linux/amd64,linux/arm64`) |
| `BLOB_CHUNK` | chunk size in bytes (default `16000000`) |

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
