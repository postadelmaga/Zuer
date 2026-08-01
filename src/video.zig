//! Player video nativo per zuer-gui: apertura container, avanzamento della
//! riproduzione, decodifica dei frame in `static_rgba` e disegno dei controlli
//! overlay (timeline + play/pausa, stile YouTube).
//!
//! È la controparte a finestra del decoder `media` (poster). Tutta l'interazione
//! con libav vive in `player.zig`, importato qui **solo** quando il player video è
//! abilitato (`build_options.video`); altrimenti è uno stub e ogni funzione reale
//! resta non-analizzata perché gui.zig la chiama solo sotto `if (has_video)`.
//! Il resto del viewer (testo/immagini/mesh) non dipende da questo modulo:
//! `has_video` è così un vero confine di modulo, non solo un flag sparso.

const std = @import("std");
const builtin = @import("builtin");
const zicro = @import("zicro");
const paint = zicro.paint;
const glyph = @import("glyph.zig");

// player.zig fa un @cImport degli header libav: importalo solo quando il video è
// attivo, con uno stub minimale altrimenti (vedi il gate `has_video` in gui.zig).
const player_mod = if (@import("build_options").video) @import("decoders/player.zig") else struct {
    pub const Player = struct {
        pub fn deinit(_: *Player) void {}
    };
    pub const Frame = struct {};
};

// Audio del player (thread + device zicro). Solo con video attivo; altrimenti uno
// stub, mai usato (gui chiama il path video sotto `if (has_video)` comptime).
const AudioPlayer = if (@import("build_options").video) @import("audio_player.zig").AudioPlayer else struct {};

// Thread di decodifica video + coda di frame (vedi `video_decoder.zig`). Gated
// come AudioPlayer: importa libav solo con il video attivo, stub vuoto altrimenti
// (usato solo dentro i rami `has_video`, comptime-eliminati quando il video è off).
const VideoDecoder = if (@import("build_options").video) @import("video_decoder.zig").VideoDecoder else struct {};

/// Frame video decodificato al massimo a questa dimensione per lato (limita memoria
/// e tempo di rasterizzazione: i 4K si riscalano a 1920 sul lato lungo).
const video_max_dim: usize = 1920;

/// Stato del player video nativo (libav). Il *thread di decodifica* (`decoder`)
/// è l'unico a toccare il `Player`; il present e il thread finestra comunicano
/// solo via la coda del decoder e via flag sotto `mutex` (play/pausa, `seek_to`,
/// attività del mouse per l'auto-hide dei controlli).
pub const VideoState = struct {
    // Decodifica su thread dedicato con coda di read-ahead. Il present sceglie
    // dalla coda il frame all'altezza del clock audio (`advanceVideo`), invece
    // di decodificare inline: uno stallo di rete non congela più il present e il
    // video si riaggancia all'audio scartando i frame in ritardo.
    decoder: ?*VideoDecoder = null,
    playing: bool = true,
    pos_s: f64 = 0, // posizione di riproduzione corrente (secondi)
    dur_s: f64 = 0, // durata totale (0 se ignota)
    shown_pts: f64 = 0, // PTS del frame attualmente in `static_rgba`
    // Controlli overlay (stile YouTube): `controls` = alpha di fade (0..1),
    // `idle_s` = secondi dall'ultimo movimento del mouse (guida l'auto-hide).
    // La temporizzazione è ad accumulo di `frame_dt`: nessun orologio a muro.
    controls: f32 = 0,
    idle_s: f64 = 999,
    // Seek richiesto dall'input (secondi, <0 = nessuno) e stato scrubbing.
    seek_to: f64 = -1,
    scrubbing: bool = false,
    // Riproduzione audio (thread + device). null se il file non ha audio o il
    // device non si apre → il video va muto. Quando presente E in avanzamento, è
    // il clock master; `audio_clk_prev` traccia il valore precedente per capire se
    // sta davvero drenando (device muto → clock fermo → NON congelare il video).
    audio: ?*AudioPlayer = null,
    audio_clk_prev: f64 = -1,
    // Modalità audio-only (mp3, wav, flac…): nessun `player` video, il frame è un
    // oscilloscopio disegnato dai campioni live (`drawOscilloscope`). La stessa
    // macchina di controlli/seek/pausa del video vale identica.
    audio_only: bool = false,
    // Testina di lettura dell'oscilloscopio (indice ASSOLUTO di campione, stesse
    // unità di `AudioPlayer.scopeWritten`). Avanza al wall-clock (`dt·rate`) così il
    // tracciato scorre in continuo tra un blocco audio e l'altro; si riaggancia se
    // esce dai campioni validi (pausa, seek, underrun).
    scope_head: f64 = 0,

    pub fn isActive(self: *const VideoState) bool {
        return self.decoder != null or self.audio_only;
    }

    /// Ferma il thread di decodifica (che chiude il container) e l'audio.
    /// Idempotente: azzera `decoder` così una seconda chiamata è un no-op e lo
    /// stato è pronto per un eventuale `setupVideo` successivo (navigazione).
    pub fn deinit(self: *VideoState) void {
        if (@import("build_options").video) {
            if (self.audio) |a| a.stopAndDestroy();
            self.audio = null;
            // Ferma e joina il thread di decodifica PRIMA di tornare: dopo questo
            // nessuno tocca più il Player (chiuso da stopAndDestroy).
            if (self.decoder) |d| d.stopAndDestroy();
        }
        self.decoder = null;
        // Riporta a sentinella lo stato di riproduzione residuo: un seek o uno
        // scrubbing pendenti non devono applicarsi al PROSSIMO video aperto, e
        // il clock audio precedente non deve inquinare la drift-correction.
        self.seek_to = -1;
        self.scrubbing = false;
        self.audio_clk_prev = -1;
        self.audio_only = false;
        self.scope_head = 0;
    }
};

/// Destinazione del frame corrente: `gpa` più i puntatori al buffer RGBA e alle sue
/// dimensioni (locali del thread finestra in gui.zig). Disaccoppia il player dal
/// `GuiAppState` completo — tocca solo questi campi.
pub const FrameSink = struct {
    gpa: std.mem.Allocator,
    rgba: *[]u8,
    w: *u32,
    h: *u32,
};

/// Primo frame (poster) restituito da `setupVideo`: il chiamante ne prende possesso
/// (diventa `static_rgba`).
pub const VideoFirst = struct { rgba: []u8, w: u32, h: u32 };

/// Apre il player video su un thread di decodifica dedicato, decodifica il primo
/// frame (poster) in RGBA e inizializza `vs` (durata, posizione, `playing`). Il
/// chiamante prende possesso di `.rgba` (→ `static_rgba`) e del decoder in
/// `vs.decoder` (fermato/chiuso da `deinit`).
pub fn setupVideo(vs: *VideoState, path: []const u8, gpa: std.mem.Allocator) !VideoFirst {
    // Strippa un eventuale suffisso `#N` (pagina/frammento interno) SOLO se dopo
    // il `#` ci sono esclusivamente cifre: un nome legittimo come "video #1.mp4"
    // non va troncato.
    var clean: []const u8 = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| {
        const suffix = path[h + 1 ..];
        const all_digits = suffix.len > 0 and blk: {
            for (suffix) |ch| if (!std.ascii.isDigit(ch)) break :blk false;
            break :blk true;
        };
        if (all_digits) clean = path[0..h];
    }
    const path_z = try gpa.dupeZ(u8, clean);
    defer gpa.free(path_z);

    const r = try VideoDecoder.start(path_z.ptr, gpa, video_max_dim);
    errdefer r.dec.stopAndDestroy();

    vs.dur_s = r.dec.duration_s;
    vs.pos_s = r.pts_s;
    vs.shown_pts = r.pts_s;
    vs.playing = true;
    vs.decoder = r.dec;
    // Avvia l'audio (handle libav separato + thread). null se il file è muto.
    vs.audio = AudioPlayer.start(path_z.ptr, gpa);
    // Audio come clock master del video: il loop lo coordina il present, non
    // l'auto-loop del thread audio (vedi campo `loop` in AudioPlayer).
    if (vs.audio) |a| a.loop.store(false, .monotonic);
    return .{ .rgba = r.rgba, .w = r.w, .h = r.h };
}

/// Decoder + poster per la RIACCENSIONE del solo video (toggle 'v'): apre il
/// container su `path` (file o URL) e avvia il thread; l'audio in corso non
/// viene toccato. Il chiamante installa `dec` in `VideoState` sotto `mutex`.
pub const VideoOnly = struct { dec: *VideoDecoder, rgba: []u8, w: u32, h: u32 };

pub fn openVideoOnly(path: []const u8, gpa: std.mem.Allocator) !VideoOnly {
    if (comptime @import("build_options").video) {
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);
        const r = try VideoDecoder.start(path_z.ptr, gpa, video_max_dim);
        return .{ .dec = r.dec, .rgba = r.rgba, .w = r.w, .h = r.h };
    }
    return error.NoVideo;
}

/// Come `setupVideo`, ma per uno stream remoto con URL video e URL audio
/// SEPARATI (yt-dlp risolve i formati DASH di YouTube su due URL distinti; con
/// un formato muxed i due URL coincidono). Nessuno stripping di frammenti `#`:
/// gli URL vanno passati a libav così come sono. Usato dalla ricerca YouTube
/// (`yt_search.openWorker`) su uno stato LOCALE, fuori dai lock.
pub fn setupStream(vs: *VideoState, video_url: []const u8, audio_url: []const u8, gpa: std.mem.Allocator) !VideoFirst {
    if (comptime !@import("build_options").video) return error.NoVideo;
    const vurl_z = try gpa.dupeZ(u8, video_url);
    defer gpa.free(vurl_z);
    const aurl_z = try gpa.dupeZ(u8, audio_url);
    defer gpa.free(aurl_z);

    const r = try VideoDecoder.start(vurl_z.ptr, gpa, video_max_dim);
    errdefer r.dec.stopAndDestroy();

    vs.dur_s = r.dec.duration_s;
    vs.pos_s = r.pts_s;
    vs.shown_pts = r.pts_s;
    vs.playing = true;
    vs.decoder = r.dec;
    // Audio dal SUO URL (stream DASH separato). null se non si apre: video muto.
    vs.audio = AudioPlayer.start(aurl_z.ptr, gpa);
    // Loop coordinato dal present (vedi `loop` in AudioPlayer).
    if (vs.audio) |a| a.loop.store(false, .monotonic);
    return .{ .rgba = r.rgba, .w = r.w, .h = r.h };
}

/// Apre SOLO l'audio di un file (mp3, wav, flac, ogg…) e mette `vs` in modalità
/// visualizzatore: nessun player video, l'oscilloscopio viene disegnato dai
/// campioni live in `advanceAudio`+`drawOscilloscope`. Ritorna un canvas iniziale
/// (→ `static_rgba`) così la finestra nasce già dimensionata come un video. Usato
/// da `nav.startVideo` come fallback quando `setupVideo` non trova stream video.
pub fn setupAudio(vs: *VideoState, path: []const u8, gpa: std.mem.Allocator) !VideoFirst {
    if (comptime @import("build_options").video) {
        var clean: []const u8 = path;
        if (std.mem.indexOfScalar(u8, path, '#')) |h| clean = path[0..h];
        const path_z = try gpa.dupeZ(u8, clean);
        defer gpa.free(path_z);

        const a = AudioPlayer.start(path_z.ptr, gpa) orelse return error.NoAudio;
        errdefer a.stopAndDestroy();

        const w: u32 = 960;
        const h: u32 = 540;
        // 4-byte aligned: drawOscBackground riempie le righe come parole u32
        // (stesso pattern del framebuffer del worker in gui.zig).
        const rgba = try gpa.alignedAlloc(u8, .@"4", @as(usize, w) * h * 4);
        drawOscBackground(rgba, w, h);

        vs.audio = a;
        vs.audio_only = true;
        vs.decoder = null;
        vs.dur_s = a.duration_s;
        vs.pos_s = 0;
        vs.shown_pts = 0;
        vs.playing = true;
        return .{ .rgba = rgba, .w = w, .h = h };
    }
    return error.NoAudio;
}

/// Avanza la riproduzione di `dt` secondi: applica un seek pendente, fa avanzare
/// `pos_s` agganciandolo al clock audio master, gestisce il loop a fine video e
/// SCEGLIE dalla coda del decoder il frame all'altezza di `pos_s` (scartando i
/// più vecchi). NON decodifica qui: il thread del decoder produce in anticipo,
/// quindi uno stallo di rete/decode non blocca il present — che intanto tiene
/// l'ultimo frame — e il video si riaggancia scartando i frame in ritardo invece
/// di accumularlo. Ritorna `true` se ha aggiornato il frame in `sink.rgba`.
pub fn advanceVideo(sink: FrameSink, vs: *VideoState, dt: f32) bool {
    const dec = vs.decoder orelse return false;

    // 1. Seek richiesto dall'input: svuota la coda del decoder e riposiziona
    // decoder e audio. `audio_clk_prev` a sentinella così la drift riparte pulita.
    if (vs.seek_to >= 0) {
        dec.seekAndFlush(vs.seek_to);
        if (comptime @import("build_options").video) {
            if (vs.audio) |a| a.seek(vs.seek_to);
        }
        vs.pos_s = vs.seek_to;
        vs.audio_clk_prev = -1;
        vs.seek_to = -1;
    }

    // 2. `pos_s` avanza col wall-clock (`dt`) — cadenza regolare, non eredita gli
    // scatti da ~20 ms del clock audio — e, se l'audio DRENA davvero, si corregge
    // verso di esso (clock master): deriva grande (avvio/seek/loop) → snap duro,
    // piccola → nudge impercettibile. Audio fermo o assente → puro wall-clock, così
    // il video non si congela mai per colpa dell'audio.
    var drained = false;
    var audio_pos: f64 = 0;
    if (comptime @import("build_options").video) {
        if (vs.audio) |a| {
            a.setPlaying(vs.playing);
            const ac = a.clockSeconds();
            if (ac > vs.audio_clk_prev + 0.0005) drained = true;
            vs.audio_clk_prev = ac;
            audio_pos = ac;
        }
    }
    if (vs.playing) {
        vs.pos_s += dt;
        if (drained) {
            const threshold: f64 = if (dec.frame_rate > 30.0) 0.035 else 0.065;
            const err = audio_pos - vs.pos_s;
            if (@abs(err) > threshold) vs.pos_s = audio_pos else vs.pos_s += err * 0.05;
        }
    }

    // 3. Loop a fine video, coordinato con l'audio: durata nota → `pos_s >= dur_s`;
    // ignota → coda del decoder esaurita a EOF. Riavvolge entrambi e riparte da 0;
    // la coda è vuota, niente da presentare finché il decoder non la ripopola.
    const at_end = (vs.dur_s > 0 and vs.pos_s >= vs.dur_s) or
        (vs.dur_s <= 0 and vs.playing and dec.drained());
    if (at_end) {
        dec.seekAndFlush(0);
        if (comptime @import("build_options").video) {
            if (vs.audio) |a| a.seek(0);
        }
        vs.pos_s = 0;
        vs.shown_pts = 0;
        vs.audio_clk_prev = -1;
        return false;
    }

    // 4. Presenta dalla coda il frame più recente con `pts <= pos_s`, scartando i
    // più vecchi. Se non è ancora pronto (decoder indietro) tiene l'ultimo frame.
    const picked = dec.pickInto(vs.pos_s, sink.gpa, sink.rgba, sink.w, sink.h);
    if (picked.presented) {
        vs.shown_pts = picked.pts_s;
        return true;
    }
    return false;
}

/// Modalità audio-only: aggiorna la temporizzazione (posizione, seek, play/pausa)
/// dal clock audio. Non decodifica nulla — il "frame" è l'oscilloscopio, disegnato
/// a parte con `drawOscilloscope`. Ritorna true in riproduzione (il tracciato si
/// muove → il chiamante ripresenta) e false in pausa (frame congelato).
pub fn advanceAudio(vs: *VideoState, dt: f32) bool {
    if (comptime @import("build_options").video) {
        if (vs.seek_to >= 0) {
            if (vs.audio) |a| a.seek(vs.seek_to);
            vs.pos_s = vs.seek_to;
            vs.seek_to = -1;
            vs.scope_head = 0; // fuori banda → il draw riaggancia al nuovo flusso
        } else if (vs.audio) |a| {
            a.setPlaying(vs.playing);
            // Il clock audio è la verità: in pausa è fermo, a fine brano l'auto-loop
            // del thread audio lo riporta a 0 e la barra riparte da capo.
            if (vs.playing) {
                vs.pos_s = a.clockSeconds();
                // Testina al wall-clock: scorre di `dt·rate` campioni. In pausa NON
                // avanza (frame congelato). Il clamp entro la banda valida del ring
                // (e il riaggancio se ne esce) sta nel draw, che rilegge `scope_w`.
                vs.scope_head += @as(f64, dt) * AudioPlayer.scope_rate;
            }
        }
        if (vs.dur_s > 0 and vs.pos_s > vs.dur_s) vs.pos_s = vs.dur_s;
        return vs.playing;
    }
    return false;
}

// ── Oscilloscopio stile Winamp (neon glow su vetro) ─────────────────────────
// Fondo TRASLUCIDO (alpha < 255): come per i documenti di testo, sotto c'è il
// pannello di vetro di zrame con il blur del compositore. Più coprente ai bordi
// (il neon vuole scuro dietro), più vetro al centro.
const osc_bg_edge = [4]u8{ 3, 5, 9, 175 }; // ai bordi: quasi nero
const osc_bg_center = [4]u8{ 10, 16, 26, 115 }; // al centro: blu notte, più blur

/// Fondo a gradiente verticale traslucido. Ogni riga è un colore solido: si
/// impacchetta un pixel u32 (byte order R,G,B,A) e si riempie la riga con un
/// @memset di parole — ordini di grandezza più veloce dei 4 store scalari per
/// pixel di prima, e a 60 Hz su una finestra grande il fondo era il costo
/// dominante del visualizzatore.
fn drawOscBackground(buf: []u8, W: u32, H: u32) void {
    if (W == 0 or H == 0) return;
    const words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buf[0 .. @as(usize, W) * H * 4]));
    const half: f32 = @as(f32, @floatFromInt(H)) * 0.5;
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        const dy = @abs(@as(f32, @floatFromInt(y)) - half) / @max(1.0, half); // 0 centro → 1 bordo
        const t = (1.0 - dy) * (1.0 - dy); // luce concentrata al centro
        var px: u32 = 0;
        inline for (0..4) |ch| {
            const e: f32 = @floatFromInt(osc_bg_edge[ch]);
            const m: f32 = @floatFromInt(osc_bg_center[ch]);
            const v: u32 = @intFromFloat(e + (m - e) * t);
            px |= v << (8 * ch);
        }
        const row = @as(usize, y) * W;
        @memset(words[row .. row + W], px);
    }
}

/// Somma additiva (con clamp a 255) di un colore sul pixel RGBA — il "bloom" neon
/// quando linea e glow si sovrappongono. Alza anche l'ALPHA dell'intensità del
/// colore: sul fondo traslucido il tracciato si porta la propria copertura (core
/// quasi opaco, alone semi-trasparente sul vetro). Aritmetica intera pura: niente
/// conversioni float per pixel nel loop più caldo del visualizzatore.
fn addPix(buf: []u8, idx: usize, r: u16, g: u16, b: u16) void {
    buf[idx + 0] = @intCast(@min(255, @as(u16, buf[idx + 0]) + r));
    buf[idx + 1] = @intCast(@min(255, @as(u16, buf[idx + 1]) + g));
    buf[idx + 2] = @intCast(@min(255, @as(u16, buf[idx + 2]) + b));
    buf[idx + 3] = @intCast(@min(255, @as(u16, buf[idx + 3]) + @max(r, @max(g, b))));
}

/// Colore del tracciato per magnitudine 0..1: verde al centro → giallo → rosso ai
/// picchi (gradiente stile analizzatore Winamp).
fn oscColor(mag: f32) [3]u8 {
    const m = std.math.clamp(mag, 0.0, 1.0);
    if (m < 0.5) {
        const t = m / 0.5; // verde → giallo
        return .{ @intFromFloat(60.0 + 195.0 * t), 255, @intFromFloat(120.0 * (1.0 - t)) };
    }
    const t = (m - 0.5) / 0.5; // giallo → rosso
    return .{ 255, @intFromFloat(255.0 * (1.0 - 0.75 * t)), 0 };
}

/// Disegna l'oscilloscopio Winamp: fondo scuro, linea centrale fioca e il
/// tracciato dei campioni live (colonna verticale connessa, colore per ampiezza).
pub fn drawOscilloscope(buf: []u8, W: u32, H: u32, vs: *VideoState) void {
    drawOscBackground(buf, W, H);
    if (W == 0 or H == 0) return;
    if (comptime !@import("build_options").video) return;
    const a = vs.audio orelse return;

    const Hi: i32 = @intCast(H);
    const cyf: f32 = @as(f32, @floatFromInt(H)) * 0.5;
    const cy: i32 = @intFromFloat(cyf);

    // Linea centrale di riferimento: glow orizzontale fioco (additivo). Il colore
    // è costante lungo la riga: convertito a interi UNA volta per banda.
    {
        const band: i32 = @max(@as(i32, 1), @divTrunc(Hi, 260));
        var dyi: i32 = -band;
        while (dyi <= band) : (dyi += 1) {
            const yy = cy + dyi;
            if (yy < 0 or yy >= Hi) continue;
            const f = 1.0 - @abs(@as(f32, @floatFromInt(dyi))) / @as(f32, @floatFromInt(band + 1));
            const lr: u16 = @intFromFloat(4.0 * f);
            const lg: u16 = @intFromFloat(20.0 * f);
            const lb: u16 = @intFromFloat(12.0 * f);
            const row = @as(usize, @intCast(yy)) * W;
            var x: u32 = 0;
            while (x < W) : (x += 1) addPix(buf, (row + x) * 4, lr, lg, lb);
        }
    }

    // ~2048 campioni (~43 ms) danno un tracciato stabile ma vivo. Mappati sulle
    // colonne della finestra, con linea connessa tra colonne adiacenti.
    var samples: [2048]f32 = undefined;
    const n: usize = @min(samples.len, @max(@as(usize, 1), @as(usize, W)));

    // Testina di lettura ancorata al wall-clock (avanzata in `advanceAudio`),
    // riclampata sulla banda valida del ring RILEGGENDO `scope_w` ora. Latenza
    // MINIMA: nessun buffer artificiale dietro la punta — quando la testina
    // raggiunge l'ultimo campione (`> scope_w`, tra un blocco e l'altro) si aggancia
    // lì (`= scope_w`) e riparte appena arriva un blocco nuovo. Così il bordo destro
    // del tracciato è sempre il campione più recente disponibile: media ~mezzo
    // blocco di ritardo. Se resta troppo indietro (pausa lunga/seek/underrun) →
    // riaggancio secco alla punta.
    const cap = AudioPlayer.scope_capacity;
    const w = a.scopeWritten();
    const min_end: usize = if (w > cap - n) w - (cap - n) else 0;
    var end: usize = if (vs.scope_head <= 0) 0 else @intFromFloat(vs.scope_head);
    if (end > w or end < min_end) {
        end = w; // aggancio alla punta (nessun lag artificiale)
        vs.scope_head = @floatFromInt(end);
    }
    a.copyScopeAt(samples[0..n], end);

    const amp: f32 = @as(f32, @floatFromInt(H)) * 0.44;
    const den: usize = @max(@as(usize, 1), @as(usize, W) - 1);
    // Raggio del glow: scala con l'altezza (~3-9 px) per un neon coerente a ogni
    // dimensione di finestra. `invR` normalizza il falloff.
    const R: i32 = @max(@as(i32, 5), @divTrunc(Hi, 90));
    const invR: f32 = 1.0 / @as(f32, @floatFromInt(R + 1));
    var prev_y: i32 = cy;
    var x: u32 = 0;
    while (x < W) : (x += 1) {
        const si = (@as(usize, x) * (n - 1)) / den;
        const s = std.math.clamp(samples[@min(si, n - 1)], -1.0, 1.0);
        const y: i32 = @intFromFloat(cyf - s * amp);
        const col = oscColor(@abs(s));
        const cr: f32 = @floatFromInt(col[0]);
        const cg: f32 = @floatFromInt(col[1]);
        const cb: f32 = @floatFromInt(col[2]);
        // Core: tiene la tinta neon (0.8·colore) + spinta bianca contenuta.
        // Costante lungo la colonna → interi precalcolati fuori dal loop verticale.
        const core_r: u16 = @intFromFloat(cr * 0.8 + 95.0);
        const core_g: u16 = @intFromFloat(cg * 0.8 + 95.0);
        const core_b: u16 = @intFromFloat(cb * 0.8 + 95.0);
        // Segmento connesso tra colonne: core pieno tra prev_y..y, glow additivo ±R.
        const ylo = @min(prev_y, y);
        const yhi = @max(prev_y, y);
        var yy = @max(@as(i32, 0), ylo - R);
        const yy_end = @min(Hi - 1, yhi + R);
        while (yy <= yy_end) : (yy += 1) {
            const idx = (@as(usize, @intCast(yy)) * W + x) * 4;
            if (yy >= ylo and yy <= yhi) {
                addPix(buf, idx, core_r, core_g, core_b);
            } else {
                const d: f32 = @floatFromInt(if (yy < ylo) ylo - yy else yy - yhi);
                const f = 1.0 - d * invR; // 0..1
                if (f > 0) {
                    const g2 = f * f * 1.35; // falloff morbido, alone con più corpo
                    addPix(buf, idx, @intFromFloat(cr * g2), @intFromFloat(cg * g2), @intFromFloat(cb * g2));
                }
            }
        }
        prev_y = y;
    }
}

/// Alpha-blend src-over di un colore sul pixel RGBA in `buf[idx..]`.
fn blendPixel(buf: []u8, idx: usize, r: u8, g: u8, b: u8, a: u8) void {
    const af: u32 = a;
    const inv: u32 = 255 - af;
    buf[idx + 0] = @intCast((@as(u32, r) * af + @as(u32, buf[idx + 0]) * inv) / 255);
    buf[idx + 1] = @intCast((@as(u32, g) * af + @as(u32, buf[idx + 1]) * inv) / 255);
    buf[idx + 2] = @intCast((@as(u32, b) * af + @as(u32, buf[idx + 2]) * inv) / 255);
    buf[idx + 3] = @max(buf[idx + 3], a);
}

/// Triangolo "play" pieno (punta a destra) fuso sul buffer RGBA, alpha `a`.
fn fillPlayTriangle(buf: []u8, W: u32, H: u32, cx: f32, cy: f32, s: f32, a: f32) void {
    const half = s / 2.0;
    const left = cx - s * 0.35;
    const right = cx + s * 0.45;
    const alpha: u8 = @intFromFloat(@round(255.0 * std.math.clamp(a, 0.0, 1.0)));
    var y: i32 = @intFromFloat(@floor(cy - half));
    const y1: i32 = @intFromFloat(@ceil(cy + half));
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    while (y < y1) : (y += 1) {
        if (y < 0 or y >= hi) continue;
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const dy = @abs(fy - cy);
        if (dy > half) continue;
        const frac = 1.0 - dy / half; // 1 al centro, 0 agli estremi
        const xr = left + (right - left) * frac;
        var x: i32 = @intFromFloat(@floor(left));
        const xend: i32 = @intFromFloat(@ceil(xr));
        while (x < xend) : (x += 1) {
            if (x < 0 or x >= wi) continue;
            const off = (@as(usize, @intCast(y)) * W + @as(usize, @intCast(x))) * 4;
            blendPixel(buf, off, 255, 255, 255, alpha);
        }
    }
}

/// Rettangolo del video in aspect-fit CENTRATO nell'area contenuto (`panel`). Il
/// frame video è composto in un buffer STRETTO (`w`×`h`): è zrame a centrarlo nel
/// vetro e ad arrotondarne gli angoli (content_radius), esattamente come per ogni
/// altro tipo di file. `off_x/off_y` è l'offset di centratura che l'hit-test del
/// mouse sottrae; la divisione intera rispecchia la centratura di `chrome.composeContent`.
pub const FitRect = struct { off_x: f32, off_y: f32, w: u32, h: u32 };

pub fn videoFitRect(panel_w: u32, panel_h: u32, vid_w: u32, vid_h: u32) FitRect {
    if (panel_w == 0 or panel_h == 0 or vid_w == 0 or vid_h == 0)
        return .{ .off_x = 0, .off_y = 0, .w = @max(1, panel_w), .h = @max(1, panel_h) };
    const va = @as(f32, @floatFromInt(vid_w)) / @as(f32, @floatFromInt(vid_h));
    const ca = @as(f32, @floatFromInt(panel_w)) / @as(f32, @floatFromInt(panel_h));
    var w = panel_w;
    var h = panel_h;
    if (va > ca) {
        h = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(panel_w)) / va))));
    } else {
        w = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(panel_h)) * va))));
    }
    return .{ .off_x = @floatFromInt((panel_w - w) / 2), .off_y = @floatFromInt((panel_h - h) / 2), .w = w, .h = h };
}

/// Layout della riga di controlli (coordinate locali all'area video, origine in alto
/// a sinistra del video). Una sola riga: play/pausa · tempo · timeline · durata.
const Ctrl = struct {
    cy: f32, // centro verticale della riga
    play_x: f32, // centro del pulsante play/pausa
    el_x: f32, // inizio testo tempo trascorso
    tl_x0: f32, // inizio timeline
    tl_x1: f32, // fine timeline
    dur_x: f32, // inizio testo durata
    scrim_h: f32,
};

fn ctrlLayout(vw: u32, vh: u32) Ctrl {
    const w: f32 = @floatFromInt(vw);
    const h: f32 = @floatFromInt(vh);
    const pad: f32 = 18.0;
    const time_w: f32 = 52.0; // larghezza riservata a "MM:SS"
    const gap: f32 = 12.0;
    const cy = h - 26.0;
    const play_x = pad + 8.0;
    const el_x = play_x + 22.0;
    const tl_x0 = el_x + time_w + gap;
    const tl_x1 = w - pad - time_w - gap;
    const dur_x = w - pad - time_w;
    return .{ .cy = cy, .play_x = play_x, .el_x = el_x, .tl_x0 = tl_x0, .tl_x1 = tl_x1, .dur_x = dur_x, .scrim_h = @min(h, 96.0) };
}

/// Formatta i secondi in "M:SS" (o "H:MM:SS" oltre l'ora) dentro `out`.
fn formatTime(sec: f64, out: []u8) []const u8 {
    const total: u64 = if (sec > 0) @intFromFloat(sec) else 0;
    const s = total % 60;
    const m = (total / 60) % 60;
    const hh = total / 3600;
    if (hh > 0) return std.fmt.bufPrint(out, "{d}:{d:0>2}:{d:0>2}", .{ hh, m, s }) catch out[0..0];
    return std.fmt.bufPrint(out, "{d}:{d:0>2}", .{ m, s }) catch out[0..0];
}

/// Disegna testo monospazio (Hack) a partire da (`x`,`baseline`), colore chiaro
/// modulato da `a`. Coordinate nel buffer `W`×`H`.
fn drawText(buf: []u8, W: u32, H: u32, raster: *glyph.Raster, x: i32, baseline: i32, text: []const u8, a: f32) void {
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    const cell = raster.advance;
    if (cell <= 0) return;
    var pen_x = x;
    var view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const gph = raster.getGlyph(.regular, cp) catch {
            pen_x += cell;
            continue;
        };
        if (gph.bitmap.len != 0) {
            const gx0 = pen_x + gph.xoff;
            const gy0 = baseline + gph.yoff;
            var gy: i32 = 0;
            while (gy < gph.h) : (gy += 1) {
                const py = gy0 + gy;
                if (py < 0 or py >= hi) continue;
                var gx: i32 = 0;
                while (gx < gph.w) : (gx += 1) {
                    const px = gx0 + gx;
                    if (px < 0 or px >= wi) continue;
                    const cov = gph.bitmap[@intCast(gy * gph.w + gx)];
                    if (cov == 0) continue;
                    const av: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(cov)) * a));
                    if (av == 0) continue;
                    blendPixel(buf, @intCast((py * wi + px) * 4), 235, 238, 245, av);
                }
            }
        }
        pen_x += cell;
    }
}

/// Controlli overlay su UNA riga (play/pausa · tempo · timeline · durata), stile
/// player moderno, disegnati sul buffer video `W`×`H` (l'area video è l'intero
/// buffer), modulati dall'alpha di fade `vs.controls`.
pub fn drawVideoControls(buf: []u8, W: u32, H: u32, vs: *VideoState, raster: ?*glyph.Raster) void {
    const a = std.math.clamp(vs.controls, 0.0, 1.0);
    if (a <= 0.01) return;
    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);
    const L = ctrlLayout(W, H);
    const vwf: f32 = @floatFromInt(W);

    // Scrim: sfuma da trasparente a scuro verso il basso.
    const bands: u32 = 12;
    var i: u32 = 0;
    while (i < bands) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(bands));
        const by = @as(f32, @floatFromInt(H)) - L.scrim_h + t * L.scrim_h;
        const bh = L.scrim_h / @as(f32, @floatFromInt(bands)) + 1.0;
        canvas.fillRoundedRect(0, by, vwf, bh, 0, paint.Color.rgba(0, 0, 0, 0.55 * t * t * a));
    }

    // Timeline + knob.
    const bar_h: f32 = 4.0;
    const tl_y = L.cy - bar_h / 2.0;
    const tl_x = L.tl_x0;
    const tl_w = @max(1.0, L.tl_x1 - L.tl_x0);
    const prog: f32 = if (vs.dur_s > 0) @floatCast(std.math.clamp(vs.pos_s / vs.dur_s, 0.0, 1.0)) else 0.0;
    canvas.fillProgressBar(tl_x, tl_y, tl_w, bar_h, bar_h / 2.0, prog, paint.Color.rgba(255, 255, 255, 0.28 * a), paint.Color.rgba(237, 45, 45, 0.98 * a));
    const knob_x = tl_x + tl_w * prog;
    const knob_r: f32 = if (vs.scrubbing) 8.0 else 6.0;
    canvas.fillRoundedRect(knob_x - knob_r, L.cy - knob_r, knob_r * 2.0, knob_r * 2.0, knob_r, paint.Color.rgba(255, 255, 255, a));

    // Pulsante play/pausa (a sinistra, sulla stessa riga).
    const btn_cx = L.play_x;
    const btn_cy = L.cy;
    const s: f32 = 15.0;
    if (vs.playing) {
        const bw: f32 = 3.5;
        const gap: f32 = 3.0;
        canvas.fillRoundedRect(btn_cx - gap - bw, btn_cy - s / 2.0, bw, s, 1.5, paint.Color.rgba(255, 255, 255, a));
        canvas.fillRoundedRect(btn_cx + gap, btn_cy - s / 2.0, bw, s, 1.5, paint.Color.rgba(255, 255, 255, a));
    } else {
        fillPlayTriangle(buf, W, H, btn_cx, btn_cy, s, a);
    }

    // Testo tempo trascorso / durata (monospazio) allineato alla riga.
    if (raster) |r| {
        const baseline = @as(i32, @intFromFloat(L.cy)) + @divFloor(r.ascent + r.descent, 2);
        var el_buf: [16]u8 = undefined;
        var du_buf: [16]u8 = undefined;
        drawText(buf, W, H, r, @intFromFloat(L.el_x), baseline, formatTime(vs.pos_s, &el_buf), a);
        if (vs.dur_s > 0) drawText(buf, W, H, r, @intFromFloat(L.dur_x), baseline, formatTime(vs.dur_s, &du_buf), a);
    }
}

/// Codepoint di una stringa UTF-8 (colonne, essendo il raster monospazio).
fn cpCount(s: []const u8) usize {
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(s) catch return s.len;
    var it = view.iterator();
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

/// Sottotitolo stile YouTube: righe centrate in basso (sopra la riga dei
/// controlli), testo bianco su pill scura. `text` è una riga logica già pulita
/// (vedi yt_search.parseVtt): il wrapping a parole avviene qui, sulla larghezza
/// del video. Al più 4 righe (le eccedenze vengono troncate).
pub fn drawSubtitle(buf: []u8, W: u32, H: u32, raster: *glyph.Raster, text: []const u8) void {
    const cell = raster.advance;
    if (cell <= 0 or W < 120 or H < 120) return;
    const max_cols: usize = @intCast(@max(@divTrunc(@as(i32, @intCast(W)) - 48, cell), 8));

    // Wrapping greedy a parole: ogni riga è una slice contigua di `text`
    // (le parole sono già separate da spazi singoli).
    const Line = struct { s: usize, e: usize, cols: usize };
    var lines_arr: [4]Line = undefined;
    var nl: usize = 0;
    var cur: ?Line = null;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |word| {
        const w_cols = cpCount(word);
        const off = @intFromPtr(word.ptr) - @intFromPtr(text.ptr);
        if (cur) |*c| {
            if (c.cols + 1 + w_cols <= max_cols) {
                c.e = off + word.len;
                c.cols += 1 + w_cols;
                continue;
            }
            if (nl >= lines_arr.len) break;
            lines_arr[nl] = c.*;
            nl += 1;
        }
        cur = .{ .s = off, .e = off + word.len, .cols = w_cols };
    }
    if (cur) |c| {
        if (nl < lines_arr.len) {
            lines_arr[nl] = c;
            nl += 1;
        }
    }
    if (nl == 0) return;

    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);
    const line_h = raster.ascent - raster.descent;
    const pill_h = line_h + 8;
    const line_gap: i32 = 4;
    // Blocco ancorato sopra la riga dei controlli (cy = H-26, knob r 8).
    var y = @as(i32, @intCast(H)) - 48 - @as(i32, @intCast(nl)) * (pill_h + line_gap);
    for (lines_arr[0..nl]) |ln| {
        const tw = @as(i32, @intCast(ln.cols)) * cell;
        const px = @divTrunc(@as(i32, @intCast(W)) - tw, 2);
        canvas.fillRoundedRect(@floatFromInt(px - 8), @floatFromInt(y), @floatFromInt(tw + 16), @floatFromInt(pill_h), 5.0, paint.Color.rgba(0, 0, 0, 0.72));
        drawText(buf, W, H, raster, px, y + 4 + raster.ascent, text[ln.s..ln.e], 1.0);
        y += pill_h + line_gap;
    }
}

/// Hit-test dei controlli, in coordinate locali all'area video (`vw`×`vh`).
pub const VideoHit = enum { none, toggle, timeline };
pub fn videoControlsHit(vw: u32, vh: u32, x: f32, y: f32) VideoHit {
    const L = ctrlLayout(vw, vh);
    // Pulsante play/pausa.
    if (@abs(x - L.play_x) <= 16.0 and @abs(y - L.cy) <= 16.0) return .toggle;
    // Timeline: banda generosa attorno alla barra.
    if (y >= L.cy - 12.0 and y <= L.cy + 12.0 and x >= L.tl_x0 - 8.0 and x <= L.tl_x1 + 8.0) return .timeline;
    return .none;
}

/// Frazione 0..1 della timeline per l'ascissa `x` (coordinate locali all'area video).
pub fn videoTimelineFrac(vw: u32, vh: u32, x: f32) f32 {
    const L = ctrlLayout(vw, vh);
    const w = L.tl_x1 - L.tl_x0;
    if (w <= 0) return 0;
    return std.math.clamp((x - L.tl_x0) / w, 0.0, 1.0);
}
