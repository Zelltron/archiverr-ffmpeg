# Maintenance and ownership

Archiverr owns this build end to end: the source pin, the feature set, the
hardware paths, CVE response and the corresponding-source releases. This file
is the runbook.

## What we track

| Item | Value | Where |
|---|---|---|
| FFmpeg source | `jc-kynesim/rpi-ffmpeg`, branch `test/7.1.5/main` | `ARG FFMPEG_REPO`, `ARG FFMPEG_REF` in Dockerfile |
| Pinned commit | see `ARG FFMPEG_REF` | Dockerfile |
| Version string | `7.1.5-Archiverr` | `ARG FFMPEG_VERSION`, `--extra-version` |
| NVIDIA headers | `FFmpeg/nv-codec-headers` commit `ARG NVCODEC_REF` (= tag `ARG NVCODEC_TAG`) | Dockerfile |
| Build base | `debian:trixie-slim` (must match Archiverr's `node:20-trixie-slim` glibc) | Dockerfile |
| Image tag | `vX.Y.Z` = git tag = compose `FFMPEG_PROVIDER_TAG` / `#tag` build context = `ghcr.io/zelltron/archiverr-ffmpeg:vX.Y.Z` | media-archivist compose files, `publish.yml` |

## Patches we carry

| Patch | Why | Fork-bump check |
|---|---|---|
| `patches/0001-v4l2-request-dma-heap-opt-in.patch` | Makes the V4L2 request-API decoder's dma-heap frame pools opt-in behind `ARCHIVERR_V4L2_DMAHEAP=1`. On stock Raspberry Pi kernels the CMA heap (320 MB measured on this Pi 5) is too small for 4K HEVC pools and dma-heap allocation fails with ENOMEM; the driver's own MMap buffers work at full speed instead. Default (unset/`0`) uses MMap; set the env var to opt back into dma-heap. | Applied by the Dockerfile with `patch -p1` before `configure`. Every fork pin bump (see "Bumping the fork pin" below) must re-check this patch still applies cleanly against `libavcodec/v4l2_req_dmabufs.c` — the hunk targets `ctl_cma_new2()`; if that function moves or changes shape upstream, regenerate the patch rather than force-applying with fuzz. |
| `patches/0002-fftools-skip-hw-preroll-before-seek.patch` | With `-ss` before `-i` (accurate seek), ffmpeg decodes from the previous keyframe and drops the pre-roll frames in a `trim` filter, after the hwaccel has already copied each frame to system memory. On a Pi 5 that copy dominates 4K HEVC decode (about 50 fps with it, 130 fps without), so a seek that lands 8 s after a keyframe spent 4.5 s on frames nobody sees. The patch gives the decoder the same start the trim filter gets and drops hardware frames before the download; software decode and the trim filter are untouched, so output is identical. | Applied by the Dockerfile with `patch -p1` before `configure`. Touches only `fftools/` (`ffmpeg.h` `DecoderOpts`, `ffmpeg_dec.c` `video_frame_process()` / `dec_open()` / `dec_standalone_open()`, `ffmpeg_demux.c` `ist_use()`); on a fork bump re-check that `ist_filter_add()` still computes `trim_start_us` the same way (the patch mirrors it) and that `video_frame_process()` still calls `hwaccel_retrieve_data()` first. Regenerate rather than fuzz. |
| `patches/0003-cuda-update-func-header.patch`, `patches/0004-cuda-scale-pixfmt-converter.patch`, `patches/0005-cuda-tonemap-filter.patch` | NVIDIA transcodes of 4K HDR sources decoded on the GPU, then copied every frame to system memory to scale and tone map on the CPU (about 12 cores per stream on the owner PC, 6 streams against Plex's 12; AW-246). Upstream `scale_cuda` drops 10-bit to 8-bit without dithering (banding) and upstream has no CUDA tone mapper. These three patches are jellyfin-ffmpeg's `0002-update-cuda-func-header`, `0003-add-enhanced-cuda-pixfmt-converter-impl` and `0004-add-cuda-tonemap-impl` from its `v7.1.3-5` tag (LGPL-2.1-or-later), regenerated against the fork tree with the code unchanged: math intrinsics for the CUDA kernels, dithering when `scale_cuda` reduces bit depth, and the `tonemap_cuda` filter (BT.2390, PQ and HLG to BT.709). Built with `--enable-cuda-llvm` (clang in the build stage compiles the `.cu` kernels to PTX; nothing from clang is staged). Archiverr proves the chain at boot and keeps its CPU chain when the proof fails. | Applied by the Dockerfile with `patch -p1` before `configure`. They touch `configure` (filter deps, clang flags), `ffbuild/common.mak`, `libavfilter/Makefile`, `allfilters.c`, `colorspace.[ch]`, `vf_scale_cuda.*`, `compat/cuda/cuda_runtime.h` and add `libavfilter/cuda/*` and `vf_tonemap_cuda.c`. On a fork bump within 7.1, regenerate against the new tree (apply jellyfin-ffmpeg's patch with `patch -p1 -F0`, then `git diff`), never fuzz. On a new FFmpeg major take the three patches from the jellyfin-ffmpeg tag of that major. The build-stage assertions fail if `scale_cuda`, `tonemap_cuda`, `force_divisible_by` or `bt2390` are missing. Re-run the check under "NVIDIA filters: what real hardware showed". |
| `patches/0006-dovi-reshape-filter.patch` | Dolby Vision profile 5 has no HDR10 base layer: its planes are IPT-PQ-c2, stored reshaped, and each RPU carries the per-scene curves (polynomial, or MMR for chroma) that undo the reshaping. FFmpeg decodes the RPU into frame side data, but its only consumer is the `libplacebo` filter, which needs Vulkan, a GPU driver in the image and a GPU the Pi does not have for this. Without the curves the picture has the wrong brightness and saturation, differently in every scene (AW-279). The patch adds `dovi_reshape`, a small CPU filter (yuv444p10le in and out) that applies the curves and nothing else; Archiverr then converts the planes to SDR with its own LUT. Our own code, LGPL-2.1-or-later, arithmetic after libplacebo's `pl_shader_dovi_reshape`. | Applied by the Dockerfile with `patch -p1` before `configure`. Adds `libavfilter/vf_dovi_reshape.c` and one line each in `libavfilter/Makefile` and `allfilters.c`; on a fork bump only those two hunks can move (regenerate, never fuzz). It reads `AVDOVIMetadata` through `av_dovi_get_header()` / `av_dovi_get_mapping()` and `AVDOVIReshapingCurve` (`libavutil/dovi_meta.h`): on a new FFmpeg major check those still exist with the same fields, and drop the patch if upstream gains a CPU reshaping filter of its own. The build-stage assertion fails if the filter is missing; the verify stage runs Archiverr's chain on a clip without an RPU. Re-run the check under "Dolby Vision reshaping: how it was verified" after any change to the file. |

## Hardware matrix

| Host | Decode | Encode | Device nodes the app container needs |
|---|---|---|---|
| Raspberry Pi 5 | HEVC via `-hwaccel drm` (rpivid); H.264 software | software libx264 (no encode block) | `/dev/video19`, `/dev/media0-2`, `/dev/dri`; groups `video`, `render` |
| Raspberry Pi 4 | HEVC via `-hwaccel drm`; H.264 software (as on every Pi — no Archiverr path uses `h264_v4l2m2m` for decode) | software libx264 (`h264_v4l2m2m` is compiled in but unused: quality poor) | same as Pi 5 |
| Intel | VAAPI (`*_vaapi`) and QSV (`*_qsv`): the amd64 image stages the iHD and i965 VA drivers and the oneVPL GPU runtime; Archiverr sets `LIBVA_DRIVERS_PATH` / `ONEVPL_SEARCH_PATH` to the tree and probes both at startup. Frames stay on the GPU through `scale_vaapi` and `tonemap_vaapi` (HDR10) when Archiverr's boot proof of that chain passes, otherwise they are filtered on the CPU. **Runtime-verified: pending** (no Intel host yet; see Known gaps) | `h264_vaapi`, or `h264_qsv` fed through `hwmap=derive_device=qsv` (no HEVC encoders are built) | `/dev/dri` (uncomment it in the customer compose) |
| AMD | VAAPI via Mesa radeonsi, same filters as Intel. The published image stages the driver from v2.6.0 (`VA_DRIVERS=intel,amd`: LLVM, about 135 MB more); a local build defaults to `intel`. **Runtime-verified: pending** (no AMD host yet) | `h264_vaapi` (AMF is not built, see "Hardware not covered") | `/dev/dri` |
| NVIDIA | nvdec / cuvid; frames stay on the GPU through `scale_cuda` and `tonemap_cuda` when Archiverr's boot proof of that chain passes, otherwise they are downloaded and filtered on the CPU. Needs the NVIDIA container runtime (`docker-compose.nvidia.yml` in Archiverr) | nvenc, H.264 only (same) | NVIDIA container runtime (driver libraries, including `libcuda` for the filters) |
| Anything else | software | software | none |

`/dev/dma_heap` is **not** required for the drm path and, with the default
(patch-guarded) behavior above, is harmless if present but unnecessary —
do not add it to the device list. Only pass it through if you deliberately
set `ARCHIVERR_V4L2_DMAHEAP=1` and have confirmed the CMA heap is large
enough on that host.

Archiverr's `hardware.ts` probes each path at boot (it never trusts the
compiled-in list alone): NVENC with a real encode, `drm` and VAAPI decode
of the HEVC clip bundled with Archiverr (`hevcProbeClip.ts`; no encode), VAAPI and QSV encode with a one-frame
`h264_vaapi` / `h264_qsv` encode, and the VA-API filter chain with three
real runs (8-bit scale, 10-bit scale, HDR10 tone map of the bundled
`hevcProbeClip.ts` HDR clip, the same bytes as `test/probe-hdr10.hevc` here).
A failed probe means the software path, never an error.

### Hardware not covered

- **AMD AMF** (`h264_amf`): needs AMD's proprietary AMF runtime on Linux,
  which no image can ship. AMD GPUs use VAAPI through Mesa instead.
- **Apple VideoToolbox**: macOS frameworks only. A Linux container on a Mac
  (Docker Desktop) has no GPU access, so the sidecar cannot offer it;
  Archiverr still uses `h264_videotoolbox` when it runs natively on macOS
  with a host ffmpeg that has it.
- **Rockchip (rkmpp), Amlogic, Jetson (nvmpi/V4L2 NVMM)**: each needs a
  vendor fork or patch set on top of the Raspberry Pi fork. Those hosts run
  the software path. Adding one is its own release with its own hardware.
- **Raspberry Pi encode**: the Pi 5 has no encoder block; the Pi 4's
  `h264_v4l2m2m` stays unused (quality).

## VA drivers (amd64)

`ARG VA_DRIVERS` (default `intel`; `publish.yml` passes `intel,amd` for the
released image) installs the driver packages *after* the
FFmpeg compile and stages them into the tree: `lib/dri/<name>_drv_video.so`
with an `$ORIGIN/..` rpath (their dependency closure lands in `lib/`) and
`lib/libmfx-gen.so.1.2` for QSV. `DRIVERS` next to `VERSION` lists what was
staged (one `<file> <debian package>` line each; empty on arm64 or `none`).
libva and libvpl dlopen these by name, so Archiverr must point
`LIBVA_DRIVERS_PATH` at `<tree>/lib/dri` and `ONEVPL_SEARCH_PATH` at
`<tree>/lib` (it does, from `constants.ts`, when the directory exists). CI
builds both variants on every push. Bumping the fork or Debian base: re-check
the `ldd` assertions on `lib/dri/*.so` still resolve inside the tree.

## Dolby Vision reshaping: how it was verified (v2.7.0)

No clip with an RPU is in this repo (Dolby's test streams are not ours to
redistribute), so CI only proves the filter is built and passes frames
without metadata through. The arithmetic was checked by hand on 2026-11-23:

- Source: Dolby's public profile 5 test stream
  (`DolbyVision_Atmos/profile5_HLS`, 1080p rendition; polynomial luma in 7
  pieces, first-order chroma, curves that change per scene).
- Reference: `libplacebo=apply_dolbyvision=true` (FFmpeg 6.1, software
  Vulkan) rendering the same frames to BT.2020 PQ.
- Result: FFmpeg 7.1.5 with this patch, `dovi_reshape` followed by the
  IPT-PQ-c2 to BT.2020 conversion, differs from the reference by 0.002 of
  the PQ signal on average (95th percentile 0.007). Without the filter the
  mean difference is 0.09 to 0.14.
- Cost: about one fifth on top of the HDR10 tone-map chain at 720p (x86,
  4 threads). Not measured on a Pi.

Not verified: MMR chroma mapping (the sample uses polynomials only; the
code follows libplacebo's shader term for term), 4K sources, AV1 (profile
10), and whether every hardware decode path attaches the RPU to its frames
(`-hwaccel drm`, VA-API, NVDEC through the native decoders should;
`hevc_cuvid` and `hevc_v4l2m2m` do not parse it, and the filter then passes
the frame through unchanged with a warning).

To repeat: decode a profile 5 file with
`-vf scale=in_range=full:out_range=full,format=yuv444p10le,dovi_reshape`
and compare against libplacebo, or simply watch it through Archiverr's
H.264 transcode: skin tones and greys must be neutral and scene cuts must
not change the overall brightness.

## NVIDIA filters: what real hardware showed (v2.5.0, RTX 3080)

- The first use of `scale_cuda` or `tonemap_cuda` after a driver or image
  change compiles its kernels: about 3 s per filter before the first frame.
  The NVIDIA driver caches the result (`CUDA_CACHE_PATH`, default
  `$HOME/.nv/ComputeCache`). Archiverr points that at its data volume and
  runs both filters in its boot probe, so viewers never pay it. Any other
  consumer of this tree should do the same.
- Each 4K session holds about 1.06 GB of GPU memory (0.9 GB when frames are
  downloaded instead). A 10 GB card runs out at 9 concurrent 4K streams;
  ffmpeg then logs `CUDA_ERROR_OUT_OF_MEMORY` and can still exit 0 after a
  few frames.
- `tonemap_cuda` takes 10-bit input only ("Unsupported input format depth:
  8"). 8-bit video tagged PQ is first widened on the GPU
  (`scale_cuda=format=p010le`), then tone mapped.
- A source NVDEC cannot decode (H.264 Hi10P) arrives as system frames and
  `scale_cuda` fails the run with exit 218; the caller needs a CPU fallback.
- Re-run this check on real hardware after a fork bump or a new FFmpeg
  major: both boot-probe commands, one 4K HDR10 title for `speed=` and CPU
  cores, and an SSIM against the CPU chain.

## Known gaps

- **Intel and AMD VAAPI/QSV are staged but not runtime-verified.** No Intel
  or AMD GPU host has run the tree yet; CI proves the drivers build, stage
  and resolve and that `scale_vaapi`, `tonemap_vaapi`, `hwmap` and `hwupload`
  exist with the options Archiverr passes, not that they decode or filter.
  First run on real hardware: check the boot log lines `[Player] VA-API
  device:` and `[Player] Intel|AMD GPU filters:`, play one 4K HDR10 title
  and note `speed=` and CPU use, as for NVIDIA above. Tracked as a separate Archiverr ticket (AW:
  "verify bundled Intel VA drivers on real hardware"). Until then the
  Archiverr docs say "bundled, verification pending".

- **v2.0.0 (and v1.1.0) do not build on amd64.** The first native amd64 CI run
  (https://github.com/Zelltron/archiverr-ffmpeg/actions/runs/36493019155)
  failed at `configure`: `nasm/yasm not found or too old`. v1.1.0 has the
  same gap (no nasm in its package list). Commit `f8581da` installs `nasm`
  on amd64 and passes CI
  (https://github.com/Zelltron/archiverr-ffmpeg/actions/runs/36493213294):
  every build-stage assertion (including `hevc_qsv`) and the verify stage
  in `node:20-trixie-slim` pass. amd64 is therefore **CI-verified but not
  runtime-verified**: no x86 host with a GPU has run the tree, and VAAPI /
  QSV / NVIDIA need runtimes no image ships. **v2.0.1 is the first tag that
  contains the nasm fix**; the Archiverr compose files default to it. Keep
  x86 customers on v2.0.1 or later, never on v2.0.0/v1.1.0.

## Host glibc constraint (owner box)

This tree is built on Debian trixie, and the owner host (Raspberry Pi 5,
Ubuntu 24.04) runs these binaries directly, not only inside the Archiverr
container — the dev server, scripts and tests all shell out to
`/opt/archiverr-ffmpeg/ffmpeg` on the bare host. The host's glibc must
therefore be at least as new as the highest `GLIBC_x.y` symbol version any
binary or library in the staged tree imports. Check this on every bump:

```bash
for f in ffmpeg ffprobe lib/*.so*; do objdump -T "$f" | grep -oE 'GLIBC_[0-9.]+'; done | sort -uV | tail -1
```

and compare it against `ldd --version` on the host. v2.0.0 imports up to
`GLIBC_2.39`, and Ubuntu 24.04 ships `2.39` — it works, but with no margin.
A future trixie point release could raise the highest imported symbol past
what Ubuntu 24.04 ships, which breaks the host-run binaries (not the
Archiverr container, which stays on `node:20-trixie-slim`) until the host
OS is upgraded. Re-run this check before promoting any new tag.

Consumer images must be trixie-based (glibc 2.41) or newer; bookworm cannot
load the tree. That covers media-archivist's `Dockerfile`, `Dockerfile.dev`
and `Dockerfile.prod` as well as any third-party image that mounts the tree.

## Staging contract (consumed by Archiverr)

`stage.sh` wipes `/shared` and copies: `ffmpeg`, `ffprobe` (RPATH `$ORIGIN/lib`),
`lib/`, `LICENSES/`, `VERSION`, then `.ready` last. It refuses to wipe (exit 1,
healthcheck fails) when `/shared` is non-empty but holds neither `VERSION` nor
`.ready`, i.e. when a bind mount points at a directory that is not a previous
tree; always give the sidecar a dedicated directory or a named volume. Archiverr mounts that
directory read-only at `/opt/archiverr-ffmpeg`, waits for `.ready` through the
compose healthcheck, and logs `VERSION` at startup. Do not rename these files
without changing `server/routes/player/constants.ts` and `hardware.ts` in
media-archivist.

## Bumping the fork pin

1. `git ls-remote https://github.com/jc-kynesim/rpi-ffmpeg test/7.1.x/main`
   (or the next point release branch) and pick the commit.
2. Set `ARG FFMPEG_REF`, `ARG FFMPEG_VERSION` (and `NVCODEC_TAG` plus
   `NVCODEC_REF` from `git ls-remote https://github.com/FFmpeg/nv-codec-headers.git
   'refs/tags/<tag>^{}'` if FFmpeg requires newer headers).
3. `docker build --target verify -t archiverr-ffmpeg:verify .` on the Pi; the
   build fails on any missing hardware path (assertions in the Dockerfile).
4. Run the real-hardware check on the Pi (below). Record the speed in
   CHANGELOG.md.
5. Build the final image with `--build-arg GIT_COMMIT=$(git rev-parse HEAD)`.
6. Commit, tag `vX.Y.Z`, push, then `./mirror-sources.sh` and attach
   `sources/` to the GitHub release. Publishing the release runs
   `publish.yml`, which pushes `ghcr.io/zelltron/archiverr-ffmpeg:vX.Y.Z`
   (amd64 + arm64) and fails if the release has no assets. For a release
   published before the workflow existed, run it by hand (Actions > publish >
   Run workflow, tag `vX.Y.Z`).
7. Bump the tag in media-archivist `docker-compose.yml` and
   `docker-compose.customer.yml`, deploy, and confirm the startup log line
   `[Player] ffmpeg: ffmpeg version X-Archiverr ...`.

Major version rule: a new FFmpeg major (8.x) is its own release and its own
verification pass; never combine it with a hardware or contract change.

## Real-hardware check (Pi 5)

```bash
docker run --rm --device /dev/video19 --device /dev/media0 --device /dev/media1 \
  --device /dev/media2 --device /dev/dri --group-add 44 --group-add 992 \
  -v /mnt/merged/movies:/media:ro archiverr-ffmpeg:verify \
  /tree/ffmpeg -hide_banner -v verbose -hwaccel drm -ss 600 -t 20 \
  -i "/media/<some 4K HEVC file>.mp4" -map 0:v:0 -f null - 2>&1 | grep -E "speed=|v4l2|drm" | tail
```
Pass: the request-device line is present and `speed=` is above 1.0x.

## CVE response

- FFmpeg / fork CVE: bump the pin to the fork's fixed point-release branch.
- Bundled library CVE (x264, libass, dav1d, openssl, libdrm, libva, ...):
  rebuild the same tag with `--no-cache`; Debian trixie provides the fix.
  Cut a patch release (`vX.Y.Z+1`) so compose users get it.
- Floor: rebuild quarterly even without a known CVE.

## Release checklist

- [ ] Dockerfile ARGs updated, assertions pass, real-hardware check recorded
- [ ] CHANGELOG.md entry
- [ ] git tag matches image tag; release created with `sources/` attached
- [ ] `publish` workflow green; `docker buildx imagetools inspect ghcr.io/zelltron/archiverr-ffmpeg:vX.Y.Z` lists amd64 and arm64
- [ ] media-archivist compose files bumped; THIRD_PARTY_NOTICES §D still accurate
