#!/usr/bin/env bash
# Prova dei formati che la FFmpeg di Zuer (scripts/build-ffmpeg.sh) deve aprire: un
# clip per ogni combinazione contenitore/codec dell'elenco, generato al momento con
# la ffmpeg da riga di comando (solo per creare i file: non è quella provata).
# Ogni clip passa da feature-probe, cioè dallo stesso player libav di zuer-gui:
#   video → 60 frame, pts continui, seek;  audio → orologio di riproduzione che avanza.
# Audio MUTO: le tracce sono silenzio (anullsrc).
#
#   scripts/ffmpeg-check.sh <feature-probe> [cartella-di-lavoro]
#
# Un encoder assente nella ffmpeg che genera i clip salta quel caso con un avviso;
# con FFMPEG_CHECK_STRICT=1 (CI) è un errore.
set -uo pipefail
PROBE="$1"
D="${2:-$(mktemp -d)}"
FF="${FFMPEG_CLI:-ffmpeg}"
# Su Linux VP9 andrebbe al decoder GPU compute (solo Linux): qui si prova FFmpeg.
export ZUER_VP9_LIBAV=1
mkdir -p "$D"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) W() { cygpath -w "$1"; } ;;
  *) W() { printf '%s' "$1"; } ;;
esac
FAIL=0; SKIP=0; N=0
ENC=" $("$FF" -hide_banner -encoders 2>/dev/null | awk 'NR>10{print $2}' | tr '\n' ' ') "

V="-f lavfi -i testsrc2=size=320x240:rate=30 -t 6"
# Vorbis: libvorbis se c'è, altrimenti l'encoder nativo (sperimentale: -strict -2).
pick() { local e; for e; do [[ "$ENC" == *" $e "* ]] && { echo "$e"; return; }; done; echo "$1"; }
VORBIS="$(pick libvorbis vorbis)"
A="-f lavfi -i anullsrc=r=48000:cl=stereo -t 6"

gen() { # file encoder... -- argomenti ffmpeg
  local out="$1"; shift; local e
  while [[ "$1" != -- ]]; do
    if [[ "$ENC" != *" $1 "* ]]; then
      echo "avviso: encoder $1 assente in $FF: salto $(basename "$out")"; SKIP=$((SKIP+1)); return 1
    fi
    shift
  done
  shift
  # shellcheck disable=SC2086
  "$FF" -loglevel error -y "$@" "$(W "$out")" || { echo "FALLITO: generazione di $(basename "$out")"; FAIL=1; return 1; }
}
probe() { # video|audio file
  N=$((N+1))
  local out
  out="$("$PROBE" "$1" "$(W "$2")" 2>&1 | tr -d '\r')"; local rc=$?
  if [[ $rc != 0 ]] || grep -q FALLITO <<<"$out"; then
    echo "FALLITO: $(basename "$2")"; sed 's/^/    /' <<<"$out" | grep -v '^    info' | head -8; FAIL=1
  else
    echo "ok: $(basename "$2") — $(grep -m1 -oE '[0-9]+ frame [0-9]+x[0-9]+|orologio di riproduzione a [0-9.]+s' <<<"$out")"
  fi
}
vid() { local f="$D/$1"; shift; gen "$f" "$@" && probe video "$f"; }
aud() { local f="$D/$1"; shift; gen "$f" "$@" && probe audio "$f"; }

echo "── video"
# shellcheck disable=SC2086
{
vid h264-aac.mp4        libx264 aac -- $V $A -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest
vid hevc-aac.mp4        libx265 aac -- $V $A -c:v libx265 -pix_fmt yuv420p -tag:v hvc1 -c:a aac -shortest -x265-params log-level=error
vid hevc10.mkv          libx265 -- $V -c:v libx265 -pix_fmt yuv420p10le -x265-params log-level=error
vid av1-aac.mp4         libsvtav1 aac -- $V $A -c:v libsvtav1 -preset 12 -c:a aac -shortest
vid av1-opus.webm       libsvtav1 libopus -- $V $A -c:v libsvtav1 -preset 12 -c:a libopus -shortest
vid vp9-opus.webm       libvpx-vp9 libopus -- $V $A -c:v libvpx-vp9 -deadline realtime -c:a libopus -shortest
vid vp8-vorbis.webm     libvpx $VORBIS -- $V $A -c:v libvpx -deadline realtime -c:a $VORBIS -strict -2 -shortest
vid h264-ac3.mkv        libx264 ac3 -- $V $A -c:v libx264 -pix_fmt yuv420p -c:a ac3 -shortest
vid h264-eac3.mkv       libx264 eac3 -- $V $A -c:v libx264 -pix_fmt yuv420p -c:a eac3 -shortest
vid h264-dts.mkv        libx264 dca -- $V $A -c:v libx264 -pix_fmt yuv420p -c:a dca -strict -2 -shortest
vid mpeg2-mp2.mkv       mpeg2video mp2 -- $V $A -c:v mpeg2video -c:a mp2 -shortest
vid mpeg1.mkv           mpeg1video -- $V -c:v mpeg1video
vid h264-alac.mov       libx264 alac -- $V $A -c:v libx264 -pix_fmt yuv420p -c:a alac -shortest
vid mjpeg-pcm.mov       mjpeg pcm_s16le -- $V $A -c:v mjpeg -c:a pcm_s16le -shortest
vid h264.m4v            libx264 -- $V -c:v libx264 -pix_fmt yuv420p -f mp4
vid mpeg4-mp3.avi       mpeg4 libmp3lame -- $V $A -c:v mpeg4 -c:a libmp3lame -shortest
vid divx3-mp3.avi       msmpeg4 libmp3lame -- $V $A -c:v msmpeg4 -c:a libmp3lame -shortest
vid mjpeg-pcm.avi       mjpeg pcm_s16le -- $V $A -c:v mjpeg -c:a pcm_s16le -shortest
# Contenitori e codec "di una volta" e di produzione (Windows Media, Flash, DVD,
# MPEG-TS dei camcorder, 3GP dei telefoni, ProRes, DV, lossless).
vid wmv2-wma.wmv        wmv2 wmav2 -- $V $A -c:v wmv2 -c:a wmav2 -shortest
vid flv1-mp3.flv        flv libmp3lame -- $V $A -c:v flv -c:a libmp3lame -ar 44100 -shortest
vid mpeg2-mp2.mpg       mpeg2video mp2 -- $V $A -c:v mpeg2video -c:a mp2 -shortest -f mpeg
vid mpeg2-ac3.vob       mpeg2video ac3 -- $V $A -c:v mpeg2video -c:a ac3 -shortest -f vob
# MPEG-TS non ha indice: il seek atterra su un fotogramma qualunque e H.264 riparte
# dal keyframe successivo. GOP di 1 s come le registrazioni reali (DVB, camcorder);
# col default di ffmpeg (250) la clip di 6 s ha un solo keyframe e il seek non trova nulla.
vid h264-aac.m2ts       libx264 aac -- $V $A -c:v libx264 -pix_fmt yuv420p -g 30 -c:a aac -shortest -f mpegts
vid h264-aac.3gp        libx264 aac -- $V $A -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest
vid prores-pcm.mov      prores_ks pcm_s24le -- $V $A -c:v prores_ks -c:a pcm_s24le -shortest
vid dv.dv               dvvideo -- -f lavfi -i testsrc2=size=720x576:rate=25 -t 4 -c:v dvvideo -pix_fmt yuv420p -f dv
vid huffyuv.avi         huffyuv -- $V -c:v huffyuv
vid ffv1.mkv            ffv1 -- $V -c:v ffv1
# Theora non ha un encoder nativo (e la ffmpeg di Homebrew non ha libtheora): clip
# fisso nel repository, generato con testsrc2 + anullsrc (tests/media/SOURCES.md).
probe video "$(cd "$(dirname "${BASH_SOURCE[0]}")/../tests/media" && pwd)/theora-vorbis.ogv"
# HLS (ripiego di yt-dlp): playlist e segmenti MPEG-TS, H.264 + AAC.
mkdir -p "$D/hls"
gen "$D/hls/playlist.m3u8" libx264 aac -- $V $A -c:v libx264 -pix_fmt yuv420p -g 30 -c:a aac -shortest \
  -f hls -hls_time 2 -hls_playlist_type vod &&
  probe video "$D/hls/playlist.m3u8"

echo "── audio"
aud mp3.mp3             libmp3lame -- $A -c:a libmp3lame
aud pcm16.wav           pcm_s16le -- $A -c:a pcm_s16le
aud pcm24.wav           pcm_s24le -- $A -c:a pcm_s24le
aud float.wav           pcm_f32le -- $A -c:a pcm_f32le
aud mulaw.wav           pcm_mulaw -- $A -c:a pcm_mulaw -ar 8000 -ac 1
aud ima.wav             adpcm_ima_wav -- $A -c:a adpcm_ima_wav
aud msadpcm.wav         adpcm_ms -- $A -c:a adpcm_ms
aud flac.flac           flac -- $A -c:a flac
aud vorbis.ogg          $VORBIS -- $A -c:a $VORBIS -strict -2
aud flac.oga            flac -- $A -c:a flac -f ogg
aud opus.opus           libopus -- $A -c:a libopus
aud aac.m4a             aac -- $A -c:a aac
aud alac.m4a            alac -- $A -c:a alac
aud adts.aac            aac -- $A -c:a aac -f adts
aud pcm16.aiff          pcm_s16be -- $A -c:a pcm_s16be
aud alac.caf            alac -- $A -c:a alac -f caf
aud pcm16.w64           pcm_s16le -- $A -c:a pcm_s16le -f w64
aud wma.wma             wmav2 -- $A -c:a wmav2
aud ac3.ac3             ac3 -- $A -c:a ac3
aud eac3.eac3           eac3 -- $A -c:a eac3
aud wavpack.wv          wavpack -- $A -c:a wavpack
aud tta.tta             tta -- $A -c:a tta
aud opus.mka            libopus -- $A -c:a libopus -f matroska
}

echo "ffmpeg-check: $N prove, $SKIP saltate"
[[ $N -gt 0 ]] || { echo "ffmpeg-check: nessuna prova eseguita"; FAIL=1; }
if [[ $SKIP -gt 0 && "${FFMPEG_CHECK_STRICT:-0}" == 1 ]]; then echo "ffmpeg-check: casi saltati in modalità stretta"; FAIL=1; fi
[[ $FAIL == 0 ]] && echo "ffmpeg-check: tutto ok" || echo "ffmpeg-check: FALLITO"
exit "$FAIL"
