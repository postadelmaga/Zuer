# Compilare e sviluppare Zuer

Requisiti, build per ogni sistema, installer, variabili d'ambiente e strumenti di sviluppo. Come funziona dentro: [architettura.md](architettura.md).

## Requisiti

- **Zig 0.17** (vedi `minimum_zig_version` in `build.zig.zon`)
- **glslc** (shaderc) — compila gli shader GLSL → SPIR-V durante la build
- Il framework **zicro** (con dentro **zrame**, il livello finestra) come repository fratello in `../Zicro`
- **Linux**: loader Vulkan di sistema, FFmpeg (pkg-config), `wayland-client`, EGL/GL,
  GBM (Mesa), PipeWire, harfbuzz;
  a runtime, facoltativi: **libmpv** (`libmpv.so.2`: senza, il video ripiega su
  libav, senza piano dmabuf), `libva` (sonda hwdec), `poppler` (`pdftoppm`) e
  LibreOffice (`soffice`) per pdf/office, ImageMagick per i formati immagine rari,
  `yt-dlp` per i link YouTube, `lp` (CUPS) per la stampa

## Build & installazione (Linux)

```sh
zig build -Doptimize=ReleaseFast   # zig-out/bin/{zuer, zuer-gui} + plugin in zig-out/lib
./install.sh              # installa in ~/.local/bin + associazioni file (ReleaseSafe)
./install.sh --fast       # build Debug senza LLVM: compila in pochi secondi (sviluppo)
./install.sh --uninstall  # rimuove binari, plugin, voci di menu e associazioni
zuer --version            # (anche zuer-gui --version)
```

`install.sh` rende Zuer l'applicazione **predefinita** per immagini, testo, csv,
markdown, obj/glb e zip (`xdg-mime default`) e su KDE registra Meta+Z e la voce
"Anteprima rapida" di Dolphin. I plugin si cercano solo accanto all'eseguibile
(`<exe>/decoders`, `<exe>`, `<exe>/../lib`), mai nella cartella corrente.

Uso:

```sh
zuer file.csv             # viewer nel terminale (kitty graphics o fallback half-block)
zuer-gui immagine.png     # viewer a finestra
zuer-gui ~/cartella/       # naviga i file della cartella con le frecce
```

## Windows (cross-compile da Linux)

`zuer-gui.exe` gira su Windows — provato in CI su Windows Server 2022 (installer,
office, video, 3D con lavapipe, senza loader Vulkan) e sotto Wine. Il rendering GPU
passa per il loader Vulkan di sistema (`vulkan-1.dll`, aperto a runtime: senza
loader o driver si spegne solo il 3D), il testo/immagini per il compositing CPU. La finestra è **frameless con vetro**, come su
Wayland: pannello arrotondato, ombra decorativa e traslucenza sono dipinti
client-side (stesso `drawChrome` di zicro) e spinti con alpha per-pixel via
`UpdateLayeredWindow` — quindi si vedono **anche sotto Wine**. L'unico pezzo
riservato a Windows vero è il **blur sfocato dietro** il vetro (l'acrilico DWM,
esattamente come su Linux il blur richiede KWin).

```sh
# zuer-gui.exe + i plugin decoder come .dll — SEMPRE in ReleaseFast (vedi sotto)
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast

# DLL di FFmpeg (video e audio), compilate dal sorgente in MSYS2 UCRT64 — NON in git
scripts/build-ffmpeg.sh windows       # → zig-out/ffmpeg-windows/bin/
```

## Installer (`.exe`)

Un unico setup Windows con NSIS (`makensis`):

```sh
ZUER_FFMPEG_DIR=zig-out/ffmpeg-windows scripts/build-windows-installer.sh  # → Zuer-Setup.exe
scripts/build-windows-installer.sh --no-ffmpeg                            # senza video né audio
```

FFmpeg è compilata da `scripts/build-ffmpeg.sh` (stesso script per Windows e macOS)
con `--disable-everything` più **solo** i demuxer, decoder, parser e protocolli che
Zuer usa (elenco commentato nello script), D3D11VA/VideoToolbox e dav1d statico:
niente encoder, muxer, filtri o dispositivi. Stesso commit degli header in
`vendor/ffmpeg` (avformat 63), quindi stessa ABI. `scripts/ffmpeg-check.sh` prova
ogni formato dell'elenco col player di Zuer.

> `mingw-w64` (e opzionalmente `nasm` per le SIMD x86) servono **solo qui, sul
> PC che costruisce l'installer**, per compilare le DLL una volta. **L'utente
> finale non installa nulla**: dentro `Zuer-Setup.exe` le DLL sono già compilate
> e pronte — un singolo `.exe` autosufficiente, come qualsiasi setup Windows.

Lo script cross-compila in ReleaseFast, impacchetta `zuer-gui.exe` + i decoder
`.dll` (+ opzionalmente le DLL FFmpeg), genera un'icona e produce un installer
**per-utente** (nessun admin/UAC): copia in `%LOCALAPPDATA%\Programs\Zuer`,
aggiunge un collegamento nel menu Start e una voce in **App e funzionalità** per
la disinstallazione. Registra le **associazioni** per tutte le estensioni note ai
decoder inclusi (testo/codice, csv, markdown, mesh, immagini, glb, archivi,
media): Zuer compare in "Apri con" e tra le **App predefinite** di Windows —
senza rubare i default esistenti (l'utente lo elegge default dal pannello). Le
estensioni sono rigenerate a ogni build da `src/decoders/*.zig`, quindi restano
in sync (office e PDF inclusi: il PDF usa `pdfium.dll`, installata accanto all'app).

> **Compila sempre con `-Doptimize=ReleaseFast`.** Il default di `zig build` è Debug:
> il rendering GPU resta veloce (lo fa la GPU) ma il **compositing CPU** dei frame
> gira non ottimizzato ed è 3–4× più lento — il 3D diventa scattoso.

## Variabili d'ambiente utili

| Var | Effetto |
|-----|---------|
| `ZUER_GPU=<indice\|nome>` | forza la GPU (es. `ZUER_GPU=intel` o `ZUER_GPU=0`); zuer logga i device che vede. Off-Linux preferisce l'**integrata** (readback economico) |
| `ZUER_WORKERS=<n>` | numero massimo di worker dello scheduler condiviso (default: core logici − 1) |
| `ZUER_THUMB_JOBS=<n>` | job paralleli delle miniature per cartella (default 2, mai oltre `ZUER_WORKERS`) |
| `ZUER_TRACE=1` | diagnostica su stderr: avvio del motore video, contesto GL, ricomposizioni e costo dell'overlay al secondo, riga "fine sessione" (frame, persi, pacing, A/V) |
| `ZUER_MPV_OPTS=k=v,…` | opzioni passate a mpv (es. `hwdec=no`, `ao=null` per i test muti) |
| `ZUER_VIDEO_PLANE=0` | niente piano dmabuf: frame letti dalla GPU e composti in CPU |
| `ZUER_NO_MPV=1` | video col solo decoder libav |
| `ZUER_NO_CRASH_REPORT=1` | disattiva il report dei crash (vedi RELEASE-1.0.0.md) |
| `ZUER_CRASH_NO_BROWSER=1` | report solo verso `ZUER_CRASH_URL`, mai il browser |
| `ZUER_OPAQUE=1` | finestra **opaca** (BitBlt veloce) invece del vetro layered: utile per testare 3D/video fluidi **sotto Wine**, dove senza DWM il vetro va composto in software. Su Windows vero il DWM compone il vetro in GPU, quindi non serve |

Due capacità native, ognuna con la sua import-lib, attivabili a parte:

| Flag | Default | Cosa abilita |
|------|---------|--------------|
| `-Dvulkan` | Linux + Windows + macOS | renderer mesh/testo. Il loader (`libvulkan.so.1` / `vulkan-1.dll` / MoltenVK nel bundle macOS) si apre a runtime: senza loader o driver Zuer parte e spegne solo il 3D |
| `-Dffmpeg` | Linux + Windows + macOS | player video libav, risolto a runtime. Su Windows e macOS usa gli header in `vendor/ffmpeg/`; DLL Windows e dylib macOS si compilano con `scripts/build-ffmpeg.sh` |

> Le DLL FFmpeg (~130 MB) seguono il modello VLC: **spediscono con l'app, non con il
> sorgente**. In git stanno solo header e import-lib (~2.3 MB) per compilare.

Ancora solo su Linux: la **TUI** (`zuer`, il present GPU nel terminale usa un memfd
cross-process del protocollo kitty) e i decoder **pdf/office** (tool esterni).

## Strumenti di sviluppo

```sh
zig build gpu-selftest    # render headless di un cubo per validare la pipeline mesh
zig build raster-debug -- file      # rasterizza un file su PPM (stdout)
zig build decode-test -- file       # decodifica un file e stampa il risultato
zig build print-debug -- file out.pdf    # il PDF che Ctrl+P manderebbe in stampa (immagini: zig-out/bin/print-debug)
zig build bench-decode -- fg bg...  # latenza di un decode con altri decode in sfondo
zig build test                      # test unitari (detector, scheduler, miniature)
zig build player-test -- video      # itera i frame video col motore libav
scripts/bench-thumbnails.sh dir 5 none seq w1 w2 w3 w4   # pipeline miniature headless
```

## Componenti di terze parti

Componenti di terze parti in `vendor/`: stb (pubblico dominio / MIT), TinySoundFont
(MIT), nanosvg (zlib), header e import-lib di FFmpeg (LGPL/GPL secondo la build).
libwebp (BSD-3-Clause) è una dipendenza Zig compilata dal sorgente (`build.zig.zon`).
L'installer Windows include PDFium (BSD-3-Clause e licenze dei componenti, in
`PDFium-LICENSE.txt`, build `bblanchon/pdfium-binaries` fissata in
`scripts/fetch-pdfium.sh`); il FFmpeg del bundle macOS contiene dav1d (BSD-2-Clause). Le DLL FFmpeg
dell'installer Windows hanno la licenza della build scaricata (LGPL); nel bundle
macOS FFmpeg è compilato LGPL dallo stesso commit e MoltenVK è Apache-2.0: licenze e
riferimenti al sorgente in `Zuer.app/Contents/Resources`.
