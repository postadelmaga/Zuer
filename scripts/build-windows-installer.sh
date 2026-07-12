#!/usr/bin/env bash
# Costruisce l'installer Windows di zuer-gui partendo da Linux:
#   1. cross-compila `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast`
#      in una staging dir pulita (solo exe + DLL, niente .pdb);
#   2. opzionalmente scarica le DLL runtime FFmpeg (player video) accanto all'exe;
#   3. genera un'icona .ico (se ImageMagick è presente);
#   4. genera `installer/associations.nsh` con le estensioni note ai decoder
#      effettivamente inclusi nel build Windows (text/csv/markdown/mesh/image/
#      glb/archive/media — office/pdf sono Linux-only e quindi non associati);
#   5. compila `installer/zuer.nsi` con `makensis` → un unico Zuer-Setup.exe.
#
# Uso:  scripts/build-windows-installer.sh [--no-ffmpeg] [--out FILE.exe]
#   --no-ffmpeg   installer minuscolo senza le DLL FFmpeg (i video non si aprono
#                 finché l'utente non esegue scripts/fetch-ffmpeg-dlls.sh a mano).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# FFmpeg: full = DLL "gpl-shared" di BtbN (~131 MB, scaricate); trimmed = build
# minimale stile VLC (pochi MB, compilata); none = niente video.
FFMPEG=full
OUT="$ROOT/Zuer-Setup.exe"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ffmpeg)       FFMPEG=none;    shift ;;
    --ffmpeg-trimmed)  FFMPEG=trimmed; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "opzione sconosciuta: $1" >&2; exit 2 ;;
  esac
done

command -v makensis >/dev/null || { echo "✗ makensis non trovato (installa NSIS)"; exit 1; }

VERSION="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
VERSION="${VERSION:-0.1.0}"
STAGE="$ROOT/zig-out/win-installer"

echo "→ [1/5] build Windows ReleaseFast → $STAGE"
rm -rf "$STAGE"
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast --prefix "$STAGE"
# Solo runtime: via i simboli di debug, restano exe + DLL.
find "$STAGE/bin" -name '*.pdb' -delete
BIN="$STAGE/bin"
[[ -f "$BIN/zuer-gui.exe" ]] || { echo "✗ zuer-gui.exe non prodotto"; exit 1; }

NSIS_DEFS=(-DSTAGE="$BIN" -DVERSION="$VERSION" -DOUTFILE="$OUT")

case "$FFMPEG" in
  full)
    echo "→ [2/5] FFmpeg full: scarico le DLL gpl-shared di BtbN (~131 MB)"
    "$ROOT/scripts/fetch-ffmpeg-dlls.sh" "$BIN"
    NSIS_DEFS+=(-DHAVE_FFMPEG=1) ;;
  trimmed)
    echo "→ [2/5] FFmpeg trimmed: compilo un FFmpeg minimale (stile VLC)"
    "$ROOT/scripts/build-ffmpeg-trimmed.sh" "$BIN"
    NSIS_DEFS+=(-DHAVE_FFMPEG=1) ;;
  none)
    echo "→ [2/5] --no-ffmpeg: salto le DLL FFmpeg (i video non si apriranno)" ;;
esac

echo "→ [3/5] icona"
if command -v magick >/dev/null || command -v convert >/dev/null; then
  IM="$(command -v magick || command -v convert)"
  # "Z" bianca su tondo blu, multi-risoluzione.
  "$IM" -size 256x256 xc:none \
    -fill '#2563eb' -draw 'roundrectangle 8,8 248,248 48,48' \
    -fill white -font DejaVu-Sans-Bold -pointsize 190 -gravity center -annotate +0-6 'Z' \
    -define icon:auto-resize=256,128,64,48,32,16 "$BIN/zuer.ico" 2>/dev/null \
    && NSIS_DEFS+=(-DHAVE_ICON=1) && echo "  ✓ zuer.ico" \
    || echo "  · icona non generata (uso l'icona dell'exe)"
else
  echo "  · ImageMagick assente: uso l'icona dell'exe"
fi

echo "→ [4/5] genero associations.nsh"
# ── Estensioni per decoder incluso nel build Windows ────────────────────────
# Fonte di verità: le stringhe `zuer_extensions` in src/decoders/*.zig. Escluse
# le voci senza estensione reale (gitignore/editorconfig/dockerfile/make…) e i
# decoder Linux-only (office: xlsx/docx/…, pdf).
EXTS="$(cat <<'LIST'
txt text log nfo rst adoc asciidoc org tex bib srt vtt diff patch
json jsonl ndjson yaml yml toml ini cfg conf properties env plist lock
xml html htm xhtml css scss sass less
sh bash zsh fish ps1 bat cmd mk cmake gradle
rs py pyi js mjs cjs jsx ts tsx c h cc cpp cxx hpp hh cs java kt kts go rb php swift scala lua pl pm r sql dart ex exs erl hrl hs clj cljs vim asm s zig jl nim proto graphql gql
csv tsv
md markdown
obj stl
png jpg jpeg gif bmp tga psd hdr pic pnm pbm pgm ppm svg svgz webp tif tiff ico avif
glb
zip jar apk cbz epub xpi whl
mp3 wav flac ogg oga ogv opus m4a mp4 m4v mov mkv webm avi mid midi
LIST
)"

NSH="$ROOT/installer/associations.nsh"
{
  echo "; GENERATO da scripts/build-windows-installer.sh — non modificare a mano."
  echo "; Estensioni note ai decoder inclusi nel build Windows."
  echo "!macro RegisterAssociations"
  for e in $EXTS; do
    echo "  WriteRegStr HKCU \"Software\\Classes\\.$e\\OpenWithProgIds\" \"\${PROGID}\" \"\""
    echo "  WriteRegStr HKCU \"Software\\\${APP}\\Capabilities\\FileAssociations\" \".$e\" \"\${PROGID}\""
  done
  echo "!macroend"
  echo "!macro UnregisterAssociations"
  for e in $EXTS; do
    # 1) voce OpenWithProgIds sotto Classes (registrata da noi).
    echo "  DeleteRegValue HKCU \"Software\\Classes\\.$e\\OpenWithProgIds\" \"\${PROGID}\""
    # 2) cache di Explorer per-utente: la copia in FileExts di \"Apri con\"…
    echo "  DeleteRegValue HKCU \"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\.$e\\OpenWithProgids\" \"\${PROGID}\""
    # 3) …e la scelta di default (UserChoice) SE punta a Zuer → torna \"chiedi\".
    echo "  ReadRegStr \$0 HKCU \"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\.$e\\UserChoice\" \"ProgId\""
    echo "  \${If} \$0 == \"\${PROGID}\""
    echo "    DeleteRegKey HKCU \"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\.$e\\UserChoice\""
    echo "  \${EndIf}"
  done
  echo "!macroend"
} > "$NSH"
echo "  ✓ $(echo "$EXTS" | wc -w) estensioni"

echo "→ [5/5] makensis"
makensis -V2 "${NSIS_DEFS[@]}" "$ROOT/installer/zuer.nsi"

echo
echo "✓ Installer pronto: $OUT ($(du -h "$OUT" | cut -f1))"
