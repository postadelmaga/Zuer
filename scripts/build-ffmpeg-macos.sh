#!/usr/bin/env bash
# Compila le librerie FFmpeg (LGPL, shared) per il bundle macOS arm64, sul Mac
# stesso (VideoToolbox richiede l'SDK Apple: niente cross-compilazione).
#
# Stesso commit delle DLL Windows (scripts/fetch-ffmpeg-dlls.sh): stessa ABI
# (avformat-63, avcodec-63, avutil-61, swscale-10, swresample-7) degli header
# vendorati in vendor/ffmpeg/include, che zuer-gui e il plugin media usano per
# risolvere i simboli a runtime.
#
# Licenza: LGPL-2.1-or-later (nessun --enable-gpl / --enable-nonfree; nessuna
# libreria esterna: --disable-autodetect, poi solo framework di sistema Apple).
# Install name `@rpath/…` più LC_RPATH `@loader_path`: le dylib si trovano fra
# loro dentro Zuer.app/Contents/Frameworks, senza percorsi assoluti.
#
# Uscita: <prefix>/lib/lib{avutil,…}.N.dylib e <prefix>/share/zuer/FFmpeg-{LICENSE,SOURCE}.txt
#   scripts/build-ffmpeg-macos.sh [prefix]     (default: zig-out/ffmpeg-macos)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${1:-$ROOT/zig-out/ffmpeg-macos}"
FF_COMMIT="5d85b7bfb2b024fd367ae3a938b4ac46a39e3a26" # = FFMPEG_COMMIT di fetch-ffmpeg-dlls.sh
WORK="${ZUER_FFMPEG_WORK:-$ROOT/zig-out/ffmpeg-macos-build}"
SRC="$WORK/src"

[[ "$(uname -s)" == Darwin ]] || { echo "✗ da eseguire su macOS (serve l'SDK per VideoToolbox)"; exit 1; }

CONFIGURE_ARGS=(
  --prefix="$PREFIX"
  --arch=arm64 --cc=clang
  --enable-shared --disable-static
  --disable-programs --disable-doc --disable-debug
  --disable-autodetect
  # Solo framework di sistema: decodifica hardware, TLS per i video di rete, zlib.
  --enable-videotoolbox --enable-securetransport --enable-zlib
  --disable-avdevice --disable-avfilter --disable-encoders --disable-muxers
  --disable-outdevs --disable-indevs
  --install-name-dir=@rpath
  --extra-ldflags=-Wl,-rpath,@loader_path
)
HAVE=1
for n in avutil swresample swscale avcodec avformat; do
  compgen -G "$PREFIX/lib/lib$n.[0-9]*.dylib" >/dev/null || HAVE=0
done
STAMP="$PREFIX/share/zuer/.build-hash"
HASH="$(shasum -a 256 <<<"$FF_COMMIT ${CONFIGURE_ARGS[*]}" | cut -d' ' -f1)"
if [[ $HAVE == 1 && -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" ]]; then
  echo "→ FFmpeg macOS già compilato ($PREFIX): riuso"
  exit 0
fi

if [[ ! -f "$SRC/configure" ]]; then
  echo "→ fetch FFmpeg @ $FF_COMMIT (shallow)"
  rm -rf "$SRC"; mkdir -p "$SRC"; git -C "$SRC" init -q
  git -C "$SRC" remote add origin https://github.com/FFmpeg/FFmpeg.git
  git -C "$SRC" fetch -q --depth 1 origin "$FF_COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$FF_COMMIT" ]] || { echo "✗ sorgente non al commit atteso"; exit 1; }

mkdir -p "$WORK/build"; cd "$WORK/build"
echo "→ configure"
"$SRC/configure" "${CONFIGURE_ARGS[@]}" > configure.log || { tail -30 configure.log; exit 1; }
grep -q 'License: LGPL version 2.1 or later' configure.log || { echo "✗ licenza inattesa"; grep -i license configure.log; exit 1; }
echo "→ make"
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null

mkdir -p "$PREFIX/share/zuer"
cat "$SRC/LICENSE.md" "$SRC/COPYING.LGPLv2.1" > "$PREFIX/share/zuer/FFmpeg-LICENSE.txt"
cat > "$PREFIX/share/zuer/FFmpeg-SOURCE.txt" <<TXT
FFmpeg — librerie distribuite con Zuer per macOS (LGPL-2.1-or-later)

Sorgente:  https://github.com/FFmpeg/FFmpeg/tree/$FF_COMMIT
Commit:    $FF_COMMIT
Configure: ${CONFIGURE_ARGS[*]}
Script:    scripts/build-ffmpeg-macos.sh (repository di Zuer)

Le librerie sono dylib separate in Zuer.app/Contents/Frameworks, caricate a
runtime: si possono sostituire con una build propria della stessa ABI.
TXT
echo "$HASH" > "$STAMP"
ls -l "$PREFIX"/lib/*.dylib
echo "✓ FFmpeg macOS in $PREFIX"
