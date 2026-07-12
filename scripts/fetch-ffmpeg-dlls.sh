#!/usr/bin/env bash
# Fetch the FFmpeg runtime DLLs for the Windows build of zuer-gui and drop them next
# to the executable. These are NOT committed (the shared build is ~130 MB) — like VLC,
# they ship with the app, not with the source. Build-time deps (headers + import libs)
# live in vendor/ffmpeg/ and ARE committed.
#
# Usage: scripts/fetch-ffmpeg-dlls.sh [dest-dir]   (default: zig-out/bin)
set -euo pipefail
DEST="${1:-zig-out/bin}"

# ── Release pinnata di BtbN/FFmpeg-Builds ────────────────────────────────────
# Vincolo "major 63": le import-lib vendored in vendor/ffmpeg/lib sono generate
# dal commit FFmpeg 6d72600a30 (BtbN N-125444, avformat MAJOR 63 — vedi
# scripts/build-ffmpeg-trimmed.sh). L'exe cerca avformat-63.dll a runtime, quindi
# NON si usa il tag mobile "latest" (prima o poi passerà ad avformat-64 e le DLL
# non combacerebbero più con le import-lib): si pinna l'autobuild che contiene
# esattamente quel commit. Se aggiorni vendor/ffmpeg, aggiorna tag/asset/hash qui.
BTBN_TAG="autobuild-2026-07-03-13-21"
ASSET="ffmpeg-N-125444-g6d72600a30-win64-gpl-shared.zip"
URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/$BTBN_TAG/$ASSET"
# sha256 dell'asset sopra (verificato il 2026-07-07: contiene avformat-63.dll).
EXPECTED_SHA256="6e25b455be1eb102e1e69d62b39bc45074cf8fc4f097bee847339778529c37af"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "→ downloading FFmpeg win64 shared ($BTBN_TAG, ~76 MB)…"
curl -fsSL -o "$TMP/ff.zip" "$URL"
# Verifica supply-chain: le DLL finiscono dentro Zuer-Setup.exe, quindi il
# pacchetto scaricato deve corrispondere bit-a-bit a quello verificato a mano.
echo "→ verifying sha256…"
echo "$EXPECTED_SHA256  $TMP/ff.zip" | sha256sum -c - >/dev/null \
  || { echo "✗ sha256 non corrisponde: asset compromesso o cambiato ($URL)"; exit 1; }
echo "→ extracting…"
unzip -q "$TMP/ff.zip" -d "$TMP"
PKG="$(find "$TMP" -maxdepth 1 -type d -name 'ffmpeg-*win64*' | head -1)"
# Sanity check sui soname: l'exe è linkato contro avformat MAJOR 63 (vendor/ffmpeg).
[[ -f "$PKG/bin/avformat-63.dll" ]] \
  || { echo "✗ avformat-63.dll assente nel pacchetto: major diverso dalle import-lib vendored (serve MAJOR 63)"; exit 1; }
mkdir -p "$DEST"
# Only the libs zuer links (+ swresample, an avcodec runtime dep).
for dll in avformat-*.dll avcodec-*.dll avutil-*.dll swscale-*.dll swresample-*.dll; do
  cp -v "$PKG"/bin/$dll "$DEST"/
done
echo "✓ FFmpeg DLLs in $DEST — zuer-gui.exe can now open video files."
