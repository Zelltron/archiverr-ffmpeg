# archiverr-ffmpeg

Self-contained FFmpeg sidecar image for [Archiverr](https://archiverr.io).
It builds vanilla FFmpeg from source and stages relocatable
`ffmpeg`/`ffprobe` binaries onto a shared Docker volume, where the
Archiverr container invokes them via `child_process`.

This repository is the **corresponding source** for the built image:
the Dockerfile and `stage.sh` are the complete "scripts to control
compilation and installation" in the sense of GPLv3 §1.

## Why a sidecar

FFmpeg built with libx264/libx265 is GPL. Archiverr's own image is
proprietary and must stay GPL-free, so the GPL binaries live in this
separate image and cross only a process boundary at runtime. Do not
install ffmpeg/libx264/libx265 into the Archiverr image.

## What's inside

FFmpeg (pinned by `ARG FFMPEG_VERSION`) built on `debian:trixie` with
exactly the features Archiverr uses:

| Feature | Purpose |
|---|---|
| libx264 / libx265 | software encode (transcode, optimize) |
| h264/hevc_v4l2m2m | Raspberry Pi hardware codecs (mainline V4L2 M2M — auto-enabled from kernel headers, no configure flag) |
| libass + freetype/fontconfig/fribidi/harfbuzz | subtitle burn-in |
| libdav1d | fast AV1 software decode |
| openssl (`--enable-version3`) | TLS for IPTV https inputs |
| libzvbi | DVB teletext subtitle decode (IPTV streams) |
| OpenCL (`--enable-opencl`) | GPU filters (e.g. `tonemap_opencl`) — dormant on the Pi (no ICD driver), available on Intel/AMD hosts that expose one |
| native aac/ac3/dts/... | audio (built into FFmpeg) |

Deliberately excluded: libbluray (Archiverr never reads BDMV disc
structures) and libvpx/libopus/libvorbis/libtheora (Archiverr encodes
only h264/hevc/aac/eac3; FFmpeg's native decoders already cover
playback of VP9/Opus/Vorbis/Theora media).

The binaries are dynamically linked with `RPATH=$ORIGIN/lib` (old-style
`DT_RPATH`, so it covers transitive deps); every non-glibc `.so` is
staged into `lib/` beside them. Only glibc comes from the consuming
image — the build verifies the tree inside `node:20-trixie-slim` (the
Archiverr base) as a dedicated stage, including a real encode.

Final image: ~80 MB (alpine + the staged tree). The container copies
the tree to `/shared`, writes `/shared/.ready` for the healthcheck,
then idles.

## Build

```bash
docker build -t archiverr-ffmpeg:latest \
  --build-arg GIT_COMMIT=$(git rev-parse HEAD) .
```

Archiverr's compose files build this repo directly as the
`ffmpeg-provider` service — customers build locally, so Archiverr
never distributes the GPL binaries themselves.

## Licensing

- **This repository** (Dockerfile, stage.sh, scripts): GPL-3.0-or-later
  (see `LICENSE`).
- **The built image** contains FFmpeg compiled with `--enable-gpl
  --enable-version3` and linked against libx264/libx265 → the combined
  work is effectively **GPL-3.0-or-later**. License texts for FFmpeg and
  the Debian copyright file of every bundled library are staged into
  `LICENSES/` inside the image and on the shared volume.
- `--enable-version3` exists because OpenSSL (Apache-2.0) is
  GPLv3-compatible but not GPLv2-compatible.
- `libfdk_aac` is deliberately excluded (GPL-incompatible for
  redistribution); Archiverr uses FFmpeg's native AAC encoder.

### If you redistribute the built image

Anyone who distributes the *built image* (e.g. pushes it to a registry
others pull from) must offer the corresponding source. To cut a
compliant release of this repo:

1. Tag the commit, matching the image tag.
2. Run `./mirror-sources.sh <FFMPEG_VERSION>` and attach the contents
   of `sources/` (FFmpeg tarball + Debian source packages of bundled
   libs) to the GitHub release.
3. Build with `--build-arg GIT_COMMIT=<sha>` so the image's
   `org.opencontainers.image.revision` label points back here.

Note: H.264/HEVC are patent-encumbered codecs. Building and running
locally is one thing; *distributing* encoder binaries commercially may
have patent implications independent of copyright. Archiverr's default
model has customers build this image on their own machines.

## Security updates

Owning the build means owning CVE response: bump `FFMPEG_VERSION` when
a point release lands, and rebuild (no version bump needed) to pick up
Debian security updates for the bundled libraries. Quarterly rebuilds
are a sensible floor even without a specific CVE.
