#!/usr/bin/env bash
set -e

# Modalità di build. Default: ReleaseSafe (ottimizzato, sicuro, binario piccolo).
#   --fast | -f : build Debug col backend self-hosted di Zig (niente LLVM) →
#                 compila in pochi secondi invece di ~50s, ma i binari sono NON
#                 ottimizzati (più lenti a runtime). Utile per iterare in fretta.
# NB: mold/altri linker esterni NON aiutano — Zig 0.16 linka in-process (LLD o
# self-hosted), non invoca mai un linker di sistema, quindi non c'è nulla da
# accelerare sul link: il tempo è tutto in LLVM (codegen ReleaseSafe).
OPTIMIZE="ReleaseSafe"
for arg in "$@"; do
  case "$arg" in
    --fast|-f) OPTIMIZE="Debug" ;;
  esac
done

echo "Building zuer and zuer-gui in ${OPTIMIZE} mode..."
if [ "$OPTIMIZE" = "Debug" ]; then
  echo "  (build veloce senza LLVM: binari non ottimizzati, per sviluppo)"
fi
zig build -Doptimize="$OPTIMIZE"

# Set target directory
# ~/.local/bin is the standard user-level binary directory.
# If run as root, we install to /usr/local/bin.
INSTALL_DIR="$HOME/.local/bin"
if [ "$EUID" -eq 0 ]; then
  INSTALL_DIR="/usr/local/bin"
fi

# Ensure target directory exists
mkdir -p "$INSTALL_DIR"

# Copy binaries to installation directory
cp zig-out/bin/zuer "$INSTALL_DIR/zuer"
cp zig-out/bin/zuer-gui "$INSTALL_DIR/zuer-gui"

# Copy decoders as shared library plugins
mkdir -p "$INSTALL_DIR/decoders"
cp zig-out/lib/libdecoder_*.so "$INSTALL_DIR/decoders/"

# Determine application directory path
APP_DIR="$HOME/.local/share/applications"
if [ "$EUID" -eq 0 ]; then
  APP_DIR="/usr/share/applications"
fi
mkdir -p "$APP_DIR"

# Create/Overwrite desktop entry for zuer-gui
echo "Creating desktop entry for zuer-gui..."
cat <<EOF > "$APP_DIR/zuer-gui.desktop"
[Desktop Entry]
Type=Application
Name=Zuer GUI
Comment=Visualizzatore universale zuer: immagini, modelli 3D, testo, archivi e media
Exec=$INSTALL_DIR/zuer-gui %f
Icon=utilities-terminal
Terminal=false
Categories=Graphics;Viewer;
MimeType=image/png;image/jpeg;image/gif;image/bmp;image/svg+xml;model/obj;model/gltf-binary;application/zip;text/plain;text/csv;text/markdown;audio/mpeg;audio/flac;audio/ogg;audio/x-wav;video/mp4;video/x-matroska;video/webm;video/x-msvideo;video/quicktime;
EOF

# Clean up previous mime associations to zuer-gui
echo "Cleaning previous associations for zuer-gui..."
python3 - <<'EOF'
import os
mime_files = [
    os.path.expanduser("~/.config/mimeapps.list"),
    os.path.expanduser("~/.local/share/applications/mimeapps.list")
]
for filepath in mime_files:
    if not os.path.exists(filepath):
        continue
    try:
        with open(filepath, "r") as f:
            content = f.read()
        lines = content.splitlines()
        new_lines = []
        for line in lines:
            if "=" in line and not line.startswith("["):
                mime, apps = line.split("=", 1)
                app_list = [a for a in apps.split(";") if a and "zuer-gui" not in a]
                if app_list:
                    new_lines.append(f"{mime}={';'.join(app_list)};")
            else:
                new_lines.append(line)
        with open(filepath, "w") as f:
            f.write("\n".join(new_lines) + "\n")
    except Exception as e:
        print(f"Error cleaning {filepath}: {e}")
EOF

# Set new associations to zuer-gui
echo "Setting new file associations..."
xdg-mime default zuer-gui.desktop image/png image/jpeg image/gif image/bmp image/svg+xml model/obj model/gltf-binary application/zip text/plain text/csv text/markdown

# Update desktop database
echo "Updating desktop database..."
update-desktop-database "$APP_DIR"

# Rebuild KDE sycoca cache if applicable
if command -v kbuildsycoca6 &> /dev/null; then
  echo "Rebuilding KDE sycoca cache..."
  kbuildsycoca6 --noincremental
fi

echo "--------------------------------------------------------"
echo "Success! zuer installed to: $INSTALL_DIR/zuer"
echo "Success! zuer-gui installed to: $INSTALL_DIR/zuer-gui"
echo "--------------------------------------------------------"

# Warn if target directory is not in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo "WARNING: $INSTALL_DIR is not in your PATH."
  echo "You may need to add it to your ~/.bashrc or ~/.zshrc:"
  echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
fi
