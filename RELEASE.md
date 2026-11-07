# Zuer 1.0.0-rc.1 — note di rilascio

Release candidate, tag `v1.0.0-rc.1`. Zicro al commit di `.github/zicro.ref`
(`b784b75`: `main` 5b1cf99 più la correzione Cocoa per macOS). Ogni affermazione qui sotto dice **come** è stata verificata:

- **verificato**: provato su questa macchina, con lo script indicato;
- **guasto iniettato / simulato**: la reazione di Zuer è provata, l'evento vero no;
- **non verificato**: non provato; può funzionare, nessuna garanzia;
- **non supportato**: non funziona o non è previsto.

Macchina di prova: Intel HD Graphics 520 (Skylake GT2), Mesa 26.2.6, VA-API (libva
2.24), mpv 0.41, FFmpeg 9.0, PipeWire, CachyOS (kernel 7.3), Zig 0.17.0. Compositor:
sway 1.12 headless (GLES2), KWin 6.8.2 `--virtual`, Weston headless.

## Dopo rc.1: ramo `platform-parity` (non ancora rilasciato)

Queste modifiche **non sono nei pacchetti rc.1 pubblicati**; entreranno nella
prossima RC. Stato di verifica di ciascuna in "Piattaforme" e "Verifiche".

- **Vulkan opzionale ovunque.** Nessun binario importa più `vulkan-1.dll` /
  `libvulkan.so.1`: il loader si apre a runtime (`src/renderer/vk_loader.zig`) e
  ogni condizione ha il suo errore (loader assente o non valido, nessun driver,
  istanza, enumerazione, nessuna GPU, nessuna coda grafica, device). Senza Vulkan
  Zuer parte e al posto di un modello 3D mostra il motivo. Device perso durante
  l'uso: il renderer si ricostruisce e il file si ricarica; dopo 2 perdite resta
  spento.
- **Office ovunque**: il plugin (DOCX, XLSX/XLSM, PPTX, ODT, ODS, ODP; Zig puro) ora
  è anche nei pacchetti macOS e Windows.
- **macOS arm64 completo**: PDF con CoreGraphics (di sistema), video con FFmpeg LGPL
  nel bundle e decodifica VideoToolbox, audio con AudioQueue (Zicro), 3D con
  MoltenVK nel bundle. Le librerie si aprono a runtime: se mancano, la funzione
  si spegne con un messaggio, l'app no.
- **`feature-probe`** (strumento di prova, non distribuito) e prove reali in CI.

## Novità rispetto a `main` (1234c9e)

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
  `<exe>/../lib`), mai nella cartella corrente. Prima `zuer` lanciato da un'altra
  cartella non trovava i plugin, e lanciato da una cartella scaricata avrebbe
  caricato i `.so` presenti lì.

**Rilascio**
- Versione 1.0.0-rc.1, `zuer --version` e `zuer-gui --version`.
- `install.sh --uninstall`; il desktop entry dichiara `StartupWMClass=it.zuer.gui`,
  uguale all'`app_id` della finestra.
- La GUI compila di nuovo per macOS: falliva anche su `main`.
- macOS: al primo avvio vero su un Mac l'app moriva con un'eccezione Objective-C
  (`platformWindow`, selettore del solo backend Cocotron). Corretto in Zicro.
- Pacchetti macOS arm64 e Windows x64 costruiti e verificati da GitHub Actions
  (`.github/workflows/release.yml`); FFmpeg per Windows ripinnato su una build
  LGPL, con licenza e riferimenti al sorgente nell'installer.

**Nuove verifiche**: `scripts/gpu-reset-check.sh`, `scripts/edge-check.sh`, sorgenti
malformate e cambio hw→sw in `scripts/video-check.sh`, `zuer-video-bench open-at`,
test dello scrim in `zig build test`.

## Dipendenze a runtime (Linux)

Obbligatorie: `wayland-client`, EGL + OpenGL, GBM (Mesa), loader Vulkan, PipeWire,
ALSA (`libasound`), harfbuzz, FFmpeg (libavformat/codec/util, swscale, swresample).

Facoltative, caricate solo al bisogno:

| Libreria / programma | Se manca |
|---|---|
| `libmpv.so.2` | il video usa il decoder libav: niente piano dmabuf, frame copiati in CPU |
| `libvulkan.so.1` (+ driver) | *(dopo rc.1)* niente modelli 3D, con il motivo a schermo; il resto funziona |
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
| sway (wlroots) | — | ✅ verificato, headless |
| KWin (Plasma 6) | — | ⚠️ `--virtual`, 2 monitor, scala 1,25: verificato; sessione Plasma reale **non verificata** |
| Weston | — | ⚠️ headless pixman/gl: si apre e riproduce; lento (GL software) |
| GNOME/Mutter | — | ❓ non verificato |
| GPU AMD | — | ❓ non verificato |
| NVIDIA (driver proprietario) | — | ❓ **non verificato**: ripiego glFinish previsto, mai provato |
| Windows x64 (rc.1) | ✅ nativo (CI `windows-2022`) | ⚠️ CI: installazione silenziosa, `--version`, finestra aperta 8 s con un file di testo (runner senza GPU né driver Vulkan), disinstallazione; Wine: installazione/disinstallazione. Nessuna prova con un utente, una GPU vera, video o 3D |
| Windows x64 (dopo rc.1) | ✅ cross-compilato; CI nativa **non ancora eseguita** | ⚠️ Wine 11.21 (questa macchina): installazione, DOCX/XLSX/PPTX/ODT/ODS, mesh, video (decodifica, seek), render 3D con winevulkan; senza loader (`vulkan-1=d`) e senza driver la GUI resta aperta con testo/docx/xlsx/video/3D e il 3D dice perché; disinstallazione pulita. Windows vero: **non verificato** |
| macOS arm64 (rc.1) | ✅ nativo (CI `macos-15`, Apple Silicon) | ⚠️ CI: `--version`, finestra aperta 8 s con un file di testo; nessuna prova interattiva |
| macOS arm64 (dopo rc.1) | ✅ cross-compilato da Linux; build nativa e prove **non ancora eseguite** (il workflow le prevede) | ❓ **non verificato**: PDF/CoreGraphics, VideoToolbox, AudioQueue, MoltenVK mai eseguiti su un Mac |
| macOS x86_64 | ✅ cross-compilato | ⛔ nessun pacchetto distribuito |
| Android aarch64 (`libzuer.so`) | ✅ cross-compilato | ❓ non verificato |
| Web | — | ⛔ non supportato (nessun target) |

## Verifiche

Tutte su `rc-1.0` (Zuer d5cb407, Zicro 5b1cf99), sway headless, audio muto (sink
nullo o `ao=null`) salvo dove detto.

| Verifica | Esito | Cosa copre |
|---|---|---|
| `zig build test` (Zuer) | 43/43 | rilevamento formati, scheduler, miniature, cache mesh, scrim |
| `zig build test` (Zicro) | 172/172 | framework: paint, testo, audio, finestra |
| `scripts/video-check.sh` | 36/36 | H.264/HEVC/VP9/senza audio/corto: apertura, pausa < 2% CPU, seek, thread giusti; TS malformati; hw→sw a metà; 100 cicli a caldo e 30 a freddo senza fd/thread in più |
| `scripts/net-check.sh` | 24/24 | rete lenta, muta, che cade, che non risponde; chiusura con la rete ferma |
| `scripts/video-sync-check.sh` | 300 schermate, 0 strappate | sincronia del piano dmabuf |
| `scripts/gpu-reset-check.sh` | 5/5 | contesto perso (guasto iniettato): motore rifatto, video di nuovo a schermo, nessun fd/thread in più, protocollo pulito |
| `scripts/edge-check.sh` | 24/24 | 20 file limite in apertura, FIFO, plugin trovati da `/` |
| `scripts/wayland_check.py` | 0 violazioni | invarianti di protocollo (buffer, configure, formati) nelle tracce sopra |
| `scripts/vulkan-fallback-check.sh` *(dopo rc.1)* | 27/27 | renderer con Vulkan vero; loader assente, non valido, senza driver, guasti iniettati su istanza/enumerazione/nessuna GPU/device: errore distinto (selftest) e GUI viva con cubo e testo; device perso una volta (ricostruito) e sempre (ripiego) |

Al primo giro del gate `video-sync-check` ed `edge-check` sono falliti per `/tmp`
pieno sulla macchina di prova (le schermate e un file da 300 MB non trovavano
posto); liberato lo spazio sono passati entrambi.

**Mutazioni**: ogni correzione di questa RC è stata tolta di proposito e la sua
verifica è fallita (start=0, fallimento rapido, attesa END_FILE, loop, ripresa
hw→sw, ripartenza del motore perso, motore perso rimesso nel pool, scrim, FIFO nel
decoder, FIFO nei player, plugin nella cartella corrente).

**Audio sul dispositivo vero** (Intel HDA, uscita MUTA con guardia e ripristino,
registrazione dal monitor): 100 s misti e 280 s continui con pause, seek, v
spento/acceso, cambio file; nessun xrun oltre quelli fisiologici del risveglio del
dispositivo, frequenza 1000,01 Hz su 1000, nessun frame perso né duplicato. Cambio e
rimozione del dispositivo di uscita: entrambi i motori si spostano e riprendono.

**Memoria e cicli di vita**: 1000 cambi di file in GUI (RSS fra 190 e 294 MB, senza
crescita; fd 26–30, thread 14–22, stabili); 1000 aperture/chiusure a caldo, 100 a
freddo, 200 con seek (fd e thread tornano ai valori iniziali, 4 e 1).

**Benchmark** (1080p60 H.264, 12 s, riscaldamento + 5 ripetizioni, due giri
alternati `main`/rc, mediana ± deviazione):

| Misura | `main` (1234c9e) | rc-1.0 |
|---|---|---|
| CPU processo, piano dmabuf | 25 ± 0,7% | 25 ± 0,8% |
| CPU processo, readback | 70 ± 0,6% | 70–71 ± 0,8% |
| frame scartati da mpv in 10 s, dmabuf | 0–0,4 | 0 |
| frame scartati da mpv in 10 s, readback | 2 | 1,6–1,8 |
| frame persi (slot occupati), entrambi | 0 | 0 |
| RSS in riproduzione, dmabuf | 280–281 MB | 281–283 MB |
| apertura a caldo (media di 50, mediana di 5) | 71 ± 3 ms | 80 ± 3 ms |
| apertura a freddo (media di 10, mediana di 5) | 159 ± 2 ms | 168 ± 3 ms |
| chiusura (massimo) | 16 ms | 14 ms |

Riproduzione invariata. Le aperture costano ~9 ms in più, misurato e attribuito:
`loadfile` senza `start=0` (provato a parità di tutto il resto: 68 → 79 ms a caldo).
`start=0` è un seek preciso e su un MPEG-TS senza indice lasciava il video a fine
stream senza frame (apertura fallita dopo 20 s): tenuto il comportamento corretto,
accettato il costo. Il contesto GL robusto è stato escluso come causa (A/B, nessuna
differenza).

## Distribuzione

I pacchetti sono costruiti da GitHub Actions (`.github/workflows/release.yml`) al
push del tag, e allegati alla GitHub Release del tag con `SHA256SUMS` e
`manifest.json` (versione, commit di Zuer e Zicro, architettura, sha256).

| Sistema | Architettura | Artefatto | Costruito su |
|---|---|---|---|
| macOS 13 o successivo | Apple Silicon (arm64) | `zuer-<versione>-macos-arm64.tar.gz` (`Zuer.app`; dopo rc.1 con `Contents/Frameworks`: FFmpeg, MoltenVK) | `macos-15`, arm64 nativo |
| Windows 10/11 | x64 | `zuer-<versione>-windows-x64-setup.exe` | `windows-2022` |
| Linux | x64 | dai sorgenti: `zig build` + `install.sh` (sopra) | — |

Non ci sono pacchetti macOS Intel, universali o Windows ARM.

**Verifica del download**: nella cartella dei file scaricati,
`sha256sum -c SHA256SUMS --ignore-missing` (Linux/Git Bash) oppure
`shasum -a 256 -c SHA256SUMS` (macOS); su Windows anche
`Get-FileHash .\zuer-…-setup.exe -Algorithm SHA256` e confronto a mano.

**macOS**: estrarre l'archivio e trascinare `Zuer.app` in Applicazioni. Il pacchetto
**non è firmato né notarizzato** (nessun certificato Apple Developer): al primo
avvio Gatekeeper lo blocca; tasto destro → Apri, oppure
`xattr -dr com.apple.quarantine /Applications/Zuer.app`. Su arm64 il binario ha
la firma ad-hoc del linker, obbligatoria per avviarsi, che non identifica
l'autore. Disinstallazione: cancellare `Zuer.app` (cache in
`~/.cache/zuer`). Il pacchetto rc.1 apre testo, codice, markdown, tabelle,
immagini e archivi. Dalla prossima RC anche PDF (CoreGraphics), documenti office,
video e audio (FFmpeg LGPL e VideoToolbox) e modelli 3D (MoltenVK): le librerie
stanno in `Zuer.app/Contents/Frameworks` con licenze e sorgente in
`Contents/Resources` (`FFmpeg-LICENSE.txt`, `FFmpeg-SOURCE.txt`,
`MoltenVK-LICENSE.txt`); senza GPU Metal il 3D si spegne con un messaggio.

**Windows**: eseguire l'installer. Installa per l'utente corrente (nessun permesso
di amministratore) in `%LOCALAPPDATA%\Programs\Zuer`, aggiunge il menu Start e
"Apri con" senza cambiare le app predefinite. L'installer **non è firmato**:
SmartScreen avvisa ("Ulteriori informazioni" → "Esegui comunque").
Disinstallazione da Impostazioni → App installate, o `uninstall.exe` nella
cartella; in silenzio: `zuer-…-setup.exe /S`, `uninstall.exe /S`. Il video usa le DLL FFmpeg
incluse (LGPL-3.0, build BtbN: vedi `FFmpeg-SOURCE.txt` nella cartella).

Vulkan: in rc.1 il loader (`vulkan-1.dll`, installato con qualsiasi driver GPU
recente) è un requisito, senza l'eseguibile non parte. Dalla prossima RC non lo è
più: senza loader o senza driver Zuer parte e solo i modelli 3D non si vedono
(con il motivo a schermo). Dalla prossima RC l'installer apre anche i documenti
office; i PDF restano non supportati su Windows (nessun motore PDF incluso).

**Licenze nei pacchetti**: `LICENSE` (AGPL-3.0-or-later) in entrambi; nell'installer
Windows anche `FFmpeg-LICENSE.txt` e `FFmpeg-SOURCE.txt` (commit FFmpeg e
indirizzi del sorgente corrispondente). Il sorgente di Zuer per ogni versione è
il tag su GitHub; quello di Zicro è il commit in `.github/zicro.ref`.

### Fare una nuova RC

1. Su `main`, aggiornare `.version` in `build.zig.zon` (es. `1.0.0-rc.2`) e
   `android:versionName`; se Zicro è cambiato, il suo commit (già su GitHub) in
   `.github/zicro.ref`.
2. Gate locale: `zig build test`, `scripts/video-check.sh`, `net-check.sh`,
   `video-sync-check.sh`, `gpu-reset-check.sh`, `edge-check.sh`,
   `vulkan-fallback-check.sh`.
3. Prova del workflow senza pubblicare: Actions → release → Run workflow con
   `tag=main` e `dry_run` (o `gh workflow run release.yml -f tag=main -f dry_run=true`).
4. Tag annotato sul commit provato e push: `git tag -a v1.0.0-rc.2 -m "…"`,
   `git push origin v1.0.0-rc.2`. Il workflow parte da solo e pubblica.
5. Se serve rifarlo sullo stesso tag: `gh workflow run release.yml -f tag=v1.0.0-rc.2`
   (aggiorna la release solo se è dello stesso commit, senza duplicati).
6. Se `fetch-ffmpeg-dlls.sh` dà 404, BtbN ha ritirato l'autobuild pinnato:
   sceglierne uno recente come spiegato nello script, e portare lo stesso commit
   in `scripts/build-ffmpeg-macos.sh` (le due piattaforme condividono l'ABI degli
   header vendorati).

## Limiti noti

1. **Reset GPU e sospensione veri non provati.** La ripresa dopo un contesto perso è
   provata solo per **guasto iniettato** (`ZUER_TEST_GPU_RESET_AFTER`). Un reset vero
   del driver e un suspend/resume reale non sono stati eseguiti, perché avrebbero
   sospeso la macchina di sviluppo. Senza contesto robusto (driver senza
   `EGL_EXT_create_context_robustness` né EGL 1.5) la perdita non si vede: serve
   riaprire il video.
2. **Spegnendo il video col tasto `v`** l'audio passa dal motore mpv al player
   Zicro. Sul dispositivo vero si ripete un tratto di 11–55 ms (un quanto del grafo
   PipeWire), con un click. libmpv non espone la latenza della sua coda verso il
   dispositivo. Riaccendendo il video la pausa è di ~85 ms.
3. **Passaggio hw→sw a metà:** restano ~0,4 s di immagine ferma. È mpv che riprova
   i backend hardware (Vulkan, NVDEC, VA-API, VDPAU) prima del software; non li
   abbiamo tolti, perché su altre macchine servono.
4. **KWin importa i dmabuf in ritardo:** se rifiuta un buffer, il client non lo
   sa (il protocollo non lo dice) e quel frame non compare. Su sway il rifiuto
   arriva e Zuer ripiega sul readback.
5. **Readback a 1080p60** (senza piano dmabuf, es. compositor senza
   linux-dmabuf): ~70% di un core e ~2 frame scartati da mpv ogni 10 s sulla HD 520.
6. **Chiusura con la rete ferma:** fino a ~180 ms, perché si attende
   l'interruzione di libav.
7. **`install.sh`** rende Zuer l'applicazione predefinita per diversi tipi MIME e su
   KDE prende Meta+Z. L'installer Windows invece non cambia i predefiniti.
8. **Pacchetti non firmati**: nessun certificato Apple Developer ID né Windows
   Authenticode configurato. macOS: solo firma ad-hoc, nessuna notarizzazione
   (Gatekeeper chiede conferma); Windows: SmartScreen avvisa. Il workflow non finge
   firme: `manifest.json` dice `"signed": false`.
9. **Windows senza loader Vulkan** (`vulkan-1.dll`, es. macchine virtuali senza
   driver GPU): in rc.1 `zuer-gui.exe` non parte, nemmeno per il testo, perché il
   loader è importato staticamente. Corretto dopo rc.1 (vedi sopra).
10. **macOS**: in rc.1 build ridotta (testo, tabelle, immagini, archivi; niente
   video, 3D, PDF, office); dopo rc.1 completa ma **non ancora eseguita su un Mac**.
   Restano: niente AV1 software (FFmpeg senza dav1d: solo dove VideoToolbox lo
   decodifica, M3 e successivi), niente cache su disco delle pagine PDF né
   eviction LRU delle cache (solo Linux), audio senza misura della latenza del
   dispositivo (sincronia A/V meno precisa che su PipeWire), 3D solo con una GPU
   Metal. `CFBundleShortVersionString` è `1.0.0` (macOS vuole x.y.z).
11. **Formati office binari** (DOC, XLS, PPT) non supportati su nessuna piattaforma;
   PDF non supportato su Windows.
12. **Aperture ~9 ms più lente di `main`** (vedi Benchmark): costo del caricare senza
   `start=0`, che rendeva inapribili i TS senza indice.

## Licenza

AGPL-3.0-or-later (`LICENSE`), come Zicro. Componenti di terze parti: vedi README.
