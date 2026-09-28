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
| NVIDIA headers | `FFmpeg/nv-codec-headers` tag in `ARG NVCODEC_TAG` | Dockerfile |
| Build base | `debian:trixie-slim` (must match Archiverr's `node:20-trixie-slim` glibc) | Dockerfile |
| Image tag | `vX.Y.Z` = git tag = compose `FFMPEG_PROVIDER_TAG` / `#tag` build context | media-archivist compose files |

## Patches we carry

| Patch | Why | Fork-bump check |
|---|---|---|
| `patches/0001-v4l2-request-dma-heap-opt-in.patch` | Makes the V4L2 request-API decoder's dma-heap frame pools opt-in behind `ARCHIVERR_V4L2_DMAHEAP=1`. On stock Raspberry Pi kernels the CMA heap (320 MB measured on this Pi 5) is too small for 4K HEVC pools and dma-heap allocation fails with ENOMEM; the driver's own MMap buffers work at full speed instead. Default (unset/`0`) uses MMap; set the env var to opt back into dma-heap. | Applied by the Dockerfile with `patch -p1` before `configure`. Every fork pin bump (see "Bumping the fork pin" below) must re-check this patch still applies cleanly against `libavcodec/v4l2_req_dmabufs.c` — the hunk targets `ctl_cma_new2()`; if that function moves or changes shape upstream, regenerate the patch rather than force-applying with fuzz. |

## Hardware matrix

| Host | Decode | Encode | Device nodes the app container needs |
|---|---|---|---|
| Raspberry Pi 5 | HEVC via `-hwaccel drm` (rpivid); H.264 software | software libx264 (no encode block) | `/dev/video19`, `/dev/media0-2`, `/dev/dri`; groups `video`, `render` |
| Raspberry Pi 4 | HEVC via `-hwaccel drm`; H.264 via `h264_v4l2m2m` | `h264_v4l2m2m` (quality poor; Archiverr uses libx264) | same as Pi 5 plus the M2M nodes |
| Intel / AMD | VAAPI (`*_vaapi`); Intel also QSV (`*_qsv`, amd64 build) | VAAPI / QSV | `/dev/dri` |
| NVIDIA | nvdec / cuvid | nvenc | NVIDIA container runtime (driver libraries) |
| Anything else | software | software | none |

`/dev/dma_heap` is **not** required for the drm path and, with the default
(patch-guarded) behavior above, is harmless if present but unnecessary —
do not add it to the device list. Only pass it through if you deliberately
set `ARCHIVERR_V4L2_DMAHEAP=1` and have confirmed the CMA heap is large
enough on that host.

Archiverr's `hardware.ts` probes each path at boot (it never trusts the
compiled-in list alone): NVENC with a real encode, `drm` with a libx265
round trip on the Pi. A failed probe means the software path, never an error.

## Known gaps

- **amd64 is unverified in v2.0.0.** No x86 host was available to run the
  Dockerfile end to end; the amd64-only steps (the `libvpl-dev` install, the
  `--enable-libvpl` configure flag, and the `hevc_qsv` decoder assertion in
  the build stage) are guarded (`[ "$(dpkg --print-architecture)" = "amd64" ]`)
  but have not actually executed anywhere. Before promoting `v2.0.0` to the
  customer compose defaults for x86 hosts, run the Dockerfile on the first
  real x86 host and fix anything that fails there.

## Staging contract (consumed by Archiverr)

`stage.sh` wipes `/shared` and copies: `ffmpeg`, `ffprobe` (RPATH `$ORIGIN/lib`),
`lib/`, `LICENSES/`, `VERSION`, then `.ready` last. Archiverr mounts that
directory read-only at `/opt/archiverr-ffmpeg`, waits for `.ready` through the
compose healthcheck, and logs `VERSION` at startup. Do not rename these files
without changing `server/routes/player/constants.ts` and `hardware.ts` in
media-archivist.

## Bumping the fork pin

1. `git ls-remote https://github.com/jc-kynesim/rpi-ffmpeg test/7.1.x/main`
   (or the next point release branch) and pick the commit.
2. Set `ARG FFMPEG_REF`, `ARG FFMPEG_VERSION` (and `NVCODEC_TAG` if FFmpeg
   requires newer headers).
3. `docker build --target verify -t archiverr-ffmpeg:verify .` on the Pi; the
   build fails on any missing hardware path (assertions in the Dockerfile).
4. Run the real-hardware check on the Pi (below). Record the speed in
   CHANGELOG.md.
5. Build the final image with `--build-arg GIT_COMMIT=$(git rev-parse HEAD)`.
6. Commit, tag `vX.Y.Z`, push, then `./mirror-sources.sh` and attach
   `sources/` to the GitHub release.
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
- Bundled library CVE (x264, x265, libass, dav1d, openssl, libdrm, libva, ...):
  rebuild the same tag with `--no-cache`; Debian trixie provides the fix.
  Cut a patch release (`vX.Y.Z+1`) so compose users get it.
- Floor: rebuild quarterly even without a known CVE.

## Release checklist

- [ ] Dockerfile ARGs updated, assertions pass, real-hardware check recorded
- [ ] CHANGELOG.md entry
- [ ] git tag matches image tag; release created with `sources/` attached
- [ ] media-archivist compose files bumped; THIRD_PARTY_NOTICES §D still accurate
