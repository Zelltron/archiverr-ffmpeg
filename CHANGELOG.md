# Changelog

## Unreleased

- `stage.sh` refuses to empty `/shared` when it is non-empty and holds neither
  `VERSION` nor `.ready` (i.e. not a previous ffmpeg tree): it prints
  `[ffmpeg-provider] refusing to empty /shared: it holds files that are not a
  previous ffmpeg tree` and exits 1, so the compose healthcheck fails visibly
  instead of a misdirected bind mount being wiped.
- nv-codec-headers is pinned by commit (`ARG NVCODEC_REF`, the commit tag
  `n12.2.72.0` points at) instead of by tag. Same headers as v2.0.0.
- `mirror-sources.sh` also archives the Debian sources of `libcap2`
  (transitive via libudev) and `gcc-14` (libgcc_s / libstdc++ runtime).
- CI: `.github/workflows/build.yml` builds the image natively on amd64
  (build-stage assertions + verify stage) on every push.
- Docs: libvpl is MIT (not Apache-2.0); VAAPI/QSV/NVIDIA need runtimes neither
  image ships, so they currently disable themselves at startup.

## v2.0.0 — 2026-09-28

- Source: Raspberry Pi FFmpeg fork (`jc-kynesim/rpi-ffmpeg`) at
  `950ab0323334111e1a4cdc6b037eadfaf0524167` (`test/7.1.5/main`), replacing
  the ffmpeg.org 7.1.3 tarball. Version string `7.1.5-Archiverr`.
- Hardware decode: `-hwaccel drm` (V4L2 request API, Pi 4/5 rpivid HEVC),
  VAAPI, Intel QSV via libvpl (amd64), NVIDIA nvdec/nvenc/cuvid via
  nv-codec-headers n12.2.72.0. New bundled libs: libdrm, libudev, libva,
  libva-drm, libvpl (amd64).
- Carries `patches/0001-v4l2-request-dma-heap-opt-in.patch`: makes the V4L2
  request-API decoder's dma-heap frame pools opt-in via
  `ARCHIVERR_V4L2_DMAHEAP=1`. Stock Pi kernels' CMA heap (320 MB measured) is
  too small for 4K HEVC pools and dma-heap allocation fails with ENOMEM;
  default behavior now uses the driver's MMap buffers, which run at full speed
  on this hardware (see measurements below). Details in
  MAINTENANCE.md "Patches we carry".
- Staging contract: adds `VERSION` (provenance) next to `.ready`. Archiverr
  mounts the tree at `/opt/archiverr-ffmpeg` from this release on.
- Corresponding source: `mirror-sources.sh` now archives the fork commit and
  nv-codec-headers, plus Debian sources for libdrm, systemd (libudev), libva,
  libvpl.
- Measured on a Pi 5 (Ubuntu 24.04, kernel 6.8.0-1060-raspi), Free Solo (2018)
  2160p HEVC Main 10, 20 s clip: software decode 0.77x, software decode +
  libx264 ultrafast 1080p 0.57x; with `-hwaccel drm`: decode 1.68x (40 fps),
  decode + libx264 1080p 1.11x. A re-run with `/dev/dma_heap` passed through
  gave 1.65x and 1.12x; the patch still forced MMap in that run, so it shows
  only that the device node's presence makes no difference, not that MMap is
  faster than dma-heap (dma-heap could not be measured: it fails with ENOMEM
  on the stock CMA heap). Verbose log line proving the hwaccel engaged:
  `Hwaccel V4L2 HEVC stateless V4; devices: /dev/media0,/dev/video19; buffers: src MMap, dst MMap; swfmt rpi4_10; V4L2fmt NC30`.
- Known gap: amd64 is unverified in this release (no x86 host available);
  see MAINTENANCE.md "Known gaps".

## v1.1.0 — 2026-09-04

- Added libzvbi (DVB teletext) and OpenCL filter support.

## v1.0.0 — 2026-09-04

- First self-contained FFmpeg 7.1.3 sidecar replacing the jellyfin/jellyfin
  staging image.
