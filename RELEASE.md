# Zuer 1.1.0 — note di rilascio

Versione stabile, tag `v1.1.0`: parità funzionale di Windows x64 e macOS arm64 con Linux.
Zicro al commit di `.github/zicro.ref` (`f5e0bac`, `main` di Zicro). Le note della 1.0.0
sono in [RELEASE-1.0.0.md](RELEASE-1.0.0.md).

Ogni affermazione dice come è stata verificata, con le stesse parole di RELEASE-1.0.0.md:

- **verificato**: provato su questa macchina Linux, con lo script indicato;
- **CI**: provato da GitHub Actions su un runner vero della piattaforma (macchina
  **virtuale**: Windows senza GPU, Mac con GPU paravirtuale, nessun utente);
- **guasto iniettato**: la reazione di Zuer è provata, l'evento vero no;
- **non verificato**: non provato su quel sistema; può funzionare, nessuna garanzia.

Nessuna funzione è stata provata su un PC Windows o un Mac **fisico**: le prove per farlo
sono in [docs/prove-hardware.md](docs/prove-hardware.md), con il kit scaricabile da ogni
run della CI.

## Cosa cambia rispetto a 1.0.0

### PDF su Windows (prima: non supportato)

- Motore **PDFium** (`pdfium.dll` nell'installer, build `bblanchon/pdfium-binaries`
  `chromium/8111`, sha256 fissato in `scripts/fetch-pdfium.sh`, V8/XFA esclusi e
  controllati). Caricata a runtime con `LoadLibraryExW` dalla cartella dell'app, mai
  dalla cartella corrente; senza la DLL il PDF dice "pdfium.dll assente o non valida:
  reinstalla Zuer" e il resto funziona. PDFium non è rientrante: ogni chiamata passa da
  un lock.
- Stesse prove sulle tre piattaforme (`scripts/pdf-check.sh`): pagine, pagina ruotata
  (`/Rotate 90` → 1650×1275), pagina oltre la fine (clamp), percorso non ASCII, colore
  di un pixel (ordine dei canali), JPEG dentro il PDF, file danneggiato, file non PDF,
  pagina di 14 400 pt ("pagina troppo grande"). Un PDF cifrato dà "documento protetto
  da password" (codice presente su PDFium e CoreGraphics, **non** coperto dalle prove).
- PDFium contro poppler sullo stesso PDF (sotto Wine): stesse dimensioni, 0,2% di pixel
  diversi (antialiasing).
- `.pdf` associato all'installazione Windows.
- Linux: poppler, su una pagina enorme, rendeva in silenzio un'immagine 1×1 (e la
  metteva in cache): ora è l'errore "pagina troppo grande", e la cache ignora le voci 1×1.

### Immagini: stesso motore ovunque

Prima WebP e SVG su Windows e macOS passavano da ImageMagick, che sul pacchetto non c'è
(e su Windows `convert.exe` è un comando di sistema che converte i dischi).

| Formato | Come | Dove |
|---|---|---|
| PNG, JPEG, GIF, BMP, TGA, PSD, HDR, PIC, PNM | stb_image, in processo | ovunque |
| WebP (anche il primo frame degli animati) | libwebp 1.5.0 compilata dal sorgente (dipendenza Zig) | ovunque |
| SVG, SVGZ | `rsvg-convert` se c'è (Linux), altrimenti nanosvg | ovunque |
| ICO (voci PNG e DIB con maschera) | parser in Zig | ovunque |
| TIFF, HEIC/HEIF, AVIF | codec di sistema: ImageIO (macOS), WIC (Windows); ImageMagick su Linux | ovunque, con limiti sotto |

- Orientamento EXIF dei JPEG (8 orientamenti), trasparenza composta su bianco, tetto di
  150 megapixel letto dall'header **prima** di decodificare.
- Windows: AVIF e HEIC richiedono le estensioni gratuite dello Store ("AV1 Video
  Extension", "HEIF Image Extensions" + "HEVC Video Extensions"); senza, il messaggio
  dice quale installare.
- `scripts/image-check.sh` con un corpus nel repository (`tests/images`): dimensioni,
  colore di pixel precisi (trasparenza, orientamento, ICO, SVG), file troncati, vuoti,
  spazzatura, immagine oltre il tetto.

### Audio

- **Windows: WASAPI** (modo condiviso, conversione di formato di sistema, evento) al
  posto di waveOut, che resta come ripiego (`ZICRO_AUDIO=waveout`). Latenza reale dal
  dispositivo (padding + latenza del flusso); cambio del dispositivo predefinito seguito
  (`IMMNotificationClient`); dispositivo perso o servizio riavviato → il flusso si
  riapre; senza alcun dispositivo i blocchi si scartano dopo un'attesa limitata, il
  player non si blocca.
- **macOS: latenza reale anche da AudioQueue** (campioni inviati meno la posizione di
  `AudioQueueGetCurrentTime`).
- Effetto: l'orologio audio su cui si sincronizza il video. Prima Windows e macOS
  usavano una stima fissa di 30 ms contro una coda reale fino a ~160 ms: il video andava
  avanti rispetto all'audio. Sotto Wine, stessa traccia muta: WASAPI 31 ms **dietro** il
  tempo reale (giusto: è la latenza hardware), waveOut 124 ms **avanti** (sbagliato).
  `feature-probe audio` ora fallisce se l'orologio supera il tempo trascorso di oltre
  50 ms dove il backend riporta la latenza.

### Video

- **Windows: decodifica hardware D3D11VA** (prima solo software), con la stessa sonda
  del primo frame, lo stesso trasferimento GPU→CPU e lo stesso ripiego al software di
  VideoToolbox su macOS.
- **Ripiego hw→sw a metà riproduzione** (player libav: Windows, macOS, Linux senza mpv):
  prima ripartiva da dove capitava; ora torna al keyframe precedente e scarta i frame
  fino all'ultimo mostrato: nessun salto né frame ripetuto. Guasto iniettabile con
  `ZUER_TEST_HWFAIL_AFTER=N`.
- **macOS: AV1 in software** con dav1d 1.5.4 (BSD-2-Clause) collegato staticamente in
  libavcodec; prima AV1 si apriva solo dove VideoToolbox lo decodifica (M3 e successivi).

### Office

Provato con documenti veri (`tests/office`: dai test di Apache POI e LibreOffice, più i
casi dei loro fuzzer; vedi `tests/office/SOURCES.md`). Trovati e corretti:

- fogli scritti col prefisso di namespace (`<x:row>`, come fa l'OpenXML SDK di
  Microsoft): risultavano vuoti;
- stringhe inline a più run: restava solo il primo;
- riferimenti numerici (`&#10;`, `&#x1F61C;`) lasciati letterali in XLSX, DOCX, PPTX, ODT;
- Office cifrato con password, o DOC/XLS/PPT rinominato (contenitore OLE): ora un
  messaggio chiaro invece di "NotAZipFile".

### Prestazioni e memoria

- GUI su Linux: soglia `mmap` di glibc fissa a 256 KB. Quella dinamica mandava i buffer
  di decodifica nelle arene dei thread worker, dove restavano frammentati: RSS di
  navigazione 88 MB → 51 MB, in riproduzione 1080p60 282 → 226 MB.
- Tre peggioramenti introdotti dal ramo e trovati dal confronto con 1.0.0 (canali alfa
  sempre a 4, copia dei WebP, ricerca dei tag XLSX) sono stati tolti prima della fine:
  tabella sotto.

## Matrice di parità

Legenda: **I** implementato · **C** compilato · **A** testato automaticamente (CI sulla
piattaforma, o gate locale per Linux) · **H** testato su hardware fisico · **M**
verificato manualmente. Linux: macchina di prova fisica (Intel HD 520), quindi H vale
per quello che il gate esegue sul dispositivo vero.

| Funzione | Linux | Windows x64 | macOS arm64 |
|---|---|---|---|
| Testo, codice, markdown, tabelle CSV | I C A H | I C A | I C A |
| Office (DOCX, XLSX, PPTX, ODT, ODS) | I C A H | I C A | I C A |
| PDF | I C A H (poppler) | I C A (PDFium) | I C A (CoreGraphics) |
| Immagini comuni + WebP + SVG + ICO | I C A H | I C A | I C A |
| HEIC, AVIF | I C A H (ImageMagick) | I C A (solo il messaggio senza estensioni Store; **con** le estensioni non provato) | I C A (ImageIO) |
| Video, decodifica software | I C A H | I C A | I C A |
| Video, decodifica hardware | I C A H (VA-API, mpv) | I C (D3D11VA: sul runner senza GPU si prova solo il ripiego) | I C A (VideoToolbox H.264/HEVC sul runner) |
| Ripiego hw→sw a metà | I C A H (guasto iniettato) | I C A (guasto iniettato, software) | I C A (guasto iniettato su VideoToolbox) |
| AV1 software | I C A H | I C A (FFmpeg BtbN) | I C A (dav1d) |
| Audio: riproduzione e orologio | I C A H (PipeWire) | I C A (WASAPI su scheda virtuale) | I C A (AudioQueue) |
| Audio: latenza reale nell'orologio | I C A H | I C A | I C A |
| Audio: perdita del dispositivo / servizio | I C A H (in 1.0.0) | I C A (riavvio del servizio audio; rimozione fisica non provata) | I C (non provato) |
| Audio: cambio del dispositivo predefinito | I C A H (in 1.0.0) | I C (non provato: una sola scheda sul runner) | I C (non provato) |
| 3D (Vulkan) | I C A H | I C A (lavapipe, software) | I C A (MoltenVK su GPU paravirtuale) |
| 3D senza Vulkan: messaggio, app viva | I C A H | I C A | I C A |
| Installazione / disinstallazione | `install.sh` | I C A (installer per utente) | I C A (bundle, firma ad-hoc) |

Nessuna cella è **M** o **H** per Windows e macOS: non c'è stato un PC o un Mac fisico.

## Verifiche

### Linux (questa macchina, gate finale sul codice del ramo)

Intel HD Graphics 520, Mesa 26.2, VA-API, mpv 0.41, FFmpeg 9.0, PipeWire, sway headless,
audio muto. Test unitari con **cache vuota** (nessun "cached": eseguiti davvero).

| Verifica | Esito |
|---|---|
| `zig build test` Zuer | 88/88 (nuovi: EXIF, parser XML office) |
| `zig build test` Zicro | 172/172 |
| `scripts/video-check.sh` | 36/36 |
| `scripts/net-check.sh` | 24/24 |
| `scripts/video-sync-check.sh` | 300 schermate, 0 strappate |
| `scripts/gpu-reset-check.sh` | 5/5 |
| `scripts/edge-check.sh` | 24/24 |
| `scripts/vulkan-fallback-check.sh` | 28/28 |
| `scripts/pdf-check.sh` | tutto ok (12 prove) |
| `scripts/image-check.sh` | tutto ok (43 prove; 2 file corrotti nel gruppo "nessun crash, esito libero") |
| `scripts/office-check.sh` | tutto ok (29 prove) |
| `feature-probe` audio, video, hw→sw iniettato, gpu, pagine PDF | ok; hw→sw: 60 frame, pts continui (salto massimo 17 ms) |
| navigazione GUI, 1000 cambi in cartella mista | RSS 51–52 MB costante, fd 18, thread 7; Esc chiude in 326 ms |

### macOS arm64 (CI, `macos-15`, Apple Silicon virtualizzato)

Oltre alle prove di 1.0.0 (bundle, dipendenze, firma ad-hoc, office, 3D MoltenVK, GUI):

| Prova | Esito |
|---|---|
| `pdf-check.sh` (CoreGraphics) | tutto ok, stessi valori di Linux; 3 aperture 122 ms |
| `image-check.sh` (ImageIO per TIFF, HEIC, AVIF) | tutto ok, HEIC e AVIF compresi |
| `office-check.sh` | tutto ok |
| video H.264 e HEVC | VideoToolbox attivo, 60 frame, seek, pts continui |
| AV1 (`libsvtav1`) | dav1d software, 60 frame, seek |
| hw→sw iniettato su VideoToolbox | pts continui |
| audio AudioQueue | orologio che avanza, latenza riportata ~7 700 frame (160 ms) |

### Windows x64 (CI, `windows-2022`, nessuna GPU)

Scheda audio: VB-CABLE, scheda **virtuale** installata solo sulla VM effimera della CI
(vedi "Dipendenze").

| Prova | Esito |
|---|---|
| file nel pacchetto | `pdfium.dll`, `PDFium-LICENSE.txt`, `decoder_pdf.dll`; `.pdf` associato |
| `pdf-check.sh` (PDFium) | tutto ok, stessi valori di Linux; 3 aperture 250 ms |
| `ZUER_PDFIUM=none` | messaggio "pdfium.dll assente o non valida" |
| `image-check.sh` (WIC) | tutto ok; AVIF e HEIC: messaggio con l'estensione Store da installare (il runner non le ha) |
| `office-check.sh` | tutto ok |
| video | software (nessuna GPU: D3D11VA non provato), pts continui, seek |
| WASAPI | dispositivo elencato; orologio che avanza, latenza 4 800 frame (100 ms) |
| uscita reale | tono a 1 kHz catturato in loopback dal mix del dispositivo: RMS 0,062, tono 2·10¹⁰ volte sopra le frequenze vicine |
| waveOut forzato | funziona |
| orologio contro tempo reale | WASAPI +0,017 s (entro i 50 ms della latenza hardware non riportata); waveOut +0,12 s (stima fissa: solo avviso) |
| riavvio del servizio audio durante la riproduzione | il flusso se ne accorge (7 tentativi di riapertura mentre il servizio riparte), ~0,2 s di vuoto, poi l'orologio riprende regolare |
| rimozione fisica / cambio del predefinito | **non provati** (vedi "Prove non eseguibili") |
| GUI con PDF e WebP, senza loader Vulkan, lavapipe, device perso | viva, come in 1.0.0 |

## Benchmark: 1.0.0 contro 1.1 (Linux)

Stessa macchina, build `v1.0.0` (Zicro `65cfc86`) e `parity-1.1` alternate; mediane.
Decodifica: processo `feature-probe` intero, 1 riscaldamento + 7 ripetizioni, cache su
disco vuota a ogni giro. Carico medio ~1.

| Caso | 1.0.0 tempo / CPU / RSS | 1.1 tempo / CPU / RSS |
|---|---|---|
| JPEG 24 MP | 346 ms / 339 ms / 147 MB | 324 / 321 / 149 |
| PNG 12 MP | 310 / 308 / 79 | 311 / 309 / 80 |
| WebP 4K | 90 / 89 / 26 | 87 / 86 / 27 |
| SVG | 16 / 16 / 18 | 16 / 16 / 18 |
| HEIC 12 MP | non supportato | 2 934 / 3 462 / 212 (ImageMagick) |
| PDF pagina 1, a freddo | 68 / 68 / 29 | 69 / 68 / 29 |
| PDF con foto, a freddo | 69 / 68 / 30 | 69 / 68 / 30 |
| XLSX 20 000 × 8 | 72 / 71 / 28 | 70 / 69 / 29 |
| DOCX, ODT | 3 / 3 / 16 | 3 / 3 / 16 |
| video 1080p60 libav: 60 frame + seek | 1 733 / 1 590 / 427 | 1 685 / 1 558 / 431 |

GUI (`scripts/video-bench-gui.sh`, H.264 1080p60, 5 × 12 s per build, due giri):

| Misura | 1.0.0 | 1.1 |
|---|---|---|
| CPU processo, piano dmabuf | 25% | 25% |
| CPU processo, readback | 75–77% | 74–76% |
| RSS in riproduzione, dmabuf | 282 MB | 226 MB |
| RSS in riproduzione, readback | 305–309 MB | 255 MB |
| frame persi / scartati da mpv in 10 s | 0 / 0–1 | 0 / 0 |
| seek (30 per build, zuer-video-bench) | mediana 90 ms, media 93 | mediana 82 ms, media 87 |
| apertura a caldo / a freddo | 63–87 / 170–184 ms | 61–86 / 174–185 ms |
| navigazione 300 cambi, stessa cartella | RSS 57–72 MB | RSS 51 MB |

Su Windows e macOS non ci sono misure confrontabili: i runner sono virtuali e
condivisi. I tempi PDF della CI (3 aperture, processo intero) sono indicativi.

## Dipendenze nuove

| Componente | Dove | Licenza | Peso | Note di sicurezza |
|---|---|---|---|---|
| PDFium `chromium/8111` (bblanchon/pdfium-binaries) | installer Windows | BSD-3-Clause + licenze dei componenti (FreeType, libjpeg-turbo, OpenJPEG, zlib, ICU…) in `PDFium-LICENSE.txt` | `pdfium.dll` 7,6 MB | sha256 fissato; build senza V8 né XFA (verificato da `args.gn`); caricata solo dalla cartella dell'app |
| libwebp 1.5.0 | compilata nel plugin immagini, ogni piattaforma | BSD-3-Clause | plugin immagini senza simboli 142 KB → 573 KB (libwebp, nanosvg, formati stb in più insieme); `decoder_image.dll` 729 KB | tarball del tag ufficiale, hash Zig in `build.zig.zon` |
| nanosvg (commit `5cefd98`) | `vendor/nanosvg`, plugin immagini | zlib | header-only | file e tetti di dimensione nel parser di Zuer (64 MB di testo, lato massimo del raster) |
| dav1d 1.5.4 (`54706fc`) | statico in libavcodec, bundle macOS | BSD-2-Clause | non misurato a parte (dentro `libavcodec`; la libreria Homebrew intera è ~1 MB) | compilato dal sorgente al commit fissato; licenza in `FFmpeg-LICENSE.txt` |
| VB-CABLE 4.3 | **solo CI Windows**, VM effimera | donationware (uso libero, ridistribuzione integrata vietata) | — | non è una dipendenza di Zuer e non entra nei pacchetti; zip fissato per sha256 |
| devcon (dallo zip di Scream 4.0) | **solo CI Windows** | MS-PL | — | zip fissato per sha256 |

Tutte compatibili con AGPL-3.0-or-later per i componenti distribuiti (PDFium, libwebp,
nanosvg, dav1d). Nessun servizio cloud.

## Prove non eseguibili qui, e perché

- **Qualsiasi cosa su un PC Windows o un Mac fisico**: nessuna macchina disponibile.
  Procedura ripetibile: [docs/prove-hardware.md](docs/prove-hardware.md).
- **D3D11VA vero**: il runner Windows non ha GPU; sotto Wine D3D11VA non c'è e Zuer
  ripiega sul software (provato). Il codice condivide sonda e ripiego con VideoToolbox,
  provato davvero sul runner macOS.
- **Qualità audio e sincronia A/V percepita**: i runner non hanno altoparlanti; l'audio
  della CI va su una scheda virtuale (Windows) o su quella del runner (macOS).
- **3D su GPU vera** Windows e macOS: lavapipe (software) e GPU paravirtuale Apple.
- **HEIC/AVIF su Windows con le estensioni Store**: il runner non le ha e non si
  installano senza account Store.
- **Rimozione fisica del dispositivo audio e cambio del predefinito su Windows**: la
  scheda virtuale della CI non si rimuove né si disattiva senza riavvio (pnputil: 194), e
  disattivare l'endpoint non invalida un flusso aperto (provato: 0 riaperture). Si prova
  solo il riavvio del servizio audio, che il flusso vede e da cui riparte. Un primo
  tentativo con la disattivazione dell'endpoint "passava" senza provare nulla: la prova
  ora esige che la riapertura sia avvenuta.
- **Rimozione del dispositivo audio su macOS**: nessun modo di simularla sul runner.

## Problemi residui

1. Su Windows **senza** le estensioni dello Store HEIC e AVIF non si aprono (messaggio
   chiaro). Non c'è un decoder incluso per non aggiungere HEVC (brevetti) all'installer.
2. waveOut (solo ripiego) resta con la latenza stimata: orologio ~0,1 s avanti.
3. Su Linux HEIC passa da ImageMagick: 3 s per 12 MP.
4. Cache su disco delle pagine PDF solo su Linux (su Windows e macOS il motore è in
   processo e più veloce di poppler; non ce n'è bisogno per le prove fatte).
5. Tutti i limiti di RELEASE-1.0.0.md restano, tranne quelli chiusi qui: PDF su Windows,
   latenza audio su macOS, AV1 software su macOS, decodifica hardware su Windows
   (implementata, non provata su GPU vera).
