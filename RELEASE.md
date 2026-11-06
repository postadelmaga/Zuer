# Zuer 1.0.0-rc.1 — note di rilascio

Release candidate. Ramo `rc-1.0` (Zuer) su Zicro `rc-1.0` (= `main` 5b1cf99): nessun
tag, nulla pubblicato. Ogni affermazione qui sotto dice **come** è stata verificata:

- **verificato**: provato su questa macchina, con lo script indicato;
- **guasto iniettato / simulato**: la reazione di Zuer è provata, l'evento vero no;
- **non verificato**: non provato; può funzionare, nessuna garanzia;
- **non supportato**: non funziona o non è previsto.

Macchina di prova: Intel HD Graphics 520 (Skylake GT2), Mesa 26.2.6, VA-API (libva
2.24), mpv 0.41, FFmpeg 9.0, PipeWire, CachyOS (kernel 7.3), Zig 0.17.0. Compositor:
sway 1.12 headless (GLES2), KWin 6.8.2 `--virtual`, Weston headless.

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
| `libva` (+ driver VA-API) | niente sonda dei codec hardware; mpv decide da sé |
| `pdftoppm` (poppler), `soffice` | PDF e documenti office non si aprono |
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
| Windows x86_64 | ✅ cross-compilato | ⚠️ in passato provato sotto Wine; questa RC no |
| macOS arm64 / x86_64 | ✅ cross-compilato | ❓ mai avviato |
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
8. **Aperture ~9 ms più lente di `main`** (vedi Benchmark): costo del caricare senza
   `start=0`, che rendeva inapribili i TS senza indice.

## Licenza

AGPL-3.0-or-later (`LICENSE`), come Zicro. Componenti di terze parti: vedi README.
