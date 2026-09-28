#!/bin/sh
# Stage the self-contained ffmpeg tree onto the shared directory/volume the
# Archiverr container mounts read-only at /opt/archiverr-ffmpeg (or wherever
# FFMPEG_BIN/FFPROBE_BIN point). Contract consumed by Archiverr:
#   /shared/ffmpeg, /shared/ffprobe   binaries (RPATH=$ORIGIN/lib)
#   /shared/lib/                      every non-glibc shared library
#   /shared/LICENSES/                 license texts (GPL corresponding-source pointer)
#   /shared/VERSION                   "ffmpeg version ..." + source= + revision= lines
#   /shared/.ready                    written last; the compose healthcheck tests it
set -e

rm -f /shared/.ready
# Clear whatever a previous provider left behind.
find /shared -mindepth 1 -maxdepth 1 -exec rm -rf {} +

cp -a /tree/. /shared/
touch /shared/.ready
echo "[ffmpeg-provider] staged $(ls /shared/ | wc -l) entries at /shared"
echo "[ffmpeg-provider] $(head -1 /shared/VERSION)"
exec tail -f /dev/null
