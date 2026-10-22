# archiverr-ffmpeg

Self-contained FFmpeg sidecar image for [Archiverr](https://archiverr.io).
It builds the [Raspberry Pi FFmpeg fork](https://github.com/jc-kynesim/rpi-ffmpeg)
(upstream FFmpeg plus guarded Pi patches) from source at a pinned commit and
stages relocatable `ffmpeg`/`ffprobe` binaries onto a shared directory, where
the Archiverr container invokes them via `child_process`.

This repository is the **corresponding source** for the built image: the
Dockerfile and `stage.sh` are the complete "scripts to control compilation and
installation" in the sense of GPLv3 §1. `MAINTENANCE.md` records what we own
and how it is kept current; `CHANGELOG.md` lists releases.

## Why a sidecar

FFmpeg built with libx264 is GPL. Archiverr's own image is proprietary
and must stay GPL-free, so the GPL binaries live in this separate image and
cross only a process boundary at runtime. Do not install ffmpeg/libx264
into the Archiverr image.

## Why the Raspberry Pi fork

Upstream FFmpeg (through 9.0) has no V4L2 request-API hwaccel, so it can never
use the Pi 4/5 `rpivid` HEVC decoder. The fork adds that hwaccel (`-hwaccel drm`),
tracks upstream point releases, and its patches are guarded so the same source
builds and behaves like vanilla on x86. One source, one Dockerfile, every host.

On top of the fork, the build applies our own patches from `patches/` before
`configure` runs (see "Patches we carry" in `MAINTENANCE.md`):
`0001-v4l2-request-dma-heap-opt-in.patch` makes the V4L2 request-API
decoder's dma-heap frame pools opt-in behind `ARCHIVERR_V4L2_DMAHEAP=1`
(the stock Pi CMA heap is too small for 4K HEVC pools, so by default the
decoder logs `dma_heap buffers disabled (set ARCHIVERR_V4L2_DMAHEAP=1 to
enable); using mmap buffers` and uses the driver's MMap buffers, which every
`-hwaccel drm` speed figure in this repo was measured with), and
`0002-fftools-skip-hw-preroll-before-seek.patch` drops hardware frames that
precede an accurate `-ss` start before the hwaccel downloads them, so a seek
that lands several seconds past a source keyframe no longer copies the
pre-roll to system memory only to discard it.

## What's inside

Version string `7.1.5-Archiverr` (`ARG FFMPEG_VERSION`, source pinned by
`ARG FFMPEG_REF`), built on `debian:trixie`:

| Feature | Purpose |
|---|---|
| libx264 | software H.264 encode (transcode, optimize) |
| `-hwaccel drm` (V4L2 request API, `--enable-v4l2-request --enable-sand`) | Raspberry Pi 4/5 hardware HEVC decode via `rpivid`; needs `/dev/video19`, `/dev/media0-2`, `/dev/dri` |
| h264_v4l2m2m / hevc_v4l2m2m | Pi 4 stateful V4L2 M2M codecs (auto-enabled from kernel headers); HEVC is decode only |
| VAAPI (`--enable-vaapi`) | Intel / AMD decode, and H.264 encode, via `/dev/dri/renderD128`. amd64 images stage the Intel VA drivers (iHD for Broadwell and newer, i965 for older iGPUs) under `lib/dri/`; AMD's Mesa driver is a build-time opt-in (`VA_DRIVERS=intel,amd`, adds LLVM, about 135 MB) |
| Intel QSV (`--enable-libvpl`, amd64 only) | Intel media SDK path through oneVPL; the oneVPL GPU runtime (`libmfx-gen`) is staged in `lib/` |
| NVIDIA nvdec / nvenc / cuvid (`--enable-ffnvcodec`) | MIT headers at build time; driver libraries loaded at runtime only when present (see below) |
| libass + freetype/fontconfig/fribidi/harfbuzz | subtitle burn-in |
| libdav1d | fast AV1 software decode |
| openssl (`--enable-version3`) | TLS for IPTV https inputs |
| libzvbi | DVB teletext subtitle decode (IPTV streams) |
| OpenCL (`--enable-opencl`) | GPU filters (e.g. `tonemap_opencl`) on hosts with an ICD |
| native aac/ac3/dts/... | audio (built into FFmpeg) |

HEVC is decode only. The image contains no HEVC encoder: no `libx265`, and
the hardware HEVC encoders (`hevc_nvenc`, `hevc_vaapi`, `hevc_qsv`,
`hevc_v4l2m2m`) are disabled at configure time. Archiverr transcodes to
H.264 and copies HEVC without re-encoding it. The verify stage fails the
build if any HEVC encoder appears (codec patents, AW-172).

**Hardware status in this release.** Raspberry Pi 4/5 HEVC decode
(`-hwaccel drm`) is the hardware path verified on real hardware. VAAPI, QSV
and NVIDIA are compiled in and Archiverr probes each at startup. On amd64
the staged tree carries VA drivers in `lib/dri/` (Intel `iHD` and `i965` by
default, plus Mesa's `radeonsi` with `VA_DRIVERS=intel,amd`) and the oneVPL
GPU runtime; NVIDIA still needs the NVIDIA container runtime from the host.
Paths whose hardware or driver is missing disable themselves and transcoding
stays in software. Every bundled library's licence is in `LICENSES/`, and
`mirror-sources.sh` collects its source for each release.

Deliberately excluded: libbluray (Archiverr never reads BDMV disc structures),
libvpx/libopus/libvorbis/libtheora (Archiverr encodes only h264/hevc/aac/eac3),
libfdk_aac (GPL-incompatible), and anything CUDA-SDK based (`--enable-cuda-nvcc`,
non-free).

The binaries are dynamically linked with `RPATH=$ORIGIN/lib` (old-style
`DT_RPATH`, so it covers transitive deps); every non-glibc `.so` is staged into
`lib/` beside them. Only glibc comes from the consuming image — the build
verifies the tree inside `node:20-trixie-slim` (the Archiverr base) as a
dedicated stage, including a real libx264/aac encode and a decode of the bundled HEVC clip
(`test/probe.hevc`, the same clip Archiverr's hardware probe uses).
The Pi decode path is verified on real hardware before each release
(see MAINTENANCE.md).

The container copies the tree to `/shared`, writes `/shared/VERSION`
(provenance) and `/shared/.ready` (healthcheck), then idles.

## Build

```bash
docker build -t archiverr-ffmpeg:v2.1.0 \
  --build-arg GIT_COMMIT=$(git rev-parse HEAD) .
```

`--build-arg VA_DRIVERS=...` selects the VA drivers staged on amd64:
`intel` (default: iHD + i965 + oneVPL GPU runtime, about 30 MB, all MIT),
`intel,amd` (adds Mesa radeonsi and its LLVM dependency, about 135 MB more)
or `none`. arm64 builds stage no drivers whatever the value. Archiverr's
compose files pass it through as `FFMPEG_VA_DRIVERS`.

Each release is also published as a multi-arch image (amd64 with
`VA_DRIVERS=intel`, arm64), `ghcr.io/zelltron/archiverr-ffmpeg:<tag>`, by
`.github/workflows/publish.yml`, so installs (NAS app stores in particular)
can pull it instead of compiling FFmpeg. The workflow runs when a GitHub
release is published, and refuses to push unless the release already
carries the corresponding source (see below). Building locally from this
repo stays supported, and is the way to get `intel,amd` or `none`. Native
arm64 builds on a Pi 5 take 30-40 minutes.

## Licensing

- **This repository** (Dockerfile, scripts): GPL-3.0-or-later (see `LICENSE`).
- **The built image** contains FFmpeg (the Raspberry Pi fork, LGPL/GPL like
  upstream, credit jc-kynesim and Raspberry Pi Ltd) compiled with
  `--enable-gpl --enable-version3` and linked against libx264 → the
  combined work is **GPL-3.0-or-later**. License texts for FFmpeg,
  nv-codec-headers (MIT), the staged VA drivers (Intel media-driver MIT/BSD,
  gmmlib MIT, i965 MIT, oneVPL GPU runtime MIT; Mesa MIT and LLVM
  Apache-2.0-with-LLVM-exception in the `amd` variant) and the Debian copyright file of every bundled
  library are staged into `LICENSES/` inside the image and on the shared
  directory. The nv-codec-headers tag ships no `LICENSE` file, so the
  Dockerfile assembles `LICENSES/nv-codec-headers.LICENSE` from the MIT
  notices in the headers themselves.
- `--enable-version3` exists because OpenSSL 3 (Apache-2.0) is
  GPLv3-compatible but not GPLv2-compatible. libvpl is MIT.

### If you redistribute the built image

Anyone who distributes the *built image* must offer the corresponding source.
The corresponding source is this repository (Dockerfile, `stage.sh`,
`patches/`) plus the mirrored fork archive produced by `mirror-sources.sh`. To
cut a compliant release of this repo:

1. Tag the commit, matching the image tag.
2. Run `./mirror-sources.sh` and attach the contents of `sources/` (fork
   archive at the pinned commit, nv-codec-headers archive, Debian source
   packages of bundled libs) to the GitHub release.
3. Build with `--build-arg GIT_COMMIT=<sha>` so the image's
   `org.opencontainers.image.revision` label points back here.

The published ghcr.io images follow these steps: the release (with
`sources/` attached) is what triggers the publish, and the image's
`org.opencontainers.image.source` label points at this repository.

Note: H.264/HEVC are patent-encumbered codecs. Building and running locally is
one thing; *distributing* encoder and decoder binaries commercially may have
patent implications independent of copyright, which apply to the published
ghcr.io images. To keep that exposure small the images carry no HEVC encoder
(see "What's inside"); licensing is tracked in AW-172.

## Security updates

Owning the build means owning CVE response: move `FFMPEG_REF` to the fork's
matching point-release branch head when upstream ships a fix, and rebuild (no
version bump needed) to pick up Debian security updates for the bundled
libraries. Quarterly rebuilds are the floor. Procedure in MAINTENANCE.md.
