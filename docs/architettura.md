# Architettura di Zuer

Come è fatto dentro: moduli, plugin, concorrenza, miniature e misure. Per compilare: [sviluppo.md](sviluppo.md).

Due frontend condividono lo stesso stack di decodifica e rendering:

```
 zuer (TUI)   tui.zig ── loader.zig ─┐
                                     ├─ decoder.zig ── plugin (decoders/*.zig → .so/.dll):
 zuer-gui     gui.zig ── nav.zig ────┘   registro,       text, csv, markdown, image, glb, mesh,
                                         dispatch,       archive, tar, media, pdf, office
                                         estrazione

 rendering GPU:  gpu_renderer.zig (Vulkan) · renderer/vk.zig (binding) · voxel.zig · vtex.zig
 rendering CPU:  text_render.zig · md_layout.zig · glyph.zig (stb_truetype) · compose.zig
 per sistema:    terminal.zig · clipboard.zig · dynlib.zig · proc.zig · diskcache.zig
                 (finestra, input e audio: zicro/zrame)
```

## Moduli

**TUI** (`main.zig`): un documento zicro con lo stato in `state.zig`, la vista in
`tui.zig` e il piano dati in `loader.zig` (decodifica su un thread, risultato come
azione).

**GUI** (`gui.zig`: avvio, finestra, render worker), divisa per mestiere:

- **`gui_state.zig`** — `GuiAppState`, lo stato condiviso fra thread finestra, render
  worker, loader e prefetch. I campi sono raggruppati per lock (`shared`, `nav`, `pf`):
  quale mutex protegge cosa si legge lì.
- **`nav.zig`** — il piano dati della GUI: navigazione fra i file della cartella,
  caricamento asincrono «vince l'ultimo» (`postLoad`/`loadWorker`), decode iniziale,
  prefetch dei vicini, e `applyDecoded`, l'unico punto che installa un contenuto nel
  renderer. Da `loader.zig` prende solo lo staging della geometria verso la GPU
  (`GpuStage`: memfd zero-copy su Linux, buffer CPU altrove).
- **`input.zig`** — i tre callback di zrame (tastiera, rotella, mouse), doppio click,
  selezione del testo e comandi di vista (zoom, pan, scorrimento, pagina PDF).
- **`layout.zig`** — dal percorso o dal contenuto decodificato al tipo di finestra
  (`WinKind`), e da lì a zoom e dimensione iniziale.
- **`compose.zig`** — composizione CPU dei frame (immagini adattate con zoom e pan,
  testo 1:1 con intestazione ancorata, selezione, barra delle linguette).
- **overlay** — `file_explorer.zig` (tasto `e`, con le miniature di `thumbs.zig`),
  `yt_search.zig` (tasto `y`, attraverso `ytdlp.zig`), `print.zig` (Ctrl+P).
- **media** — `video.zig`, `video_decoder.zig` e i due motori: vedi [Media](#media).

## Plugin e formati

I **decoder** sono librerie dinamiche caricate a richiesta (`libdecoder_<nome>.so`,
`decoder_<nome>.dll`); su Android sono linkati nell'unica libreria dell'APK. Il
contratto sta in tre file:

- **`formats.zig`** — l'unica tabella «quale plugin apre quale estensione». Da lì
  vengono le estensioni che ogni plugin dichiara, il manifest con cui l'host carica il
  solo plugin che serve (invece di aprirli tutti), gli archivi di cui si apre una voce
  (`fragment.zig`) e le liste con cui la GUI sceglie la forma della finestra prima del
  decode. Un test lega le une alle altre.
- **`decoder_abi.zig`** — i tipi del risultato (`Decoded`), il loro layout C
  (`DecodedC`) con i convertitori nelle due direzioni, la versione dell'ABI (impronta
  a comptime della versione di Zig: host e plugin compilati con Zig diversi non si
  caricano) e `exportPlugin`.
- **`decoder.zig`** — l'host: registro dei plugin, dispatch per estensione e per
  contenuto (`detect.zig`), estrazione delle voci d'archivio (`extract_cache.zig`).
  Riesporta tutto il contratto: i plugin importano solo `decoder`.

Aggiungere un decoder = un file in `src/decoders/` con `plugin_name`, `pluginDecode`
e `comptime { decoder.exportPlugin(@This()); }`, una riga in `formats.zig` e una voce
nella lista di `build.zig`. Facoltativi: `pluginDecodeCoarse` (prima fase veloce),
`plugin_content_prefix` (quanti byte del file servono; 0 = solo il percorso),
`pluginSetHost` (servizi dell'host, vedi [Concorrenza](#concorrenza)).

Dentro un plugin l'`io` dell'host non funziona (non attraversa il confine della
libreria dinamica): file e processi passano da chiamate grezze, raccolte in due file.

- **`proc.zig`** — l'unico posto da cui si lanciano processi: `runCapture…` (stdout
  catturato, scadenza, tetto sui byte, annullamento), `runDetached` (deve solo
  partire: `xdg-open`), `runFeed` (gli si scrive lo stdin: `wl-copy`). Sempre argv,
  mai una shell. Su Unix il figlio ha un gruppo di processi suo e alla scadenza muore
  tutto il gruppo.
- **`diskcache.zig`** — le primitive delle cache su disco: cartella per sistema
  (`~/.cache/zuer/<nome>`, `%LOCALAPPDATA%\zuer\<nome>`), scrittura atomica con
  pulizia del temporaneo (`AtomicWriter`), tetto LRU e sweep dei temporanei orfani
  (solo Linux).

| Cache | Dove | Tetto | Chiave |
|---|---|---|---|
| mesh coarse (`meshcache.zig`) | `mesh/` | 1 GiB | percorso reale; valida per mtime + dimensione + checksum |
| texture decodificate (`decoders/texcache.zig`) | `tex/` | 256 MiB | hash dei byte codificati |
| pagine PDF (`decoders/pdf.zig`) | `pdf/` | 256 MiB | percorso, dimensione, mtime, pagina, risoluzione |
| tile delle texture (`vtcache.zig`) | `vt/` | 512 MiB | dimensioni e hash dei pixel |
| miniature (`thumbs.zig`) | `thumbs/` | 128 MiB | cartella reale, nome, mtime, dimensione |
| voci estratte dagli archivi (`extract_cache.zig`) | `extract/` | 2 GiB | percorso + mtime dell'archivio |

Mesh, texture e pagine PDF sono attive solo su Linux. Le altre ovunque; il tetto di
tile e miniature però si applica solo su Linux (la cache d'estrazione ha il suo).

## Media

Un file audio o video non passa dal decode come gli altri: il plugin `media` ne
produce solo la scheda (poster, durata, tag), e la riproduzione è una **sessione**.

- **`video.zig`** — il lato GUI: apre e chiude la sessione, avanza la riproduzione
  dentro il render loop, disegna controlli, oscilloscopio e sottotitoli.
- **`video_decoder.zig`** — la sessione: un thread dedicato che possiede il motore e
  produce frame per il present attraverso una coda SPSC senza lock (`wake.zig` per le
  sveglie). Un seek non svuota la coda: alza una generazione, e i frame vecchi
  vengono scartati.
- **Due motori**, scelti all'apertura:
  - **mpv** (`decoders/mpv_video.zig`, Linux, preferito): demux, decodifica (hardware
    quando c'è), audio, sincronia, seek, rete. Il suo clock è l'autorità. Rende in un
    FBO su un contesto EGL suo; il motore sopravvive alla sessione e il video dopo lo
    riusa.
  - **FFmpeg** (`decoders/player.zig`, ripiego: niente libmpv, Windows, macOS):
    decodifica in anticipo una coda di frame con il loro pts; l'audio e il clock sono
    di `audio_player.zig`, pilotato da `video.zig`.
- **Solo audio**: stesso percorso, senza traccia video si disegna l'oscilloscopio.
  I MIDI suonano con il synth incluso (TinySoundFont).
- **YouTube**: `yt_search.zig` risolve gli URL con `yt-dlp` e li passa alla sessione;
  video e audio DASH separati li unisce mpv.

## Concorrenza

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

## File aperti dal sistema (Finder, `open -a`)

Su macOS un file aperto dal Finder non arriva in argv. macOS lancia l'app e le
manda un Apple Event (`kAEOpenDocuments`); AppKit lo passa al delegate
`application:openURLs:` di Zicro (`window_cocoa.zig`), che chiama `on_open_file` con
`[url path]`. In Zuer (`gui.openFileFromSystem` → `file_explorer.openFromSystem`)
questo equivale a lanciare `zuer-gui <percorso>`:

- la callback gira sul thread finestra, dentro `win.run()`, a stato inizializzato;
- il caricamento passa da `nav.postLoad`, latest-wins. Zuer mostra un documento alla
  volta: di un evento con più file li apre tutti, in ordine, e resta sull'ultimo; le
  frecce scorrono poi la sua cartella. Un file mancante in mezzo è segnalato e non
  ferma gli altri. Un secondo evento mentre il loader decodifica sostituisce il primo;
- il file iniziale (`decodeInitial`) riceve la generazione letta prima di creare il suo
  thread, quindi non si installa sopra un file chiesto nel frattempo;
- un file che non si può aprire mostra un messaggio al posto del contenuto
  (`nav.showMessage`), non solo una riga su stderr.

**Errori e cache di prefetch.** Il contenuto che si lascia viene parcheggiato nella
cache sotto il suo percorso (`parkOutgoingLocked`), così tornando indietro non si
ridecodifica. Un messaggio d'errore (file non trovato, permessi, decode fallito) non
è il contenuto del file: lo si installa con `applyMessage`, che marca
`shared.decoded_is_message`, e non viene mai parcheggiato. Altrimenti un file creato
o reso leggibile dopo, riaperto allo stesso percorso, mostrerebbe l'errore di prima.
Il prefetch già scartava i decode falliti.

**Accenti in un'altra forma Unicode** (`src/unicode_path.zig`). Gli URL dei file
arrivano con gli accenti decomposti (NFD, HFS+): `NSURL fileURLWithPath:` →
`CFURLCreateWithFileSystemPath` → `CFStringGetFileSystemRepresentation` decompone già
nel processo che manda l'evento. Il nome originale non viaggia nell'evento.

- **macOS:** APFS e HFS+ aprono il file in entrambe le forme, quindi non serve altro.
- **Darling:** fa lo stesso su un filesystem Linux, che confronta i byte: `città.png`
  salvato composto arriva come `citta` + U+0300 e non esiste.
- **Linux:** succede anche a un file copiato da un Mac (nome decomposto) quando lo si
  apre scrivendo il nome a mano.

`findEquivalent` interviene solo se il percorso ricevuto dà `FileNotFound` e può avere
un'altra forma. Succede quando contiene byte non ASCII, oppure `;`, `` ` `` o `K`: sono
la NFD di U+037E, U+1FEF e U+212A, e da macOS o Darling quei nomi arrivano in ASCII
(`ascii_nfd_targets`, generato). Per ogni componente che non esiste elenca la sola cartella che lo
contiene, senza ricorsione, e prende la voce con la stessa NFD:

- se le voci equivalenti sono più d'una (su Linux possono coesistere) dà
  `AmbiguousName` e non ne sceglie nessuna;
- il nome usato è quello del disco, quindi lo sono anche l'etichetta e le frecce;
- il confronto è solo canonico. Maiuscole e minuscole contano: su Windows un nome
  che differisce sia per forma Unicode sia per maiuscole non si ritrova.

Lo usano `openFromSystem` e l'argomento da riga di comando (`nav.resolveInitialFile`).
La NFD è completa (Unicode 16, Hangul compreso) e le tabelle sono generate da
`scripts/gen-unicode-nfd.py`. Su tutti i codepoint e su 50.000 stringhe casuali con
più segni combinanti coincide con `unicodedata` di Python.

Costo: nessuno se il file esiste. Nel caso di ripiego, circa 7 ms per una cartella di
10.000 voci, di cui circa 4,5 ms per la sola lettura della cartella e circa 250 ns
per nome.

Prova d'integrazione sotto Darling: `scripts/darling-open-check.py <Zuer.app>`.
Copre ASCII, NFC e NFD, cold launch e istanza aperta, cartella accentata, giapponese e
coreano, punto interrogativo greco, file inesistente, nomi ambigui, più documenti
(anche con un file mancante in mezzo), secondo evento a loader occupato, errore in
cache poi file creato (ASCII e Unicode). Uccide per PID solo i processi del bundle di
prova.

## Miniature dell'esploratore

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

Portabilità: zicro e zrame nascondono le differenze di OS (finestra, input,
dynamic loading) dietro API uniformi, così zuer resta in gran parte agnostico rispetto
alla piattaforma. I punti che restano specifici sono isolati in file per-OS
(`terminal.zig`, `clipboard.zig`, `dynlib.zig`, `proc.zig`, `diskcache.zig`) o dietro
flag comptime.

## Benchmark (riferimento)

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

### Prestazioni della GUI (novembre 2026)

Stessa macchina, Zig 0.17.1, ReleaseSafe, sway headless (pixman), `HOME` vuota per ogni
esecuzione. I tempi vengono da una sonda temporanea (mai committata) che stampa primo
frame, fasi decode/prep/apply, navigazione e compose per frame. Serie finale alternata
fra la 0.4.0 (`dab62e1`) e i quattro interventi (`fde4917`…`e50c3df`), 5 round,
mediana [min–max], carico 0,9–2,4 con una VM di un'altra sessione su un core. Le
misure per singolo intervento sono nei messaggi di commit.

| scenario | 0.4.0 | dopo |
|---|---|---|
| apertura JPEG 2048², primo frame | 313 [287–399] ms | **163** [124–252] ms |
| apertura PNG enorme | 2510 [2476–3571] ms | **2040** [1978–2112] ms |
| apertura markdown da 641 KB | 174 [156–235] ms | **104** [96–115] ms |
| apertura glb a freddo (4 texture 1024²), fase prep | 433 [416–693] ms | **236** [225–272] ms |
| relayout del markdown allo zoom | 157 [132–221] ms | **109** [87–183] ms |
| frecce: markdown | 193 [156–370] ms | **141** [108–242] ms |
| frecce: immagine non precaricata | 301 [81–647] ms | **232** [103–597] ms |
| miniature con cache calda (57 file, 2 job) | 2547 [1993–3053] ms | **38** [18–53] ms |

La riga delle miniature viene dalla serie del suo commit (`bench-thumbnails`, 5 round
alternati). Con la cache calda costano anche meno CPU (2481 → 38 ms) e meno RSS (353 →
91 MB): prima le miniature quadrate 256×256 non si rileggevano mai dalla cache. Il primo
frame del glb segue di poco (1304 → 1267 ms), perché in questa serie dominava la fase
apply (~600 ms, GPU), uguale prima e dopo. In un'altra finestra, con apply a ~200 ms,
lo stesso intervento ha portato il primo frame da 1119 a 864 ms. Restano nella
dispersione l'apertura di testo, CSV, PDF e archivi, il compose per frame (zoom di
immagini: serie mirata di 8 round, 11,6 contro 11,3 ms), la CPU a riposo e la RSS. Le
uscite non cambiano di un byte: pixel decodificati (con e senza `ZUER_GUI=1`), miniature,
PDF di stampa e file `.vtc` sono identici alla 0.4.0.

Provati e scartati, perché il guadagno non usciva dal rumore:
- conversione RGB→RGBA più veloce: il ciclo vale ~6 ms, il resto è l'allocatore, che in
  ReleaseSafe azzera e non riusa;
- bilineare di `composeFrame` a due canali per moltiplicazione: il compilatore vettorizza
  già il ciclo, la variante è più lenta del 14%;
- tabelle di colonna precalcolate per frame: +2,5%.

