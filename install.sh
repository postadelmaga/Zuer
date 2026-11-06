#!/usr/bin/env bash
set -e

# Modalità di build. Default: ReleaseSafe (ottimizzato, sicuro, binario piccolo).
#   --fast | -f : build Debug col backend self-hosted di Zig (niente LLVM) →
#                 compila in pochi secondi invece di ~50s, ma i binari sono NON
#                 ottimizzati (più lenti a runtime). Utile per iterare in fretta.
# NB: mold/altri linker esterni NON aiutano — Zig 0.16 linka in-process (LLD o
# self-hosted), non invoca mai un linker di sistema, quindi non c'è nulla da
# accelerare sul link: il tempo è tutto in LLVM (codegen ReleaseSafe).
#   --uninstall : rimuove ciò che questo script installa (binari, plugin, voci
#                 di menu, service menu, associazioni e scorciatoia di Zuer).
OPTIMIZE="ReleaseSafe"
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --fast|-f) OPTIMIZE="Debug" ;;
    --uninstall) UNINSTALL=1 ;;
  esac
done

INSTALL_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
if [ "$EUID" -eq 0 ]; then
  INSTALL_DIR="/usr/local/bin"
  APP_DIR="/usr/share/applications"
fi
SVCMENU_DIR="$HOME/.local/share/kio/servicemenus"

# Toglie zuer-gui.desktop da ogni associazione in mimeapps.list (prima di
# registrarne di nuove, e alla disinstallazione).
clean_mime_associations() {
python3 - <<'PYEOF'
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
PYEOF
}

if [ "$UNINSTALL" = 1 ]; then
  echo "Uninstalling zuer from $INSTALL_DIR..."
  rm -f "$INSTALL_DIR/zuer" "$INSTALL_DIR/zuer-gui"
  rm -rf "$INSTALL_DIR/decoders"
  rm -f "$APP_DIR/zuer-gui.desktop" "$SVCMENU_DIR/zuer-quicklook.desktop"
  clean_mime_associations
  if command -v kwriteconfig6 &> /dev/null; then
    kwriteconfig6 --file kglobalshortcutsrc --group services \
      --group zuer-gui.desktop --key browse --delete &> /dev/null || true
  fi
  command -v update-desktop-database &> /dev/null && update-desktop-database "$APP_DIR" || true
  command -v kbuildsycoca6 &> /dev/null && kbuildsycoca6 --noincremental &> /dev/null || true
  echo "zuer rimosso. (Cache e log restano in ~/.cache/zuer, se presenti.)"
  exit 0
fi

echo "Building zuer and zuer-gui in ${OPTIMIZE} mode..."
if [ "$OPTIMIZE" = "Debug" ]; then
  echo "  (build veloce senza LLVM: binari non ottimizzati, per sviluppo)"
fi
zig build -Doptimize="$OPTIMIZE"

# Ensure target directory exists
mkdir -p "$INSTALL_DIR"

# Copy binaries to installation directory
cp zig-out/bin/zuer "$INSTALL_DIR/zuer"
cp zig-out/bin/zuer-gui "$INSTALL_DIR/zuer-gui"

# Copy decoders as shared library plugins
mkdir -p "$INSTALL_DIR/decoders"
cp zig-out/lib/libdecoder_*.so "$INSTALL_DIR/decoders/"

mkdir -p "$APP_DIR"

# Create/Overwrite desktop entry for zuer-gui
echo "Creating desktop entry for zuer-gui..."
# UN solo lanciatore per Zuer. Lo "Sfoglia" (home nel file explorer) è
# un'azione di questo stesso entry, non un secondo .desktop: nel menu delle
# applicazioni compare come voce del tasto destro su "Zuer", non come un'app
# in più accanto.
cat <<EOF > "$APP_DIR/zuer-gui.desktop"
[Desktop Entry]
Type=Application
Name=Zuer
GenericName=Visualizzatore universale
Comment=Immagini, modelli 3D, testo, archivi e media
Exec=$INSTALL_DIR/zuer-gui %f
Icon=utilities-terminal
Terminal=false
StartupWMClass=it.zuer.gui
Categories=Graphics;Viewer;
Actions=browse;
MimeType=image/png;image/jpeg;image/gif;image/bmp;image/svg+xml;model/obj;model/gltf-binary;application/zip;text/plain;text/csv;text/markdown;audio/mpeg;audio/flac;audio/ogg;audio/x-wav;video/mp4;video/x-matroska;video/webm;video/x-msvideo;video/quicktime;

[Desktop Action browse]
Name=Sfoglia la home
Exec=$INSTALL_DIR/zuer-gui $HOME
EOF

# Clean up previous mime associations to zuer-gui
echo "Cleaning previous associations for zuer-gui..."
clean_mime_associations

# Set new associations to zuer-gui
echo "Setting new file associations..."
xdg-mime default zuer-gui.desktop image/png image/jpeg image/gif image/bmp image/svg+xml model/obj model/gltf-binary application/zip text/plain text/csv text/markdown

# Update desktop database
echo "Updating desktop database..."
update-desktop-database "$APP_DIR"

# Lanciatori di un tempo, ora doppioni: "Zuer (Sfoglia)" è diventato l'azione
# `browse` di zuer-gui.desktop; viewer è il visualizzatore Rust sostituito da
# Zuer.
rm -f "$APP_DIR/zuer-browse.desktop" "$APP_DIR/viewer-app.desktop"

# KDE: una sola voce "Anteprima rapida (Quick Look)" nel menu contestuale di
# Dolphin (service menu). Niente doppioni: le vecchie voci ("Apri con Zuer",
# "Anteprima con zuer", "Apri con viewer") vengono rimosse qui sotto — in
# passato erano file separati e si accavallavano tutte nello stesso menu.
mkdir -p "$SVCMENU_DIR"
rm -f "$SVCMENU_DIR/zuer.desktop" \
      "$SVCMENU_DIR/zuer-preview.desktop" \
      "$SVCMENU_DIR/viewer.desktop" \
      "$HOME/.local/share/kservices5/ServiceMenus/zuer-preview.desktop" \
      "$HOME/.local/share/kservices5/ServiceMenus/zuer.desktop" \
      "$HOME/.local/share/kservices5/ServiceMenus/viewer.desktop"
cat <<EOF > "$SVCMENU_DIR/zuer-quicklook.desktop"
[Desktop Entry]
Type=Service
ServiceTypes=KonqPopupMenu/Plugin
X-KDE-ServiceTypes=KonqPopupMenu/Plugin
MimeType=all/allfiles;inode/directory;
Actions=zuerQuickLook;
X-KDE-Priority=TopLevel

[Desktop Action zuerQuickLook]
Name=Anteprima rapida (Quick Look)
Icon=quickview
Exec=$INSTALL_DIR/zuer-gui %f
EOF
chmod +x "$SVCMENU_DIR/zuer-quicklook.desktop" # Dolphin recente esige il bit eseguibile

# …e scorciatoia globale Meta+Z → azione "Sfoglia la home" di zuer-gui.desktop
# (kglobalaccel registra ogni Desktop Action col suo nome come chiave). Solo la
# registrazione nel config: su Plasma 6 diventa attiva al prossimo login
# (kglobalaccel attiva i componenti "services" quando li carica all'avvio).
# NON Ctrl+Z (è l'Annulla di sistema); Meta+Z è libera.
#
# Un solo proprietario per Meta+Z: né `_launch` di zuer-gui.desktop (aprirebbe
# la ricerca YouTube, non la home) né il vecchio zuer-browse.desktop.
if command -v kwriteconfig6 &> /dev/null; then
  echo "Registering global shortcut Meta+Z (KDE)..."
  kwriteconfig6 --file kglobalshortcutsrc --group services \
    --group zuer-gui.desktop --key browse "Meta+Z"
  kwriteconfig6 --file kglobalshortcutsrc --group services \
    --group zuer-gui.desktop --key _launch --delete &> /dev/null || true
  kwriteconfig6 --file kglobalshortcutsrc --group services \
    --group zuer-browse.desktop --key _launch --delete &> /dev/null || true
  # …e a runtime, perché quei componenti sono attivi e il grab sopravvive al
  # file finché non si rifà il login (lista di tasti vuota = nessun tasto).
  if command -v gdbus &> /dev/null; then
    for comp in "zuer-gui.desktop','_launch','Zuer GUI','Zuer GUI" \
                "zuer-browse.desktop','_launch','Zuer (Sfoglia)','Zuer (Sfoglia)"; do
      gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
        --method org.kde.KGlobalAccel.setForeignShortcutKeys \
        "['$comp']" "@a(ai) []" &> /dev/null || true
    done
  fi
fi

# La scorciatoia per il Quick Look si assegna DENTRO Dolphin, non come
# scorciatoia globale. Dolphin espone le voci dei service menu nel suo editor
# (Impostazioni > Configura le scorciatoie, cerca "Quick Look") e le salva in
# ~/.local/share/kxmlgui5/dolphin/dolphinui.rc come
#   <Action name="servicemenu_zuer-quicklook.desktop::zuerQuickLook" shortcut="Meta+Space"/>
#
# Qui NON la si scrive, deliberatamente: quel file lo possiede Dolphin, che lo
# riscrive quando l'utente cambia scorciatoie o barre: un'iniezione fatta
# mentre Dolphin è aperto verrebbe sovrascritta all'uscita, in silenzio.
#
# La via globale (uno script che recuperava la selezione dalla finestra Dolphin
# attiva, su una scorciatoia in kglobalshortcutsrc) è stata RIMOSSA: su Plasma 6
# kglobalaccel vive dentro KWin e attiva i componenti "services" solo quando li
# carica all'avvio, quindi una voce aggiunta a sessione avviata resta
# `isActive=false` — elencata, invocabile via D-Bus e muta al tasto fino al
# logout. La scorciatoia di Dolphin invoca l'azione del service menu
# direttamente, con %f già espanso: niente script, niente appunti, niente focus.
rm -f "$INSTALL_DIR/zuer-quicklook" "$APP_DIR/zuer-quicklook.desktop"
if command -v kwriteconfig6 &> /dev/null; then
  kwriteconfig6 --file kglobalshortcutsrc --group services \
    --group zuer-quicklook.desktop --key _launch --delete &> /dev/null || true
fi
if ! grep -q "servicemenu_zuer-quicklook.desktop::zuerQuickLook" \
     "$HOME/.local/share/kxmlgui5/dolphin/dolphinui.rc" 2> /dev/null; then
  QUICKLOOK_HINT=1
fi

# Rebuild KDE sycoca cache if applicable
if command -v kbuildsycoca6 &> /dev/null; then
  echo "Rebuilding KDE sycoca cache..."
  kbuildsycoca6 --noincremental
fi

echo "--------------------------------------------------------"
echo "Success! zuer installed to: $INSTALL_DIR/zuer"
echo "Success! zuer-gui installed to: $INSTALL_DIR/zuer-gui"
if [ -n "${QUICKLOOK_HINT:-}" ]; then
  echo "--------------------------------------------------------"
  echo "Per il Quick Look da tastiera: in Dolphin, Impostazioni > Configura le"
  echo "scorciatoie, cerca \"Quick Look\" e assegnale il tasto che preferisci."
  echo "(Va impostata lì, non nelle scorciatoie globali: la voce del menu"
  echo "contestuale riceve il file selezionato, una scorciatoia globale no.)"
fi
echo "--------------------------------------------------------"

# Warn if target directory is not in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo "WARNING: $INSTALL_DIR is not in your PATH."
  echo "You may need to add it to your ~/.bashrc or ~/.zshrc:"
  echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
fi
