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
| Image tag | `vX.Y.Z` = git tag = compose `FFMPEG_PROVIDER_TAG` / `#tag` build context | media-archivist compose files |

## Patches we carry

| Patch | Why | Fork-bump check |
|---|---|---|
| `patches/0001-v4l2-request-dma-heap-opt-in.patch` | Makes the V4L2 request-API decoder's dma-heap frame pools opt-in behind `ARCHIVERR_V4L2_DMAHEAP=1`. On stock Raspberry Pi kernels the CMA heap (320 MB measured on this Pi 5) is too small for 4K HEVC pools and dma-heap allocation fails with ENOMEM; the driver's own MMap buffers work at full speed instead. Default (unset/`0`) uses MMap; set the env var to opt back into dma-heap. | Applied by the Dockerfile with `patch -p1` before `configure`. Every fork pin bump (see "Bumping the fork pin" below) must re-check this patch still applies cleanly against `libavcodec/v4l2_req_dmabufs.c` — the hunk targets `ctl_cma_new2()`; if that function moves or changes shape upstream, regenerate the patch rather than force-applying with fuzz. |

## Hardware matrix

| Host | Decode | Encode | Device nodes the app container needs |
|---|---|---|---|
| Raspberry Pi 5 | HEVC via `-hwaccel drm` (rpivid); H.264 software | software libx264 (no encode block) | `/dev/video19`, `/dev/media0-2`, `/dev/dri`; groups `video`, `render` |
| Raspberry Pi 4 | HEVC via `-hwaccel drm`; H.264 software (as on every Pi — no Archiverr path uses `h264_v4l2m2m` for decode) | software libx264 (`h264_v4l2m2m` is compiled in but unused: quality poor) | same as Pi 5 |
| Intel / AMD | VAAPI (`*_vaapi`); Intel also QSV (`*_qsv`, amd64 build) — compiled in, probed at startup, but needs a VA driver / oneVPL runtime that no image ships today, so it disables itself | same | `/dev/dri` plus the driver/runtime |
| NVIDIA | nvdec / cuvid — compiled in, needs the NVIDIA container runtime, which no image configures today | nvenc (same) | NVIDIA container runtime (driver libraries) |
| Anything else | software | software | none |

`/dev/dma_heap` is **not** required for the drm path and, with the default
(patch-guarded) behavior above, is harmless if present but unnecessary —
do not add it to the device list. Only pass it through if you deliberately
set `ARCHIVERR_V4L2_DMAHEAP=1` and have confirmed the CMA heap is large
enough on that host.

Archiverr's `hardware.ts` probes each path at boot (it never trusts the
compiled-in list alone): NVENC with a real encode, `drm` and VAAPI decode
with a libx265 round trip, VAAPI and QSV encode with a one-frame
`h264_vaapi` / `h264_qsv` encode. A failed probe means the software path, never an error.

## Known gaps

- **v2.0.0 does not build on amd64.** The first native amd64 CI run
  (https://github.com/Zelltron/archiverr-ffmpeg/actions/runs/36493019155)
  failed at `configure`: `nasm/yasm not found or too old`. v1.1.0 has the
  same gap (no nasm in its package list). Commit `f8581da` installs `nasm`
  on amd64 and passes CI
  (https://github.com/Zelltron/archiverr-ffmpeg/actions/runs/36493213294):
  every build-stage assertion (including `hevc_qsv`) and the verify stage
  in `node:20-trixie-slim` pass. amd64 is therefore **CI-verified but not
  runtime-verified**: no x86 host with a GPU has run the tree, and VAAPI /
  QSV / NVIDIA need runtimes no image ships. Tag a release containing the
  nasm fix before pointing x86 customers at a tag; until then the customer
  compose documents the commit SHA as `FFMPEG_PROVIDER_TAG` for amd64.

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
