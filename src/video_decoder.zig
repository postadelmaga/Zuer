//! La sessione video: UN thread dedicato che possiede il motore di decodifica e
//! produce frame per il present, disaccoppiato da lui.
//!
//! Due motori, scelti all'apertura:
//! * **mpv** (Linux, preferito): l'unico che tocca la sorgente. Demux, decodifica
//!   (hw quando c'è), audio, sincronia A/V, seek, loop e rete sono suoi; il suo
//!   clock è l'autorità temporale (`clockSeconds`). Il poster è il suo primo
//!   frame: nessuna apertura FFmpeg a parte. Il lavoro lo fa un `MpvEngine` (thread
//!   + contesto EGL + istanza mpv) che sopravvive alla sessione: il video dopo
//!   riusa istanza e shader già compilati invece di ricrearli (~400 ms). Il thread
//!   dorme su una `Wake` finché mpv (callback di evento e di frame), un comando o
//!   il present non lo svegliano.
//! * **FFmpeg** (`Player`, ripiego: niente libmpv, init EGL/mpv fallita,
//!   Windows): decodifica in anticipo una coda di frame col loro pts; l'audio e il
//!   clock master sono di `AudioPlayer`, gestiti da `video.zig`.
//!
//! Coda SPSC lock-free tra il thread (produttore) e il present (consumatore): il
//! produttore possiede `tail`, il consumatore `head`; ogni slot è riempito PRIMA
//! di pubblicare `tail` (release) e letto dopo un `tail` acquire. Il seek NON
//! resetta gli indici: bumpando `gen` i frame della posizione vecchia diventano
//! "stale" e `pickInto` li scarta senza presentarli.
//!
//! Ciclo di vita: tutto ciò che un thread crea (mpv, il contesto EGL, la
//! connessione Wayland di mpv) lo distrugge quel thread prima di uscire. Una
//! sessione FFmpeg ha il suo thread, fermato e joinato da `stopAndDestroy`; una
//! sessione mpv restituisce il motore al pool (uno inattivo al più, ritirato dopo
//! `ENGINE_IDLE_NS`; `shutdownEngines` lo chiude subito).

const std = @import("std");
const builtin = @import("builtin");
const player_mod = @import("decoders/player.zig");
const Wake = @import("wake.zig").Wake;
const Once = @import("wake.zig").Once;

// Backend video hardware-accelerato via libmpv (render API): Linux-only, gate
// a livello di TIPO (non solo runtime) perché mpv_video.zig fa @cImport di
// header (mpv/EGL) che su Windows/macOS non esistono — stesso pattern già
// usato per cvp9 in decoders/player.zig.
const mpv_enabled = builtin.os.tag == .linux and @import("build_options").mpv;
const mpv_video = if (mpv_enabled) @import("decoders/mpv_video.zig") else struct {
    pub const MpvVideo = struct {};
};

/// Slot della coda: buffer RGBA di proprietà, riusato tra i giri (la dimensione
/// dei frame è costante per un dato video: `realloc` scatta al più una volta).
/// Allineato a 4 nel TIPO: `pickInto` SCAMBIA questo buffer con quello del sink
/// (`static_rgba`), quindi i due devono avere lo stesso allineamento o il `free`
/// finale dichiarerebbe un allineamento diverso da quello dell'alloc.
const Slot = struct {
    pixels: []align(4) u8 = &.{},
    cap: usize = 0,
    w: u32 = 0,
    h: u32 = 0,
    pts_s: f64 = 0,
    gen: u32 = 0, // epoca di produzione: != gen corrente ⇒ frame pre-seek, da scartare
};

/// Profondità della coda di read-ahead (FFmpeg). ~8 frame ≈ 0,27 s a 30 fps:
/// abbastanza per assorbire il jitter di decode/rete senza tenere in RAM troppi
/// frame (a 1080p RGBA sono ~8 MB l'uno). Con mpv la coda è solo una cassetta:
/// mpv consegna i frame quando sono dovuti, il present prende sempre l'ultimo.
const CAP: u64 = 8;

/// Pausa dopo un errore di decodifica (packet corrotto) prima di riprovare.
const ERROR_RETRY_MS: u64 = 4;

/// Quanto aspettare il primo frame di mpv prima di arrendersi (rete lenta).
const MPV_FIRST_FRAME_TIMEOUT_NS: u64 = 20 * std.time.ns_per_s;

/// Taglia a cui rendere (e scartare) un frame dovuto quando mpv non ha ancora
/// notificato la sua: quella tipica, così gli scaler non cambiano dopo.
const FALLBACK_W: u32 = 1920;
const FALLBACK_H: u32 = 1080;

/// Un motore mpv inattivo da tanto si ritira (libera istanza, contesto GL e i
/// suoi thread): il riuso conta per chi passa da un video all'altro.
const ENGINE_IDLE_NS: u64 = 30 * std.time.ns_per_s;

/// Esito di `pickInto`: se ha copiato un nuovo frame nel sink e con quale pts.
pub const Picked = struct { presented: bool = false, pts_s: f64 = 0 };

pub const Backend = enum { ffmpeg, mpv };

/// Un frame in un dmabuf, pronto per il compositor (vedi `Presenter`).
pub const GpuFrame = struct { slot: u8, fd: i32, width: u32, height: u32, stride: u32, fourcc: u32, modifier: u64 };

/// Chi mette a schermo i frame GPU: la finestra (`presentDmabuf` su un subsurface,
/// da qualunque thread). `present` false = il compositor non lo supporta (formato
/// non annunciato, niente linux-dmabuf): si ripiega sul readback. `slot_free`:
/// il compositor ha rilasciato lo slot e non è in coda — solo lì si rende.
/// `hide` toglie il piano a fine sessione.
pub const Presenter = struct {
    ctx: *anyopaque,
    present: *const fn (ctx: *anyopaque, frame: *const GpuFrame) bool,
    slot_free: *const fn (ctx: *anyopaque, slot: u8) bool,
    hide: *const fn (ctx: *anyopaque) void,
};

/// Contatori di una sessione GPU, stampati a fine sessione (`logSession`):
/// frame a schermo, frame persi perché ogni slot era ancora del compositor,
/// intervallo tra present (media e deviazione: il pacing).
const GpuStats = struct {
    frames: u64 = 0,
    busy_drops: u64 = 0,
    last_ns: i64 = 0,
    n: u64 = 0,
    sum_ms: f64 = 0,
    sumsq_ms: f64 = 0,
    max_ms: f64 = 0,

    fn tick(s: *GpuStats, now: i64) void {
        s.frames += 1;
        if (s.last_ns != 0) {
            const d = @as(f64, @floatFromInt(now - s.last_ns)) / 1e6;
            // Le pause (play fermo, seek) non sono pacing: fuori dal conto.
            if (d < 250) {
                s.n += 1;
                s.sum_ms += d;
                s.sumsq_ms += d * d;
                s.max_ms = @max(s.max_ms, d);
            }
        }
        s.last_ns = now;
    }
};

const GpuPresent = enum { presented, busy, unavailable };

/// Il presenter del processo (uno per finestra; Zuer ne ha una): registrato una
/// volta all'avvio, vale per ogni sessione mpv aperta dopo.
var presenter_global: ?Presenter = null;

pub fn setPresenter(p: ?Presenter) void {
    presenter_global = p;
}

/// `open_failed`: la sorgente non si apre (mpv l'ha rifiutata prima di caricarla);
/// `failed`: il motore o il primo frame non arrivano — lì un altro decoder può servire.
const StartState = enum(u8) { pending, ok, failed, open_failed, no_video };

pub const VideoDecoder = struct {
    /// Solo col motore FFmpeg: con mpv la sorgente non viene mai aperta da Zuer.
    player: ?player_mod.Player,
    backend: Backend,
    gpa: std.mem.Allocator,
    max_dim: usize,
    // Copiati all'avvio così il present li legge senza toccare il motore.
    duration_s: f64,
    frame_rate: f64,
    /// L'audio della sorgente è dentro il motore (mpv): niente `AudioPlayer`, e il
    /// clock è `clockSeconds`.
    audio_inside: bool = false,

    thread: ?std.Thread = null,
    /// Sveglia della sessione: il thread FFmpeg ci dorme sopra; con mpv è quella
    /// su cui `start`/`stopAndDestroy` attendono il motore.
    wake: Wake = .{},
    /// Dove vanno i comandi del present (seek, pausa, taglia, slot liberati): la
    /// `wake` del thread che produce — la propria (FFmpeg) o quella del motore.
    cmd_wake: *Wake = undefined,
    ring: [CAP]Slot = @splat(.{}),
    head: std.atomic.Value(u64) = .init(0), // consumatore: prossimo da leggere
    tail: std.atomic.Value(u64) = .init(0), // produttore: prossimo da scrivere

    stop: std.atomic.Value(bool) = .init(false),
    // Taglia di presentazione (fit-rect della finestra) richiesta dal present:
    // il produttore scala i frame direttamente a questa dimensione (0 = ignota).
    target_w: std.atomic.Value(u32) = .init(0),
    target_h: std.atomic.Value(u32) = .init(0),
    // Seek richiesto (ms, -1 = nessuno). Il consumatore bumpa `gen` e lo imposta;
    // il thread riposiziona il motore e adotta la nuova `gen`.
    seek_ms: std.atomic.Value(i64) = .init(-1),
    gen: std.atomic.Value(u32) = .init(0),
    // Fine stream (FFmpeg): il thread smette di produrre e attende un seek. Il
    // LOOP è guidato dal consumatore (che deve riavvolgere anche l'audio).
    eof: std.atomic.Value(bool) = .init(false),
    pause_req: std.atomic.Value(bool) = .init(false),

    // --- solo mpv ---
    engine: if (mpv_enabled) ?*MpvEngine else void = if (mpv_enabled) null else {},
    /// Il motore ha lasciato la sessione: da qui la sua memoria si può liberare
    /// (`Once`: il motore non la tocca più dopo averlo segnalato).
    engine_done: Once = .{},
    path_owned: [:0]const u8 = &[_:0]u8{},
    audio_url_owned: ?[:0]const u8 = null,
    want_audio: bool = true,
    start_state: std.atomic.Value(StartState) = .init(.pending),
    /// Posizione di mpv (`time-pos`, bit di un f64): l'autorità temporale.
    clock_bits: std.atomic.Value(u64) = .init(0),
    duration_bits: std.atomic.Value(u64) = .init(0),
    buffering: std.atomic.Value(bool) = .init(false),
    presenter: ?Presenter = null,
    /// I frame vanno a schermo come dmabuf (niente coda, niente copie CPU).
    gpu_active: std.atomic.Value(bool) = .init(false),
    /// Epoca (`gen`) dell'ultimo frame messo a schermo o in coda: uguale a `gen`
    /// = il seek è chiuso e si vede la posizione nuova.
    shown_gen: std.atomic.Value(u32) = .init(0),
    gpu_stats: GpuStats = .{},
    start_s: f64 = 0,

    /// Poster (primo frame) + decoder avviato. Il chiamante prende possesso di
    /// `.rgba` (→ `static_rgba`) e del decoder (chiuso da `stopAndDestroy`).
    pub const StartResult = struct { dec: *VideoDecoder, rgba: []align(4) u8, w: u32, h: u32, pts_s: f64 };

    pub const StartOptions = struct {
        /// Traccia audio in un URL separato (stream DASH): solo il motore mpv la
        /// usa; col ripiego FFmpeg la apre `AudioPlayer`.
        audio_url: ?[]const u8 = null,
        /// false: video muto (l'audio della sorgente suona già altrove).
        audio: bool = true,
        /// Posizione di partenza (s): la sessione apre lì, senza un seek dopo.
        start_s: f64 = 0,
        /// La sessione resta in pausa dopo il primo frame finché `setPlaying(true)`:
        /// chi chiude prima un altro audio non lo sente sovrapporsi (tasto v).
        paused: bool = false,
    };

    /// Apre la sessione su `path_z` e ne restituisce il poster. mpv se c'è;
    /// altrimenti (motore mpv non disponibile o guasto) FFmpeg; una sorgente che
    /// mpv non apre è `error.OpenFailed` senza secondo tentativo. `error.NoVideoStream`
    /// se mpv ha aperto la sorgente e non ha video (un audio con copertina).
    pub fn start(path_z: [*:0]const u8, gpa: std.mem.Allocator, max_dim: usize, opts: StartOptions) !StartResult {
        if (comptime mpv_enabled) {
            if (std.c.getenv("ZUER_NO_MPV") == null) {
                if (startMpv(path_z, gpa, max_dim, opts)) |r| return r else |e| switch (e) {
                    error.NoVideoStream => return e,
                    // mpv apre con la stessa libavformat del ripiego: una sorgente che
                    // non si apre (rete giù, 404, file illeggibile) non si aprirebbe
                    // nemmeno lì — ritentare raddoppia solo connessioni e attesa.
                    error.MpvOpenFailed => return error.OpenFailed,
                    error.MpvUnavailable => {}, // già detto una volta, all'init fallita
                    else => std.log.warn("zuer video: mpv non apre la sorgente ({s}), ripiego sul decoder FFmpeg", .{@errorName(e)}),
                }
            }
        }
        return startFfmpeg(path_z, gpa, max_dim);
    }

    fn startFfmpeg(path_z: [*:0]const u8, gpa: std.mem.Allocator, max_dim: usize) !StartResult {
        var p = try player_mod.Player.open(path_z);
        errdefer p.deinit();
        const frame = (try p.nextFrame(max_dim, gpa, null)) orelse return error.NoFrameDecoded;
        const w: u32 = @intCast(frame.width);
        const h: u32 = @intCast(frame.height);
        const need = @as(usize, w) * h * 4;

        // Allineato a 4: finisce in `static_rgba`, che compose aliasa come []u32.
        const poster = try gpa.alignedAlloc(u8, .@"4", need);
        errdefer gpa.free(poster);
        @memcpy(poster, frame.pixels[0..need]);

        const self = try gpa.create(VideoDecoder);
        errdefer gpa.destroy(self);
        self.* = .{
            .player = p,
            .backend = .ffmpeg,
            .gpa = gpa,
            .max_dim = max_dim,
            .duration_s = p.duration_s,
            .frame_rate = p.frame_rate,
        };
        self.cmd_wake = &self.wake;
        // Semina il primo frame come slot 0 (gen 0, pubblicato con tail = 1).
        self.ring[0].pixels = try gpa.alignedAlloc(u8, .@"4", need);
        errdefer gpa.free(self.ring[0].pixels);
        self.ring[0].cap = need;
        @memcpy(self.ring[0].pixels, frame.pixels[0..need]);
        self.ring[0].w = w;
        self.ring[0].h = h;
        self.ring[0].pts_s = frame.pts_s;
        self.tail.store(1, .release);

        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        logSession(self, "decoder FFmpeg", "");
        return .{ .dec = self, .rgba = poster, .w = w, .h = h, .pts_s = frame.pts_s };
    }

    /// mpv: un motore (dal pool o nuovo) apre la sorgente e rende il primo frame
    /// nello slot 0; qui si aspetta solo l'esito (sveglia, niente polling).
    fn startMpv(path_z: [*:0]const u8, gpa: std.mem.Allocator, max_dim: usize, opts: StartOptions) !StartResult {
        if (comptime !mpv_enabled) unreachable;
        const self = try gpa.create(VideoDecoder);
        self.* = .{
            .player = null,
            .backend = .mpv,
            .gpa = gpa,
            .max_dim = max_dim,
            .duration_s = 0,
            .frame_rate = 0,
            .want_audio = opts.audio,
            .start_s = opts.start_s,
            .presenter = presenter_global,
            .pause_req = .init(opts.paused),
        };
        var attached = false;
        defer if (!attached) self.freeMemory();
        self.path_owned = try gpa.dupeSentinel(u8, std.mem.span(path_z), 0);
        if (opts.audio_url) |u| {
            // Stesso URL di video e audio = formato muxed: niente traccia a parte.
            if (!std.mem.eql(u8, u, std.mem.span(path_z))) self.audio_url_owned = try gpa.dupeSentinel(u8, u, 0);
        }
        if (MpvEngine.unavailable.load(.acquire)) return error.MpvUnavailable;
        const eng = try MpvEngine.acquire(gpa);
        self.engine = eng;
        self.cmd_wake = &eng.wake;
        eng.attach(self);
        attached = true;

        while (true) {
            const snap = self.wake.prepare();
            if (self.start_state.load(.acquire) != .pending) break;
            self.wake.wait(snap, null);
        }
        const st = self.start_state.load(.acquire);
        if (st != .ok) {
            self.stopAndDestroy();
            return switch (st) {
                .no_video => error.NoVideoStream,
                .open_failed => error.MpvOpenFailed,
                else => error.MpvStartFailed,
            };
        }
        // Lo slot 0 è del consumatore finché `head` non lo supera: il motore non
        // lo riscrive, la copia qui è sicura.
        const s0 = &self.ring[0];
        const need = @as(usize, s0.w) * s0.h * 4;
        const poster = gpa.alignedAlloc(u8, .@"4", need) catch |e| {
            self.stopAndDestroy();
            return e;
        };
        @memcpy(poster, s0.pixels[0..need]);
        return .{ .dec = self, .rgba = poster, .w = s0.w, .h = s0.h, .pts_s = s0.pts_s };
    }

    /// Ferma la sessione e ne libera la memoria. FFmpeg: ferma e joina il thread,
    /// chiude il `Player`. mpv: il motore scarica la sorgente e lascia la sessione
    /// (attesa sulla sveglia), poi torna al pool.
    pub fn stopAndDestroy(self: *VideoDecoder) void {
        self.stop.store(true, .monotonic);
        self.cmd_wake.notify();
        // FFmpeg: una lettura ferma sulla rete torna subito invece di bloccare il join.
        if (self.player) |*p| p.interrupt();
        if (self.thread) |t| t.join();
        self.thread = null;
        if (comptime mpv_enabled) {
            if (self.engine) |eng| {
                // Il motore lascia la sessione appena smette di presentare: qui non
                // si aspetta lo scaricamento della sorgente (con la rete ferma dura
                // quanto libavformat impiega ad annullare la lettura).
                self.engine_done.wait();
                MpvEngine.release(eng);
                self.engine = null;
                // Il piano video resta col suo ultimo frame finché non lo si toglie.
                if (self.gpu_active.load(.acquire)) {
                    if (self.presenter) |p| p.hide(p.ctx);
                }
            }
        }
        if (self.player) |*p| p.deinit();
        self.freeMemory();
    }

    fn freeMemory(self: *VideoDecoder) void {
        for (&self.ring) |*s| if (s.cap > 0) self.gpa.free(s.pixels);
        if (self.path_owned.len > 0) self.gpa.free(self.path_owned);
        if (self.audio_url_owned) |u| self.gpa.free(u);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Comunica al produttore la taglia a cui presentare (fit-rect corrente):
    /// i frame successivi arrivano già a quella dimensione, filtrati bene, e il
    /// compositore li copia 1:1 invece di ricampionarli nearest.
    pub fn setTargetSize(self: *VideoDecoder, w: u32, h: u32) void {
        if (self.target_w.load(.monotonic) == w and self.target_h.load(.monotonic) == h) return;
        if (std.c.getenv("ZUER_TRACE") != null) std.debug.print("[trace] video target {d}x{d}\n", .{ w, h });
        self.target_w.store(w, .monotonic);
        self.target_h.store(h, .monotonic);
        self.cmd_wake.notify(); // mpv: in pausa rende di nuovo il frame alla taglia nuova
    }

    pub fn setPlaying(self: *VideoDecoder, playing: bool) void {
        if (self.pause_req.load(.monotonic) == !playing) return;
        self.pause_req.store(!playing, .monotonic);
        self.cmd_wake.notify();
    }

    /// Posizione del motore (mpv): l'autorità temporale quando `audio_inside`.
    pub fn clockSeconds(self: *const VideoDecoder) f64 {
        return @bitCast(self.clock_bits.load(.acquire));
    }

    /// Durata nota al motore (mpv può saperla solo dopo l'apertura, o mai: live).
    pub fn durationSeconds(self: *const VideoDecoder) f64 {
        if (self.backend == .mpv) return @bitCast(self.duration_bits.load(.acquire));
        return self.duration_s;
    }

    /// I frame vanno a schermo come dmabuf: il present non riceve frame CPU e
    /// compone solo l'overlay (trasparente sul video).
    pub fn gpuPresenting(self: *const VideoDecoder) bool {
        return self.gpu_active.load(.acquire);
    }

    /// L'ultimo seek è chiuso: a schermo (o in coda) c'è la posizione nuova.
    pub fn settled(self: *const VideoDecoder) bool {
        return self.shown_gen.load(.acquire) == self.gen.load(.monotonic);
    }

    /// Lo stream di rete sta riempiendo la cache (mpv in pausa per buffering).
    pub fn isBuffering(self: *const VideoDecoder) bool {
        return self.buffering.load(.monotonic);
    }

    /// Se il motore è mpv ma l'audio suona altrove (`AudioPlayer`), una grande
    /// deriva dal clock audio va tradotta in un vero seek: mpv fa pacing per
    /// conto suo e non si riaggancia scartando frame come il motore FFmpeg.
    pub fn resyncIfMpv(self: *VideoDecoder, seconds: f64) void {
        if (self.backend == .mpv) self.seekAndFlush(seconds);
    }

    /// Riposiziona a `seconds`: bumpa `gen` (i frame in coda della posizione
    /// vecchia diventano stale → scartati da `pickInto`) e delega il seek al
    /// thread. Non tocca gli indici della coda.
    ///
    /// INVARIANTE: `seekAndFlush` e `pickInto` sono chiamate dallo STESSO thread
    /// consumatore (il present), serializzate dal chiamante sotto
    /// `state.shared.mutex`. È SOLO il consumatore a bumpare `gen`, quindi entro
    /// una `pickInto` la gen è ferma e nessuno slot può avere gen > quella letta.
    pub fn seekAndFlush(self: *VideoDecoder, seconds: f64) void {
        _ = self.gen.fetchAdd(1, .monotonic);
        self.eof.store(false, .monotonic);
        self.seek_ms.store(@intFromFloat(@max(0, seconds) * 1000.0), .monotonic);
        self.cmd_wake.notify();
    }

    /// True quando lo stream è finito e la coda (dei frame ancora validi) è vuota:
    /// il consumatore usa questo per il loop quando la durata è ignota.
    pub fn drained(self: *VideoDecoder) bool {
        if (!self.eof.load(.monotonic)) return false;
        return self.head.load(.monotonic) == self.tail.load(.acquire);
    }

    /// Sceglie il frame più recente con `pts <= up_to_pts`, scartando i più vecchi
    /// (e quelli stale post-seek), e lo cede al sink. `presented=false` se non c'è
    /// (ancora) un frame all'altezza del clock: il present tiene l'ultimo.
    ///
    /// `force_first`: usato SUBITO dopo un seek — presenta il primo frame fresco
    /// disponibile ANCHE se il suo pts è > up_to_pts (video in pausa).
    pub fn pickInto(self: *VideoDecoder, up_to_pts: f64, force_first: bool, gpa: std.mem.Allocator, rgba: *[]align(4) u8, w: *u32, h: *u32) Picked {
        _ = gpa;
        const g = self.gen.load(.monotonic);
        const t = self.tail.load(.acquire);
        const hd0 = self.head.load(.monotonic);
        var hd = hd0;

        // Scarta i frame pre-seek (gen diversa): sono sempre in testa.
        while (hd < t and self.ring[hd % CAP].gen != g) hd += 1;
        // Scarta i frame ormai vecchi: finché ce n'è un ALTRO subito dopo ancora
        // <= target, quello in testa è superato.
        if (!force_first) {
            while (t - hd >= 2 and self.ring[(hd + 1) % CAP].pts_s <= up_to_pts) hd += 1;
        }

        var result: Picked = .{};
        if (hd < t and (force_first or self.ring[hd % CAP].pts_s <= up_to_pts)) {
            const s = &self.ring[hd % CAP];
            // Zero-copy: lo slot cede il suo buffer al sink e prende in cambio il
            // vecchio buffer del sink (riusato al prossimo produce).
            const old = rgba.*;
            rgba.* = s.pixels[0..s.cap];
            s.pixels = old;
            s.cap = old.len;
            w.* = s.w;
            h.* = s.h;
            result = .{ .presented = true, .pts_s = s.pts_s };
            hd += 1;
        }
        // Pubblica il nuovo head e, se ha liberato slot, sveglia il produttore
        // (che in coda piena dorme invece di ripassare a intervalli).
        self.head.store(hd, .release);
        if (hd != hd0) self.cmd_wake.notify();
        return result;
    }

    // =====================================================================
    // Sessione mpv (gira sul thread del motore)
    // =====================================================================

    fn finishStart(self: *VideoDecoder, st: StartState) void {
        self.start_state.store(st, .release);
        self.wake.notify();
    }

    fn applyEvents(self: *VideoDecoder, ev: anytype) void {
        if (ev.pos_s) |p| self.clock_bits.store(@bitCast(p), .release);
        if (ev.duration_s) |d| self.duration_bits.store(@bitCast(d), .release);
        if (ev.buffering) |b| self.buffering.store(b, .monotonic);
    }

    /// Fino al primo frame: lo rende nello slot 0 alla taglia nativa (limitata a
    /// `max_dim`) e segnala `start`. false se la sorgente non va.
    fn mpvFirstFrame(self: *VideoDecoder, m: *mpv_video.MpvVideo, ew: *Wake, scratch: *std.ArrayList(u8)) bool {
        const t0 = monotonicNs();
        var loaded = false;
        // mpv ha già un frame (dovuto e reso): manca solo la taglia per il poster.
        var shown = false;
        var any_due = false;
        while (true) {
            const snap = ew.prepare();
            if (self.stop.load(.monotonic)) {
                self.finishStart(.failed);
                return false;
            }
            const ev = m.pollEvents();
            self.applyEvents(ev);
            if (ev.failed or (ev.ended and !loaded)) {
                self.finishStart(if (loaded) .failed else .open_failed);
                return false;
            }
            if (ev.file_loaded) {
                trace("mpv file-loaded", .{});
                loaded = true;
            }
            if (ev.playback_restart) trace("mpv playback-restart", .{});
            // Partita (in pausa) senza traccia video: un audio, magari con
            // copertina (`audio-display=no`). Ci pensa il visualizzatore audio.
            if (ev.playback_restart and loaded and !m.hasVideo()) {
                self.finishStart(.no_video);
                return false;
            }
            // Il flag "frame dovuto" va letto a ogni risveglio e il frame reso
            // subito: se resta lì, mpv aspetta 200 ms prima di proseguire. La
            // taglia (`dwidth`) mpv la notifica solo DOPO averlo mostrato: se
            // ancora non c'è, si rende alla taglia di ripiego e si ridisegna
            // (lo stesso frame, mpv lo consente) appena arriva.
            var ready = false;
            if (m.frameDue()) {
                any_due = true;
                trace("mpv primo frame dovuto", .{});
                if (m.displaySize() == null) {
                    m.renderDiscard(FALLBACK_W, FALLBACK_H);
                    shown = true;
                } else ready = true;
            }
            if (shown and m.displaySize() != null) ready = true;
            if (ready) {
                if (m.displaySize()) |disp| {
                    const sz = mpv_video.MpvVideo.fitSize(disp, 0, 0, @intCast(self.max_dim));
                    if (m.renderReadback(scratch, self.gpa, sz[0], sz[1]) catch null) |fr| {
                        trace("mpv primo frame reso", .{});
                        if (self.storeSlot(0, scratch.items, fr.width, fr.height, fr.pts_s, 0)) {
                            self.tail.store(1, .release);
                            // L'audio della sorgente è di mpv (anche se non c'è: allora
                            // non serve nemmeno un `AudioPlayer`).
                            self.audio_inside = self.want_audio;
                            const fps = m.frameRate();
                            self.frame_rate = if (fps > 0) fps else 30.0;
                            self.duration_s = self.durationSeconds();
                            const hw = m.hwdec();
                            logSession(self, "mpv", if (hw.len == 0) "no" else hw);
                            self.finishStart(.ok);
                            return true;
                        }
                    }
                }
            }
            // Ripartita con una traccia video ma senza averne mai dato un frame
            // (letto qui, dopo `frameDue` di questo giro): mpv ha il video già a
            // fine stream (seek/partenza su un TS senza indice, troncato o
            // corrotto) e in pausa ci resterebbe: si fallisce subito, come per
            // una sorgente illeggibile, invece di aspettare il limite di 20 s.
            // Su 91 aperture normali (6 formati) il frame arriva sempre prima.
            if (ev.playback_restart and loaded and m.hasVideo() and !any_due) {
                std.log.warn("zuer video: mpv è ripartito senza un frame video (stream non decodificabile da questa posizione)", .{});
                self.finishStart(.failed);
                return false;
            }
            const elapsed: u64 = @intCast(monotonicNs() - t0);
            if (elapsed >= MPV_FIRST_FRAME_TIMEOUT_NS) {
                std.log.warn("zuer video: mpv senza primo frame dopo {d} s", .{MPV_FIRST_FRAME_TIMEOUT_NS / std.time.ns_per_s});
                self.finishStart(.failed);
                return false;
            }
            ew.wait(snap, MPV_FIRST_FRAME_TIMEOUT_NS - elapsed);
        }
    }

    /// Regime: dorme su `ew`; a ogni risveglio applica i comandi, svuota gli
    /// eventi di mpv e, se mpv ha un frame dovuto, lo rende. In pausa mpv non
    /// produce frame né eventi: il thread resta fermo finché non arriva un comando.
    fn mpvLoop(self: *VideoDecoder, m: *mpv_video.MpvVideo, ew: *Wake) void {
        var prod_gen: u32 = self.gen.load(.monotonic);
        // La sorgente parte in pausa (poster): il primo giro applica lo stato voluto.
        var applied_pause = true;
        // Un frame è stato dovuto dall'ultimo playback_restart (il primo è già reso).
        var due_since_restart = true;
        // Dopo un seek mpv rende ancora frame della posizione vecchia finché non
        // annuncia `playback_restart`: quelli non vanno presentati (era il frame
        // "sbagliato" mostrato subito dopo un seek all'indietro).
        var awaiting_restart = false;
        // Un frame da pubblicare (nuovo, o lo stesso a una taglia nuova) in attesa
        // di seek finito o di uno slot libero.
        var dirty = false;
        var last_w: u32 = 0;
        var last_h: u32 = 0;
        var slot_wait = false;
        const tracing = std.c.getenv("ZUER_TRACE") != null;
        var report_at = monotonicNs() + 10 * std.time.ns_per_s;
        while (true) {
            const snap = ew.prepare();
            if (self.stop.load(.monotonic)) break;
            if (tracing and monotonicNs() >= report_at) {
                report_at += 10 * std.time.ns_per_s;
                traceState(self, m);
            }

            // Prima il seek, poi la ripresa: arrivati insieme, mpv non suona
            // nemmeno un istante dalla posizione vecchia.
            const sk = self.seek_ms.swap(-1, .monotonic);
            if (sk >= 0) {
                trace("mpv seek {d} ms", .{sk});
                m.seek(@as(f64, @floatFromInt(sk)) / 1000.0);
                prod_gen = self.gen.load(.monotonic);
                awaiting_restart = true;
            }
            const want_pause = self.pause_req.load(.monotonic);
            if (want_pause != applied_pause) {
                m.setPaused(want_pause);
                applied_pause = want_pause;
            }
            const ev = m.pollEvents();
            self.applyEvents(ev);
            // Il decoder hardware ha ceduto a metà (mpv è passato al software): i
            // pacchetti dal keyframe in poi li hanno consumati i tentativi falliti,
            // e il software, partito a metà GOP, non mostra nulla fino al keyframe
            // successivo (misurato: 1,2 s con GOP da 1 s, 7 s con GOP da 5 s). Un
            // seek esatto alla posizione corrente lo fa ripartire dal keyframe.
            if (ev.hw_to_sw and !awaiting_restart) {
                std.log.info("zuer video: decodifica hardware fallita, mpv passa al software; riparto dal keyframe a {d:.2} s", .{m.pos});
                m.seek(m.pos);
                awaiting_restart = true;
            }
            if (ev.playback_restart and awaiting_restart) {
                trace("mpv seek finito", .{});
                awaiting_restart = false;
                dirty = true; // il frame corrente ora è quello della posizione nuova
            }
            // Un frame dovuto va SEMPRE reso subito: il VO di mpv attende il nostro
            // disegno fino a 200 ms prima di andare avanti (log: "render() not
            // being called or stuck"), e intanto audio e video si fermano.
            const due = m.frameDue();
            // Ripartita (loop o seek) senza un frame dal restart precedente: da qui
            // il video non si riposiziona (TS senza indice, troncato: libavformat
            // legge fino in fondo senza dare pacchetti) e col loop mpv rigirerebbe
            // a vuoto al 95% di CPU. Il loop si spegne: mpv si ferma sull'ultimo frame.
            if (ev.playback_restart) {
                if (!due and !due_since_restart and m.hasVideo() and !m.loop_off) {
                    std.log.warn("zuer video: il video non si riposiziona (ripartito senza frame): loop spento per questo file", .{});
                    m.setLoop(false);
                }
                due_since_restart = false;
            }
            if (due) due_since_restart = true;
            if (m.displaySize() == null and due) {
                m.renderDiscard(if (last_w > 0) last_w else FALLBACK_W, if (last_h > 0) last_h else FALLBACK_H);
            } else if (m.displaySize()) |d| {
                const sz = mpv_video.MpvVideo.fitSize(d, self.target_w.load(.monotonic), self.target_h.load(.monotonic), @intCast(self.max_dim));
                if (due) dirty = true;
                if (sz[0] != last_w or sz[1] != last_h) dirty = true; // resize: anche in pausa
                const room = self.tail.load(.monotonic) - self.head.load(.acquire) < CAP;
                const gp: GpuPresent = if (dirty and !awaiting_restart) self.presentGpu(m, sz, prod_gen) else .unavailable;
                if (gp == .presented) {
                    dirty = false;
                    last_w = sz[0];
                    last_h = sz[1];
                } else if (gp == .busy) {
                    // Ogni slot è ancora del compositor: il frame dovuto si scarta
                    // (mpv non va fermato) e `dirty` resta — quello corrente va a
                    // schermo appena uno slot si libera. Il rilascio arriva sul thread
                    // della finestra, che non ci sveglia: attesa breve, solo qui.
                    if (due) m.renderDiscard(if (last_w > 0) last_w else sz[0], if (last_h > 0) last_h else sz[1]);
                    if (due) self.gpu_stats.busy_drops += 1;
                    slot_wait = true;
                } else if (dirty and !awaiting_restart and room) {
                    // Lo slot `tail` è del produttore finché non lo pubblica: mpv ci
                    // legge dentro direttamente (una copia CPU in meno per frame).
                    const t = self.tail.load(.monotonic);
                    if (self.slotFor(t, sz[0], sz[1])) |dst| {
                        if (m.renderReadbackTo(dst, sz[0], sz[1])) |fr| {
                            const slot = &self.ring[t % CAP];
                            slot.w = fr.width;
                            slot.h = fr.height;
                            slot.pts_s = fr.pts_s;
                            slot.gen = prod_gen;
                            self.tail.store(t + 1, .release);
                            self.shown_gen.store(prod_gen, .release);
                        }
                    } else if (due) m.renderDiscard(sz[0], sz[1]);
                    dirty = false;
                    last_w = sz[0];
                    last_h = sz[1];
                } else if (due) {
                    // Seek non ancora chiuso (frame della posizione vecchia) o coda
                    // piena (present indietro): reso e scartato, come un frame perso.
                    if (awaiting_restart) trace("mpv frame durante il seek", .{});
                    if (last_w > 0) m.renderDiscard(last_w, last_h) else m.renderDiscard(sz[0], sz[1]);
                    if (!awaiting_restart) dirty = false;
                }
            }
            const tmo: ?u64 = if (slot_wait) 2 * std.time.ns_per_ms else if (tracing) @intCast(@max(0, report_at - monotonicNs())) else null;
            ew.wait(snap, tmo);
            slot_wait = false;
        }
    }

    /// Percorso GPU: rende nel primo dmabuf libero e lo passa al presenter.
    /// `unavailable` se non c'è presenter o il percorso non va (da lì readback).
    fn presentGpu(self: *VideoDecoder, m: *mpv_video.MpvVideo, sz: [2]u32, prod_gen: u32) GpuPresent {
        const p = self.presenter orelse return .unavailable;
        if (m.gpuDisabled()) return .unavailable;
        const g = switch (m.renderGpu(sz[0], sz[1], p.ctx, p.slot_free)) {
            .frame => |f| f,
            .busy => return .busy,
            .unavailable => return .unavailable,
        };
        const frame: GpuFrame = .{ .slot = g.slot, .fd = g.fd, .width = g.width, .height = g.height, .stride = g.stride, .fourcc = g.fourcc, .modifier = g.modifier };
        if (!p.present(p.ctx, &frame)) {
            std.log.warn("zuer video: il compositor non accetta il piano dmabuf (formato non annunciato, import rifiutato o niente linux-dmabuf), readback CPU", .{});
            m.disableGpu();
            if (self.gpu_active.swap(false, .acq_rel)) p.hide(p.ctx);
            return .unavailable;
        }
        if (!self.gpu_active.swap(true, .acq_rel)) logGpu(m);
        self.gpu_stats.tick(monotonicNs());
        self.shown_gen.store(prod_gen, .release);
        return .presented;
    }

    /// Il buffer dello slot di indice assoluto `t`, grande almeno w×h×4 (riallocato
    /// solo se cresce: a taglia costante nessuna allocazione per frame).
    fn slotFor(self: *VideoDecoder, t: u64, w: u32, h: u32) ?[]u8 {
        const need = @as(usize, w) * h * 4;
        const slot = &self.ring[t % CAP];
        if (slot.cap < need) {
            const nb = self.gpa.realloc(slot.pixels, need) catch return null;
            slot.pixels = nb;
            slot.cap = need;
        }
        return slot.pixels[0..need];
    }

    /// Copia `pixels` nello slot di indice assoluto `t` (riallocandolo se serve).
    fn storeSlot(self: *VideoDecoder, t: u64, pixels: []const u8, w: u32, h: u32, pts_s: f64, gen: u32) bool {
        const need = @as(usize, w) * h * 4;
        const slot = &self.ring[t % CAP];
        if (slot.cap < need) {
            const nb = self.gpa.realloc(slot.pixels, need) catch return false;
            slot.pixels = nb;
            slot.cap = need;
        }
        @memcpy(slot.pixels[0..need], pixels[0..need]);
        slot.w = w;
        slot.h = h;
        slot.pts_s = pts_s;
        slot.gen = gen;
        return true;
    }

    // =====================================================================
    // Motore FFmpeg (ripiego)
    // =====================================================================

    fn threadMain(self: *VideoDecoder) void {
        const pl = &self.player.?;
        var prod_gen: u32 = self.gen.load(.monotonic);
        // Soglia post-seek (-1 = nessuna): `seek(BACKWARD)` atterra al keyframe
        // PRECEDENTE il target, quindi i primi frame decodificati sono pre-target.
        // Passata a `nextFrame`, che li scarta INTERNAMENTE a costo quasi zero.
        var prod_skip_until: f64 = -1;
        while (!self.stop.load(.monotonic)) {
            const sk = self.seek_ms.swap(-1, .monotonic);
            if (sk >= 0) {
                const target = @as(f64, @floatFromInt(sk)) / 1000.0;
                pl.seek(target);
                self.eof.store(false, .monotonic);
                prod_gen = self.gen.load(.monotonic); // adotta l'epoca del seek
                prod_skip_until = target;
            }
            // Stream finito, o coda piena (pausa, display più lento del decode):
            // dorme finché un seek, uno stop o uno slot liberato non lo svegliano.
            {
                const snap = self.wake.prepare();
                if (self.stop.load(.monotonic) or self.seek_ms.load(.monotonic) >= 0) continue;
                const full = self.tail.load(.monotonic) - self.head.load(.acquire) >= CAP;
                if (self.eof.load(.monotonic) or full) {
                    self.wake.wait(snap, null);
                    continue;
                }
            }

            pl.target_w = @intCast(self.target_w.load(.monotonic));
            pl.target_h = @intCast(self.target_h.load(.monotonic));
            const maybe = pl.nextFrame(self.max_dim, self.gpa, if (prod_skip_until >= 0) prod_skip_until else null) catch {
                // Errore di decode (packet corrotto) ≠ EOF: salta e riprova.
                sleepMs(ERROR_RETRY_MS);
                continue;
            };
            const fr = maybe orelse {
                self.eof.store(true, .monotonic);
                continue;
            };
            // Un seek è arrivato mentre decodificavamo: scarta questo frame.
            if (self.seek_ms.load(.monotonic) >= 0) continue;
            prod_skip_until = -1;

            const t = self.tail.load(.monotonic);
            // Lo scratch del player vale solo fino al prossimo nextFrame: copia ora.
            if (!self.storeSlot(t, fr.pixels, @intCast(fr.width), @intCast(fr.height), fr.pts_s, prod_gen)) {
                sleepMs(ERROR_RETRY_MS); // niente memoria per lo slot: rinuncia a questo frame
                continue;
            }
            self.tail.store(t + 1, .release);
        }
    }
};

/// Il motore mpv: un thread che possiede contesto EGL, istanza mpv e render
/// context (con i suoi shader già compilati) e serve una sessione alla volta.
/// Finita una sessione torna nel pool (uno inattivo al più): il video successivo
/// parte con `loadfile` invece di ricreare tutto. Inattivo per `ENGINE_IDLE_NS`
/// si ritira da solo; chi acquisisce o `shutdownEngines` ne fa il join.
const MpvEngine = if (mpv_enabled) struct {
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    /// Sveglia del thread: callback di mpv (eventi, frame) e comandi della sessione.
    wake: Wake = .{},
    session: std.atomic.Value(?*VideoDecoder) = .init(null),
    /// Quante sessioni sono state attaccate (sotto `pool_lock`): a fine servizio il
    /// motore toglie la sessione solo se nessuna è arrivata nel frattempo. Il
    /// puntatore non basta: la sessione liberata può tornare allo stesso indirizzo.
    attach_seq: u64 = 0,
    quit: std.atomic.Value(bool) = .init(false),
    /// Il thread è uscito (init fallita o ritiro): va solo joinato.
    dead: std.atomic.Value(bool) = .init(false),

    /// L'init è fallita una volta (niente libmpv, niente Wayland, EGL): è
    /// l'ambiente, non la sorgente — le aperture successive vanno dritte a FFmpeg.
    var unavailable: std.atomic.Value(bool) = .init(false);
    var pool_lock: std.atomic.Mutex = .unlocked;
    var idle: ?*MpvEngine = null;
    /// Motori usciti da soli (ritiro per inattività) in attesa di join.
    var exited: [4]?*MpvEngine = @splat(null);

    fn lockPool() void {
        while (!pool_lock.tryLock()) std.Thread.yield() catch {};
    }

    fn acquire(gpa: std.mem.Allocator) !*MpvEngine {
        reapExited();
        lockPool();
        const e = idle;
        idle = null;
        pool_lock.unlock();
        if (e) |eng| {
            trace("motore mpv riusato", .{});
            return eng;
        }
        const eng = try gpa.create(MpvEngine);
        eng.* = .{ .gpa = gpa };
        eng.thread = std.Thread.spawn(.{}, run, .{eng}) catch |err| {
            gpa.destroy(eng);
            return err;
        };
        return eng;
    }

    /// Restituisce il motore: nel pool se è vivo e il posto è libero. Altrimenti
    /// si ritira da solo (come per inattività) e lo joina chi acquisisce dopo o
    /// `shutdownEngines`: chi chiude una sessione non aspetta lo scaricamento della
    /// sorgente né la distruzione di mpv. Solo se la lista dei ritirati è piena, join.
    fn release(eng: *MpvEngine) void {
        if (!eng.dead.load(.acquire)) {
            lockPool();
            var retired = false;
            const keep = idle == null;
            if (keep) {
                idle = eng;
            } else for (&exited) |*x| if (x.* == null) {
                x.* = eng;
                retired = true;
                break;
            };
            pool_lock.unlock();
            if (keep) {
                eng.wake.notify(); // riparte il conto dell'inattività
                return;
            }
            if (retired) {
                eng.quit.store(true, .release);
                eng.wake.notify();
                return;
            }
        }
        eng.shutdown();
    }

    fn shutdown(eng: *MpvEngine) void {
        eng.quit.store(true, .release);
        eng.wake.notify();
        if (eng.thread) |t| t.join();
        eng.gpa.destroy(eng);
    }

    fn reapExited() void {
        lockPool();
        var list = exited;
        exited = @splat(null);
        pool_lock.unlock();
        for (list) |maybe| if (maybe) |eng| {
            if (eng.thread) |t| t.join();
            eng.gpa.destroy(eng);
        };
        _ = &list;
    }

    fn attach(eng: *MpvEngine, s: *VideoDecoder) void {
        lockPool();
        eng.attach_seq +%= 1;
        eng.session.store(s, .release);
        pool_lock.unlock();
        eng.wake.notify();
    }

    fn run(eng: *MpvEngine) void {
        trace("motore mpv: avvio", .{});
        var mv = mpv_video.MpvVideo.init(.{
            .wake_ctx = &eng.wake,
            .wake_fn = Wake.notifyC,
        }) catch |e| {
            std.log.warn("zuer video: init mpv fallita ({s}), da qui decoder FFmpeg", .{@errorName(e)});
            unavailable.store(true, .release);
            eng.dead.store(true, .release);
            // La sessione che l'ha chiesto (se c'è già, o appena arriva) fallisce.
            while (!eng.quit.load(.acquire)) {
                const snap = eng.wake.prepare();
                if (eng.session.swap(null, .acq_rel)) |s| {
                    s.finishStart(.failed);
                    s.engine_done.set();
                }
                eng.wake.wait(snap, null);
            }
            return;
        };
        // Teardown sullo stesso thread di init: il contesto EGL è corrente qui.
        defer mv.deinit();
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(eng.gpa);
        trace("motore mpv: pronto", .{});

        var idle_since = monotonicNs();
        // Dopo una sessione, alla prima pausa senza sessioni in attesa: `trimHeap`.
        var trim_pending = false;
        while (true) {
            const snap = eng.wake.prepare();
            if (eng.quit.load(.acquire)) break;
            lockPool();
            const cur = eng.session.load(.acquire);
            const seq = eng.attach_seq;
            pool_lock.unlock();
            if (cur) |s| {
                eng.serve(&mv, s, seq, &scratch);
                idle_since = monotonicNs();
                trim_pending = true;
                continue;
            }
            if (trim_pending) {
                // Qui nessuno aspetta il motore (3–20 ms misurati): chi apre un
                // video subito dopo non paga il trim.
                trim_pending = false;
                trimHeap();
                continue; // una sessione può essere arrivata nel frattempo
            }
            // Inattivo: niente da fare finché non arriva una sessione o il ritiro.
            _ = mv.pollEvents();
            if (mv.frameDue()) mv.renderDiscard(@max(1, @as(u32, @intCast(mv.fbo_w))), @max(1, @as(u32, @intCast(mv.fbo_h))));
            const idle_ns: u64 = @intCast(monotonicNs() - idle_since);
            if (idle_ns >= ENGINE_IDLE_NS) {
                lockPool();
                const mine = idle == eng;
                var slot: ?usize = null;
                if (mine) {
                    for (exited, 0..) |x, i| if (x == null) {
                        slot = i;
                        break;
                    };
                    if (slot) |i| {
                        idle = null;
                        exited[i] = eng;
                    }
                }
                pool_lock.unlock();
                if (mine and slot != null) {
                    trace("motore mpv: ritirato per inattività", .{});
                    eng.dead.store(true, .release);
                    break;
                }
                idle_since = monotonicNs();
                continue;
            }
            eng.wake.wait(snap, ENGINE_IDLE_NS - idle_ns);
        }
    }

    /// Una sessione dall'apertura alla fine; poi la lascia e scarica la sorgente.
    fn serve(eng: *MpvEngine, m: *mpv_video.MpvVideo, s: *VideoDecoder, seq: u64, scratch: *std.ArrayList(u8)) void {
        m.audio_url = s.audio_url_owned;
        m.loadFile(s.path_owned, s.want_audio, s.start_s);
        if (s.mpvFirstFrame(m, &eng.wake, scratch)) s.mpvLoop(m, &eng.wake);
        logEnd(s, m);
        m.stopPlayback();
        m.audio_url = null;
        // La sessione è libera da qui: il ciclo è finito, il motore non presenta
        // più frame e non tocca più `s` (chi chiude la libera appena lo vede). Lo
        // scaricamento sotto resta del motore: gli eventi di questo file finiscono
        // prima che serva la sessione successiva, e dal pool il motore va a chi lo
        // chiede solo dopo (chi apre aspetta, chi chiude no).
        const done = &s.engine_done;
        done.set();
        // Si aspetta l'END_FILE solo se il file non è già finito: dopo un errore
        // d'apertura o una fine naturale mpv non ne manda un altro, e qui si
        // restava 1 s ad aspettarlo (misurato: 1000 ms su file vuoti/illeggibili).
        // Il limite resta per un mpv che non risponde, e lo dice.
        const t0 = monotonicNs();
        while (m.file_active) {
            const snap = eng.wake.prepare();
            _ = m.pollEvents();
            if (m.frameDue()) m.renderDiscard(@max(1, @as(u32, @intCast(m.fbo_w))), @max(1, @as(u32, @intCast(m.fbo_h))));
            if (!m.file_active) break;
            const el: u64 = @intCast(monotonicNs() - t0);
            if (el >= std.time.ns_per_s) {
                std.log.warn("zuer video: mpv non ha chiuso il file entro 1 s", .{});
                m.file_active = false;
                break;
            }
            eng.wake.wait(snap, std.time.ns_per_s - el);
        }
        trace("mpv stop in {d:.1} ms", .{@as(f64, @floatFromInt(monotonicNs() - t0)) / 1e6});
        // Solo se è ancora lei: dal pool il motore può già avere una sessione nuova.
        lockPool();
        if (eng.attach_seq == seq) eng.session.store(null, .release);
        pool_lock.unlock();
    }
} else void;

/// Restituisce al sistema la memoria già liberata che glibc tiene nelle arene.
/// Una sessione video alloca e libera parecchio da molti thread (demuxer, decoder,
/// cache di mpv): glibc conserva quelle pagine e l'RSS si assestava ~120 MB sopra
/// la memoria in uso (misurato con malloc_stats su 1000 cambi di file). Gira sul
/// thread del motore quando resta senza sessioni, fuori dal percorso della GUI e
/// dell'apertura successiva.
fn trimHeap() void {
    if (comptime builtin.os.tag != .linux or builtin.abi.isMusl() or !builtin.link_libc) return;
    const t0 = monotonicNs();
    _ = malloc_trim(0);
    trace("malloc_trim in {d:.1} ms", .{@as(f64, @floatFromInt(monotonicNs() - t0)) / 1e6});
}

extern "c" fn malloc_trim(pad: usize) c_int;

/// Chiude il motore mpv inattivo (e quelli già ritirati), sul loro thread: per
/// l'uscita ordinata dell'app e per i test che contano fd e thread.
pub fn shutdownEngines() void {
    if (comptime !mpv_enabled) return;
    MpvEngine.reapExited();
    MpvEngine.lockPool();
    const e = MpvEngine.idle;
    MpvEngine.idle = null;
    MpvEngine.pool_lock.unlock();
    if (e) |eng| eng.shutdown();
}

/// Fine sessione: frame a schermo e persi, pacing dei present, scarto A/V.
fn logEnd(s: *const VideoDecoder, m: anytype) void {
    const g = s.gpu_stats;
    const mean = if (g.n > 0) g.sum_ms / @as(f64, @floatFromInt(g.n)) else 0;
    const sd = if (g.n > 1) @sqrt(@max(0, g.sumsq_ms / @as(f64, @floatFromInt(g.n)) - mean * mean)) else 0;
    std.log.info("zuer video: fine sessione: dmabuf frame={d} persi_slot_occupati={d} intervallo_ms media={d:.2} dev={d:.2} max={d:.1}; mpv drop={d} vo_ritardati={d} avsync_max_ms={d:.1}", .{
        g.frames, g.busy_drops, mean, sd, g.max_ms, m.drops, m.delayed, m.avsync_max * 1000,
    });
}

/// Ogni 10 s con ZUER_TRACE: dove si è, scarto A/V massimo nell'intervallo,
/// contatori di mpv e dei present. Per seguire le prove lunghe (clock, drop).
fn traceState(s: *const VideoDecoder, m: *mpv_video.MpvVideo) void {
    trace("stato: pos={d:.1} avsync_max_10s_ms={d:.1} mpv drop={d} vo_ritardati={d} dmabuf frame={d} persi={d}", .{
        m.pos, m.avsync_win * 1000, m.drops, m.delayed, s.gpu_stats.frames, s.gpu_stats.busy_drops,
    });
    m.avsync_win = 0;
}

fn logGpu(m: anytype) void {
    const hw = m.hwdec();
    // `*-copy`: il decoder hw riporta i frame in RAM e mpv li ricarica (succede se
    // il compositor gira su una GPU senza VA-API: decodifica sull'altra, con copia).
    const copy = std.mem.endsWith(u8, hw, "-copy");
    std.log.info("zuer video: piano dmabuf attivo (hwdec={s}, XBGR8888 LINEAR, {s})", .{
        if (hw.len == 0) "no" else hw,
        if (copy) "decodifica con copia in RAM, presentazione senza copie" else "nessuna copia CPU per frame",
    });
}

/// Una riga per sessione: quale motore, quale decodifica hw, dove va l'audio.
fn logSession(self: *const VideoDecoder, engine: []const u8, hwdec: []const u8) void {
    std.log.info("zuer video: {s}{s}{s}, audio {s}, {d:.0} fps, durata {d:.1} s", .{
        engine,
        if (hwdec.len > 0) " hwdec=" else "",
        hwdec,
        if (self.audio_inside) "nel motore" else "separato",
        self.frame_rate,
        self.durationSeconds(),
    });
}

/// Diagnostica a tempo (ZUER_TRACE=1): fasi di apertura e seek del motore.
fn trace(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("ZUER_TRACE") == null) return;
    const ms = @as(f64, @floatFromInt(@mod(monotonicNs(), 100 * std.time.ns_per_s))) / 1e6;
    std.debug.print("[trace {d:.1}] " ++ fmt ++ "\n", .{ms} ++ args);
}

fn monotonicNs() i64 {
    if (comptime builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
    return 0;
}

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

fn sleepMs(ms: u64) void {
    if (comptime builtin.os.tag == .windows) {
        Sleep(@intCast(ms));
    } else {
        const req = std.c.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&req, null);
    }
}
