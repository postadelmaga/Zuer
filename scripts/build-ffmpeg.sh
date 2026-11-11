#!/usr/bin/env bash
# Compila le librerie FFmpeg (LGPL-2.1-or-later, shared) distribuite con Zuer, dal
# sorgente e con SOLO i componenti che Zuer usa. Stesso commit, stessi componenti su
# Windows e macOS; Linux è solo per le prove locali (il pacchetto Linux usa la
# FFmpeg di sistema tramite mpv).
#
#   scripts/build-ffmpeg.sh windows [prefix]   dentro MSYS2 UCRT64 (gcc, make, nasm,
#                                              meson, ninja, git)
#   scripts/build-ffmpeg.sh macos   [prefix]   su un Mac (serve l'SDK per VideoToolbox)
#   scripts/build-ffmpeg.sh linux   [prefix]   prova locale dell'elenco dei componenti
#
# Uscita: <prefix>/bin/*.dll (Windows) o <prefix>/lib/*.{dylib,so*}, più
# <prefix>/share/zuer/FFmpeg-{LICENSE,SOURCE}.txt.
#
# ABI: il commit è quello degli header vendorati in vendor/ffmpeg/include
# (avformat-63, avcodec-63, avutil-61, swscale-10, swresample-7). Disattivare un
# componente non toglie simboli pubblici: zuer-gui e il plugin media, che risolvono
# le funzioni a runtime, funzionano senza modifiche.
#
# Cosa entra, e perché (ogni voce è una cosa che Zuer apre):
#   - file locali delle estensioni del plugin media (src/decoders/media.zig):
#     mp3 wav flac ogg oga ogv opus m4a mp4 m4v mov mkv webm avi;
#   - flussi di yt-dlp (`bv*+ba/b`): DASH = mp4/webm su https; HLS come ripiego;
#   - decodifica hardware: D3D11VA (Windows), VideoToolbox (macOS);
#   - AV1 software: dav1d, compilato qui e collegato staticamente in avcodec.
# Niente encoder, muxer, filtri, dispositivi, programmi: Zuer decodifica soltanto.
# Un formato fuori da questo elenco non si apre: va aggiunto qui, con la sua prova
# (scripts/ffmpeg-check.sh).
set -euo pipefail

PLATFORM="${1:?uso: build-ffmpeg.sh windows|macos|linux [prefix]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${2:-$ROOT/zig-out/ffmpeg-$PLATFORM}"
WORK="${ZUER_FFMPEG_WORK:-$ROOT/zig-out/ffmpeg-$PLATFORM-build}"
SRC="$WORK/src"

FF_COMMIT="5d85b7bfb2b024fd367ae3a938b4ac46a39e3a26" # header in vendor/ffmpeg
DAV1D_TAG="1.5.4"
DAV1D_COMMIT="54706fc6bc0cdecab7e9593974a4039cc038fca7"

# ── Componenti ────────────────────────────────────────────────────────────────
# Contenitori: MP4/MOV/3GP, MKV/WebM, AVI, MPEG-TS/PS (mpg, vob, m2ts), WMV/ASF, FLV,
# DV, e quelli solo audio (MP3, FLAC, WAV/W64, Ogg, AAC, AIFF, CAF, AC-3, DTS, AMR,
# WavPack, Monkey's Audio, Musepack, TTA) più HLS per yt-dlp.
DEMUXERS="mov,matroska,avi,mp3,flac,wav,w64,ogg,aac,hls,mpegts,mpegps,mpegvideo,\
asf,flv,dv,aiff,caf,ac3,eac3,dts,amr,wv,ape,mpc,mpc8,tta"
# Video: i formati moderni (H.264, HEVC, VP8/9, AV1) e quelli che si trovano nei
# vecchi mp4/avi/mov/ogv/wmv/flv (MPEG-4 Part 2 e DivX, MPEG-1/2, Theora, MJPEG,
# WMV 1-3/VC-1, Sorenson/H.263, VP6, Cinepak, Indeo, SVQ) e i formati di
# produzione (ProRes, DNxHD, DV, HuffYUV, FFV1).
# `av1` è il decoder che usa l'hardware; `libdav1d` quello software.
DECODERS_VIDEO="h264,hevc,vp8,vp9,av1,libdav1d,mpeg4,msmpeg4v1,msmpeg4v2,msmpeg4v3,\
mpeg1video,mpeg2video,theora,mjpeg,wmv1,wmv2,wmv3,vc1,flv,h263,vp6,vp6f,vp6a,\
svq1,svq3,cinepak,indeo3,indeo5,prores,dnxhd,dvvideo,huffyuv,ffv1"
# Audio: quelli dei contenitori sopra (AAC, AC-3/E-AC-3/DTS/TrueHD dei film, MP3/MP2,
# FLAC, Vorbis, Opus, ALAC, WMA, AMR, WavPack, APE, Musepack, TTA, QDesign) e i
# PCM/ADPCM di wav/aiff/caf/mov.
DECODERS_AUDIO="aac,ac3,eac3,dca,truehd,mlp,mp2,mp3,mp3float,flac,vorbis,opus,alac,\
wmav1,wmav2,wmapro,wmalossless,amrnb,amrwb,wavpack,ape,tta,mpc7,mpc8,qdm2,gsm,gsm_ms,\
pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,\
pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_mulaw,pcm_alaw,\
adpcm_ima_wav,adpcm_ima_qt,adpcm_ms"
PARSERS="h264,hevc,mpeg4video,mpegvideo,vp8,vp9,av1,aac,ac3,dca,flac,mpegaudio,opus,\
vorbis,mjpeg,vc1,h263,mlp,dvaudio,amr"
PROTOCOLS="file,http,https,tcp,tls,crypto"

COMMON=(
  --prefix="$PREFIX"
  --enable-shared --disable-static
  --disable-programs --disable-doc --disable-debug
  --disable-autodetect --disable-everything
  --disable-avdevice --disable-avfilter
  --enable-swscale --enable-swresample --enable-network
  --enable-demuxer="$DEMUXERS"
  --enable-decoder="$DECODERS_VIDEO,$DECODERS_AUDIO"
  --enable-parser="$PARSERS"
  --enable-protocol="$PROTOCOLS"
  --enable-libdav1d --pkg-config-flags=--static
)
case "$PLATFORM" in
  windows)
    [[ "${MSYSTEM:-}" == UCRT64 ]] || { echo "✗ da eseguire in MSYS2 UCRT64 (stessa CRT di zuer-gui)"; exit 1; }
    NCPU="$(nproc)"
    PLAT=(
      --arch=x86_64 --target-os=mingw32
      # Decodifica hardware e TLS di sistema (Schannel): nessuna DLL in più.
      --enable-d3d11va --enable-schannel
      --enable-hwaccel=h264_d3d11va,h264_d3d11va2,hevc_d3d11va,hevc_d3d11va2,vp9_d3d11va,vp9_d3d11va2,av1_d3d11va,av1_d3d11va2
      # Thread nativi di Windows. clock_gettime e nanosleep di mingw-w64 stanno però
      # in libwinpthread: collegata statica (in coda, dopo gli oggetti), come libgcc,
      # così accanto alle DLL di FFmpeg non serve nessuna DLL di runtime di gcc.
      --disable-pthreads --enable-w32threads
      --extra-ldflags=-static-libgcc
      "--extra-libs=-Wl,-Bstatic -lwinpthread -Wl,-Bdynamic"
    ) ;;
  macos)
    [[ "$(uname -s)" == Darwin ]] || { echo "✗ da eseguire su macOS (serve l'SDK per VideoToolbox)"; exit 1; }
    NCPU="$(sysctl -n hw.ncpu)"
    # Architettura della macchina che compila: arm64 su Apple Silicon, x86_64 su un
    # Mac Intel. Niente cross-compilazione: ogni pacchetto si compila e si prova sul
    # suo hardware (release.yml usa un runner per architettura).
    MAC_ARCH="$(uname -m)"
    case "$MAC_ARCH" in
      arm64) ;;
      # L'assembly x86 di FFmpeg e dav1d (SIMD, essenziale per AV1 in software) si
      # assembla con nasm: senza, dav1d non si configura.
      x86_64) command -v nasm >/dev/null || { echo "✗ su Intel serve nasm (brew install nasm)"; exit 1; } ;;
      *) echo "✗ architettura macOS non supportata: $MAC_ARCH"; exit 2 ;;
    esac
    PLAT=(
      --arch="$MAC_ARCH" --cc=clang
      --enable-videotoolbox --enable-securetransport --enable-zlib
      --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,vp9_videotoolbox,av1_videotoolbox
      # Install name `@rpath/…` più LC_RPATH `@loader_path`: le dylib si trovano fra
      # loro dentro Zuer.app/Contents/Frameworks, senza percorsi assoluti.
      --install-name-dir=@rpath --extra-ldflags=-Wl,-rpath,@loader_path
    ) ;;
  linux)
    NCPU="$(nproc)"
    PLAT=(--enable-openssl) ;;
  *) echo "✗ piattaforma sconosciuta: $PLATFORM"; exit 2 ;;
esac
CONFIGURE_ARGS=("${COMMON[@]}" "${PLAT[@]}")

# ── Riuso: stesso commit e stessa configurazione → niente da rifare ──────────
STAMP="$PREFIX/share/zuer/.build-hash"
HASH="$( (echo "$FF_COMMIT $DAV1D_COMMIT ${CONFIGURE_ARGS[*]}") | sha256sum 2>/dev/null || (echo "$FF_COMMIT $DAV1D_COMMIT ${CONFIGURE_ARGS[*]}") | shasum -a 256)"
HASH="${HASH%% *}"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" ]]; then
  echo "→ FFmpeg $PLATFORM già compilato con questa configurazione ($PREFIX): riuso"
  exit 0
fi

fetch() { # url commit dir
  if [[ ! -d "$3/.git" || "$(git -C "$3" rev-parse HEAD 2>/dev/null)" != "$2" ]]; then
    rm -rf "$3"; mkdir -p "$3"; git -C "$3" init -q
    git -C "$3" remote add origin "$1"
    git -C "$3" fetch -q --depth 1 origin "$2"
    git -C "$3" checkout -q FETCH_HEAD
  fi
  [[ "$(git -C "$3" rev-parse HEAD)" == "$2" ]] || { echo "✗ $1 non al commit $2"; exit 1; }
}

echo "→ FFmpeg @ $FF_COMMIT"
fetch https://github.com/FFmpeg/FFmpeg.git "$FF_COMMIT" "$SRC"

# dav1d statico (meson + ninja), installato in un prefisso di lavoro solo per il link.
DAV1D_SRC="$WORK/dav1d"; DAV1D_PREFIX="$WORK/dav1d-prefix"
command -v meson >/dev/null && command -v ninja >/dev/null || { echo "✗ servono meson e ninja"; exit 1; }
if [[ ! -f "$DAV1D_PREFIX/lib/libdav1d.a" ]]; then
  echo "→ dav1d $DAV1D_TAG @ $DAV1D_COMMIT"
  fetch https://code.videolan.org/videolan/dav1d.git "$DAV1D_COMMIT" "$DAV1D_SRC"
  rm -rf "$WORK/dav1d-build" "$DAV1D_PREFIX"
  meson setup "$WORK/dav1d-build" "$DAV1D_SRC" --prefix="$DAV1D_PREFIX" --libdir=lib \
    --buildtype=release --default-library=static -Denable_tools=false -Denable_tests=false >/dev/null
  ninja -C "$WORK/dav1d-build" install >/dev/null
fi
export PKG_CONFIG_PATH="$DAV1D_PREFIX/lib/pkgconfig"

rm -rf "$WORK/build" "$PREFIX"; mkdir -p "$WORK/build"; cd "$WORK/build"
echo "→ configure"
"$SRC/configure" "${CONFIGURE_ARGS[@]}" > configure.log 2>&1 || { tail -30 configure.log; tail -40 ffbuild/config.log 2>/dev/null; exit 1; }
grep -q 'License: LGPL version 2.1 or later' configure.log || { echo "✗ licenza inattesa"; grep -i license configure.log; exit 1; }
# Un nome sbagliato nell'elenco passa in silenzio come avviso: qui è un errore.
if grep -i 'did not match anything' configure.log; then echo "✗ componente sconosciuto"; exit 1; fi
# Ogni componente chiesto deve risultare attivo (una dipendenza mancante, es. TLS,
# lo spegnerebbe senza errori).
active() { # tipo elenco
  local n
  for n in ${2//,/ }; do
    grep -q "^#define CONFIG_$(tr a-z A-Z <<<"${n}_$1") 1" config_components.h \
      || { echo "✗ $1 $n non attivo dopo configure"; exit 1; }
  done
}
active demuxer "$DEMUXERS"; active decoder "$DECODERS_VIDEO,$DECODERS_AUDIO"
active parser "$PARSERS"; active protocol "$PROTOCOLS"
[[ "$PLATFORM" == windows ]] && active hwaccel h264_d3d11va,hevc_d3d11va,vp9_d3d11va,av1_d3d11va
[[ "$PLATFORM" == macos ]] && active hwaccel h264_videotoolbox,hevc_videotoolbox
true
NCPU="${ZUER_FFMPEG_JOBS:-$NCPU}"
echo "→ make -j$NCPU"
make -j"$NCPU" >/dev/null
make install >/dev/null

mkdir -p "$PREFIX/share/zuer"
{
  cat "$SRC/LICENSE.md" "$SRC/COPYING.LGPLv2.1"
  echo; echo "================================================================================"
  echo "dav1d $DAV1D_TAG (collegato staticamente in libavcodec) — BSD-2-Clause"
  echo "================================================================================"
  cat "$DAV1D_SRC/COPYING"
} > "$PREFIX/share/zuer/FFmpeg-LICENSE.txt"
cat > "$PREFIX/share/zuer/FFmpeg-SOURCE.txt" <<TXT
FFmpeg — librerie distribuite con Zuer ($PLATFORM), LGPL-2.1-or-later

Sorgente:  https://github.com/FFmpeg/FFmpeg/tree/$FF_COMMIT
Commit:    $FF_COMMIT
Configure: ${CONFIGURE_ARGS[*]}
dav1d:     $DAV1D_TAG, https://code.videolan.org/videolan/dav1d commit $DAV1D_COMMIT (BSD-2-Clause, statico)
Script:    scripts/build-ffmpeg.sh (repository di Zuer)

Le librerie sono file separati, caricati a runtime: si possono sostituire con una
build propria della stessa ABI.
TXT
echo "$HASH" > "$STAMP"
case "$PLATFORM" in
  windows) strip -s "$PREFIX"/bin/*.dll; ls -l "$PREFIX"/bin/*.dll ;;
  *) ls -lL "$PREFIX"/lib/*.{dylib,so} 2>/dev/null || true ;;
esac
echo "✓ FFmpeg $PLATFORM in $PREFIX"
