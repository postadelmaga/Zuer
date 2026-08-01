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

/// Esito di `pickInto`: se ha copiato un nuovo frame nel sink e con quale pts.
pub const Picked = struct { presented: bool = false, pts_s: f64 = 0 };

pub const VideoDecoder = struct {
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
        const frame = (try p.nextFrame(max_dim, gpa)) orelse return error.NoFrameDecoded;
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

    /// Ferma e joina il thread, poi libera coda e `Player`.
    pub fn stopAndDestroy(self: *VideoDecoder) void {
        self.stop.store(true, .monotonic);
        if (self.thread) |t| t.join();
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

    fn threadMain(self: *VideoDecoder) void {
        var prod_gen: u32 = self.gen.load(.monotonic);
        // Soglia post-seek (-1 = nessuna): `seek(BACKWARD)` atterra al keyframe
        // PRECEDENTE il target, quindi i primi frame decodificati sono pre-target.
        // Vanno SCARTATI qui (non accodati), altrimenti — con la coda di sole CAP
        // posizioni — sfilerebbero nel present a velocità di decodifica (fast
        // forward). Come lo `skip_until_s` del thread audio.
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

            const maybe = self.player.nextFrame(self.max_dim, self.gpa) catch {
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
            // Scarta i frame tra il keyframe e il target (mai accodati): il primo
            // frame >= target chiude lo skip e viene accodato normalmente.
            if (prod_skip_until >= 0) {
                if (fr.pts_s < prod_skip_until) continue;
                prod_skip_until = -1;
            }

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
            // Copia SUBITO lo scratch del player (valido solo fino al prossimo
            // nextFrame) nello slot di proprietà, poi pubblica.
            @memcpy(slot.pixels[0..need], fr.pixels[0..need]);
            slot.w = w;
            slot.h = h;
            slot.pts_s = fr.pts_s;
            slot.gen = prod_gen;
            self.tail.store(t + 1, .release);
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
