#!/bin/sh
# Collect the exact corresponding sources for a release of the
# archiverr-ffmpeg image, for attaching to the GitHub release.
#
# GPLv3 §6 "Corresponding Source" = the FFmpeg tree we compile (the
# Raspberry Pi fork at the pinned commit — NOT the ffmpeg.org tarball),
# the nv-codec-headers we build against, and the source of every
# copyleft library whose binary we redistribute in lib/. Permissive
# libraries are mirrored too for completeness.
#
# Usage: ./mirror-sources.sh [FFMPEG_REF] [NVCODEC_TAG]
#   defaults: the ARG values in Dockerfile
# Output: ./sources/
set -eu

FFMPEG_REPO="jc-kynesim/rpi-ffmpeg"
FFMPEG_REF="${1:-$(sed -n 's/^ARG FFMPEG_REF=//p' Dockerfile | head -1)}"
NVCODEC_TAG="${2:-$(sed -n 's/^ARG NVCODEC_TAG=//p' Dockerfile | head -1)}"
OUT="$(pwd)/sources"
mkdir -p "$OUT"

echo "==> ${FFMPEG_REPO} @ ${FFMPEG_REF}"
curl -fsSL "https://github.com/${FFMPEG_REPO}/archive/${FFMPEG_REF}.tar.gz" \
     -o "$OUT/rpi-ffmpeg-${FFMPEG_REF}.tar.gz"

echo "==> nv-codec-headers ${NVCODEC_TAG}"
curl -fsSL "https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/${NVCODEC_TAG}.tar.gz" \
     -o "$OUT/nv-codec-headers-${NVCODEC_TAG}.tar.gz"

echo "==> Debian source packages for bundled libraries"
# Run inside the same image the build uses so versions match exactly.
docker run --rm -v "$OUT":/out -w /out debian:trixie-slim sh -c '
  set -e
  sed -i "s/^Types: deb$/Types: deb deb-src/" /etc/apt/sources.list.d/debian.sources
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends dpkg-dev ca-certificates >/dev/null
  # GPL (mandatory) + the rest of the bundled runtime libs (completeness)
  for src in x264 x265 libass dav1d freetype fontconfig fribidi harfbuzz \
             glib2.0 graphite2 libpng1.6 brotli expat libunibreak numactl \
             openssl zlib bzip2 pcre2 libzstd zvbi ocl-icd \
             libdrm systemd libva libvpl; do
    apt-get source --download-only "$src" 2>/dev/null || echo "WARN: no source for $src"
  done
'
ls -la "$OUT"
echo "Attach the contents of ./sources/ to the GitHub release."
