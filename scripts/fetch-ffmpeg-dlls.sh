#!/usr/bin/env bash
# Fetch the FFmpeg runtime DLLs for the Windows build of zuer-gui and drop them next
# to the executable. These are NOT committed (the shared build is ~130 MB) — like VLC,
# they ship with the app, not with the source. Build-time deps (headers + import libs)
# live in vendor/ffmpeg/ and ARE committed.
#
# Usage: scripts/fetch-ffmpeg-dlls.sh [dest-dir]   (default: zig-out/bin)
set -euo pipefail
DEST="${1:-zig-out/bin}"
URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl-shared.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "→ downloading FFmpeg win64 shared (~76 MB)…"
curl -fsSL -o "$TMP/ff.zip" "$URL"
echo "→ extracting…"
unzip -q "$TMP/ff.zip" -d "$TMP"
PKG="$(find "$TMP" -maxdepth 1 -type d -name 'ffmpeg-*win64*' | head -1)"
mkdir -p "$DEST"
# Only the libs zuer links (+ swresample, an avcodec runtime dep).
for dll in avformat-*.dll avcodec-*.dll avutil-*.dll swscale-*.dll swresample-*.dll; do
  cp -v "$PKG"/bin/$dll "$DEST"/
done
echo "✓ FFmpeg DLLs in $DEST — zuer-gui.exe can now open video files."
