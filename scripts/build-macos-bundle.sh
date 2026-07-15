#!/usr/bin/env bash
# Impacchetta zuer-gui in un bundle macOS `Zuer.app` partendo dagli artefatti già
# compilati (nessuna build: riusa zig-out). Il bundle registra le associazioni
# file via CFBundleDocumentTypes (ruolo Viewer, LSHandlerRank Alternate: si
# aggiunge ad "Apri con" senza rubare i default, stessa filosofia dell'installer
# Windows) — LaunchServices le indicizza appena l'app viene copiata in
# /Applications (o al primo avvio).
#
# Uso:  scripts/build-macos-bundle.sh [--arch arm64|x86_64] [--build] [--out DIR]
#   --arch   architettura degli artefatti da impacchettare (default: arm64;
#            arm64 → zig-out/bin+lib, x86_64 → zig-out/macos-x64/bin+lib)
#   --build  ricompila prima di impacchettare (di default NO: si riusa zig-out)
#   --out    directory di uscita (default: zig-out/macos)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH=arm64
DO_BUILD=0
OUT="$ROOT/zig-out/macos"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --build) DO_BUILD=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "opzione sconosciuta: $1" >&2; exit 2 ;;
  esac
done

case "$ARCH" in
  arm64)  ZIG_TARGET=aarch64-macos; BIN="$ROOT/zig-out/bin"; LIB="$ROOT/zig-out/lib" ;;
  x86_64) ZIG_TARGET=x86_64-macos; BIN="$ROOT/zig-out/macos-x64/bin"; LIB="$ROOT/zig-out/macos-x64/lib" ;;
  *) echo "arch non supportata: $ARCH (arm64|x86_64)" >&2; exit 2 ;;
esac

if [[ $DO_BUILD -eq 1 ]]; then
  echo "→ build $ZIG_TARGET"
  if [[ "$ARCH" == arm64 ]]; then zig build -Dtarget=$ZIG_TARGET
  else zig build -Dtarget=$ZIG_TARGET --prefix "$ROOT/zig-out/macos-x64"; fi
fi
[[ -f "$BIN/zuer-gui" ]] || { echo "✗ $BIN/zuer-gui assente: compila prima con zig build -Dtarget=$ZIG_TARGET"; exit 1; }

VERSION="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
VERSION="${VERSION:-0.1.0}"

APP="$OUT/Zuer.app"
echo "→ bundle $APP (arch $ARCH, v$VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS/decoders" "$APP/Contents/Resources"

cp "$BIN/zuer-gui" "$APP/Contents/MacOS/"
# I plugin accanto all'exe: il registro li scansiona in <exe_dir>/decoders.
cp "$LIB"/libdecoder_*.dylib "$APP/Contents/MacOS/decoders/"

# Icona .icns (stessa "Z" su tondo blu dell'installer Windows), multi-risoluzione.
# L'ICNS è assemblato a mano da python3 (header 'icns' + chunk PNG tipizzati):
# l'encoder ICNS di ImageMagick non è affidabile — con certi build scrive un PNG
# con estensione .icns senza errore, e macOS non lo mostrerebbe.
HAVE_ICON=0
if command -v magick >/dev/null && command -v python3 >/dev/null; then
  TMPI="$(mktemp -d)"; trap 'rm -rf "$TMPI"' EXIT
  for s in 16 32 128 256 512; do
    magick -size ${s}x${s} xc:none \
      -fill '#2563eb' -draw "roundrectangle $((s/32)),$((s/32)) $((s-1-s/32)),$((s-1-s/32)) $((s*3/16)),$((s*3/16))" \
      -fill white -font DejaVu-Sans-Bold -pointsize $((s*3/4)) -gravity center -annotate +0-$((s/42)) 'Z' \
      "$TMPI/icon_$s.png" 2>/dev/null || break
  done
  if [[ -f "$TMPI/icon_512.png" ]] && python3 - "$TMPI" "$APP/Contents/Resources/zuer.icns" <<'PY'
import struct, sys
tmp, out = sys.argv[1], sys.argv[2]
# Tipi ICNS per PNG embedded: icp4/icp5=16/32, ic07/ic08/ic09=128/256/512.
chunks = []
for size, typ in ((16, b"icp4"), (32, b"icp5"), (128, b"ic07"), (256, b"ic08"), (512, b"ic09")):
    with open(f"{tmp}/icon_{size}.png", "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"icon_{size}.png non è un PNG"
    chunks.append(typ + struct.pack(">I", 8 + len(data)) + data)
body = b"".join(chunks)
with open(out, "wb") as f:
    f.write(b"icns" + struct.pack(">I", 8 + len(body)) + body)
PY
  then HAVE_ICON=1; fi
fi
[[ $HAVE_ICON -eq 1 ]] && echo "  ✓ zuer.icns" || echo "  · icona non generata (serve ImageMagick + python3)"

# Estensioni note ai decoder inclusi nel build macOS. Stessa lista dell'installer
# Windows (fonte di verità: `zuer_extensions` in src/decoders/*.zig), MENO i
# media (mp3/mp4/…): su macOS ffmpeg è spento di default, aprire file che non si
# possono decodificare sarebbe solo rumore in "Apri con".
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
LIST
)"

PLIST="$APP/Contents/Info.plist"
{
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Zuer</string>
	<key>CFBundleDisplayName</key><string>Zuer</string>
	<key>CFBundleIdentifier</key><string>dev.zuer.viewer</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleExecutable</key><string>zuer-gui</string>
PL
  [[ $HAVE_ICON -eq 1 ]] && printf '\t<key>CFBundleIconFile</key><string>zuer</string>\n'
  cat <<PL
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>Documento Zuer</string>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>CFBundleTypeExtensions</key>
			<array>
PL
  for e in $EXTS; do printf '\t\t\t\t<string>%s</string>\n' "$e"; done
  cat <<PL
			</array>
		</dict>
		<dict>
			<key>CFBundleTypeName</key><string>Cartella</string>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array><string>public.folder</string></array>
		</dict>
	</array>
</dict>
</plist>
PL
} > "$PLIST"
printf 'APPL????' > "$APP/Contents/PkgInfo"

N_EXT=$(echo "$EXTS" | wc -w)
echo "  ✓ Info.plist ($N_EXT estensioni in \"Apri con\")"

# Archivio distribuibile (tar preserva permessi/exec; su Mac: doppio click o
# tar -xzf, poi trascinare Zuer.app in /Applications).
TARBALL="$OUT/Zuer-macos-$ARCH.tar.gz"
tar -C "$OUT" -czf "$TARBALL" Zuer.app
echo
echo "✓ Bundle pronto: $APP"
echo "✓ Archivio:      $TARBALL ($(du -h "$TARBALL" | cut -f1))"
echo
echo "Su macOS: copia Zuer.app in /Applications. Le associazioni \"Apri con\""
echo "sono registrate da LaunchServices automaticamente. Il binario ha firma"
echo "ad-hoc (cross-compile): al primo avvio Gatekeeper chiede conferma"
echo "(tasto destro → Apri), oppure: xattr -dr com.apple.quarantine /Applications/Zuer.app"
echo
echo "Scorciatoia globale (manuale, macOS non permette di auto-installarla):"
echo "  Impostazioni di Sistema → Tastiera → Abbreviazioni → App → aggiungi"
echo "  ⌥⌘Z per Zuer (NON ⌘Z: è l'Annulla di sistema)."
