# Clip di prova

| File | Origine |
|---|---|
| `theora-vorbis.ogv` | generato con `ffmpeg -f lavfi -i testsrc2=size=160x120:rate=30 -f lavfi -i anullsrc=r=48000:cl=stereo -t 6 -c:v libtheora -q:v 1 -c:a libvorbis -q:a 0 -shortest` (audio muto) |

Usato da `scripts/ffmpeg-check.sh`: Theora non ha un encoder nativo in FFmpeg e la
ffmpeg di Homebrew non ha libtheora, quindi il clip non si può generare su ogni runner.
