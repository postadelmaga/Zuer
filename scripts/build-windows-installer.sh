#!/usr/bin/env bash
# Costruisce l'installer Windows di zuer-gui partendo da Linux:
#   1. cross-compila `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast`
#      in una staging dir pulita (solo exe + DLL, niente .pdb);
#   2. scarica pdfium.dll (PDF) e, salvo --no-ffmpeg, copia accanto all'exe le DLL
#      FFmpeg compilate da scripts/build-ffmpeg.sh (prefisso in ZUER_FFMPEG_DIR);
#   3. genera un'icona .ico (se ImageMagick è presente);
#   4. genera `installer/associations.nsh` con le estensioni note ai decoder
#      effettivamente inclusi nel build Windows (text/csv/markdown/mesh/image/
#      glb/archive/media/office/pdf);
#   5. compila `installer/zuer.nsi` con `makensis` → un unico Zuer-Setup.exe.
#
# Uso:  ZUER_FFMPEG_DIR=<prefisso> scripts/build-windows-installer.sh [--no-ffmpeg] [--out FILE.exe]
#   ZUER_FFMPEG_DIR  prefisso di `scripts/build-ffmpeg.sh windows` (in MSYS2 UCRT64)
#   --no-ffmpeg      installer senza FFmpeg: video e audio non si aprono.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FFMPEG=yes
OUT="$ROOT/Zuer-Setup.exe"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ffmpeg)       FFMPEG=none;    shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "opzione sconosciuta: $1" >&2; exit 2 ;;
  esac
done

command -v makensis >/dev/null || { echo "✗ makensis non trovato (installa NSIS)"; exit 1; }

# Versione completa (anche il suffisso -rc.N): è quella in "App installate".
VERSION="$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' build.zig.zon | head -1)"
[[ -n "$VERSION" ]] || { echo "✗ versione non trovata in build.zig.zon"; exit 1; }
STAGE="$ROOT/zig-out/win-installer"

echo "→ [1/5] build Windows ReleaseFast → $STAGE"
rm -rf "$STAGE"
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast --prefix "$STAGE"
# Solo runtime: via i simboli di debug, restano exe + DLL.
find "$STAGE/bin" -name '*.pdb' -delete
BIN="$STAGE/bin"
[[ -f "$BIN/zuer-gui.exe" ]] || { echo "✗ zuer-gui.exe non prodotto"; exit 1; }
cp "$ROOT/LICENSE" "$BIN/LICENSE.txt" # AGPL-3.0-or-later, installata accanto all'exe
cp "$ROOT/THIRD-PARTY-NOTICES.txt" "$BIN/THIRD-PARTY-NOTICES.txt" # libwebp, nanosvg, TinySoundFont

# makensis lavora nella cartella dello script .nsi: la staging gli arriva come percorso
# RELATIVO a installer/, senza lettere di unità. Sotto Git Bash (runner Windows) il
# percorso assoluto, anche convertito in D:\…, dava "File: … -> no files found".
NSIS_STAGE="$(realpath --relative-to="$ROOT/installer" "$BIN")"
NSIS_SCRIPT="$ROOT/installer/zuer.nsi"
command -v cygpath >/dev/null && NSIS_SCRIPT="$(cygpath -w "$NSIS_SCRIPT")"
NSIS_DEFS=(-DSTAGE="$NSIS_STAGE" -DVERSION="$VERSION" -DOUTFILE="$OUT")

echo "→ [2/5] PDFium (motore PDF)"
"$ROOT/scripts/fetch-pdfium.sh" "$BIN"

case "$FFMPEG" in
  yes)
    FF="${ZUER_FFMPEG_DIR:?ZUER_FFMPEG_DIR: prefisso di scripts/build-ffmpeg.sh windows (oppure --no-ffmpeg)}"
    echo "→ [2/5] FFmpeg da $FF"
    # Solo le librerie che Zuer apre, con i major degli header in vendor/ffmpeg.
    for dll in avformat-63 avcodec-63 avutil-61 swscale-10 swresample-7; do
      [[ -f "$FF/bin/$dll.dll" ]] || { echo "✗ $FF/bin/$dll.dll assente: major diverso dagli header vendorati?"; exit 1; }
      cp "$FF/bin/$dll.dll" "$BIN/"
    done
    cp "$FF/share/zuer/FFmpeg-LICENSE.txt" "$FF/share/zuer/FFmpeg-SOURCE.txt" "$BIN/"
    NSIS_DEFS+=(-DHAVE_FFMPEG=1) ;;
  none)
    echo "→ [2/5] --no-ffmpeg: niente FFmpeg (video e audio non si apriranno)" ;;
esac

echo "→ [3/5] icona"
if command -v magick >/dev/null || command -v convert >/dev/null; then
  IM="$(command -v magick || command -v convert)"
  # "Z" bianca su tondo blu, multi-risoluzione.
  "$IM" -size 256x256 xc:none \
    -fill '#2563eb' -draw 'roundrectangle 8,8 248,248 48,48' \
    -fill white -font "${ZUER_ICON_FONT:-DejaVu-Sans-Bold}" -pointsize 190 -gravity center -annotate +0-6 'Z' \
    -define icon:auto-resize=256,128,64,48,32,16 "$BIN/zuer.ico" 2>/dev/null \
    && NSIS_DEFS+=(-DHAVE_ICON=1) && echo "  ✓ zuer.ico" \
    || echo "  · icona non generata (uso l'icona dell'exe)"
else
  echo "  · ImageMagick assente: uso l'icona dell'exe"
fi

echo "→ [4/5] genero associations.nsh"
# ── Estensioni per decoder incluso nel build Windows ────────────────────────
# Fonte di verità: le stringhe `zuer_extensions` in src/decoders/*.zig. Escluse
# le voci senza estensione reale (gitignore/editorconfig/dockerfile/make…).
EXTS="$(cat <<'LIST'
txt text log nfo rst adoc asciidoc org tex bib srt vtt diff patch
json jsonl ndjson yaml yml toml ini cfg conf properties env plist lock
xml html htm xhtml css scss sass less
sh bash zsh fish ps1 bat cmd mk cmake gradle
rs py pyi js mjs cjs jsx ts tsx c h cc cpp cxx hpp hh cs java kt kts go rb php swift scala lua pl pm r sql dart ex exs erl hrl hs clj cljs vim asm s zig jl nim proto graphql gql
csv tsv
md markdown
obj stl
png jpg jpeg gif bmp tga psd hdr pic pnm pbm pgm ppm svg svgz webp tif tiff ico avif heic heif
glb
zip jar apk cbz epub xpi whl
mp3 wav flac ogg oga ogv opus m4a mp4 m4v mov mkv webm avi mid midi
docx pptx odt odp xlsx xlsm ods
pdf
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
ls -la "$BIN"
[[ -f "$BIN/zuer-gui.exe" ]] || { echo "✗ zuer-gui.exe sparito dalla staging prima di makensis (antivirus?)"; exit 1; }
makensis -V2 "${NSIS_DEFS[@]}" "$NSIS_SCRIPT"

echo
echo "✓ Installer pronto: $OUT ($(du -h "$OUT" | cut -f1))"
