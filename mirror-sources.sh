#!/bin/sh
# Collect the exact corresponding sources for a release of the
# archiverr-ffmpeg image, for attaching to the GitHub release.
#
# GPLv3 §6 "Corresponding Source" = the FFmpeg source we compile plus
# the source of every copyleft library whose binary we redistribute in
# lib/. This script downloads the pinned FFmpeg tarball and the Debian
# source packages for the GPL-licensed bundled libs (x264, x265).
# The remaining bundled libs are permissive/LGPL; their Debian source
# packages are fetched too for completeness.
#
# Usage: ./mirror-sources.sh [FFMPEG_VERSION]   (default: 7.1.3)
# Output: ./sources/
set -eu

FFMPEG_VERSION="${1:-7.1.3}"
OUT="$(pwd)/sources"
mkdir -p "$OUT"

echo "==> FFmpeg ${FFMPEG_VERSION} tarball + signature"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
     -o "$OUT/ffmpeg-${FFMPEG_VERSION}.tar.xz"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz.asc" \
     -o "$OUT/ffmpeg-${FFMPEG_VERSION}.tar.xz.asc" || true

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
             openssl zlib bzip2 pcre2 libzstd zvbi ocl-icd; do
    apt-get source --download-only "$src" 2>/dev/null || echo "WARN: no source for $src"
  done
'
ls -la "$OUT"
echo "Attach the contents of ./sources/ to the GitHub release."
