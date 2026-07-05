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
const zicro = @import("zicro");
const paint = zicro.paint;

// player.zig fa un @cImport degli header libav: importalo solo quando il video è
// attivo, con uno stub minimale altrimenti (vedi il gate `has_video` in gui.zig).
const player_mod = if (@import("build_options").video) @import("decoders/player.zig") else struct {
    pub const Player = struct {
        pub fn deinit(_: *Player) void {}
    };
    pub const Frame = struct {};
};

/// Frame video decodificato al massimo a questa dimensione per lato (limita memoria
/// e tempo di rasterizzazione: i 4K si riscalano a 1920 sul lato lungo).
const video_max_dim: usize = 1920;

/// Stato del player video nativo (libav). Il *worker* è l'unico a toccare il
/// `Player` (decodifica, seek); il thread finestra comunica solo via flag sotto
/// `mutex` (play/pausa, `seek_to`, attività del mouse per l'auto-hide dei controlli).
pub const VideoState = struct {
    player: ?player_mod.Player = null,
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

    pub fn isActive(self: *const VideoState) bool {
        return self.player != null;
    }

    /// Chiude il container libav. Idempotente (no-op se non c'è player).
    pub fn deinit(self: *VideoState) void {
        if (self.player) |*p| p.deinit();
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

/// Apre il player video, decodifica il primo frame (poster) in RGBA e inizializza
/// `vs` (durata, posizione, temporizzazione, `playing`). Il chiamante prende
/// possesso di `.rgba` (→ `static_rgba`) e di `vs.player` (chiuso da `deinit`).
pub fn setupVideo(vs: *VideoState, path: []const u8, gpa: std.mem.Allocator) !VideoFirst {
    var clean: []const u8 = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| clean = path[0..h];
    const path_z = try gpa.dupeZ(u8, clean);
    defer gpa.free(path_z);

    var p = try player_mod.Player.open(path_z.ptr);
    errdefer p.deinit();
    const frame = (try p.nextFrame(video_max_dim, gpa)) orelse return error.NoFrameDecoded;
    defer gpa.free(frame.pixels);

    const w: u32 = @intCast(frame.width);
    const h: u32 = @intCast(frame.height);
    const rgba = try gpa.alloc(u8, @as(usize, w) * h * 4);
    rgbToRgba(frame.pixels, rgba, @as(usize, w) * h);

    vs.dur_s = p.duration_s;
    vs.pos_s = frame.pts_s;
    vs.shown_pts = frame.pts_s;
    vs.playing = true;
    vs.player = p;
    return .{ .rgba = rgba, .w = w, .h = h };
}

/// Espande RGB24 impacchettato in RGBA8 opaco (alpha=255).
fn rgbToRgba(src: []const u8, dst: []u8, npx: usize) void {
    var i: usize = 0;
    while (i < npx) : (i += 1) {
        dst[i * 4 + 0] = src[i * 3 + 0];
        dst[i * 4 + 1] = src[i * 3 + 1];
        dst[i * 4 + 2] = src[i * 3 + 2];
        dst[i * 4 + 3] = 255;
    }
}

/// Sostituisce il frame corrente in `sink.rgba` con `fr` (RGB→RGBA), riallocando
/// solo se cambia la dimensione. Prende possesso di `fr.pixels` (lo libera).
fn updateVideoFrame(sink: FrameSink, fr: player_mod.Frame) void {
    const w: u32 = @intCast(fr.width);
    const h: u32 = @intCast(fr.height);
    const need = @as(usize, w) * h * 4;
    if (sink.rgba.*.len != need) {
        sink.gpa.free(sink.rgba.*);
        sink.rgba.* = sink.gpa.alloc(u8, need) catch {
            sink.rgba.* = &.{};
            sink.w.* = 0;
            sink.h.* = 0;
            sink.gpa.free(fr.pixels);
            return;
        };
    }
    rgbToRgba(fr.pixels, sink.rgba.*, @as(usize, w) * h);
    sink.w.* = w;
    sink.h.* = h;
    sink.gpa.free(fr.pixels);
}

/// Avanza la riproduzione di `dt` secondi: applica un seek pendente, fa avanzare
/// `pos_s`, gestisce il loop a fine video e decodifica in avanti finché il frame
/// mostrato raggiunge `pos_s` (recupero, con tetto di iterazioni per non stallare).
/// Ritorna `true` se ha aggiornato il frame in `sink.rgba` (→ serve ricomporre).
pub fn advanceVideo(sink: FrameSink, vs: *VideoState, dt: f32) bool {
    if (vs.seek_to >= 0) {
        if (vs.player) |*p| p.seek(vs.seek_to);
        vs.pos_s = vs.seek_to;
        vs.shown_pts = vs.seek_to - 1.0; // forza il decode del prossimo frame
        vs.seek_to = -1;
    } else if (vs.playing) {
        vs.pos_s += dt;
    }
    if (vs.dur_s > 0 and vs.pos_s >= vs.dur_s) {
        if (vs.player) |*p| p.seek(0);
        vs.pos_s = 0;
        vs.shown_pts = -1;
    }
    var decoded_any = false;
    var guard: u32 = 0;
    while (vs.shown_pts < vs.pos_s and guard < 8) : (guard += 1) {
        const p = &(vs.player.?);
        const maybe = p.nextFrame(video_max_dim, sink.gpa) catch null;
        if (maybe) |fr| {
            updateVideoFrame(sink, fr);
            vs.shown_pts = fr.pts_s;
            decoded_any = true;
        } else {
            p.seek(0); // EOF → loop
            vs.pos_s = 0;
            vs.shown_pts = 0;
            break;
        }
    }
    return decoded_any;
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

/// Controlli overlay stile YouTube: scrim sfumato in basso, timeline (primitiva
/// `fillProgressBar` di zicro) con knob scrubber e pulsante play/pausa. Tutto
/// modulato dall'alpha di fade `vs.controls`.
pub fn drawVideoControls(buf: []u8, W: u32, H: u32, vs: *VideoState) void {
    const a = std.math.clamp(vs.controls, 0.0, 1.0);
    const fw: f32 = @floatFromInt(W);
    const fh: f32 = @floatFromInt(H);
    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);

    // Scrim: banda scura che sfuma da trasparente (in alto) a scuro (in basso).
    const scrim_h = @min(fh, 120.0);
    const bands: u32 = 12;
    var i: u32 = 0;
    while (i < bands) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(bands));
        const by = fh - scrim_h + t * scrim_h;
        const bh = scrim_h / @as(f32, @floatFromInt(bands)) + 1.0;
        canvas.fillRoundedRect(0, by, fw, bh, 0, paint.Color.rgba(0, 0, 0, 0.5 * t * t * a));
    }

    // Timeline (progress bar) + knob dello scrubber.
    const margin: f32 = 18.0;
    const tl_h: f32 = 5.0;
    const tl_y = fh - 44.0;
    const tl_w = fw - margin * 2.0;
    const prog: f32 = if (vs.dur_s > 0) @floatCast(std.math.clamp(vs.pos_s / vs.dur_s, 0.0, 1.0)) else 0.0;
    canvas.fillProgressBar(margin, tl_y, tl_w, tl_h, tl_h / 2.0, prog, paint.Color.rgba(255, 255, 255, 0.28 * a), paint.Color.rgba(237, 45, 45, 0.95 * a));
    const knob_x = margin + tl_w * prog;
    const knob_r: f32 = if (vs.scrubbing) 9.0 else 7.0;
    canvas.fillRoundedRect(knob_x - knob_r, tl_y + tl_h / 2.0 - knob_r, knob_r * 2.0, knob_r * 2.0, knob_r, paint.Color.rgba(255, 255, 255, a));

    // Pulsante play/pausa (riga sotto la timeline, a sinistra).
    const btn_cx = margin + 8.0;
    const btn_cy = fh - 18.0;
    const s: f32 = 16.0;
    if (vs.playing) {
        const bw: f32 = 4.0;
        const gap: f32 = 3.0;
        canvas.fillRoundedRect(btn_cx - gap - bw, btn_cy - s / 2.0, bw, s, 1.5, paint.Color.rgba(255, 255, 255, a));
        canvas.fillRoundedRect(btn_cx + gap, btn_cy - s / 2.0, bw, s, 1.5, paint.Color.rgba(255, 255, 255, a));
    } else {
        fillPlayTriangle(buf, W, H, btn_cx, btn_cy, s, a);
    }
}

/// Hit-test dei controlli video (coordinate finestra). Ritorna l'azione del click.
pub const VideoHit = enum { none, toggle, timeline };
pub fn videoControlsHit(W: u32, H: u32, x: f32, y: f32) VideoHit {
    const fw: f32 = @floatFromInt(W);
    const fh: f32 = @floatFromInt(H);
    const margin: f32 = 18.0;
    // Timeline: banda generosa attorno alla barra (facile da agganciare).
    const tl_y = fh - 44.0;
    if (y >= tl_y - 12.0 and y <= tl_y + 16.0 and x >= margin - 6.0 and x <= fw - margin + 6.0) {
        return .timeline;
    }
    // Pulsante play/pausa.
    const btn_cx = margin + 8.0;
    const btn_cy = fh - 18.0;
    if (x >= btn_cx - 16.0 and x <= btn_cx + 16.0 and y >= btn_cy - 16.0 and y <= btn_cy + 16.0) {
        return .toggle;
    }
    return .none;
}

/// Frazione 0..1 della timeline corrispondente all'ascissa `x` (per il seek).
pub fn videoTimelineFrac(W: u32, x: f32) f32 {
    const fw: f32 = @floatFromInt(W);
    const margin: f32 = 18.0;
    const tl_w = fw - margin * 2.0;
    if (tl_w <= 0) return 0;
    return std.math.clamp((x - margin) / tl_w, 0.0, 1.0);
}
