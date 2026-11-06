#!/usr/bin/env bash
# Fetch the FFmpeg runtime DLLs for the Windows build of zuer-gui and drop them next
# to the executable. These are NOT committed (the shared build is ~130 MB) — like VLC,
# they ship with the app, not with the source. Build-time deps (headers + import libs)
# live in vendor/ffmpeg/ and ARE committed.
#
# Usage: scripts/fetch-ffmpeg-dlls.sh [dest-dir]   (default: zig-out/bin)
set -euo pipefail
DEST="${1:-zig-out/bin}"

# ── Build pinnata di BtbN/FFmpeg-Builds ──────────────────────────────────────
# Vincolo ABI: le import-lib e gli header in vendor/ffmpeg sono avformat/avcodec 63.3,
# avutil 61.2, swscale 10.2, swresample 7.2 (FFmpeg master N-125444). Servono DLL con
# gli STESSI major e minor >= quelli: un ramo di rilascio (n9.0 = avformat 63.1) è
# PIÙ VECCHIO degli header e non va bene; un master successivo sì.
# Variante LGPL (`--enable-version3`, niente `--enable-gpl`): Zuer decodifica soltanto,
# i componenti GPL (encoder x264/x265…) non servono e gli obblighi sono minori. LGPL-3.0
# in collegamento dinamico è compatibile con l'AGPL-3.0 di Zuer.
# BtbN tiene gli autobuild datati per alcune settimane: alla prossima release, se il
# download dà 404, scegline uno recente (`gh release list -R BtbN/FFmpeg-Builds`),
# aggiorna tag/asset/hash/commit qui sotto e rifai il controllo dei major/minor.
BTBN_TAG="autobuild-2026-11-06-12-50"
ASSET="ffmpeg-N-128532-g5d85b7bfb2-win64-lgpl-shared.zip"
FFMPEG_COMMIT="5d85b7bfb2"
URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/$BTBN_TAG/$ASSET"
# sha256 dell'asset sopra (verificato il 2026-11-07: avformat-63.dll = Lavf63.18.100).
EXPECTED_SHA256="d23988d45427bff6c445bbb1e510df6ad6d1470df78d3522cc60d70d16cd62c3"

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
# Major delle DLL = major delle import-lib vendored (vendor/ffmpeg).
for dll in avformat-63 avcodec-63 avutil-61 swscale-10 swresample-7; do
  [[ -f "$PKG/bin/$dll.dll" ]] \
    || { echo "✗ $dll.dll assente: major diverso dalle import-lib vendored"; exit 1; }
done
mkdir -p "$DEST"
# Solo le librerie che zuer collega (+ swresample, dipendenza di avcodec).
for dll in avformat-63 avcodec-63 avutil-61 swscale-10 swresample-7; do
  cp -v "$PKG/bin/$dll.dll" "$DEST"/
done
# Obblighi LGPL: testo della licenza e da dove si ottiene il sorgente corrispondente.
cp "$PKG/LICENSE.txt" "$DEST/FFmpeg-LICENSE.txt"
cat > "$DEST/FFmpeg-SOURCE.txt" <<SRC
Le librerie FFmpeg incluse (avformat-63, avcodec-63, avutil-61, swscale-10,
swresample-7) sono distribuite sotto LGPL-3.0-or-later (vedi FFmpeg-LICENSE.txt),
non modificate, come costruite da BtbN/FFmpeg-Builds.

Build:     $ASSET
Release:   https://github.com/BtbN/FFmpeg-Builds/releases/tag/$BTBN_TAG
SHA-256:   $EXPECTED_SHA256
Sorgente:  FFmpeg commit $FFMPEG_COMMIT
           https://git.ffmpeg.org/gitweb/ffmpeg.git/commit/$FFMPEG_COMMIT
           https://github.com/FFmpeg/FFmpeg/tree/$FFMPEG_COMMIT
Script di build: https://github.com/BtbN/FFmpeg-Builds
SRC
echo "✓ FFmpeg DLLs in $DEST — zuer-gui.exe can now open video files."
