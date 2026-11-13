# Architettura di Zuer

Come è fatto dentro: moduli, plugin, concorrenza, miniature e misure. Per compilare: [sviluppo.md](sviluppo.md).

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
- il caricamento passa da `nav.postLoad`, latest-wins: con più file in un evento, o un
  secondo evento mentre il loader decodifica, si vede l'ultimo. Il file iniziale
  (`decodeInitial`) riceve la generazione letta prima di creare il suo thread, quindi
  non si installa sopra un file chiesto nel frattempo;
- un file che non si può aprire mostra un messaggio al posto del contenuto
  (`nav.showMessage`), non solo una riga su stderr.

**Accenti in un'altra forma Unicode** (`src/unicode_path.zig`). Gli URL dei file
arrivano con gli accenti decomposti (NFD, HFS+): `NSURL fileURLWithPath:` →
`CFURLCreateWithFileSystemPath` → `CFStringGetFileSystemRepresentation` decompone già
nel processo che manda l'evento. Il nome originale non viaggia nell'evento.

- **macOS:** APFS e HFS+ aprono il file in entrambe le forme, quindi non serve altro.
- **Darling:** fa lo stesso su un filesystem Linux, che confronta i byte: `città.png`
  salvato composto arriva come `citta` + U+0300 e non esiste.
- **Linux:** succede anche a un file copiato da un Mac (nome decomposto) quando lo si
  apre scrivendo il nome a mano.

`findEquivalent` interviene solo se il percorso ricevuto dà `FileNotFound` e contiene
byte non ASCII. Per ogni componente che non esiste elenca la sola cartella che lo
contiene, senza ricorsione, e prende la voce con la stessa NFD:

- se le voci equivalenti sono più d'una (su Linux possono coesistere) dà
  `AmbiguousName` e non ne sceglie nessuna;
- il nome usato è quello del disco, quindi lo sono anche l'etichetta e le frecce.

Lo usano `openFromSystem` e l'argomento da riga di comando (`nav.resolveInitialFile`).
La NFD è completa (Unicode 16, Hangul compreso) e le tabelle sono generate da
`scripts/gen-unicode-nfd.py`. Su tutti i codepoint e su 50.000 stringhe casuali con
più segni combinanti coincide con `unicodedata` di Python.

Costo: nessuno se il file esiste. Nel caso di ripiego, circa 7 ms per una cartella di
10.000 voci, di cui circa 4,5 ms per la sola lettura della cartella e circa 250 ns
per nome.

Prova d'integrazione sotto Darling: `scripts/darling-open-check.py <Zuer.app>`.
Copre ASCII, NFC e NFD, cold launch e istanza aperta, cartella accentata, giapponese e
coreano, file inesistente, nomi ambigui, più documenti, secondo evento a loader
occupato.

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

Portabilità: zicro e zrame nascondono le differenze di OS (finestra, input, clipboard,
dynamic loading) dietro API uniformi, così zuer resta in gran parte agnostico rispetto
alla piattaforma. I punti che restano specifici sono isolati in file per-OS
(`terminal.zig`, `clipboard.zig`, `dynlib.zig`) o dietro flag comptime.

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
