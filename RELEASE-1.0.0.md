# Zuer 1.0.0 — note di rilascio

Versione stabile, tag `v1.0.0`. Zicro al commit di `.github/zicro.ref` (`65cfc86`,
`main` di Zicro). Ogni affermazione qui sotto dice **come** è stata verificata:

- **verificato**: provato su questa macchina, con lo script indicato;
- **CI**: provato da GitHub Actions su un runner vero della piattaforma (macchina
  virtuale: niente GPU fisica, niente utente), con le prove indicate;
- **guasto iniettato / simulato**: la reazione di Zuer è provata, l'evento vero no;
- **non verificato**: non provato; può funzionare, nessuna garanzia;
- **non supportato**: non funziona o non è previsto.

Macchina di prova Linux: Intel HD Graphics 520 (Skylake GT2), Mesa 26.2.6, VA-API
(libva 2.24), mpv 0.41, FFmpeg 9.0, PipeWire, CachyOS (kernel 7.3), Zig 0.17.0.
Compositor: sway 1.12 headless (GLES2), KWin 6.8.2 `--virtual`, Weston headless.

## Novità rispetto a 1.0.0-rc.1

- **Vulkan facoltativo ovunque.** Nessun binario importa più `vulkan-1.dll` /
  `libvulkan.so.1`: il loader si apre a runtime (`src/renderer/vk_loader.zig`; su
  Windows solo dalla cartella dell'app e da System32, mai dalla cartella corrente)
  e ogni condizione ha il suo errore: loader assente o non valido, nessun driver,
  istanza, enumerazione, nessuna GPU, nessuna coda grafica, device. Senza Vulkan
  Zuer parte e al posto di un modello 3D mostra il motivo. Device perso durante
  l'uso: il renderer si ricostruisce e il file si ricarica; dopo 2 perdite resta
  spento. In rc.1 su Windows senza loader l'app non partiva nemmeno per il testo.
- **macOS arm64 completo**: PDF con CoreGraphics (di sistema), video con FFmpeg LGPL
  nel bundle e decodifica VideoToolbox, audio con AudioQueue (Zicro), 3D con
  MoltenVK nel bundle. Le librerie si aprono a runtime: se mancano, la funzione
  si spegne con un messaggio, l'app no. In rc.1 il pacchetto macOS apriva solo
  testo, tabelle, immagini e archivi.
- **Office ovunque**: il plugin (DOCX, XLSX/XLSM, PPTX, ODT, ODS, ODP; Zig puro) è
  ora anche nei pacchetti macOS e Windows, con le associazioni dei file.
- **Correzioni trovate dalle prove sui runner veri**:
  - macOS: aprendo un PDF, un video o un modello 3D l'app moriva (AppKit,
    "transaction must be valid"): il ridimensionamento della finestra partiva dal
    thread di decodifica. Ora va sempre sul main thread (Zicro `65cfc86`).
  - Linux e Windows: con un guasto Vulkan dopo la creazione dell'istanza
    (enumerazione, device) la GUI andava in SIGSEGV leggendo un'immagine vuota
    nell'istante fra l'errore e il messaggio sostitutivo. Corretto.
  - macOS: una pagina PDF Letter a 150 dpi usciva di una riga più alta (1651
    invece di 1650 pixel) per un errore di arrotondamento.
- **`feature-probe`** (strumento di prova, non distribuito) e prove reali nella CI
  di macOS e Windows (sotto, "Verifiche").

## Già in rc.1, rispetto a `main` (1234c9e)

**Video**
- Sorgenti malformate (MPEG-TS senza indice, troncati, rumore, vuoti): l'apertura
  fallisce o parte in ~0,3 s invece di 20 s di attesa; la chiusura dopo un'apertura
  fallita non aspetta più 1 s; un TS minuscolo in loop non gira più a vuoto (95% → 0,6%
  di CPU). Il loop si spegne solo per il file che non si riposiziona.
- Decoder hardware che cede a metà riproduzione: mpv passa al software e Zuer
  riparte dall'ultimo keyframe; il blocco dell'immagine scende da 1,7 s a 0,6 s (GOP
  1 s) e da 7,1 s a 0,9 s (GOP 5 s).
- Contesto GPU perso (reset del driver): contesto EGL robusto dove il driver lo
  offre; il motore perso viene distrutto e rifatto alla stessa posizione, play/pausa
  conservati. Prima restava rotto per tutti i video successivi.
- Controlli sopra il piano dmabuf: una ricomposizione costa 3,4 ms invece di 13,5;
  CPU di Zuer a controlli visibili 33–35% → 27–29% (1080p60).

**Apertura dei file**
- FIFO e file speciali rifiutati con un messaggio. Prima una FIFO bloccava il
  decoder e, col nome di un video, impediva all'app di chiudersi.
- Plugin cercati solo accanto all'eseguibile (`<exe>/decoders`, `<exe>`,
  `<exe>/../lib`), mai nella cartella corrente.

**Rilascio**
- `zuer --version` e `zuer-gui --version`; `install.sh --uninstall`; il desktop
  entry dichiara `StartupWMClass=it.zuer.gui`, uguale all'`app_id` della finestra.
- Pacchetti macOS arm64 e Windows x64 costruiti e verificati da GitHub Actions
  (`.github/workflows/release.yml`); FFmpeg per Windows su una build LGPL, con
  licenza e riferimenti al sorgente nell'installer.

## Dipendenze a runtime (Linux)

Obbligatorie: `wayland-client`, EGL + OpenGL, GBM (Mesa), PipeWire, ALSA
(`libasound`), harfbuzz, FFmpeg (libavformat/codec/util, swscale, swresample).

Facoltative, caricate solo al bisogno:

| Libreria / programma | Se manca |
|---|---|
| `libvulkan.so.1` (+ driver) | niente modelli 3D, con il motivo a schermo; il resto funziona |
| `libmpv.so.2` | il video usa il decoder libav: niente piano dmabuf, frame copiati in CPU |
| `libva` (+ driver VA-API) | niente sonda dei codec hardware; mpv decide da sé |
| `pdftoppm`, `pdfinfo` (poppler) | i PDF non si aprono (i documenti office non hanno dipendenze) |
| ImageMagick (`convert`) | i formati immagine rari (HEIC, AVIF, TIFF…) non si aprono |
| `libwebp` | WebP non si apre |
| `yt-dlp` | i link YouTube non si aprono |

## Diagnostica

- `ZUER_TRACE=1`: avvio e fine del motore video, contesto GL (robusto o no), percorso
  di presentazione (dmabuf o readback) e perché, ricomposizioni dell'overlay al
  secondo e quanto costano, riga "fine sessione" (frame, persi, pacing, A/V).
- `zuer --json <file>`: decodifica col codice della GUI e stampa il risultato.
- Vulkan: il motivo per cui il 3D è spento è a schermo e nel log
  (`init renderer Vulkan fallita: <errore>`). `ZUER_VULKAN_LOADER=<percorso>` usa un
  loader preciso; `ZUER_VULKAN_LOADER=none` simula un sistema senza Vulkan.
- Crash: il log va in `~/.cache/zuer/crash.log`. Al **riavvio successivo** Zuer apre
  il browser su una issue GitHub precompilata (`postadelmaga/Zuer`) con la coda del
  log; l'utente la rivede e decide se inviarla. Nulla parte da solo, salvo un
  endpoint configurato con `ZUER_CRASH_URL`. Disattivazione totale:
  `ZUER_NO_CRASH_REPORT=1`; niente browser: `ZUER_CRASH_NO_BROWSER=1`.

## Piattaforme

| Piattaforma | Build | Prove dinamiche |
|---|---|---|
| Linux x86_64, Intel + Mesa, VA-API | ✅ | ✅ verificato: suite completa (sotto) |
| Linux, decodifica solo software | ✅ | ✅ verificato: `ZUER_MPV_OPTS=hwdec=no`, ripiego hw→sw |
| Linux senza piano dmabuf (readback) | ✅ | ✅ verificato: `ZUER_VIDEO_PLANE=0` |
| Linux senza libmpv (solo libav) | ✅ | ⚠️ verificato solo in parte (`ZUER_NO_MPV=1`) |
| Linux senza Vulkan / senza driver | ✅ | ✅ verificato: `scripts/vulkan-fallback-check.sh` |
| sway (wlroots) | — | ✅ verificato, headless |
| KWin (Plasma 6) | — | ⚠️ `--virtual`, 2 monitor, scala 1,25: verificato; sessione Plasma reale **non verificata** |
| Weston | — | ⚠️ headless pixman/gl: si apre e riproduce; lento (GL software) |
| GNOME/Mutter | — | ❓ non verificato |
| GPU AMD | — | ❓ non verificato |
| NVIDIA (driver proprietario) | — | ❓ **non verificato**: ripiego glFinish previsto, mai provato |
| Windows x64 | ✅ nativo (CI `windows-2022`) | ✅ CI: installer, import dei binari, office, video (software, seek), GUI viva senza loader Vulkan e con loader senza driver, Vulkan funzionante (lavapipe, **software**), perdita del device, disinstallazione. ❓ **non verificati**: GPU fisica, decodifica hardware, audio (il runner non ha uscita audio), uso interattivo |
| macOS arm64 | ✅ nativo (CI `macos-15`, Apple Silicon) | ✅ CI: bundle (arm64, dipendenze, rpath, licenze, firma ad-hoc), PDF con rotazione, office, VideoToolbox H.264/HEVC con seek, audio AudioQueue (orologio che avanza), 3D MoltenVK su Metal (GPU paravirtuale del runner), GUI viva con ogni tipo di file. ❓ **non verificati**: un Mac fisico, qualità audio e sincronia A/V, uso interattivo, Gatekeeper con un download vero |
| macOS x86_64 | ✅ cross-compilato | ⛔ nessun pacchetto distribuito |
| Android aarch64 (`libzuer.so`) | ✅ cross-compilato | ❓ non verificato |
| Web | — | ⛔ non supportato (nessun target) |

## Verifiche

### Linux (questa macchina)

Gate sul codice di 1.0.0 (Zuer `platform-parity` + versione, Zicro `65cfc86`),
sway headless, audio muto (sink nullo o `ao=null`). Fasi in serie, una build per
volta (`-j1`): il gate precedente era stato fermato dalla memoria della macchina.

| Verifica | Esito | Cosa copre |
|---|---|---|
| build ReleaseFast | ok (picco 640 MB) | `zuer`, `zuer-gui`, plugin |
| `zig build test` (Zuer) | ok | rilevamento formati, scheduler, miniature, cache mesh, scrim |
| `zig build test` (Zicro) | ok | framework: paint, testo, audio, finestra |
| `scripts/video-check.sh` | 36/36 | H.264/HEVC/VP9/senza audio/corto: apertura, pausa < 2% CPU, seek, thread giusti; TS malformati; hw→sw a metà; 100 cicli a caldo e 30 a freddo senza fd/thread in più |
| `scripts/net-check.sh` | 24/24 | rete lenta, muta, che cade, che non risponde; chiusura con la rete ferma |
| `scripts/video-sync-check.sh` | 300 schermate, 0 strappate | sincronia del piano dmabuf |
| `scripts/gpu-reset-check.sh` | 5/5 | contesto perso (guasto iniettato): motore rifatto, video di nuovo a schermo, nessun fd/thread in più, protocollo Wayland pulito (`wayland_check.py`) |
| `scripts/edge-check.sh` | 24/24 | 20 file limite in apertura, FIFO, plugin trovati da `/` |
| `scripts/vulkan-fallback-check.sh` | 28/28 | Vulkan vero; loader assente, non valido, senza driver, guasti iniettati su istanza/enumerazione/nessuna GPU/device: errore distinto e GUI viva con cubo e testo; device perso una volta (ricostruito) e sempre (ripiego) |
| `feature-probe` | ok | PDF (pagina ruotata 1650×1275), office, mesh, video (60 frame + seek, VA-API), render offscreen del cubo |
| navigazione in GUI | 1000 cambi, nessuna crescita | ↓ ogni 250 ms in una cartella mista (testo, PDF, office, 3D, 3 video): RSS 50–54 MB, fd 18, thread 7 dal centesimo al millesimo cambio; Esc chiude in 329 ms |

Il primo giro del gate ha trovato il SIGSEGV dopo un guasto Vulkan (sopra,
"Correzioni"), corretto prima del rilascio; la schermata del messaggio sostitutivo
è stata controllata a vista.

**Già verificati in rc.1** (codice invariato da allora: video mpv, audio Linux):
mutazioni di ogni correzione rc.1 (tolta di proposito, la sua verifica fallisce);
audio sul dispositivo vero (Intel HDA, uscita muta con guardia e ripristino: 100 s
misti e 280 s continui, nessun frame perso né duplicato, cambio e rimozione del
dispositivo); 1000 aperture/chiusure a caldo, 100 a freddo, 200 con seek.

### macOS arm64 (CI, runner `macos-15`, macOS 15.8, Apple Silicon virtualizzato)

Pacchetto estratto in una cartella pulita; `feature-probe` dentro una copia del
bundle (stessi plugin e librerie dell'app).

| Prova | Esito |
|---|---|
| architettura di ogni binario e dylib | arm64 |
| dipendenze dinamiche | solo `/usr/lib`, `/System/Library` o `@rpath` verso `Contents/Frameworks`; nessun rpath verso la macchina di build; `zuer-gui` non linka Vulkan né libav |
| licenze nel bundle | `LICENSE`, `FFmpeg-LICENSE.txt` (LGPL), `FFmpeg-SOURCE.txt`, `MoltenVK-LICENSE.txt` (Apache-2.0) |
| firma | ad-hoc, `codesign --verify --strict --deep` ok (nessun Developer ID, nessuna notarizzazione) |
| PDF (CoreGraphics) | 3 pagine; pagina 2 con `/Rotate 90` resa 1650×1275 |
| office | DOCX, XLSX (2 fogli), PPTX, ODT, ODS con il loro contenuto |
| video | H.264 e HEVC: 60 frame 1280×720 con **VideoToolbox attivo**, seek |
| audio | AudioQueue: orologio di riproduzione a 0,57 s dopo 400 ms (traccia muta) |
| 3D | MoltenVK su "Apple Paravirtual device" (Metal): cubo renderizzato offscreen |
| senza Vulkan | `ZUER_VULKAN_LOADER=none`: errore `VulkanLoaderMissing`, nessun crash |
| GUI | finestra viva 6 s con testo, PDF, DOCX, XLSX, video, cubo, cubo senza Vulkan |

### Windows x64 (CI, runner `windows-2022`, nessuna GPU, nessun loader Vulkan)

| Prova | Esito |
|---|---|
| import di `zuer-gui.exe` e di ogni DLL | nessuno importa `vulkan-1.dll`; ogni DLL importata è nel pacchetto o in System32 |
| installazione silenziosa | file, voce di disinstallazione, `DisplayVersion`, associazione `.docx` |
| office, mesh, testo | DOCX, XLSX, PPTX, ODT, ODS, OBJ, TXT con il loro contenuto |
| video | decodifica software (il runner non ha GPU), 60 frame e seek |
| senza loader Vulkan | GUI viva con testo, cubo, DOCX, video; il 3D dice `VulkanLoaderMissing` |
| loader senza driver | `VulkanNoDriver`, GUI viva col cubo |
| Vulkan funzionante (lavapipe, rasterizzatore **software** di Mesa) | cubo renderizzato offscreen e in GUI |
| device perso (iniettato) | una volta: renderer ricostruito; sempre: ripiego, app viva |
| disinstallazione | pulita (resta solo `uninstall.exe`, che si cancella dopo) |
| audio | **non verificato**: il runner non ha un dispositivo di uscita |

### Benchmark (Linux, 1080p60 H.264, rc.1 contro 1.0.0)

Build alternate, riscaldamento + 5 ripetizioni, due giri. **Carico di sistema alto
durante le misure** (load average 3–5 per un'altra build sulla macchina, contro ~1
delle misure di rc.1): i valori assoluti sono più rumorosi, il confronto fra le due
build regge perché alternato.

| Misura | rc.1 | 1.0.0 |
|---|---|---|
| CPU processo, piano dmabuf (media dei giri) | 11–14% | 11–22% |
| CPU processo, readback | 72–92% | 90–91% |
| RSS in riproduzione, dmabuf | 281 MB | 282 MB |
| RSS in riproduzione, readback | 307–309 MB | 309–310 MB |
| fd in riproduzione | 26 / 19 | 26 / 19 |
| frame persi (slot dmabuf) | 0 | 0 |
| seek (60 per build, alternate) | mediana 99 ms, media 110, p90 154 | mediana 107 ms, media 115, p90 152 |
| apertura a caldo (mediana di 5 × 50) | 94 ms | 91 ms |
| apertura a freddo (mediana di 5 × 10) | 242 ms | 242 ms |

Il percorso video Linux (mpv, piano dmabuf, audio) non è cambiato fra rc.1 e 1.0.0:
le differenze stanno nel rumore del carico. Misure a macchina scarica: quelle di
rc.1 (CPU dmabuf 25%, readback 70%, apertura a caldo 80 ms, a freddo 168 ms).

## Distribuzione

I pacchetti sono costruiti da GitHub Actions (`.github/workflows/release.yml`) al
push del tag, e allegati alla GitHub Release del tag con `SHA256SUMS` e
`manifest.json` (versione, commit di Zuer e Zicro, architettura, sha256). Il
workflow pubblica solo se il tag punta al commit costruito e si chiama
`v<versione di build.zig.zon>`; rilanciato sullo stesso tag aggiorna la release
solo se è dello stesso commit.

| Sistema | Architettura | Artefatto | Costruito su |
|---|---|---|---|
| macOS 13 o successivo | Apple Silicon (arm64) | `zuer-<versione>-macos-arm64.tar.gz` (`Zuer.app`, ~25 MB di cui 20 MB in `Contents/Frameworks`: FFmpeg, MoltenVK) | `macos-15`, arm64 nativo |
| Windows 10/11 | x64 | `zuer-<versione>-windows-x64-setup.exe` | `windows-2022` |
| Linux | x64 | dai sorgenti: `zig build` + `install.sh` | — |

Non ci sono pacchetti macOS Intel, universali o Windows ARM.

**Verifica del download**: nella cartella dei file scaricati,
`sha256sum -c SHA256SUMS --ignore-missing` (Linux/Git Bash) oppure
`shasum -a 256 -c SHA256SUMS` (macOS); su Windows anche
`Get-FileHash .\zuer-…-setup.exe -Algorithm SHA256` e confronto a mano.

**macOS**: estrarre l'archivio e trascinare `Zuer.app` in Applicazioni. Il pacchetto
**non è firmato con un Developer ID né notarizzato** (nessun certificato Apple
Developer): al primo avvio Gatekeeper lo blocca; tasto destro → Apri, oppure
`xattr -dr com.apple.quarantine /Applications/Zuer.app`. La firma è solo ad-hoc,
obbligatoria su arm64 per avviarsi, e non identifica l'autore. Apre testo, codice,
markdown, tabelle, immagini, archivi, PDF (CoreGraphics), documenti office, video e
audio (FFmpeg LGPL e VideoToolbox) e modelli 3D (MoltenVK): le librerie stanno in
`Zuer.app/Contents/Frameworks`, licenze e sorgente in `Contents/Resources`. Senza
GPU Metal il 3D si spegne con un messaggio. Disinstallazione: cancellare
`Zuer.app` (cache in `~/.cache/zuer`).

**Windows**: eseguire l'installer. Installa per l'utente corrente (nessun permesso
di amministratore) in `%LOCALAPPDATA%\Programs\Zuer`, aggiunge il menu Start e
"Apri con" senza cambiare le app predefinite. L'installer **non è firmato**:
SmartScreen avvisa ("Ulteriori informazioni" → "Esegui comunque").
Disinstallazione da Impostazioni → App installate, o `uninstall.exe` nella
cartella; in silenzio: `zuer-…-setup.exe /S`, `uninstall.exe /S`. Il video usa le
DLL FFmpeg incluse (LGPL, build BtbN: vedi `FFmpeg-SOURCE.txt` nella cartella).
Vulkan non è un requisito: senza loader o senza driver Zuer parte e solo i modelli
3D non si vedono, con il motivo a schermo. **I PDF non sono supportati su Windows**
(nessun motore PDF incluso); i documenti office sì.

**Licenze nei pacchetti**: `LICENSE` (AGPL-3.0-or-later) in entrambi; FFmpeg
(LGPL) con `FFmpeg-LICENSE.txt` e `FFmpeg-SOURCE.txt` (commit FFmpeg
`5d85b7bfb2b024fd367ae3a938b4ac46a39e3a26` e indirizzi del sorgente: su macOS
compilato da quel commit con `scripts/build-ffmpeg-macos.sh`, librerie dinamiche
sostituibili); su macOS MoltenVK (Apache-2.0) con `MoltenVK-LICENSE.txt`. Il
sorgente di Zuer per ogni versione è il tag su GitHub; quello di Zicro è il commit
in `.github/zicro.ref`.

### Fare una nuova versione

1. Su `main`, aggiornare `.version` in `build.zig.zon` (es. `1.0.1`) e
   `android:versionName`; se Zicro è cambiato, il suo commit (già su GitHub) in
   `.github/zicro.ref`.
2. Gate locale, una fase per volta: `zig build test` (Zuer e Zicro),
   `scripts/video-check.sh`, `net-check.sh`, `video-sync-check.sh`,
   `gpu-reset-check.sh`, `edge-check.sh`, `vulkan-fallback-check.sh`.
3. Prova del workflow senza pubblicare, **con il workflow del ramo**:
   `gh workflow run release.yml --ref main -f tag=main -f dry_run=true`.
4. Tag annotato sul commit provato e push: `git tag -a v1.0.1 -m "…"`,
   `git push origin v1.0.1`. Il workflow parte da solo e pubblica.
5. Se serve rifarlo sullo stesso tag: `gh workflow run release.yml -f tag=v1.0.1`
   (aggiorna la release solo se è dello stesso commit, senza duplicati).
6. Se `fetch-ffmpeg-dlls.sh` dà 404, BtbN ha ritirato l'autobuild pinnato:
   sceglierne uno recente come spiegato nello script, e portare lo stesso commit
   in `scripts/build-ffmpeg-macos.sh` (le due piattaforme condividono l'ABI degli
   header vendorati).

## Limiti noti

1. **Reset GPU e sospensione veri non provati.** La ripresa dopo un contesto perso
   (video) e dopo un device Vulkan perso (3D) è provata solo per **guasto
   iniettato**. Un reset vero del driver e un suspend/resume reale non sono stati
   eseguiti. Senza contesto robusto (driver senza
   `EGL_EXT_create_context_robustness` né EGL 1.5) la perdita non si vede: serve
   riaprire il video.
2. **Spegnendo il video col tasto `v`** l'audio passa dal motore mpv al player
   Zicro. Sul dispositivo vero si ripete un tratto di 11–55 ms (un quanto del grafo
   PipeWire), con un click. Riaccendendo il video la pausa è di ~85 ms.
3. **Passaggio hw→sw a metà:** restano ~0,4 s di immagine ferma (mpv riprova i
   backend hardware prima del software).
4. **KWin importa i dmabuf in ritardo:** se rifiuta un buffer, il client non lo
   sa e quel frame non compare. Su sway il rifiuto arriva e Zuer ripiega sul readback.
5. **Readback a 1080p60** (senza piano dmabuf): ~70% di un core e ~2 frame scartati
   da mpv ogni 10 s sulla HD 520.
6. **Chiusura con la rete ferma:** fino a ~180 ms (attesa dell'interruzione di libav).
7. **`install.sh`** rende Zuer l'applicazione predefinita per diversi tipi MIME e su
   KDE prende Meta+Z. L'installer Windows invece non cambia i predefiniti.
8. **Pacchetti non firmati**: nessun certificato Apple Developer ID né Windows
   Authenticode. macOS: firma ad-hoc, nessuna notarizzazione (Gatekeeper chiede
   conferma); Windows: SmartScreen avvisa. `manifest.json` dice `"signed": false`.
9. **macOS e Windows provati su runner virtuali**, non su macchine fisiche: su
   macOS la GPU è quella paravirtuale di Apple, su Windows il 3D è provato con
   lavapipe (software). Mai provati con un utente, né su Windows l'audio e la
   decodifica hardware.
10. **macOS**: niente AV1 software (FFmpeg senza dav1d: solo dove VideoToolbox lo
   decodifica, M3 e successivi); niente cache su disco delle pagine PDF né eviction
   LRU delle cache (solo Linux); audio senza misura della latenza del dispositivo
   (sincronia A/V meno precisa che su PipeWire, non misurata); 3D solo con una GPU
   Metal.
11. **Formati office binari** (DOC, XLS, PPT) non supportati su nessuna piattaforma;
   **PDF non supportato su Windows**.
12. **Aperture ~9 ms più lente di `main` 1234c9e** (misura di rc.1): costo del
   caricare senza `start=0`, che rendeva inapribili i TS senza indice.

## Licenza

AGPL-3.0-or-later (`LICENSE`), come Zicro. Componenti di terze parti: vedi docs/sviluppo.md, "Componenti di terze parti".
