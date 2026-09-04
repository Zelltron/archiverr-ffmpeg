# ================================================================
# Archiverr ffmpeg-provider — self-built FFmpeg sidecar
# ================================================================
#
# Replaces the jellyfin/jellyfin:latest image previously used purely
# to stage jellyfin-ffmpeg's binaries onto a shared volume. This
# image builds vanilla FFmpeg from source with exactly the features
# Archiverr uses (see server/routes/player/* and server/services/iptv):
#
#   - libx264 / libx265        software encode (GPL — stays in this
#                              sidecar, never in the Archiverr image)
#   - h264_v4l2m2m / hevc_v4l2m2m  Pi 5 hardware codecs (mainline
#                              V4L2 stateful M2M — no vendor patches)
#   - libass + freetype/fontconfig/fribidi/harfbuzz  subtitle burn-in
#   - libdav1d                 fast AV1 software decode
#   - openssl                  TLS for IPTV https inputs
#   - native aac encoder, all native decoders (ac3/eac3/dts/truehd/...)
#
# Like jellyfin-ffmpeg, the binaries link their third-party libs
# dynamically, but with RPATH=$ORIGIN/lib: every non-glibc dependency
# is staged into lib/ next to the binaries, so the tree is fully
# self-contained, works at any mount path, and only requires the
# consuming image to provide a compatible glibc — which matches the
# Archiverr image (node:20-trixie-slim, same Debian trixie base).
#
# GPL COMPLIANCE: ffmpeg, libx264 and libx265 are GPL. If this image is
# ever distributed (pushed to a public registry), the corresponding
# source must be offered — see README.md in this directory. The
# Archiverr image itself remains GPL-free; the child_process boundary
# is unchanged.
#
# Build (native arm64 on the Pi):
#   docker build -t archiverr-ffmpeg:latest ffmpeg-provider/
# ================================================================

# ──────────────────────────────────────────────────────────────
# Stage 1: build FFmpeg (glibc matches node:20-trixie-slim)
# ──────────────────────────────────────────────────────────────
FROM debian:trixie-slim AS build

ARG FFMPEG_VERSION=7.1.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config curl ca-certificates xz-utils patchelf \
    # GPL codecs (static .a from -dev packages)
    libx264-dev libx265-dev libnuma-dev \
    # Subtitle burn-in stack
    libass-dev libfreetype-dev libfontconfig-dev libfribidi-dev \
    libharfbuzz-dev libexpat1-dev \
    # AV1 software decode
    libdav1d-dev \
    # TLS + compression (libzstd-dev: OpenSSL 3.5's static libs
    # reference -lzstd, so its .a must be present for the static link)
    libssl-dev zlib1g-dev libzstd-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o ffmpeg.tar.xz \
    && tar -xf ffmpeg.tar.xz --strip-components=1 \
    && rm ffmpeg.tar.xz

# --enable-version3: required for the OpenSSL (Apache-2.0) combination —
# Apache-2.0 is GPLv3-compatible but not GPLv2-compatible.
#
# V4L2 M2M (h264_v4l2m2m / hevc_v4l2m2m) needs NO configure flag or
# extra package: it is auto-enabled on Linux from the kernel UAPI
# headers (linux-libc-dev, pulled in by build-essential). Do not add
# libv4l2-dev — that is for the unrelated --enable-libv4l2 userspace
# wrapper. Presence is asserted in the tree-assembly stage below.
RUN ./configure \
        --prefix=/opt/ffmpeg \
        --extra-version=Archiverr \
        --disable-doc \
        --disable-ffplay \
        --disable-debug \
        --enable-gpl \
        --enable-version3 \
        --enable-openssl \
        --enable-zlib \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libdav1d \
        --enable-libass \
        --enable-libfreetype \
        --enable-libfontconfig \
        --enable-libfribidi \
        --enable-libharfbuzz \
    && make -j"$(nproc)" \
    && make install

# Assemble the self-contained tree: binaries at the root, every non-glibc
# shared-library dependency in lib/ (same layout jellyfin-ffmpeg uses).
# The trailing greps assert the V4L2 M2M codecs (Pi 5 hardware path)
# were compiled in — the build fails if they are missing.
# glibc-family libs are excluded — they must come from the consuming
# container (node:20-trixie-slim ships a matching trixie glibc).
# patchelf sets RPATH=$ORIGIN/lib so the binaries find the staged libs
# at any mount path without LD_LIBRARY_PATH. --force-rpath emits
# old-style DT_RPATH (not DT_RUNPATH): DT_RPATH applies to the whole
# dependency chain, so transitive deps (harfbuzz→glib, freetype→png,
# x265→numa, ...) also resolve from the staged lib/ directory.
#
# GPL compliance: LICENSES/ is staged with the full tree — FFmpeg's
# license texts from the source tarball, plus the Debian copyright
# file of every package whose .so is bundled in lib/.
RUN set -e; \
    mkdir -p /tree/lib /tree/LICENSES; \
    cp /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe /tree/; \
    for bin in /tree/ffmpeg /tree/ffprobe; do \
        ldd "$bin" | awk '/=> \//{print $3}' \
        | grep -vE '/(libc|libm|libmvec|libpthread|libdl|librt)\.so' \
        | grep -vE '/ld-linux'; \
    done | sort -u | xargs -I{} cp -L {} /tree/lib/; \
    patchelf --force-rpath --set-rpath '$ORIGIN/lib' /tree/ffmpeg /tree/ffprobe; \
    ls -la /tree/lib; \
    /tree/ffmpeg -hide_banner -decoders | grep -q hevc_v4l2m2m; \
    /tree/ffmpeg -hide_banner -encoders | grep -q h264_v4l2m2m; \
    cp /build/COPYING.GPLv3 /build/COPYING.GPLv2 /build/LICENSE.md /tree/LICENSES/; \
    for so in /tree/lib/*.so*; do \
        pkg=$(dpkg -S "$(basename "$so")" 2>/dev/null | head -1 | cut -d: -f1) || continue; \
        [ -n "$pkg" ] && [ -f "/usr/share/doc/$pkg/copyright" ] \
            && cp "/usr/share/doc/$pkg/copyright" "/tree/LICENSES/$pkg.copyright" || true; \
    done; \
    ls /tree/LICENSES

# ──────────────────────────────────────────────────────────────
# Stage 2: verify against the REAL consumer base image
# ──────────────────────────────────────────────────────────────
# node:20-trixie-slim is exactly what the Archiverr prod image runs on.
# If the tree resolves and encodes here, it works in production.
FROM node:20-trixie-slim AS verify

COPY --from=build /tree /tree
RUN set -e; \
    ldd /tree/ffmpeg | grep 'not found' && exit 1 || true; \
    /tree/ffmpeg -version; \
    /tree/ffprobe -version; \
    /tree/ffmpeg -hide_banner -loglevel error \
        -f lavfi -i color=c=black:s=320x240:r=25:d=0.5 \
        -f lavfi -i sine=frequency=440:duration=0.5 \
        -c:v libx264 -c:a aac -f null -; \
    echo "verify OK"

# ──────────────────────────────────────────────────────────────
# Stage 3: tiny staging image
# ──────────────────────────────────────────────────────────────
# Never executes ffmpeg itself (the binaries are glibc-linked; this
# stage is musl). It only copies the tree onto the shared volume,
# mirroring the contract of the old jellyfin-based sidecar:
#   /shared/ffmpeg, /shared/ffprobe, /shared/lib/, /shared/.ready
# Copying from `verify` (not `build`) forces the verify stage to run.
FROM alpine:3.20

ARG FFMPEG_VERSION=7.1.3
ARG GIT_COMMIT=unknown

LABEL org.opencontainers.image.title="Archiverr ffmpeg-provider" \
      org.opencontainers.image.description="Self-contained FFmpeg ${FFMPEG_VERSION} sidecar for Archiverr (GPL isolation boundary). Corresponding source: see image.source." \
      org.opencontainers.image.source="https://github.com/Zelltron/archiverr-ffmpeg" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.version="${FFMPEG_VERSION}"

COPY --from=verify /tree /tree
COPY stage.sh /stage.sh
RUN chmod +x /stage.sh

HEALTHCHECK --interval=5s --timeout=3s --retries=12 --start-period=5s \
    CMD test -f /shared/.ready

CMD ["/stage.sh"]
