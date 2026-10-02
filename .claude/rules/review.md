# Review checklist (archiverr-ffmpeg)

Archiverr's only ffmpeg; the Pi host runs this tree directly. Check every diff against these (runbook: `MAINTENANCE.md`).

1. `FFMPEG_REF` and `NVCODEC_REF` are full commit SHAs, and `NVCODEC_REF` is the commit of `NVCODEC_TAG`. No branch names or floating tags.
2. Every file in `patches/` still applies with `patch -p1` and no fuzz; a fork bump regenerates a patch rather than loosening the apply.
3. A new decoder, encoder, filter or hwaccel the app relies on gets a build-stage assertion in the Dockerfile, so a build without it fails.
4. The staging contract is unchanged (`ffmpeg`, `ffprobe` with RPATH `$ORIGIN/lib`, `lib/`, `LICENSES/`, `VERSION`, `.ready` copied last; refuse to wipe a foreign `/shared`), or the PR names the Archiverr change to `constants.ts` / `hardware.ts` that goes with it.
5. The build base stays Debian trixie, the verify stage uses the same Node trixie image as Archiverr's Dockerfiles, and a bump reports the highest `GLIBC_x.y` the tree imports (the Pi host is Ubuntu 24.04, glibc 2.39).
6. Licences: anything newly linked or staged is GPL-compatible, its copyright lands in `LICENSES/`, and `mirror-sources.sh` covers its source.
7. A release bumps `CHANGELOG.md` (with the Pi real-hardware `speed=` figure for decode changes) and the tag; the PR says that Archiverr's `docker-compose.yml` and `docker-compose.customer.yml` need the new tag.
8. A new FFmpeg major is its own release, never combined with a hardware or contract change.
9. Pi-specific behaviour stays opt-in where it costs memory (e.g. `ARCHIVERR_V4L2_DMAHEAP`); no new device node becomes required in the compose files without saying so.
