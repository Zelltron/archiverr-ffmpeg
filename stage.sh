#!/bin/sh
# Stage the self-contained ffmpeg tree onto the shared directory/volume the
# Archiverr container mounts read-only at /opt/archiverr-ffmpeg (or wherever
# FFMPEG_BIN/FFPROBE_BIN point). Contract consumed by Archiverr:
#   /shared/ffmpeg, /shared/ffprobe   binaries (RPATH=$ORIGIN/lib)
#   /shared/lib/                      every non-glibc shared library
#   /shared/LICENSES/                 license texts (GPL corresponding-source pointer)
#   /shared/VERSION                   "ffmpeg version ..." + source= + revision= lines
#   /shared/DRIVERS                   one "<file> <debian package>" line per staged VA driver (may be empty)
#   /shared/lib/dri/                  VA drivers (amd64 builds), for LIBVA_DRIVERS_PATH
#   /shared/.ready                    written last; the compose healthcheck tests it
set -e

# /shared is emptied on every start. Refuse if it holds anything that is not
# a previous ffmpeg tree (a bind mount pointed at the wrong host directory):
# exiting non-zero leaves .ready unwritten, so the healthcheck fails visibly.
# A fresh filesystem is still "empty": lost+found and dot-entries (for
# example .ready from an interrupted stage) do not count as foreign files.
foreign="$(ls -A /shared 2>/dev/null | grep -v -e '^lost+found$' -e '^\.' || true)"
if [ -n "$foreign" ] && [ ! -e /shared/VERSION ] && [ ! -e /shared/.ready ]; then
    echo "[ffmpeg-provider] refusing to empty /shared: it holds files that are not a previous ffmpeg tree"
    exit 1
fi

rm -f /shared/.ready
# Clear whatever a previous provider left behind.
find /shared -mindepth 1 -maxdepth 1 -exec rm -rf {} +

cp -a /tree/. /shared/
touch /shared/.ready
echo "[ffmpeg-provider] staged $(ls /shared/ | wc -l) entries at /shared"
echo "[ffmpeg-provider] $(head -1 /shared/VERSION)"
exec tail -f /dev/null
