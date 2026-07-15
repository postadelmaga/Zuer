; Installer NSIS per zuer-gui (Windows). Compilabile da Linux con `makensis`.
; Non invocarlo a mano: `scripts/build-windows-installer.sh` lo compila passando
; STAGE/VERSION/OUTFILE (+ eventuali HAVE_FFMPEG/HAVE_ICON) e generando
; `associations.nsh` con le estensioni note ai decoder effettivamente inclusi.
;
; Installazione PER-UTENTE (nessun admin/UAC): file in %LOCALAPPDATA%\Programs\Zuer,
; chiavi in HKCU. Le associazioni NON rubano il default: aggiungono Zuer alla voce
; "Apri con" (OpenWithProgIds) e lo registrano tra le App predefinite (Capabilities),
; così l'utente può eleggerlo default dal pannello di Windows. Disinstallazione da
; "App e funzionalità" (voce Uninstall in HKCU).

Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!define APP "Zuer"
!define APP_EXE "zuer-gui.exe"
!define PROGID "Zuer.Viewer"
!define PUBLISHER "Zuer"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP}"

!ifndef VERSION
  !define VERSION "0.1.0"
!endif
!ifndef STAGE
  !error "STAGE non definito: passa -DSTAGE=<dir con zuer-gui.exe e le DLL>"
!endif
!ifndef OUTFILE
  !define OUTFILE "Zuer-Setup.exe"
!endif

Name "${APP} ${VERSION}"
OutFile "${OUTFILE}"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\${APP}"
InstallDirRegKey HKCU "Software\${APP}" "InstallDir"
SetCompressor /SOLID lzma
BrandingText "${APP} ${VERSION}"

; ── UI ──────────────────────────────────────────────────────────────────────
!ifdef HAVE_ICON
  !define MUI_ICON   "${STAGE}/zuer.ico"
  !define MUI_UNICON "${STAGE}/zuer.ico"
!endif
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Avvia ${APP}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "Italian"
!insertmacro MUI_LANGUAGE "English"

; Estensioni note → macro RegisterAssociations / UnregisterAssociations.
!include "associations.nsh"

; ── Installazione ───────────────────────────────────────────────────────────
Section "Install"
  SetOutPath "$INSTDIR"

  File "${STAGE}/zuer-gui.exe"
  File "${STAGE}/decoder_*.dll"
!ifdef HAVE_FFMPEG
  ; DLL runtime FFmpeg (player video); versionate → wildcard.
  File "${STAGE}/avformat-*.dll"
  File "${STAGE}/avcodec-*.dll"
  File "${STAGE}/avutil-*.dll"
  File "${STAGE}/swscale-*.dll"
  File "${STAGE}/swresample-*.dll"
!endif
!ifdef HAVE_ICON
  File "${STAGE}/zuer.ico"
!endif

  ; ProgID: come Zuer apre un file (l'exe accetta il path come primo argomento).
  WriteRegStr HKCU "Software\Classes\${PROGID}" "" "Documento Zuer"
!ifdef HAVE_ICON
  WriteRegStr HKCU "Software\Classes\${PROGID}\DefaultIcon" "" "$INSTDIR\zuer.ico"
!else
  WriteRegStr HKCU "Software\Classes\${PROGID}\DefaultIcon" "" "$INSTDIR\${APP_EXE},0"
!endif
  WriteRegStr HKCU "Software\Classes\${PROGID}\shell\open" "FriendlyAppName" "${APP}"
  WriteRegStr HKCU "Software\Classes\${PROGID}\shell\open\command" "" '"$INSTDIR\${APP_EXE}" "%1"'

  ; Capabilities: fa comparire Zuer nel pannello "App predefinite" di Windows.
  WriteRegStr HKCU "Software\${APP}\Capabilities" "ApplicationName" "${APP}"
  WriteRegStr HKCU "Software\${APP}\Capabilities" "ApplicationDescription" "Visualizzatore universale di file (testo, immagini, mesh 3D, video, archivi)."
  WriteRegStr HKCU "Software\RegisteredApplications" "${APP}" "Software\${APP}\Capabilities"
  WriteRegStr HKCU "Software\${APP}" "InstallDir" "$INSTDIR"

  ; Registra tutte le estensioni note (OpenWithProgIds + FileAssociations).
  !insertmacro RegisterAssociations

  ; Notifica alla shell il cambio di associazioni.
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, i 0, i 0)'

  ; Collegamenti nel menu Start.
  CreateDirectory "$SMPROGRAMS\${APP}"
  CreateShortcut  "$SMPROGRAMS\${APP}\${APP}.lnk" "$INSTDIR\${APP_EXE}"
  ; "Sfoglia": apre la home in Zuer (con le frecce si naviga la cartella), con
  ; hotkey GLOBALE Ctrl+Alt+Z via .lnk (Windows attiva le hotkey dei collegamenti
  ; solo in Start Menu/Desktop; Win+Z non è assegnabile a un .lnk e Ctrl+Z è
  ; l'Annulla di sistema — Ctrl+Alt+Z è la scelta sicura).
  CreateShortcut  "$SMPROGRAMS\${APP}\${APP} (Sfoglia).lnk" "$INSTDIR\${APP_EXE}" '"$PROFILE"' "" 0 SW_SHOWNORMAL "CTRL|ALT|Z" "Sfoglia la home con ${APP}"
  CreateShortcut  "$SMPROGRAMS\${APP}\Disinstalla ${APP}.lnk" "$INSTDIR\uninstall.exe"

  ; Uninstaller + voce in "App e funzionalità" (App installate).
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayName"     "${APP}"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayVersion"  "${VERSION}"
  WriteRegStr   HKCU "${UNINST_KEY}" "Publisher"       "${PUBLISHER}"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\${APP_EXE}"
  WriteRegStr   HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr   HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" "$0"
SectionEnd

; ── Disinstallazione ────────────────────────────────────────────────────────
Section "Uninstall"
  ; Associazioni prima dei file.
  !insertmacro UnregisterAssociations
  DeleteRegKey   HKCU "Software\Classes\${PROGID}"
  DeleteRegValue HKCU "Software\RegisteredApplications" "${APP}"
  DeleteRegKey   HKCU "Software\${APP}"
  DeleteRegKey   HKCU "${UNINST_KEY}"

  Delete "$INSTDIR\${APP_EXE}"
  Delete "$INSTDIR\decoder_*.dll"
  Delete "$INSTDIR\avformat-*.dll"
  Delete "$INSTDIR\avcodec-*.dll"
  Delete "$INSTDIR\avutil-*.dll"
  Delete "$INSTDIR\swscale-*.dll"
  Delete "$INSTDIR\swresample-*.dll"
  Delete "$INSTDIR\zuer.ico"
  Delete "$INSTDIR\uninstall.exe"
  RMDir  "$INSTDIR"

  Delete "$SMPROGRAMS\${APP}\${APP}.lnk"
  Delete "$SMPROGRAMS\${APP}\${APP} (Sfoglia).lnk"
  Delete "$SMPROGRAMS\${APP}\Disinstalla ${APP}.lnk"
  RMDir  "$SMPROGRAMS\${APP}"

  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, i 0, i 0)'
SectionEnd
