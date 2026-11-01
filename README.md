# zuer

Un **viewer di file** veloce e GPU-accelerato, scritto in Zig. Apre in un lampo
documenti, tabelle, immagini, mesh 3D e video — sia nel **terminale** (`zuer`) sia
in una **finestra** (`zuer-gui`) — costruito sui framework [zicro](../Zicro) (UI/paint
in stile egui) e [zrame](../Zrame) (finestra + input cross-platform).

Gira su **Linux** (Wayland) e **Windows** (GDI); il rendering 3D passa per Vulkan e
la decodifica video per libav (FFmpeg).

---

## Formati supportati

| Categoria | Estensioni | Note |
|-----------|-----------|------|
| **Testo / codice / markdown** | `.txt`, sorgenti, `.md`, … | rasterizzazione nativa (stb_truetype), selezione + copia |
| **Tabelle** | `.csv`, `.tsv`, `.xlsx`, `.xls`, `.ods`, `.zip`, `.jar`, `.cbz`, `.epub`, … | griglia con header fisso; workbook multi-foglio con linguette |
| **Immagini** | `.png`, `.jpg`, `.gif`, `.bmp`, `.webp`, `.tif`, `.avif`, `.heic`, `.ico` | decodifica nativa (stb_image) |
| **Mesh 3D** | `.obj`, `.stl`, `.glb`, `.gltf`, `.ply`, `.fbx`, `.dae`, `.3ds` | renderer Vulkan (PBR-ish, shadow pass), orbita col mouse |
| **Video** | `.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`, … | player libav con timeline/scrubbing stile YouTube |
| **Documenti** | `.pdf`, office | reso come immagine di pagina (via `pdftoppm`/`soffice`, solo Linux) |

Il formato si riconosce anche **senza estensione o con quella sbagliata**:
`src/detect.zig` legge i byte magici dai primi 8 KB (immagini, PDF, ZIP/tar/gzip,
glb, MP4/MKV/WebM/AVI, MP3/FLAC/Ogg/WAV/MIDI) e carica solo il plugin che serve.
I formati riconosciuti ma senza decoder (ELF, PE, 7z, RAR, SQLite, HEIC, …) e gli
header troncati danno un errore esplicito. Test: `zig build test`.

Aprendo una **cartella** si apre il primo file e si naviga tra gli altri con le
frecce `← →`.

---

## Requisiti

- **Zig 0.17** (vedi `minimum_zig_version` in `build.zig.zon`)
- **glslc** (shaderc) — compila gli shader GLSL → SPIR-V durante la build
- I framework **zicro** e **zrame** come repository fratelli in `../Zicro` e `../Zrame`
- **Linux**: loader Vulkan di sistema, FFmpeg (pkg-config), `wayland-client`;
  opzionali per pdf/office: `poppler` (`pdftoppm`) e LibreOffice (`soffice`)

---

## Build & installazione (Linux)

```sh
zig build                 # produce zig-out/bin/{zuer, zuer-gui} + i plugin decoder
./install.sh              # installa in ~/.local/bin + associazioni file (ReleaseSafe)
./install.sh --fast       # build Debug senza LLVM: compila in pochi secondi (sviluppo)
```

Uso:

```sh
zuer file.csv             # viewer nel terminale (kitty graphics o fallback half-block)
zuer-gui immagine.png     # viewer a finestra
zuer-gui ~/cartella/       # naviga i file della cartella con le frecce
```

---

## Windows (cross-compile da Linux)

`zuer-gui.exe` gira su Windows — verificato sotto Wine, mesh 3D e video inclusi.
Il rendering GPU passa per il loader Vulkan di sistema (o `winevulkan`), il testo/
immagini per il compositing CPU. La finestra è **frameless con vetro**, come su
Wayland: pannello arrotondato, ombra decorativa e traslucenza sono dipinti
client-side (stesso `drawChrome` di zicro) e spinti con alpha per-pixel via
`UpdateLayeredWindow` — quindi si vedono **anche sotto Wine**. L'unico pezzo
riservato a Windows vero è il **blur sfocato dietro** il vetro (l'acrilico DWM,
esattamente come su Linux il blur richiede KWin).

```sh
# zuer-gui.exe + i plugin decoder come .dll — SEMPRE in ReleaseFast (vedi sotto)
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast

# DLL runtime di FFmpeg (per il video) accanto all'eseguibile — NON sono in git
scripts/fetch-ffmpeg-dlls.sh          # → zig-out/bin/
```

### Installer (`.exe`)

Un unico setup Windows, compilabile **da Linux** con NSIS (`makensis`):

```sh
scripts/build-windows-installer.sh                  # → Zuer-Setup.exe (FFmpeg full BtbN, ~38 MB)
scripts/build-windows-installer.sh --ffmpeg-trimmed # FFmpeg minimale stile VLC (installer ~pochi MB)
scripts/build-windows-installer.sh --no-ffmpeg      # installer minuscolo, senza video
```

`--ffmpeg-trimmed` compila (`scripts/build-ffmpeg-trimmed.sh`) un FFmpeg
`--disable-everything` con solo i demuxer/decoder che servono a zuer: le DLL
passano da ~131 MB a pochi MB. Compila lo **stesso commit** delle import-lib
vendored (avformat 63) → header e `vendor/ffmpeg/lib` restano validi as-is.

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
in sync (office/pdf sono Linux-only → non associati su Windows).

> **Compila sempre con `-Doptimize=ReleaseFast`.** Il default di `zig build` è Debug:
> il rendering GPU resta veloce (lo fa la GPU) ma il **compositing CPU** dei frame
> gira non ottimizzato ed è 3–4× più lento — il 3D diventa scattoso.

### Variabili d'ambiente utili

| Var | Effetto |
|-----|---------|
| `ZUER_GPU=<indice\|nome>` | forza la GPU (es. `ZUER_GPU=intel` o `ZUER_GPU=0`); zuer logga i device che vede. Off-Linux preferisce l'**integrata** (readback economico) |
| `ZUER_WORKERS=<n>` | numero massimo di worker dello scheduler condiviso (default: core logici − 1) |
| `ZUER_THUMB_JOBS=<n>` | job paralleli delle miniature per cartella (default 2, mai oltre `ZUER_WORKERS`) |
| `ZUER_OPAQUE=1` | finestra **opaca** (BitBlt veloce) invece del vetro layered: utile per testare 3D/video fluidi **sotto Wine**, dove senza DWM il vetro va composto in software. Su Windows vero il DWM compone il vetro in GPU, quindi non serve |

Due capacità native, ognuna con la sua import-lib, attivabili a parte:

| Flag | Default | Cosa abilita |
|------|---------|--------------|
| `-Dvulkan` | Linux + Windows | renderer mesh/testo. Su Windows usa la import-lib vendorata in `vendor/vulkan/` (→ `vulkan-1.dll`) |
| `-Dffmpeg` | Linux + Windows | player video libav. Su Windows usa header + import-lib in `vendor/ffmpeg/` (le DLL si scaricano a parte) |

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
rsvg/ImageMagick, file oltre 8 MiB: processi esterni già multi-thread o picchi di RAM
da centinaia di MB); cache su disco in `~/.cache/zuer/thumbs` con tetto LRU di
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
| tempo | 9,7 s | 10,3 s | 8,1 s | 7,7 s | 8,1 s |
| RSS massima | 446 MB | 444 MB | 489 MB | 497 MB | 510 MB |
| apertura di un JPEG 2048² durante le miniature (da solo: 125 ms) | — | 124 ms | 186 ms | 170 ms | 261 ms |

Le miniature sono identiche (stesso hash) in tutti gli scenari. Su cartelle di soli
file "pesanti" (WebP, immagini oltre 8 MiB, PDF) il parallelo non accelera né rallenta:
sono serializzati di proposito. Con la cache calda la cartella si riempie in 60–85 ms.
Default 2 job: 3 sono equivalenti entro il rumore, 4 raddoppiano l'apertura di un file.

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
