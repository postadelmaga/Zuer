#!/usr/bin/env bash
# Compila una FFmpeg "trimmed" stile VLC per Windows (cross da Linux con mingw-w64):
# configure minimale `--disable-everything` + solo i demuxer/decoder/parser che
# servono a zuer per le estensioni dichiarate dal decoder media. Le DLL shared che
# ne escono (avcodec/avformat/avutil/swscale/swresample) sono decine di volte più
# piccole di quelle "gpl-shared" di BtbN (~131 MB → pochi MB), e rimpiazzano quelle.
#
# Chiave: si compila lo STESSO commit FFmpeg da cui provengono le import-lib e gli
# header vendored in vendor/ffmpeg/ (BtbN N-125444 = commit 6d72600a30, avformat 63).
# Stesso commit → stessi soname (avformat-63.dll…) e stessa API pubblica esportata
# (disabilitare un codec NON rimuove i simboli pubblici), quindi vendor/ffmpeg/lib
# e vendor/ffmpeg/include restano validi as-is: zuer linka e gira senza modifiche.
#
# Uso:  scripts/build-ffmpeg-trimmed.sh [dest-dir]     (default: zig-out/bin)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT/zig-out/bin}"
FF_COMMIT="6d72600a301c441e4a6d46663fbbfdad7e021068"  # = vendor/ffmpeg (BtbN N-125444, avformat 63)
WORK="$ROOT/zig-out/ffmpeg-trim"
SRC="$WORK/src"
PREFIX="$WORK/install"
CROSS="x86_64-w64-mingw32-"

command -v "${CROSS}gcc" >/dev/null || { echo "✗ manca ${CROSS}gcc (mingw-w64)"; exit 1; }

# nasm → ottimizzazioni SIMD x86 (decode più veloce, DLL un filo più grandi).
# Assente → C puro (--disable-x86asm): funziona ovunque, solo più lento.
if command -v nasm >/dev/null; then ASM=--enable-x86asm; echo "· nasm trovato → SIMD x86 abilitato"; else ASM=--disable-x86asm; echo "· nasm assente → C puro"; fi

# ── Sorgente: fetch shallow del solo commit vendorato ───────────────────────
if [[ ! -f "$SRC/configure" ]]; then
  echo "→ fetch FFmpeg @ $FF_COMMIT (shallow)…"
  rm -rf "$SRC"; mkdir -p "$SRC"; git -C "$SRC" init -q
  git -C "$SRC" remote add origin https://github.com/FFmpeg/FFmpeg.git
  git -C "$SRC" fetch -q --depth 1 origin "$FF_COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
fi

# ── Set minimale che copre le estensioni del decoder media ──────────────────
# mp3 wav flac ogg oga ogv opus m4a mp4 m4v mov mkv webm avi  (midi: no synth in ffmpeg)
DEMUXERS="mov,matroska,avi,mp3,flac,wav,w64,ogg,aac,aiff,flv,m4v"
DECODERS="h264,hevc,mpeg4,mpeg2video,mpeg1video,vp8,vp9,av1,theora,mjpeg,\
aac,aac_latm,ac3,eac3,mp1,mp2,mp3,mp3float,flac,vorbis,opus,alac,\
pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,pcm_s16be,pcm_mulaw,pcm_alaw"
PARSERS="h264,hevc,mpeg4video,mpegvideo,vp8,vp9,av1,aac,aac_latm,ac3,flac,mpegaudio,opus,vorbis,mjpeg"
BSFS="h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe,aac_adtstoasc,mpeg4_unpack_bframes,extract_extradata"

mkdir -p "$WORK/build"; cd "$WORK/build"

# ── Configure con sentinella anti-staleness ──────────────────────────────────
# Un config.mak esistente NON basta per saltare il configure: se cambiano i set
# DEMUXERS/DECODERS/… o i flag qui sopra, riusarlo in silenzio spedirebbe DLL
# col set vecchio. Si hasha l'intera riga di configure e si riconfigura quando
# la sentinella manca o differisce.
CONFIGURE_ARGS=(
  --prefix="$PREFIX"
  --arch=x86_64 --target-os=mingw32 --cross-prefix="$CROSS" --enable-cross-compile
  --enable-shared --disable-static
  --disable-programs --disable-doc --disable-network --disable-autodetect
  --disable-avdevice --disable-avfilter
  --disable-debug "$ASM" --optflags='-Os'
  --extra-ldflags='-static'
  --disable-everything
  --enable-protocol=file,pipe
  --enable-demuxer="$DEMUXERS"
  --enable-decoder="$DECODERS"
  --enable-parser="$PARSERS"
  --enable-bsf="$BSFS"
  --enable-swscale --enable-swresample
)
SENTINEL="$WORK/build/.configure-hash"
CONF_HASH="$(sha256sum <<<"$FF_COMMIT ${CONFIGURE_ARGS[*]}" | cut -d' ' -f1)"
if [[ -f "$WORK/build/ffbuild/config.mak" && -f "$SENTINEL" && "$(cat "$SENTINEL")" == "$CONF_HASH" ]]; then
  echo "→ configure già fatto (stessi flag), salto (rm -rf zig-out/ffmpeg-trim per rifarlo)"
else
  echo "→ configure (trimmed, shared, -Os)…"
  "$SRC/configure" "${CONFIGURE_ARGS[@]}" >/dev/null
  echo "$CONF_HASH" >"$SENTINEL"
fi

echo "→ make (può richiedere qualche minuto)…"
make -j"$(nproc)" >/dev/null
make install >/dev/null

# ── Copia le DLL trimmed accanto all'exe (stessa interfaccia di fetch-…) ─────
mkdir -p "$DEST"
echo "→ DLL prodotte:"
shopt -s nullglob
total=0
for dll in "$PREFIX"/bin/{avutil,avcodec,avformat,swscale,swresample}-*.dll; do
  "${CROSS}strip" -s "$dll" 2>/dev/null || true
  cp -f "$dll" "$DEST/"
  sz=$(stat -c%s "$dll"); total=$((total+sz))
  awk -v s="$sz" -v n="$(basename "$dll")" 'BEGIN{printf "   %6.2f MB  %s\n", s/1048576, n}'
done
awk -v t="$total" -v d="$DEST" 'BEGIN{printf "✓ FFmpeg trimmed: %.1f MB totali in %s\n", t/1048576, d}'
