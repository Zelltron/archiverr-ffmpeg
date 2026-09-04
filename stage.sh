#!/bin/sh
# Stage the self-contained ffmpeg tree onto the shared volume consumed
# by the Archiverr container (mounted read-only at the path given by
# FFMPEG_BIN/FFPROBE_BIN, default /usr/lib/jellyfin-ffmpeg for
# backwards compatibility with host jellyfin-ffmpeg installs).
set -e

rm -f /shared/.ready
# Clear any leftovers from a previous provider (e.g. the old
# jellyfin-ffmpeg dynamic tree with its lib/ directory).
find /shared -mindepth 1 -maxdepth 1 -exec rm -rf {} +

cp -a /tree/. /shared/
touch /shared/.ready
echo "[ffmpeg-provider] staged $(ls /shared/ | wc -l) entries at /shared"
exec tail -f /dev/null
