# ================================================================
# Archiverr ffmpeg-provider — self-built FFmpeg sidecar
# ================================================================
#
# Builds FFmpeg 7.1.5 from the Raspberry Pi FFmpeg fork
# (github.com/jc-kynesim/rpi-ffmpeg), pinned by commit, plus the
# patches in patches/ (GPL corresponding source = this repo + the fork
# archive at that commit), with exactly
# the features Archiverr uses (see server/routes/player/* and
# server/services/iptv):
#
#   - libx264 / libx265        software encode (GPL — stays in this
#                              sidecar, never in the Archiverr image)
#   - Hardware decode/encode paths:
#       -hwaccel drm           V4L2 request-API hwaccel for the Pi 4/5
#                              `rpivid` HEVC decoder (fork-only), plus
#                              the `unsand` sand→planar filter
#       h264_v4l2m2m / hevc_v4l2m2m  V4L2 stateful M2M codecs
#       VAAPI                  Intel/AMD decode + encode
#       QSV (libvpl)           Intel Quick Sync, amd64 builds only
#       NVDEC / NVENC / cuvid  NVIDIA, via the MIT nv-codec-headers
#                              (driver libraries dlopen'ed at runtime)
#   - libass + freetype/fontconfig/fribidi/harfbuzz  subtitle burn-in
#   - libdav1d                 fast AV1 software decode
#   - openssl                  TLS for IPTV https inputs
#   - libzvbi                  DVB teletext subtitle decode (IPTV)
#   - OpenCL filters           tonemap_opencl etc. — dormant on the Pi
#                              (no ICD), ready for Intel/AMD hosts
#   - native aac encoder, all native decoders (ac3/eac3/dts/truehd/...)
#
# Deliberately NOT included: libbluray (Archiverr never opens BDMV
# structures), libvpx/libopus/libvorbis/libtheora (only their encoders
# would add anything — Archiverr encodes h264/hevc/aac/eac3 only; the
# native decoders already cover playback of those formats).
#
# The binaries link their third-party libs dynamically, with
# RPATH=$ORIGIN/lib: every non-glibc dependency is staged into lib/
# next to the binaries, so the tree is fully self-contained, works at
# any mount path, and only requires the consuming image to provide a
# compatible glibc — which matches the Archiverr image
# (node:20-trixie-slim, same Debian trixie base). The tree also carries
# a VERSION provenance file (version line, source commit, revision).
#
# GPL COMPLIANCE: ffmpeg, libx264 and libx265 are GPL. If this image is
# ever distributed (pushed to a public registry), the corresponding
# source must be offered — see README.md in this directory. The
# Archiverr image itself remains GPL-free; the child_process boundary
# is unchanged.
#
# Build (native arm64 on the Pi), from the root of this repo:
#   docker build -t archiverr-ffmpeg:v2.0.1 --build-arg GIT_COMMIT=$(git rev-parse HEAD) .
# ================================================================

# Raspberry Pi FFmpeg fork (upstream 7.1.5 + guarded Pi patches): the only
# FFmpeg with the V4L2 request-API hwaccel that drives the Pi 4/5 `rpivid`
# HEVC decoder (`-hwaccel drm`). Upstream FFmpeg (through 9.0) has none.
# Pinned by commit, not branch: the fork's test/ branches move.
# Declared once, globally, so VERSION and the image labels cannot disagree;
# each stage that uses them re-imports them with a bare ARG.
ARG FFMPEG_REPO=jc-kynesim/rpi-ffmpeg
ARG FFMPEG_REF=950ab0323334111e1a4cdc6b037eadfaf0524167
ARG FFMPEG_VERSION=7.1.5
# MIT headers only; the NVIDIA driver libraries are dlopen'ed at runtime.
# The build checks out NVCODEC_REF (the commit NVCODEC_TAG points at, so a
# moved tag cannot change the build); NVCODEC_TAG names the release archive
# that mirror-sources.sh collects. Bump both together.
ARG NVCODEC_TAG=n12.2.72.0
ARG NVCODEC_REF=c69278340ab1d5559c7d7bf0edf615dc33ddbba7
# VA-API / QSV runtime drivers staged into the tree (amd64 only; libva and
# libvpl dlopen them, Archiverr points LIBVA_DRIVERS_PATH / ONEVPL_SEARCH_PATH
# at lib/dri). Values: "intel" (iHD + legacy i965 + oneVPL GPU runtime, about
# 30 MB, all MIT), "intel,amd" (adds Mesa radeonsi, which drags in LLVM: about
# 135 MB more), "none". arm64 builds stage nothing whatever the value.
ARG VA_DRIVERS=intel

# ──────────────────────────────────────────────────────────────
# Stage 1: build FFmpeg (glibc matches node:20-trixie-slim)
# ──────────────────────────────────────────────────────────────
FROM debian:trixie-slim AS build

ARG FFMPEG_REPO
ARG FFMPEG_REF
ARG FFMPEG_VERSION
ARG NVCODEC_TAG
ARG NVCODEC_REF

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config curl ca-certificates xz-utils patchelf git patch \
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
    # DVB teletext subtitle decoding
    libzvbi-dev \
    # OpenCL filter support (ICD loader only)
    ocl-icd-opencl-dev opencl-c-headers \
    # V4L2 request API (Pi rpivid) needs libdrm + libudev; VAAPI needs libva
    libdrm-dev libudev-dev libva-dev \
    && rm -rf /var/lib/apt/lists/*

# x86-only build deps: Intel oneVPL (QSV), and nasm for FFmpeg's (and
# dav1d's) x86 assembly — configure refuses to run on amd64 without it.
RUN set -e; if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      apt-get update && apt-get install -y --no-install-recommends libvpl-dev nasm \
      && rm -rf /var/lib/apt/lists/*; fi

# NVIDIA codec headers (MIT): enables nvdec/nvenc/cuvid at build time.
# The repo ships no LICENSE file; each header carries its own MIT notice,
# so the license file is assembled from those leading comment blocks.
RUN git init -q /build-nv \
    && git -C /build-nv fetch -q --depth 1 https://github.com/FFmpeg/nv-codec-headers.git "${NVCODEC_REF}" \
    && git -C /build-nv checkout -q FETCH_HEAD \
    && [ "$(git -C /build-nv rev-parse HEAD)" = "${NVCODEC_REF}" ] \
    && make -C /build-nv install PREFIX=/usr \
    && for h in /build-nv/include/ffnvcodec/*.h; do \
         printf '==> %s <==\n' "$(basename "$h")"; sed -n '1,/\*\//p' "$h"; echo; \
       done > /usr/share/nv-codec-headers.LICENSE \
    && grep -q 'Permission is hereby granted' /usr/share/nv-codec-headers.LICENSE \
    && rm -rf /build-nv

WORKDIR /build
RUN curl -fsSL "https://github.com/${FFMPEG_REPO}/archive/${FFMPEG_REF}.tar.gz" -o ffmpeg.tar.gz \
    && tar -xzf ffmpeg.tar.gz --strip-components=1 \
    && rm ffmpeg.tar.gz

# Archiverr patches on top of the fork (-p1 against the source tree).
COPY patches/ /build/patches/
RUN set -e; for p in /build/patches/*.patch; do patch -p1 < "$p"; done

# --enable-version3: OpenSSL 3 (Apache-2.0) is GPLv3-compatible but not
# GPLv2-compatible. (libvpl is MIT and needs no such flag.)
# --enable-v4l2-request/--enable-libdrm/--enable-libudev/--enable-sand:
#   the fork's Pi decode path (hevc hwaccel "drm", unsand filter).
# --enable-vaapi: Intel/AMD. --enable-libvpl: Intel QSV (amd64 only).
# --enable-ffnvcodec/nvdec/nvenc/cuvid: NVIDIA via MIT headers.
# V4L2 M2M (h264/hevc_v4l2m2m) still auto-enables from kernel headers
# (linux-libc-dev). Do not add libv4l2-dev — that is for the unrelated
# --enable-libv4l2 userspace wrapper.
RUN set -e; \
    QSV_FLAGS=""; [ "$(dpkg --print-architecture)" = "amd64" ] && QSV_FLAGS="--enable-libvpl"; \
    ./configure \
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
        --enable-libzvbi \
        --enable-opencl \
        --enable-libdrm \
        --enable-libudev \
        --enable-v4l2-request \
        --enable-sand \
        --enable-vaapi \
        --enable-ffnvcodec \
        --enable-nvdec \
        --enable-nvenc \
        --enable-cuvid \
        $QSV_FLAGS \
    && make -j"$(nproc)" \
    && make install

# VA-API / QSV runtime drivers. Imported and installed here, after the
# compile, so a different VA_DRIVERS value never invalidates the FFmpeg
# build layers above.
ARG VA_DRIVERS
RUN set -e; \
    if [ "$(dpkg --print-architecture)" = "amd64" ] && [ "$VA_DRIVERS" != "none" ]; then \
        pkgs=""; \
        case ",$VA_DRIVERS," in *,intel,*) pkgs="$pkgs intel-media-va-driver i965-va-driver libmfx-gen1.2";; esac; \
        case ",$VA_DRIVERS," in *,amd,*) pkgs="$pkgs mesa-va-drivers";; esac; \
        apt-get update && apt-get install -y --no-install-recommends $pkgs \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Assemble the self-contained tree: binaries at the root, every non-glibc
# shared-library dependency in lib/.
# The hardware-surface greps assert every hardware path (drm, VAAPI,
# CUDA/NVENC/cuvid, V4L2 M2M, QSV on amd64) plus the teletext, OpenCL
# and unsand features were compiled in — the build fails if any is
# missing.
# glibc-family libs are excluded — they must come from the consuming
# container (node:20-trixie-slim ships a matching trixie glibc).
# patchelf sets RPATH=$ORIGIN/lib so the binaries find the staged libs
# at any mount path without LD_LIBRARY_PATH. --force-rpath emits
# old-style DT_RPATH (not DT_RUNPATH): DT_RPATH applies to the whole
# dependency chain, so transitive deps (harfbuzz→glib, freetype→png,
# x265→numa, ...) also resolve from the staged lib/ directory.
#
# GPL compliance: LICENSES/ is staged with the full tree — FFmpeg's
# license texts from the source tree, the nv-codec-headers MIT license,
# plus the Debian copyright file of every package whose .so is bundled
# in lib/.
# GIT_COMMIT is imported here, not earlier, so a new commit only
# invalidates this layer and not the FFmpeg compile above it.
ARG GIT_COMMIT=unknown
RUN set -e; \
    ARCH="$(dpkg --print-architecture)"; \
    mkdir -p /tree/lib /tree/LICENSES; \
    cp /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe /tree/; \
    for bin in /tree/ffmpeg /tree/ffprobe; do \
        ldd "$bin" | awk '/=> \//{print $3}' \
        | grep -vE '/(libc|libm|libmvec|libpthread|libdl|librt)\.so' \
        | grep -vE '/ld-linux'; \
    done | sort -u | xargs -I{} cp -L {} /tree/lib/; \
    patchelf --force-rpath --set-rpath '$ORIGIN/lib' /tree/ffmpeg /tree/ffprobe; \
    # VA drivers are dlopen'ed (libva: <LIBVA_DRIVERS_PATH>/<name>_drv_video.so;
    # libvpl: <ONEVPL_SEARCH_PATH>/libmfx-gen.so.1.2), so they and their own
    # dependency closure are staged by hand. DRIVERS lists what was staged
    # (empty on arm64 / VA_DRIVERS=none); Archiverr logs it at boot.
    : > /tree/DRIVERS; \
    if [ "$ARCH" = "amd64" ] && [ "$VA_DRIVERS" != "none" ]; then \
        mkdir -p /tree/lib/dri; \
        for drv in /usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so \
                   /usr/lib/x86_64-linux-gnu/dri/i965_drv_video.so \
                   /usr/lib/x86_64-linux-gnu/dri/radeonsi_drv_video.so \
                   /usr/lib/x86_64-linux-gnu/libmfx-gen.so.1.2; do \
            [ -e "$drv" ] || continue; \
            case "$drv" in *_drv_video.so) dest="/tree/lib/dri/$(basename "$drv")";; *) dest="/tree/lib/$(basename "$drv")";; esac; \
            cp -L "$drv" "$dest"; \
            ldd "$drv" | awk '/=> \//{print $3}' \
            | grep -vE '/(libc|libm|libmvec|libpthread|libdl|librt)\.so' | grep -vE '/ld-linux' \
            | while read -r dep; do [ -e "/tree/lib/$(basename "$dep")" ] || cp -L "$dep" /tree/lib/; done; \
            case "$dest" in /tree/lib/dri/*) patchelf --force-rpath --set-rpath '$ORIGIN/..' "$dest";; \
                            *) patchelf --force-rpath --set-rpath '$ORIGIN' "$dest";; esac; \
            echo "$(basename "$drv") $(dpkg -S "$drv" | cut -d: -f1)" >> /tree/DRIVERS; \
        done; \
        case ",$VA_DRIVERS," in *,intel,*) \
            test -e /tree/lib/dri/iHD_drv_video.so; test -e /tree/lib/dri/i965_drv_video.so; test -e /tree/lib/libmfx-gen.so.1.2;; esac; \
        case ",$VA_DRIVERS," in *,amd,*) test -e /tree/lib/dri/radeonsi_drv_video.so;; esac; \
        for f in /tree/lib/dri/*.so /tree/lib/libmfx-gen.so.*; do \
            [ -e "$f" ] || continue; \
            ldd "$f" | grep 'not found' && exit 1 || true; \
        done; \
    fi; \
    cat /tree/DRIVERS; \
    ls -la /tree/lib; \
    # Hardware surface assertions (build fails if any path is missing)
    /tree/ffmpeg -hide_banner -hwaccels | grep -qx drm; \
    /tree/ffmpeg -hide_banner -hwaccels | grep -qx vaapi; \
    /tree/ffmpeg -hide_banner -hwaccels | grep -qx cuda; \
    /tree/ffmpeg -hide_banner -h decoder=hevc | grep -E 'Supported hardware devices' | grep -q drm; \
    /tree/ffmpeg -hide_banner -decoders | grep -q hevc_v4l2m2m; \
    /tree/ffmpeg -hide_banner -decoders | grep -q hevc_cuvid; \
    /tree/ffmpeg -hide_banner -decoders | grep -q libzvbi_teletext; \
    /tree/ffmpeg -hide_banner -encoders | grep -q h264_v4l2m2m; \
    /tree/ffmpeg -hide_banner -encoders | grep -qE ' h264_nvenc '; \
    /tree/ffmpeg -hide_banner -encoders | grep -qE ' h264_vaapi '; \
    /tree/ffmpeg -hide_banner -filters | grep -q tonemap_opencl; \
    /tree/ffmpeg -hide_banner -filters | grep -q unsand; \
    [ "$ARCH" != "amd64" ] || /tree/ffmpeg -hide_banner -decoders | grep -q hevc_qsv; \
    # Provenance file read by Archiverr at boot
    printf '%s\nsource=https://github.com/%s/tree/%s\nrevision=%s\n' \
        "$(/tree/ffmpeg -version | head -1)" "$FFMPEG_REPO" "$FFMPEG_REF" "$GIT_COMMIT" > /tree/VERSION; \
    cat /tree/VERSION; \
    head -1 /tree/VERSION | grep -q "^ffmpeg version ${FFMPEG_VERSION}-Archiverr"; \
    cp /build/COPYING.GPLv3 /build/COPYING.GPLv2 /build/LICENSE.md /tree/LICENSES/; \
    cp /usr/share/nv-codec-headers.LICENSE /tree/LICENSES/nv-codec-headers.LICENSE; \
    for so in /tree/lib/*.so* /tree/lib/dri/*.so; do \
        [ -e "$so" ] || continue; \
        pkg=$(dpkg -S "$(basename "$so")" 2>/dev/null | head -1 | cut -d: -f1) || continue; \
        [ -n "$pkg" ] && [ -f "/usr/share/doc/$pkg/copyright" ] \
            && cp "/usr/share/doc/$pkg/copyright" "/tree/LICENSES/$pkg.copyright" || true; \
    done; \
    ls /tree/LICENSES

# ──────────────────────────────────────────────────────────────
# Stage 2: verify against the REAL consumer base image
# ──────────────────────────────────────────────────────────────
# node:20-trixie-slim is exactly what the Archiverr prod image runs on.
# If the tree resolves, encodes and decodes here, it works in production.
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
    /tree/ffmpeg -hide_banner -loglevel error \
        -f lavfi -i testsrc2=size=320x240:rate=25 -frames:v 24 \
        -c:v libx265 -x265-params log-level=error -f hevc -y /tmp/probe.hevc; \
    /tree/ffmpeg -hide_banner -loglevel error -f hevc -i /tmp/probe.hevc -f null -; \
    # VERSION format (separate commands: set -e ignores non-final && failures)
    [ "$(wc -l < /tree/VERSION)" -eq 3 ]; \
    sed -n 2p /tree/VERSION | grep -q '^source=https://github.com/'; \
    sed -n 3p /tree/VERSION | grep -q '^revision='; \
    test -f /tree/DRIVERS; \
    for f in /tree/lib/dri/*.so /tree/lib/libmfx-gen.so.*; do \
        [ -e "$f" ] || continue; \
        ldd "$f" | grep 'not found' && exit 1 || true; \
    done; \
    echo "verify OK"

# ──────────────────────────────────────────────────────────────
# Stage 3: tiny staging image
# ──────────────────────────────────────────────────────────────
# Never executes ffmpeg itself (the binaries are glibc-linked; this
# stage is musl). It only copies the tree onto the shared volume:
#   /shared/ffmpeg, /shared/ffprobe, /shared/lib/, /shared/VERSION,
#   /shared/.ready
# Copying from `verify` (not `build`) forces the verify stage to run.
FROM alpine:3.20

ARG FFMPEG_VERSION
ARG FFMPEG_REPO
ARG FFMPEG_REF
ARG VA_DRIVERS
ARG GIT_COMMIT=unknown

LABEL org.opencontainers.image.title="Archiverr ffmpeg-provider" \
      org.opencontainers.image.description="Self-contained FFmpeg ${FFMPEG_VERSION} sidecar for Archiverr, built from the Raspberry Pi FFmpeg fork (GPL isolation boundary). Corresponding source: see image.source and io.archiverr.ffmpeg.source." \
      org.opencontainers.image.source="https://github.com/Zelltron/archiverr-ffmpeg" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.version="${FFMPEG_VERSION}" \
      io.archiverr.va-drivers="${VA_DRIVERS}" \
      io.archiverr.ffmpeg.source="https://github.com/${FFMPEG_REPO}/tree/${FFMPEG_REF}"

COPY --from=verify /tree /tree
COPY stage.sh /stage.sh
RUN chmod +x /stage.sh

HEALTHCHECK --interval=5s --timeout=3s --retries=12 --start-period=5s \
    CMD test -f /shared/.ready

CMD ["/stage.sh"]
