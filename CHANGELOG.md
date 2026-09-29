# Changelog

## v2.1.0 — 2026-09-29

Minor release: bundled VA drivers for Intel hosts (AW-28). Same FFmpeg
source, patches and hardware paths as v2.0.1.

- New build arg `VA_DRIVERS` (default `intel`; `intel,amd`; `none`). amd64
  images now stage `iHD_drv_video.so`, `i965_drv_video.so` (under
  `lib/dri/`, rpath `$ORIGIN/..`) and the oneVPL GPU runtime
  `libmfx-gen.so.1.2` (in `lib/`) with their dependency closure, about 30 MB.
  `intel,amd` adds Mesa's `radeonsi_drv_video.so` and LLVM (about 135 MB).
  arm64 images stage nothing.
- Staging contract gains `DRIVERS` (one `<file> <debian package>` line per
  staged driver, empty when none) and `lib/dri/`. Archiverr 
  sets `LIBVA_DRIVERS_PATH` / `ONEVPL_SEARCH_PATH` to the tree and logs
  `DRIVERS` at boot.
- Build assertions: staged drivers exist for the selected variant and `ldd`
  resolves them inside the tree (build stage and the verify stage).
- CI builds both `intel` and `intel,amd` on amd64 on every push.
- `mirror-sources.sh` also mirrors intel-media-driver, gmmlib,
  intel-vaapi-driver, onevpl-gpu, mesa and llvm-toolchain-19.
- Image label `io.archiverr.va-drivers` records the variant.
- Runtime verification on Intel hardware is pending (no host available);
  the probes in Archiverr still disable a path that does not work.

## v2.0.1 — 2026-09-29

Patch release: the amd64 build fix and the staging guard. Same FFmpeg source
(fork commit `950ab032`), same patches, same hardware paths as v2.0.0; the
arm64 tree is byte-for-byte equivalent apart from the provenance labels.


- **amd64 build fix.** The first native amd64 CI run
  (https://github.com/Zelltron/archiverr-ffmpeg/actions/runs/36493019155)
  showed v2.0.0 cannot build on x86: `configure` stops with `nasm/yasm not
  found or too old`. `nasm` is now installed on amd64 builds; this release is
  the first tag that builds on x86 (CI-verified, not runtime-verified).
- `stage.sh` refuses to empty `/shared` when it holds foreign files (anything
  other than `lost+found`, dot-entries, or a previous ffmpeg tree with
  `VERSION`/`.ready`): it prints `[ffmpeg-provider] refusing to empty /shared:
  it holds files that are not a previous ffmpeg tree` and exits 1, so the
  compose healthcheck fails visibly instead of a misdirected bind mount being
  wiped. A freshly formatted partition (only `lost+found`) stages normally.
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
