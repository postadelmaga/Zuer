//! Thread di decodifica video con coda di frame, disaccoppiato dal present.
//!
//! Un thread dedicato POSSIEDE il `Player` e decodifica IN ANTICIPO una piccola
//! coda di frame RGBA (già scalati, pronti da presentare) con il loro pts. Il
//! present (`video.advanceVideo`) non decodifica più: legge il clock audio
//! master e sceglie dalla coda il frame più recente con `pts <= clock`,
//! scartando i più vecchi (`pickInto`). Così uno stallo di rete o un decode
//! lento NON congelano il thread di present — che continua a mostrare l'ultimo
//! frame mentre il clock audio avanza — e quando la coda si ripopola il video si
//! riaggancia scartando i frame in ritardo invece di accumularlo.
//!
//! Coda SPSC lock-free (un solo produttore = thread di decodifica, un solo
//! consumatore = present): il produttore possiede `tail`, il consumatore `head`;
//! ogni slot viene riempito PRIMA di pubblicare `tail` (release) e letto dopo un
//! `tail` acquire, quindi niente mutex (in Zig 0.16 `std.Thread.Mutex` non esiste
//! più e non vogliamo trascinare l'io di zicro in un thread di libreria). Il seek
//! NON resetta gli indici: bumpando `gen` i frame della posizione vecchia
//! diventano "stale" e `pickInto` li scarta senza presentarli — niente
//! fast-forward, niente corsa sugli indici.
//!
//! Ciclo di vita come `AudioPlayer`: `stopAndDestroy` ferma e joina il thread
//! PRIMA di chiudere il `Player`, quindi nessuna corsa sul container.

const std = @import("std");
const builtin = @import("builtin");
const player_mod = @import("decoders/player.zig");

/// Slot della coda: buffer RGBA di proprietà, riusato tra i giri (la dimensione
/// dei frame è costante per un dato video: `realloc` scatta al più una volta).
const Slot = struct {
    pixels: []u8 = &.{},
    cap: usize = 0,
    w: u32 = 0,
    h: u32 = 0,
    pts_s: f64 = 0,
    gen: u32 = 0, // epoca di produzione: != gen corrente ⇒ frame pre-seek, da scartare
};

/// Profondità della coda di read-ahead. ~8 frame ≈ 0,27 s a 30 fps: abbastanza
/// per assorbire il jitter di decode/rete senza tenere in RAM troppi frame
/// (a 1080p RGBA sono ~8 MB l'uno).
const CAP: u64 = 8;

/// Attesa del produttore quando la coda è piena (il consumatore è più lento:
/// pausa, o display più lento del decode). Polling breve, nessuna condvar.
const FULL_WAIT_MS: u64 = 4;

/// Zig 0.16 tiene i mutex bloccanti dietro `std.Io` (stesso motivo per cui la
/// coda CPU sopra usa indici atomici invece di un mutex): il pool GPU è
/// invece toccato da TRE thread — decodifica (produttore), present
/// (`pickGpu`) e finestra (il vero `wl_buffer.release`/`failed` da Zrame, via
/// `releaseGpuToken`) — uno schema a 3 vie che un semplice head/tail SPSC non
/// copre più in modo corretto. Con GPU_CAP=3 e operazioni rare (poche volte
/// al frame, più gli eventi di rilascio) uno spin su un flag lock-free è
/// enormemente più semplice di uno schema lock-free a 3 produttori/consumatori
/// fatto a mano, e il costo di contesa è trascurabile. Stessa identica forma
/// di `Zrame/src/chrome.zig`'s `SpinLock`.
const GpuLock = struct {
    flag: std.atomic.Value(bool) = .init(false),
    fn lock(self: *GpuLock) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *GpuLock) void {
        self.flag.store(false, .release);
    }
};

/// Stato di uno slot del pool GPU. `empty`: libero, il produttore può
/// scriverci. `ready`: prodotto, in attesa che il present lo scelga
/// (`pickGpu`). `presented`: preso dal present e passato a
/// `Window.presentDmabufPlanesDynamic` — resta così (fd aperti, surface VAAPI
/// viva) finché il SOLO segnale sicuro non arriva: `releaseGpuToken`,
/// chiamato dal thread finestra quando Zrame riporta `released`/`failed` per
/// il suo token (mai un timeout o un'euristica: la fase 2 usava un rilascio
/// sintetico a tempo, la fase 4 lo rimpiazza con quello vero).
const GpuSlotState = enum { empty, ready, presented };

/// Slot del pool zero-copy (dietro `ZUER_VAAPI_DMABUF`): un `GpuFrame` in
/// volo verso la presentazione. `seq` è l'ordine di produzione (per scegliere
/// il PIÙ RECENTE tra più slot `ready`, come pickInto fa per indice); `token`
/// è assegnato da `pickGpu` e riusato da Zrame/`releaseGpuToken` per
/// correlare l'evento di rilascio allo slot giusto — necessario perché,
/// diversamente dalla coda CPU, l'ordine di rilascio del compositor non è
/// garantito essere lo stesso ordine di presentazione.
const GpuSlot = struct {
    state: GpuSlotState = .empty,
    frame: player_mod.GpuFrame = undefined,
    pts_s: f64 = 0,
    gen: u32 = 0,
    seq: u64 = 0,
    token: u64 = 0,
};

/// Slot in volo nel pool GPU: deliberatamente MOLTO sotto CAP=8. Le VA
/// surface sono una risorsa scarsa condivisa col DPB del decoder (pool
/// driver ~16-20 totali) — 1 presentato, 1 pronto per lo swap immediato, 1 di
/// margine per il jitter di scheduling del compositor.
const GPU_CAP: u64 = 3;

/// Come FULL_WAIT_MS ma per il pool GPU: il consumatore (il compositor, via
/// `wl_buffer.release`) è tipicamente più lento del ring CPU.
const GPU_FULL_WAIT_MS: u64 = 4;

/// Esito di `pickInto`: se ha copiato un nuovo frame nel sink e con quale pts.
pub const Picked = struct { presented: bool = false, pts_s: f64 = 0 };

pub const VideoDecoder = struct {
    /// Esito di `pickGpu`: pronto per `Window.presentDmabufPlanesDynamic`.
    /// `token` va ripassato invariato a `releaseGpuToken` quando
    /// `Options.on_video_buffer_event` lo riporta (`released` o `failed`) —
    /// il SOLO segnale sicuro per liberare la VA surface sottostante. Nidificato
    /// (invece che a livello di modulo) così i chiamanti possono nominarlo come
    /// `VideoDecoder.GpuPick` anche attraverso lo stub senza-video di video.zig.
    pub const GpuPick = struct {
        planes: [2]player_mod.GpuPlane,
        plane_count: u8,
        fourcc: u32,
        modifier: u64,
        width: u32,
        height: u32,
        pts_s: f64,
        token: u64,
    };

    player: player_mod.Player,
    gpa: std.mem.Allocator,
    max_dim: usize,
    // Copiati all'avvio così il present li legge senza toccare il `Player`.
    duration_s: f64,
    frame_rate: f64,

    thread: ?std.Thread = null,
    ring: [CAP]Slot = [_]Slot{.{}} ** CAP,
    head: std.atomic.Value(u64) = .init(0), // consumatore: prossimo da leggere
    tail: std.atomic.Value(u64) = .init(0), // produttore: prossimo da scrivere

    // Pool zero-copy (dietro ZUER_VAAPI_DMABUF), parallelo alla coda CPU
    // sopra ma protetto da `gpu_lock` invece che da soli indici atomici (vedi
    // il commento su GpuLock: tre thread lo toccano, non due).
    gpu_ring: [GPU_CAP]GpuSlot = [_]GpuSlot{.{}} ** GPU_CAP,
    gpu_lock: GpuLock = .{},
    gpu_seq_next: u64 = 0,
    gpu_token_next: u64 = 0,
    gpu_mapped: u64 = 0,
    gpu_released: u64 = 0,
    gpu_high_water: u32 = 0,
    // Disabilita il salto del readback CPU per il RESTO di questa
    // riproduzione (mai riabilitato) — settato dal consumatore quando la
    // presentazione zero-copy fallisce (compositor senza supporto, backend
    // finestra non-Wayland, evento `.failed` persistente): senza questo il
    // produttore continuerebbe a saltare la coda CPU anche se nessuno la sta
    // più svuotando via zero-copy, congelandola sull'ultimo frame reale per
    // sempre. Stesso spirito one-shot-degrade di `Player.hwFail`.
    gpu_present_disabled: std.atomic.Value(bool) = .init(false),

    stop: std.atomic.Value(bool) = .init(false),
    // Seek richiesto (ms, -1 = nessuno). Il consumatore bumpa `gen` e lo imposta;
    // il thread riposiziona il `Player` e adotta la nuova `gen`.
    seek_ms: std.atomic.Value(i64) = .init(-1),
    gen: std.atomic.Value(u32) = .init(0),
    // Fine stream: il thread smette di produrre e attende un seek. Il LOOP è
    // guidato dal consumatore (che deve riavvolgere anche l'audio in sync).
    eof: std.atomic.Value(bool) = .init(false),

    /// Poster (primo frame) + decoder avviato. Il chiamante prende possesso di
    /// `.rgba` (→ `static_rgba`) e del decoder (chiuso da `stopAndDestroy`).
    pub const StartResult = struct { dec: *VideoDecoder, rgba: []u8, w: u32, h: u32, pts_s: f64 };

    /// Apre il container su `path_z`, decodifica il primo frame come poster (e lo
    /// semina nella coda così il present lo mostra subito), poi avvia il thread.
    pub fn start(path_z: [*:0]const u8, gpa: std.mem.Allocator, max_dim: usize) !StartResult {
        var p = try player_mod.Player.open(path_z);
        errdefer p.deinit();
        // gpu_only_ok = false: il poster/seed ha bisogno di pixel CPU veri
        // subito (diventa `static_rgba` e semina `ring[0]`), qualunque sia lo
        // stato di ZUER_VAAPI_DMABUF.
        const frame = (try p.nextFrame(max_dim, gpa, null, false)) orelse return error.NoFrameDecoded;
        const w: u32 = @intCast(frame.width);
        const h: u32 = @intCast(frame.height);
        const need = @as(usize, w) * h * 4;

        const poster = try gpa.alloc(u8, need);
        errdefer gpa.free(poster);
        @memcpy(poster, frame.pixels[0..need]);

        const self = try gpa.create(VideoDecoder);
        errdefer gpa.destroy(self);
        self.* = .{
            .player = p,
            .gpa = gpa,
            .max_dim = max_dim,
            .duration_s = p.duration_s,
            .frame_rate = p.frame_rate,
        };
        // Semina il primo frame come slot 0 (gen 0, pubblicato con tail = 1). Il
        // thread continuerà a scrivere dallo slot 1. Se l'alloc fallisce, poster
        // e decoder sono già coperti dagli errdefer sopra.
        self.ring[0].pixels = try gpa.alloc(u8, need);
        self.ring[0].cap = need;
        @memcpy(self.ring[0].pixels, frame.pixels[0..need]);
        self.ring[0].w = w;
        self.ring[0].h = h;
        self.ring[0].pts_s = frame.pts_s;
        self.tail.store(1, .release);

        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |e| {
            gpa.free(self.ring[0].pixels);
            return e;
        };
        return .{ .dec = self, .rgba = poster, .w = w, .h = h, .pts_s = frame.pts_s };
    }

    /// Ferma e joina il thread di decodifica, poi libera code, pool e `Player`.
    pub fn stopAndDestroy(self: *VideoDecoder) void {
        self.stop.store(true, .monotonic);
        if (self.thread) |t| t.join();
        // Slot GPU ancora `ready` o `presented`: nessun evento di rilascio
        // arriverà più (la finestra sta chiudendo insieme al resto), quindi
        // vanno liberati qui esplicitamente — altrimenti fd e surface VAAPI
        // restano aperti oltre la vita del decoder. Un token `presented` il
        // cui evento arriva DOPO questo punto (race di chiusura) trova
        // `releaseGpuToken` a mani vuote (nessuno slot corrisponde più): va
        // bene, `frame.release()` è già stato chiamato qui.
        self.gpu_lock.lock();
        for (&self.gpu_ring) |*s| {
            if (s.state != .empty) {
                s.frame.release();
                s.state = .empty;
            }
        }
        self.gpu_lock.unlock();
        for (&self.ring) |*s| if (s.cap > 0) self.gpa.free(s.pixels);
        self.player.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Riposiziona a `seconds`: bumpa `gen` (i frame in coda della posizione
    /// vecchia diventano stale → scartati da `pickInto`) e delega il seek del
    /// `Player` al thread. Non tocca gli indici della coda.
    ///
    /// INVARIANTE: `seekAndFlush` e `pickInto` sono chiamate dallo STESSO thread
    /// consumatore (il present), serializzate dal chiamante sotto
    /// `state.shared.mutex`. È SOLO il consumatore a bumpare `gen`, quindi entro
    /// una `pickInto` la gen è ferma e nessuno slot può avere gen > quella letta —
    /// da cui la correttezza dello scarto degli stale. Il produttore adotta la gen
    /// (non la crea). Non chiamare da un altro thread.
    pub fn seekAndFlush(self: *VideoDecoder, seconds: f64) void {
        _ = self.gen.fetchAdd(1, .monotonic);
        self.eof.store(false, .monotonic);
        self.seek_ms.store(@intFromFloat(@max(0, seconds) * 1000.0), .monotonic);
    }

    /// True quando lo stream è finito e la coda (dei frame ancora validi) è vuota:
    /// il consumatore usa questo per il loop quando la durata è ignota.
    pub fn drained(self: *VideoDecoder) bool {
        if (!self.eof.load(.monotonic)) return false;
        return self.head.load(.monotonic) == self.tail.load(.acquire);
    }

    /// Sceglie il frame più recente con `pts <= up_to_pts`, scartando i più vecchi
    /// (e quelli stale post-seek), e lo copia nel sink (riallocando `rgba` se
    /// cambia dimensione). Ritorna `presented=false` se non c'è (ancora) un frame
    /// all'altezza del clock: il present tiene l'ultimo.
    ///
    /// `force_first`: usato SUBITO dopo un seek — presenta il primo frame fresco
    /// disponibile (il frame al/dopo il target, già filtrato dallo skip del
    /// produttore) ANCHE se il suo pts è > up_to_pts. Serve a mostrare il frame di
    /// destinazione anche a video in pausa, dove `pos_s` non avanza fino a coprirlo.
    pub fn pickInto(self: *VideoDecoder, up_to_pts: f64, force_first: bool, gpa: std.mem.Allocator, rgba: *[]u8, w: *u32, h: *u32) Picked {
        const g = self.gen.load(.monotonic);
        const t = self.tail.load(.acquire);
        var hd = self.head.load(.monotonic);

        // Scarta i frame pre-seek (gen diversa): sono sempre in testa (la gen
        // cresce in modo monotono), mai presentati.
        while (hd < t and self.ring[hd % CAP].gen != g) hd += 1;
        // Scarta i frame ormai vecchi: finché ce n'è un ALTRO subito dopo ancora
        // <= target, quello in testa è superato. (Non in `force_first`: lì vogliamo
        // il PRIMO frame fresco, non l'ultimo <= clock.)
        if (!force_first) {
            while (t - hd >= 2 and self.ring[(hd + 1) % CAP].pts_s <= up_to_pts) hd += 1;
        }

        var result: Picked = .{};
        if (hd < t and (force_first or self.ring[hd % CAP].pts_s <= up_to_pts)) {
            const s = &self.ring[hd % CAP];
            const need = @as(usize, s.w) * s.h * 4;
            if (rgba.*.len != need) {
                const nb = gpa.alloc(u8, need) catch {
                    // OOM: NON toccare il sink (tieni l'ultimo frame) e lascia il
                    // frame in coda; pubblica solo gli scarti e riprova al giro dopo.
                    self.head.store(hd, .release);
                    return .{};
                };
                gpa.free(rgba.*);
                rgba.* = nb;
            }
            @memcpy(rgba.*, s.pixels[0..need]);
            w.* = s.w;
            h.* = s.h;
            result = .{ .presented = true, .pts_s = s.pts_s };
            hd += 1;
        }
        // Pubblica il nuovo head (scarti + eventuale frame consumato): libera gli
        // slot per il produttore.
        self.head.store(hd, .release);
        return result;
    }

    /// Pubblica un candidato zero-copy nel pool, con backpressure se non c'è
    /// nessuno slot `.empty` (stesso stile della coda CPU sopra: chiamato dal
    /// thread di decodifica SUBITO dopo aver preso il `GpuFrame` da
    /// `Player.takeGpuFrame`). Se lo stop arriva mentre si attende spazio, il
    /// frame viene scartato (release) invece di bloccare la chiusura.
    fn publishGpuFrame(self: *VideoDecoder, frame_in: player_mod.GpuFrame, pts_s: f64, gen: u32) void {
        var frame = frame_in;
        while (true) {
            self.gpu_lock.lock();
            for (&self.gpu_ring) |*s| {
                if (s.state != .empty) continue;
                const seq = self.gpu_seq_next;
                self.gpu_seq_next += 1;
                s.* = .{ .state = .ready, .frame = frame, .pts_s = pts_s, .gen = gen, .seq = seq };
                self.gpu_mapped += 1;
                var occ: u32 = 0;
                for (&self.gpu_ring) |*s2| {
                    if (s2.state != .empty) occ += 1;
                }
                if (occ > self.gpu_high_water) self.gpu_high_water = occ;
                self.gpu_lock.unlock();
                return;
            }
            self.gpu_lock.unlock();
            if (self.stop.load(.monotonic)) {
                frame.release();
                return;
            }
            sleepMs(GPU_FULL_WAIT_MS);
        }
    }

    /// Come `pickInto` ma per il pool zero-copy: sceglie lo slot `.ready` più
    /// recente (per `seq`) con `pts <= up_to_pts` (o il primo fresco con
    /// `force_first`), e RILASCIA (non solo scarta — sono VA surface, non
    /// byte posseduti) gli slot `.ready` di una gen precedente (post-seek) o
    /// superati da uno più recente. Lo slot scelto passa a `.presented` con
    /// un token nuovo: resta vivo finché il chiamante non lo passa a
    /// `releaseGpuToken` dopo `Options.on_video_buffer_event`. `null` se
    /// nessuno slot è pronto e all'altezza del clock (il chiamante tiene il
    /// frame già presentato).
    pub fn pickGpu(self: *VideoDecoder, up_to_pts: f64, force_first: bool) ?GpuPick {
        self.gpu_lock.lock();
        defer self.gpu_lock.unlock();
        const g = self.gen.load(.monotonic);
        var best: ?usize = null;
        for (&self.gpu_ring, 0..) |*s, i| {
            if (s.state != .ready) continue;
            if (s.gen != g) {
                s.frame.release();
                s.state = .empty;
                continue;
            }
            if (!(force_first or s.pts_s <= up_to_pts)) continue;
            if (best) |b| {
                if (s.seq > self.gpu_ring[b].seq) {
                    self.gpu_ring[b].frame.release();
                    self.gpu_ring[b].state = .empty;
                    best = i;
                } else {
                    s.frame.release();
                    s.state = .empty;
                }
            } else {
                best = i;
            }
        }
        const bi = best orelse return null;
        const s = &self.gpu_ring[bi];
        s.state = .presented;
        const token = self.gpu_token_next;
        self.gpu_token_next += 1;
        s.token = token;
        return .{
            .planes = s.frame.planes,
            .plane_count = s.frame.plane_count,
            .fourcc = s.frame.fourcc,
            .modifier = s.frame.modifier,
            .width = s.frame.width,
            .height = s.frame.height,
            .pts_s = s.pts_s,
            .token = token,
        };
    }

    /// Disabilita per SEMPRE (per il resto di questa riproduzione) il salto
    /// del readback CPU: il produttore torna a popolare la coda CPU su ogni
    /// frame come se `ZUER_VAAPI_DMABUF` non fosse mai stato impostato.
    /// Chiamato dal consumatore quando la presentazione zero-copy si è
    /// dimostrata non praticabile per questo stream (compositor che rifiuta
    /// il present, backend finestra senza dmabuf) — vedi il commento su
    /// `gpu_present_disabled`.
    pub fn disableGpuPresent(self: *VideoDecoder) void {
        self.gpu_present_disabled.store(true, .monotonic);
    }

    /// Chiamato (dal thread finestra, tramite `Options.on_video_buffer_event`)
    /// quando Zrame riporta `released`/`failed` per un token da `pickGpu`:
    /// libera la VA surface sottostante e restituisce lo slot al produttore.
    /// `false` se il token non corrisponde a nessuno slot `.presented` —
    /// atteso in una race di chiusura (vedi `stopAndDestroy`), mai altrove.
    pub fn releaseGpuToken(self: *VideoDecoder, token: u64) bool {
        self.gpu_lock.lock();
        defer self.gpu_lock.unlock();
        for (&self.gpu_ring) |*s| {
            if (s.state == .presented and s.token == token) {
                s.frame.release();
                s.state = .empty;
                self.gpu_released += 1;
                if (self.gpu_released % 60 == 0) {
                    std.log.info("zuer video: [gpu pool debug] mapped={d} released={d} high_water={d}", .{
                        self.gpu_mapped, self.gpu_released, self.gpu_high_water,
                    });
                }
                return true;
            }
        }
        return false;
    }

    fn threadMain(self: *VideoDecoder) void {
        var prod_gen: u32 = self.gen.load(.monotonic);
        // Soglia post-seek (-1 = nessuna): `seek(BACKWARD)` atterra al keyframe
        // PRECEDENTE il target, quindi i primi frame decodificati sono pre-target.
        // Passata a `nextFrame`, che li scarta INTERNAMENTE a costo quasi zero
        // (niente download/scale, vedi player.zig) — altrimenti, con la coda di
        // sole CAP posizioni, sfilerebbero nel present a velocità di decodifica
        // (fast forward). Come lo `skip_until_s` del thread audio.
        var prod_skip_until: f64 = -1;
        while (!self.stop.load(.monotonic)) {
            const sk = self.seek_ms.swap(-1, .monotonic);
            if (sk >= 0) {
                const target = @as(f64, @floatFromInt(sk)) / 1000.0;
                self.player.seek(target);
                self.eof.store(false, .monotonic);
                prod_gen = self.gen.load(.monotonic); // adotta l'epoca del seek
                prod_skip_until = target;
            }
            if (self.eof.load(.monotonic)) {
                // Stream finito: niente da produrre finché il consumatore non fa
                // ripartire con un seek (loop) o si naviga via (stop).
                sleepMs(8);
                continue;
            }
            // Backpressure: attendi spazio (il consumatore ha liberato uno slot).
            while (self.tail.load(.monotonic) - self.head.load(.acquire) >= CAP) {
                if (self.stop.load(.monotonic) or self.seek_ms.load(.monotonic) >= 0) break;
                sleepMs(FULL_WAIT_MS);
            }
            if (self.stop.load(.monotonic) or self.seek_ms.load(.monotonic) >= 0) continue;

            // Zero-copy ammesso per QUESTO frame solo se il flag globale è
            // attivo E la presentazione non l'ha già disabilitato per questo
            // stream (vedi disableGpuPresent — un present rifiutato dal
            // compositor, o il backend finestra senza supporto dmabuf, non
            // deve far restare la coda CPU congelata per il resto della
            // riproduzione).
            const gpu_only_ok = player_mod.vaapiDmabufEnabled() and
                self.player.hw_active and
                !self.gpu_present_disabled.load(.monotonic);
            const maybe = self.player.nextFrame(self.max_dim, self.gpa, if (prod_skip_until >= 0) prod_skip_until else null, gpu_only_ok) catch {
                // Errore di decode (packet corrotto) ≠ EOF: salta e riprova.
                sleepMs(4);
                continue;
            };
            const fr = maybe orelse {
                self.eof.store(true, .monotonic);
                continue;
            };
            // Un seek è arrivato mentre decodificavamo: scarta questo frame (è
            // della posizione vecchia), lo gestiamo al prossimo giro.
            if (self.seek_ms.load(.monotonic) >= 0) continue;
            // Il Player ha già scartato internamente i frame pre-target (senza
            // download/scale, vedi nextFrame/skip_before_pts): quello ricevuto
            // è già >= target, lo skip è chiuso.
            prod_skip_until = -1;

            // `fr.gpu_only`: il readback CPU è stato saltato DEL TUTTO (vedi
            // Player.frameFromCurrent) — niente da copiare nella coda CPU,
            // che resta ferma all'ultimo frame reale (fallback pronto se lo
            // zero-copy si disabilita più avanti). Altrimenti, percorso di
            // sempre: copia nello slot di proprietà e pubblica.
            if (!fr.gpu_only) {
                const w: u32 = @intCast(fr.width);
                const h: u32 = @intCast(fr.height);
                const need = @as(usize, w) * h * 4;
                const t = self.tail.load(.monotonic);
                const slot = &self.ring[t % CAP];
                if (slot.cap < need) {
                    const nb = self.gpa.realloc(slot.pixels, need) catch {
                        sleepMs(4); // niente memoria per lo slot: rinuncia a questo frame
                        continue;
                    };
                    slot.pixels = nb;
                    slot.cap = need;
                }
                // Copia SUBITO lo scratch del player (valido solo fino al
                // prossimo nextFrame) nello slot di proprietà, poi pubblica.
                @memcpy(slot.pixels[0..need], fr.pixels[0..need]);
                slot.w = w;
                slot.h = h;
                slot.pts_s = fr.pts_s;
                slot.gen = prod_gen;
                self.tail.store(t + 1, .release);
            }

            // Se un candidato zero-copy è stato prodotto per questo stesso
            // frame (vedi Player.frameFromCurrent — capita anche quando
            // `gpu_only_ok` era false, es. il primo frame dopo l'apertura),
            // pubblicalo nel pool GPU.
            if (player_mod.vaapiDmabufEnabled() and self.player.hw_active) {
                if (self.player.takeGpuFrame()) |gf| self.publishGpuFrame(gf, fr.pts_s, prod_gen);
            }
        }
    }
};

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

fn sleepMs(ms: u64) void {
    if (comptime builtin.os.tag == .windows) {
        Sleep(@intCast(ms));
    } else {
        const req = std.c.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&req, null);
    }
}
