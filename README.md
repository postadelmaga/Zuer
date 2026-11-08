# zuer

Un **viewer di file** veloce e GPU-accelerato, scritto in Zig. Apre in un lampo
documenti, tabelle, immagini, mesh 3D e video — sia nel **terminale** (`zuer`) sia
in una **finestra** (`zuer-gui`) — costruito sui framework [zicro](../Zicro) (UI/paint
in stile egui) e [zrame](../Zicro/zrame) (finestra + input cross-platform).

Gira su **Linux** (Wayland), **Windows** x64 (GDI) e **macOS** arm64 (Cocoa); il
rendering 3D passa per Vulkan (MoltenVK su macOS), aperto a runtime e facoltativo; il
video per **libmpv** su Linux (decodifica hardware, piano dmabuf del compositor) e per
libav (FFmpeg) dove mpv manca, con VideoToolbox su macOS e D3D11VA su Windows. Versione
**1.1.2**: cosa cambia in [RELEASE.md](RELEASE.md) (la 1.1.1 in [RELEASE-1.1.1.md](RELEASE-1.1.1.md)); cosa è verificato, cosa no e i limiti noti in [RELEASE-1.1.0.md](RELEASE-1.1.0.md)
(la 1.0.0 in [RELEASE-1.0.0.md](RELEASE-1.0.0.md)). Le prove su macchine fisiche:
[docs/prove-hardware.md](docs/prove-hardware.md).

---

## Formati supportati

| Categoria | Estensioni | Note |
|-----------|-----------|------|
| **Testo / codice / markdown** | `.txt`, sorgenti, `.md`, … | rasterizzazione nativa (stb_truetype), selezione + copia |
| **Tabelle** | `.csv`, `.tsv`, `.xlsx`, `.xls`, `.ods`, `.zip`, `.jar`, `.cbz`, `.epub`, … | griglia con header fisso; workbook multi-foglio con linguette |
| **Immagini** | `.png`, `.jpg`, `.gif`, `.bmp`, `.webp`, `.svg`, `.svgz`, `.ico`, `.tga`, `.psd`, `.hdr`, `.ppm`, `.tif`, `.avif`, `.heic` | in processo ovunque: stb_image, libwebp (anche il primo frame dei WebP animati), nanosvg, ICO in Zig; orientamento EXIF dei JPEG. TIFF/AVIF/HEIC dal codec di sistema (ImageIO su macOS, WIC su Windows: AVIF e HEIC richiedono le estensioni gratuite dello Store) o ImageMagick su Linux |
| **Mesh 3D** | `.obj`, `.stl`, `.glb`, `.gltf`, `.ply`, `.fbx`, `.dae`, `.3ds` | renderer Vulkan (PBR-ish, shadow pass), orbita col mouse |
| **Video** | `.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`, `.ts`, … | libmpv (Linux) o libav, timeline/scrubbing stile YouTube; audio: oscilloscopio |
| **Documenti** | `.pdf` | pagina resa come immagine: poppler (`pdftoppm`) su Linux, CoreGraphics su macOS, PDFium (incluso nell'installer) su Windows |
| **Office** | `.docx`, `.xlsx`, `.xlsm`, `.pptx`, `.odt`, `.ods`, `.odp` | decoder Zig, nessuna dipendenza, tutte le piattaforme; `.doc`/`.xls`/`.ppt` non supportati |

Il formato si riconosce anche **senza estensione o con quella sbagliata**:
`src/detect.zig` legge i byte magici dai primi 8 KB (immagini, PDF, ZIP/tar/gzip,
glb, MP4/MKV/WebM/AVI, MP3/FLAC/Ogg/WAV/MIDI) e carica solo il plugin che serve.
I formati riconosciuti ma senza decoder (ELF, PE, 7z, RAR, SQLite, HEIC, …) e gli
header troncati danno un errore esplicito. Test: `zig build test`.

Aprendo una **cartella** si apre il primo file e si passa agli altri con le frecce
`↑ ↓` (sempre, per ogni tipo di file). `← →` sfogliano le pagine nei PDF, fanno un
seek di ±5 s nei video e altrove cambiano file anche loro; nel testo si scorre con
PagSu/PagGiù o la rotellina.

---

## Requisiti

- **Zig 0.17** (vedi `minimum_zig_version` in `build.zig.zon`)
- **glslc** (shaderc) — compila gli shader GLSL → SPIR-V durante la build
- Il framework **zicro** (con dentro **zrame**, il livello finestra) come repository fratello in `../Zicro`
- **Linux**: loader Vulkan di sistema, FFmpeg (pkg-config), `wayland-client`, EGL/GL,
  GBM (Mesa), PipeWire, harfbuzz;
  a runtime, facoltativi: **libmpv** (`libmpv.so.2`: senza, il video ripiega su
  libav, senza piano dmabuf), `libva` (sonda hwdec), `poppler` (`pdftoppm`) e
  LibreOffice (`soffice`) per pdf/office, ImageMagick per i formati immagine rari,
  `yt-dlp` per i link YouTube

---

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

---

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

### Installer (`.exe`)

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

### Variabili d'ambiente utili

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

---

## Architettura

Due frontend condividono lo stesso stack di decodifica e rendering:

```
 zuer (TUI)  ─┐                        ┌─ decoder.zig ──┬─ decoders/*.zig  (plugin .so/.dll:
 zuer-gui  ──┼─ loader.zig (data plane)┤                │   text, csv, markdown, image, glb,
             │                         └─ (dispatch)    │   mesh, archive, media, pdf, office)
             │
             ├─ rendering GPU:  gpu_renderer.zig (Vulkan) · renderer/vk.zig (binding) · voxel.zig
             ├─ rendering CPU:  text_render.zig · glyph.zig (stb_truetype) · compose.zig
             └─ seam per-OS:    terminal.zig · clipboard.zig · dynlib.zig · (finestra: zrame)
```

Il **GUI** (`gui.zig`) è organizzato in moduli coesi:

- **`compose.zig`** — compositing CPU dei frame (immagini aspect-fit + zoom/pan, testo
  blittato 1:1 con header ancorato, selezione, barra linguette)
- **`layout.zig`** — dal percorso/decodifica al tipo di contenuto (`WinKind`) e da lì
  a zoom e dimensione iniziale della finestra
- **`video.zig`** — player video nativo (apertura container, riproduzione, controlli
  overlay); possiede l'import condizionale di libav
- **`loader.zig`** — piano dati: decodifica su thread worker + staging GPU della geometria
  (memfd zero-copy su Linux, buffer CPU altrove)

I **decoder** sono librerie dinamiche caricate a runtime (`decoder_<fmt>.so`/`.dll`):
aggiungerne uno = un nuovo file in `src/decoders/` più una voce nella lista di `build.zig`.

### Concorrenza

Il lavoro CPU che si parallelizza passa da **uno scheduler condiviso**
(`src/scheduler.zig`) invece che da `Thread.spawn` sparsi:

- **worker pigri e limitati**: nessun thread finché non serve, al massimo
  `ZUER_WORKERS` (default core logici − 1); un worker inattivo per 2 s esce e
  libera stack e cache di malloc;
- **quattro priorità** — `critical`, `interactive` (il file aperto dall'utente),
  `normal` (miniature), `background` (prefetch) — con anti-starvation;
- **`parallelFor`**: il thread chiamante drena gli indici, i worker liberi aiutano e
  cedono il posto tra un indice e l'altro se arriva lavoro più urgente;
- **plugin**: un `.so` non vede lo scheduler dell'host, quindi lo riceve come tabella
  C (`HostServices`) dall'export opzionale `zuer_set_host`. Oggi lo usa `glb` per le
  texture; senza la tabella (Android, host vecchi) il plugin ripiega sui propri thread;
- **cancellazione e shutdown**: un task in coda si toglie con `cancel` (il proprietario
  lo riprende subito), uno in esecuzione vede `cancelRequested()`; allo shutdown i task
  in coda sono cancellati (i fire-and-forget passano dal loro `on_done`), quelli in
  corso finiscono, i worker sono tutti gioinati, anche quelli ritirati;
- **segnale di primo piano**: il loader (thread suo, fuori dal pool) apre e chiude
  `beginForeground`/`endForeground` attorno al decode chiesto dall'utente; i lavori
  lunghi di background lo leggono per ridurre il proprio parallelismo.

I test dello scheduler (`zig build test`) impongono l'ordine delle corse con hook e
lock, non con sleep: shutdown con task in esecuzione/in coda/cancellati, ritiro di un
worker mentre arriva un task, timeout di inattività contemporaneo a un submit, coda
satura con più produttori, crescita e ritiro del pool. Quelli sulle corse corrette
sono stati verificati reintroducendo il bug: falliscono.

### Miniature dell'esploratore

La pipeline sta in `src/thumbs.zig` (senza dipendenze dalla GUI: la usa anche il
benchmark). Aprendo una cartella:

1. la scansione legge solo i nomi (al più 512 voci) e incrementa la **generazione**:
   il lavoro della cartella precedente da lì non installa più nulla;
2. un job (task `normal`) riempie dimensioni e mtime, legge la cache su disco e poi
   decodifica ciò che manca, partendo dalle card visibili;
3. ogni job aggiunge job fratelli fino a `ZUER_THUMB_JOBS` (default **2**, mai oltre i
   worker dello scheduler) se resta lavoro reclamabile; le voci si dividono con un
   claim sotto lock;
4. mentre l'utente apre un file i job in più si ritirano (ne resta uno, che cede
   comunque il worker al lavoro più urgente) e ripartono dopo;
5. i worker non toccano la GUI: installano la miniatura sotto il mutex condiviso, solo
   se la generazione è ancora quella, e chiedono un ridisegno.

Limiti: 96 miniature in RAM (≈24 MB) e 96 decode per cartella; niente miniatura oltre
256 MB; **un solo decode "pesante" alla volta** (PDF, video, formati che passano da
rsvg, codec di sistema o ImageMagick, file oltre 8 MiB: processi esterni
già multi-thread o picchi di RAM da centinaia di MB); cache su disco in `~/.cache/zuer/thumbs` con tetto LRU di
128 MB. Un decode fallito lascia in cache una voce negativa valida 24 ore, così la
cartella non lo ritenta a ogni visita.

Restano **thread dedicati**, di proposito: finestra, render, loader e prefetch (cicli
permanenti con la loro condition), audio/MIDI/video (tempo reale), le operazioni
YouTube e appunti (aspettano processi esterni: nel pool bloccherebbero worker CPU)
e la scrittura della cache mesh (I/O su disco, misurato: in un worker ritardava il
decode in primo piano).

Portabilità: zicro e zrame nascondono le differenze di OS (finestra, input, clipboard,
dynamic loading) dietro API uniformi, così zuer resta in gran parte agnostico rispetto
alla piattaforma. I punti che restano specifici sono isolati in file per-OS
(`terminal.zig`, `clipboard.zig`, `dynlib.zig`) o dietro flag comptime.

---

## Strumenti di sviluppo

```sh
zig build gpu-selftest    # render headless di un cubo per validare la pipeline mesh
zig build raster-debug -- file      # rasterizza un file su PPM (stdout)
zig build decode-test -- file       # decodifica un file e stampa il risultato
zig build bench-decode -- fg bg...  # latenza di un decode con altri decode in sfondo
zig build test                      # test unitari (detector, scheduler, miniature)
zig build player-test -- video      # itera i frame video col motore libav
scripts/bench-thumbnails.sh dir 5 none seq w1 w2 w3 w4   # pipeline miniature headless
```

### Benchmark (riferimento)

Macchina: i5-6200U (2 core fisici, 4 logici), 7,8 GB di RAM, Linux 7.3 (CachyOS),
Zig 0.17.0, build **ReleaseSafe**. Ogni esecuzione è un processo a sé con `HOME`
vuota (cache dei plugin fredde); gli scenari si alternano a ogni round; si riportano
le mediane. CPU = `getrusage` e contatori `perf_event_open` letti dal processo stesso
(`src/perfcount.zig`, solo user space: con `perf_event_paranoid=2` cambi di contesto
del kernel e migrazioni dei thread non sono accessibili). La macchina è rumorosa (lo
stesso scenario varia fino a 4× fra un round e l'altro con altri programmi aperti):
contano i confronti dentro la stessa serie alternata.

Miniature, 70 file reali (PNG, JPEG, WebP, GIF, BMP, SVG, PDF, video), cache fredda,
5 round:

| | seq | 1 job | 2 job | 3 job | 4 job |
|---|---|---|---|---|---|
| tempo | 5,0 s | 4,5 s | **2,1 s** | 2,3 s | 2,3 s |
| CPU | 4,8 s | 4,4 s | 4,1 s | 5,7 s | 5,8 s |
| RSS massima | 447 MB | 445 MB | 489 MB | 498 MB | 517 MB |
| apertura di un JPEG 2048² durante le miniature (da solo: 125 ms) | — | 124 ms | 186 ms | 170 ms | 261 ms |

Le miniature sono identiche (stesso hash) in tutti gli scenari. 16 WebP: 330 ms in
sequenza, 167 ms con 2 job (prima, via ImageMagick: ~4,8 s e 2 file falliti). Su
cartelle di soli file "pesanti" (immagini oltre 8 MiB, PDF) il parallelo non accelera
né rallenta: sono serializzati di proposito. Con la cache calda la cartella si riempie
in 60–85 ms. Default 2 job: oltre non si guadagna tempo, si spende il 40% di CPU in
più e con 4 job l'apertura di un file raddoppia. (La riga dell'apertura file è stata
misurata prima del WebP nativo.)

Decode di un GLB in primo piano con altri 3 in sfondo, 8 round, rispetto alla
versione senza scheduler: apertura **−44%** (644 → 362 ms, migliore in 8 round su 8),
CPU pari alla versione vecchia con 3 worker (cicli +0,0%), −3% con 1 worker
(`perf stat`, 8 round). Lo scheduler non aggiunge istruzioni: a parità di lavoro il
conteggio è identico entro lo 0,005%. Il +2–3% misurato in un primo tempo era
lavoro duplicato della cache mesh coarse: `meshcache.writeCoarse` controllava se il
file esisteva, ma lo scrive su un thread staccato, quindi due decode ravvicinati
dello stesso GLB serializzavano entrambi. Ora un registro delle chiavi in scrittura
lo impedisce: le istruzioni sono −1,3% rispetto alla versione vecchia e identiche
in ogni esecuzione (prima variavano del 2% a seconda dei tempi).

---

## Licenza

Copyright © 2026 Francesco Magazzù. Zuer è distribuito sotto la **GNU Affero General
Public License v3.0 o successiva** (vedi [`LICENSE`](LICENSE)), come il framework
[zicro](../Zicro).

`SPDX-License-Identifier: AGPL-3.0-or-later`

Componenti di terze parti in `vendor/`: stb (pubblico dominio / MIT), TinySoundFont
(MIT), nanosvg (zlib), header e import-lib di FFmpeg (LGPL/GPL secondo la build).
libwebp (BSD-3-Clause) è una dipendenza Zig compilata dal sorgente (`build.zig.zon`).
L'installer Windows include PDFium (BSD-3-Clause e licenze dei componenti, in
`PDFium-LICENSE.txt`, build `bblanchon/pdfium-binaries` fissata in
`scripts/fetch-pdfium.sh`); il FFmpeg del bundle macOS contiene dav1d (BSD-2-Clause). Le DLL FFmpeg
dell'installer Windows hanno la licenza della build scaricata (LGPL); nel bundle
macOS FFmpeg è compilato LGPL dallo stesso commit e MoltenVK è Apache-2.0: licenze e
riferimenti al sorgente in `Zuer.app/Contents/Resources`.
