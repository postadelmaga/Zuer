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

// Backend video hardware-accelerato via libmpv (render API): Linux-only, gate
// a livello di TIPO (non solo runtime) perché mpv_video.zig fa @cImport di
// header (mpv/EGL) che su Windows/macOS non esistono — stesso pattern già
// usato per cvp9 in decoders/player.zig. Preferito quando disponibile;
// altrove (o se l'init fallisce) resta il Player FFmpeg esistente sotto,
// invariato.
const mpv_enabled = builtin.os.tag == .linux and @import("build_options").mpv;
const mpv_video = if (mpv_enabled) @import("decoders/mpv_video.zig") else struct {
    pub const MpvVideo = struct {};
};

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
    // Taglia di presentazione (fit-rect della finestra) richiesta dal present:
    // il produttore scala i frame direttamente a questa dimensione (0 = ignota).
    target_w: std.atomic.Value(u32) = .init(0),
    target_h: std.atomic.Value(u32) = .init(0),
    // Seek richiesto (ms, -1 = nessuno). Il consumatore bumpa `gen` e lo imposta;
    // il thread riposiziona il `Player` e adotta la nuova `gen`.
    seek_ms: std.atomic.Value(i64) = .init(-1),
    gen: std.atomic.Value(u32) = .init(0),
    // Fine stream: il thread smette di produrre e attende un seek. Il LOOP è
    // guidato dal consumatore (che deve riavvolgere anche l'audio in sync).
    eof: std.atomic.Value(bool) = .init(false),

    // Backend mpv (preferito quando disponibile): non-null ⇒ `threadMain`
    // gira su mpv invece che sul `Player` FFmpeg diretto (che resta comunque
    // aperto sopra, per il poster e come fallback se l'init mpv fallisce).
    mpv: if (mpv_enabled) ?mpv_video.MpvVideo else void = if (mpv_enabled) null else {},
    // Copia di proprietà del path (mpv carica il file per conto suo, con la
    // propria `loadFile`/i propri comandi di seek — non passa dal `Player`).
    path_owned: [:0]const u8 = &[_:0]u8{},
    // Pausa richiesta per mpv (letta dal thread di decodifica, scritta dal
    // present via `setPlaying`): mpv pacing è indipendente dal nostro ring,
    // quindi la pausa lato Zuer (smettere di drenare) da sola non lo ferma.
    mpv_pause_req: if (mpv_enabled) std.atomic.Value(bool) else void = if (mpv_enabled) .init(false) else {},

    /// Poster (primo frame) + decoder avviato. Il chiamante prende possesso di
    /// `.rgba` (→ `static_rgba`) e del decoder (chiuso da `stopAndDestroy`).
    pub const StartResult = struct { dec: *VideoDecoder, rgba: []u8, w: u32, h: u32, pts_s: f64 };

    /// Apre il container su `path_z`, decodifica il primo frame come poster (e lo
    /// semina nella coda così il present lo mostra subito), poi avvia il thread.
    pub fn start(path_z: [*:0]const u8, gpa: std.mem.Allocator, max_dim: usize) !StartResult {
        var p = try player_mod.Player.open(path_z);
        errdefer p.deinit();
        const frame = (try p.nextFrame(max_dim, gpa, null)) orelse return error.NoFrameDecoded;
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

        // Path di proprietà per mpv (se disponibile — la sua init/loadFile
        // girano DENTRO il thread, vedi `threadEntry`: EGL lega il contesto al
        // thread chiamante, quindi deve essere lo STESSO thread che poi fa
        // `mpv_render_context_render`, non quello che chiama `start()`).
        if (comptime mpv_enabled) {
            self.path_owned = gpa.dupeZ(u8, std.mem.span(path_z)) catch &[_:0]u8{};
        }
        self.thread = std.Thread.spawn(.{}, threadEntry, .{self}) catch |e| {
            gpa.free(self.ring[0].pixels);
            return e;
        };
        return .{ .dec = self, .rgba = poster, .w = w, .h = h, .pts_s = frame.pts_s };
    }

    /// Ferma e joina il thread, poi libera coda, backend mpv (se attivo) e `Player`.
    pub fn stopAndDestroy(self: *VideoDecoder) void {
        self.stop.store(true, .monotonic);
        if (self.thread) |t| t.join();
        for (&self.ring) |*s| if (s.cap > 0) self.gpa.free(s.pixels);
        if (comptime mpv_enabled) {
            if (self.mpv) |*mv| mv.deinit();
            if (self.path_owned.len > 0) self.gpa.free(self.path_owned);
        }
        self.player.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Propaga play/pausa al backend mpv (se attivo). No-op per il backend
    /// FFmpeg, che già si ferma per backpressure (il ring smette di svuotarsi).
    /// Comunica al produttore la taglia a cui presentare (fit-rect corrente):
    /// i frame successivi arrivano già a quella dimensione, filtrati bene, e il
    /// compositore li copia 1:1 invece di ricampionarli nearest.
    pub fn setTargetSize(self: *VideoDecoder, w: u32, h: u32) void {
        if (self.target_w.load(.monotonic) == w and self.target_h.load(.monotonic) == h) return;
        if (std.c.getenv("ZUER_TRACE") != null) std.debug.print("[trace] video target {d}x{d}\n", .{ w, h });
        self.target_w.store(w, .monotonic);
        self.target_h.store(h, .monotonic);
    }

    pub fn setPlaying(self: *VideoDecoder, playing: bool) void {
        if (comptime mpv_enabled) self.mpv_pause_req.store(!playing, .monotonic);
    }

    /// Se il backend attivo è mpv, forza una risincronizzazione dura verso
    /// `seconds`. mpv pacing è indipendente dal ring (non "libero" come il
    /// `Player` FFmpeg, che decodifica al massimo consentito dalla
    /// backpressure): una grande deriva rispetto al clock audio non si
    /// riassorbe scartando frame dal ring come per FFmpeg, va tradotta in un
    /// vero comando di seek verso mpv (stesso canale di `seekAndFlush`, usato
    /// anche per i seek manuali dell'utente).
    pub fn resyncIfMpv(self: *VideoDecoder, seconds: f64) void {
        if (comptime mpv_enabled) {
            if (self.mpv != null) self.seekAndFlush(seconds);
        }
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
            // Zero-copy: lo slot cede il suo buffer al sink e prende in cambio il
            // vecchio buffer del sink (riusato al prossimo produce). Era un memcpy
            // da ~8 MB per frame a 1080p sul thread di present, sotto lock.
            // `rgba.len` può essere ≥ w*h*4 (capacità dello slot): i consumatori
            // indicizzano su w/h e `free` usa la lunghezza piena dell'allocazione.
            const old = rgba.*;
            rgba.* = s.pixels[0..s.cap];
            s.pixels = old;
            s.cap = old.len;
            _ = gpa;
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

    /// Unico entry point del thread: tenta l'init di mpv QUI (non in `start()`)
    /// perché EGL lega il contesto al thread che chiama `eglMakeCurrent` — deve
    /// essere lo stesso thread che poi chiama `mpv_render_context_render`,
    /// altrimenti le chiamate GL falliscono silenziosamente (visto in pratica:
    /// frame grigio piatto, contesto "current" sul thread sbagliato). Se mpv
    /// non è disponibile o l'init fallisce, ripiega su `threadMain` (Player
    /// FFmpeg diretto, già aperto da `start()`), sullo stesso thread.
    fn threadEntry(self: *VideoDecoder) void {
        if (comptime mpv_enabled) {
            if (self.path_owned.len > 0) {
                if (mpv_video.MpvVideo.init()) |mv| {
                    self.mpv = mv;
                    self.mpv.?.loadFile(self.path_owned);
                    threadMainMpvLoop(self);
                    return;
                } else |e| {
                    std.log.warn("zuer video: init mpv fallita ({}), uso il decoder FFmpeg esistente", .{e});
                }
            }
        }
        threadMain(self);
    }

    /// Come `threadMain`, ma il produttore è mpv (`self.mpv`) invece del
    /// `Player` FFmpeg diretto: stessa coda, stesso protocollo gen/stale, la
    /// differenza è solo COME si ottiene il prossimo frame RGBA. Chiamata da
    /// `threadEntry` sullo STESSO thread che ha inizializzato mpv (vedi sopra).
    fn threadMainMpvLoop(self: *VideoDecoder) void {
        var prod_gen: u32 = self.gen.load(.monotonic);
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.gpa);
        var applied_pause = false;
        while (!self.stop.load(.monotonic)) {
            const want_pause = self.mpv_pause_req.load(.monotonic);
            if (want_pause != applied_pause) {
                self.mpv.?.setPaused(want_pause);
                applied_pause = want_pause;
            }
            const sk = self.seek_ms.swap(-1, .monotonic);
            if (sk >= 0) {
                const target = @as(f64, @floatFromInt(sk)) / 1000.0;
                self.mpv.?.seek(target);
                self.eof.store(false, .monotonic);
                prod_gen = self.gen.load(.monotonic); // adotta l'epoca del seek
            }
            if (self.eof.load(.monotonic)) {
                sleepMs(8);
                continue;
            }
            // Backpressure: attendi spazio (il consumatore ha liberato uno slot).
            while (self.tail.load(.monotonic) - self.head.load(.acquire) >= CAP) {
                if (self.stop.load(.monotonic) or self.seek_ms.load(.monotonic) >= 0) break;
                sleepMs(FULL_WAIT_MS);
            }
            if (self.stop.load(.monotonic) or self.seek_ms.load(.monotonic) >= 0) continue;

            const fr = (self.mpv.?.pollFrame(&scratch, self.gpa, self.target_w.load(.monotonic), self.target_h.load(.monotonic)) catch null) orelse {
                if (self.mpv.?.eofReached()) {
                    self.eof.store(true, .monotonic);
                } else {
                    sleepMs(4);
                }
                continue;
            };
            // Un seek è arrivato mentre pompavamo mpv: scarta questo frame (è
            // della posizione vecchia), lo gestiamo al prossimo giro.
            if (self.seek_ms.load(.monotonic) >= 0) continue;

            const need = @as(usize, fr.width) * fr.height * 4;
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
            @memcpy(slot.pixels[0..need], scratch.items[0..need]);
            slot.w = fr.width;
            slot.h = fr.height;
            slot.pts_s = fr.pts_s;
            slot.gen = prod_gen;
            self.tail.store(t + 1, .release);
        }
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

            self.player.target_w = @intCast(self.target_w.load(.monotonic));
            self.player.target_h = @intCast(self.target_h.load(.monotonic));
            const maybe = self.player.nextFrame(self.max_dim, self.gpa, if (prod_skip_until >= 0) prod_skip_until else null) catch {
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
