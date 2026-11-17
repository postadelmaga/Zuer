//! Elementi comuni dei pannelli a griglia (YouTube, esploratore file): un solo
//! linguaggio visivo — fondo pieno che copre il contenuto, testo proporzionale
//! (Liberation Sans) con ellissi, miniature dagli angoli arrotondati, anello di
//! selezione, piccole icone disegnate. Tutto lavora sul frame RGBA del worker.

const std = @import("std");
const glyph = @import("glyph.zig");
const zicro = @import("zicro");
const paint = zicro.paint;

// ── Palette ──────────────────────────────────────────────────────────────────

/// Fondo dei pannelli: copre tutta la finestra (il contenuto sotto distrae).
pub const backdrop = paint.Color.rgba(11, 12, 17, 0.985);
/// Superfici rialzate: campo di ricerca, segmenti, tessere senza miniatura.
pub const surface = paint.Color.rgba(255, 255, 255, 0.06);
pub const surface_hi = paint.Color.rgba(255, 255, 255, 0.11);
pub const divider = paint.Color.rgba(255, 255, 255, 0.07);
pub const accent = paint.Color.rgba(122, 162, 255, 1.0);
pub const badge_bg = paint.Color.rgba(0, 0, 0, 0.66);

pub const fg = [3]u8{ 236, 238, 244 };
pub const dim = [3]u8{ 148, 154, 170 };
pub const faint = [3]u8{ 104, 110, 126 };
pub const warn = [3]u8{ 240, 170, 110 };
pub const err = [3]u8{ 240, 120, 110 };
pub const link = [3]u8{ 122, 162, 255 };
/// Testo su accento (segmento attivo, badge "in coda").
pub const on_accent = [3]u8{ 12, 16, 28 };

/// Corpi dei pannelli: testo (titoli, campo) e dettagli (metadati, badge).
pub const Fonts = struct {
    body: *glyph.Raster,
    small: *glyph.Raster,

    pub fn lineH(r: *const glyph.Raster) i32 {
        return r.ascent - r.descent;
    }
};

/// Area verticale entro cui disegnare (le card che scorrono escono dalla banda).
pub const ClipY = struct {
    y0: i32 = std.math.minInt(i32),
    y1: i32 = std.math.maxInt(i32),
};

// ── Testo ────────────────────────────────────────────────────────────────────

const ellipsis: u21 = 0x2026;

fn advanceOf(r: *glyph.Raster, style: glyph.Style, cp: u21) i32 {
    const g = r.getGlyph(style, cp) catch return 0;
    return g.advance;
}

/// Il carattere va disegnato? I controlli no; quelli che il font non ha (emoji,
/// simboli) nemmeno: meglio un buco che il quadratino.
fn drawable(r: *const glyph.Raster, style: glyph.Style, cp: u21) bool {
    if (cp < 0x20 or cp == 0x7f) return false;
    return r.hasGlyph(style, cp);
}

/// `drawable`, e in più uno spazio dopo un altro spazio non conta: dove spariscono
/// le emoji ("musica 🎷 jazz") non resta un buco doppio.
fn shows(r: *const glyph.Raster, style: glyph.Style, cp: u21, prev_space: *bool) bool {
    if (!drawable(r, style, cp)) return false;
    const sp = cp == ' ';
    defer prev_space.* = sp;
    return !(sp and prev_space.*);
}

/// Larghezza in pixel di `s`.
pub fn measure(r: *glyph.Raster, style: glyph.Style, s: []const u8) i32 {
    var w: i32 = 0;
    var prev_space = false;
    var view = std.unicode.Utf8View.init(s) catch return 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (!shows(r, style, cp, &prev_space)) continue;
        w += advanceOf(r, style, cp);
    }
    return w;
}

/// Byte di `s` che entrano in `max_w` px (a confine di codepoint).
pub fn fitBytes(r: *glyph.Raster, style: glyph.Style, s: []const u8, max_w: i32) usize {
    var w: i32 = 0;
    var view = std.unicode.Utf8View.init(s) catch return 0;
    var it = view.iterator();
    var end: usize = 0;
    var prev_space = false;
    while (it.nextCodepoint()) |cp| {
        if (shows(r, style, cp, &prev_space)) {
            w += advanceOf(r, style, cp);
            if (w > max_w) break;
        }
        end = it.i;
    }
    return end;
}

fn glyphAt(buf: []u8, W: u32, H: u32, r: *glyph.Raster, style: glyph.Style, cp: u21, pen_x: i32, baseline: i32, rgb: [3]u8, alpha: f32, x_lo: i32, x_hi: i32, clip: ClipY) void {
    const g = r.getGlyph(style, cp) catch return;
    if (g.bitmap.len == 0) return;
    const wi: i32 = @intCast(W);
    const y_lo = @max(clip.y0, 0);
    const y_hi = @min(clip.y1, @as(i32, @intCast(H)));
    const gx0 = pen_x + g.xoff;
    const gy0 = baseline + g.yoff;
    var gy: i32 = 0;
    while (gy < g.h) : (gy += 1) {
        const py = gy0 + gy;
        if (py < y_lo or py >= y_hi) continue;
        var gx: i32 = 0;
        while (gx < g.w) : (gx += 1) {
            const px = gx0 + gx;
            if (px < @max(x_lo, 0) or px >= @min(x_hi, wi)) continue;
            var cov: u32 = g.bitmap[@intCast(gy * g.w + gx)];
            if (cov == 0) continue;
            if (alpha < 1.0) cov = @intFromFloat(@as(f32, @floatFromInt(cov)) * alpha);
            blendPx(buf, @intCast((py * wi + px) * 4), rgb, @intCast(cov));
        }
    }
}

pub const TextOpts = struct {
    style: glyph.Style = .regular,
    /// Larghezza massima: oltre, il testo finisce con "…". 0 = nessun limite.
    max_w: i32 = 0,
    clip: ClipY = .{},
    /// Pixel visibili in orizzontale (il campo di ricerca scorre sotto i suoi bordi).
    x_lo: i32 = std.math.minInt(i32),
    x_hi: i32 = std.math.maxInt(i32),
    alpha: f32 = 1.0,
};

/// Disegna `s` dalla penna `x` sulla linea di base `baseline`; ritorna la larghezza
/// occupata. Con `max_w` il testo che non entra è troncato con un'ellissi.
pub fn text(buf: []u8, W: u32, H: u32, r: *glyph.Raster, x: i32, baseline: i32, s: []const u8, rgb: [3]u8, o: TextOpts) i32 {
    var end = s.len;
    var tail = false;
    if (o.max_w > 0 and measure(r, o.style, s) > o.max_w) {
        const ell_w = advanceOf(r, o.style, ellipsis);
        end = fitBytes(r, o.style, s, o.max_w - ell_w);
        // Niente spazio penzolante prima dell'ellissi.
        while (end > 0 and s[end - 1] == ' ') end -= 1;
        tail = true;
    }
    var pen = x;
    var view = std.unicode.Utf8View.init(s[0..end]) catch return 0;
    var it = view.iterator();
    var prev_space = false;
    while (it.nextCodepoint()) |cp| {
        if (!shows(r, o.style, cp, &prev_space)) continue;
        glyphAt(buf, W, H, r, o.style, cp, pen, baseline, rgb, o.alpha, o.x_lo, o.x_hi, o.clip);
        pen += advanceOf(r, o.style, cp);
    }
    if (tail) {
        glyphAt(buf, W, H, r, o.style, ellipsis, pen, baseline, rgb, o.alpha, o.x_lo, o.x_hi, o.clip);
        pen += advanceOf(r, o.style, ellipsis);
    }
    return pen - x;
}

/// Come `text`, centrato orizzontalmente su `cx`.
pub fn textCentered(buf: []u8, W: u32, H: u32, r: *glyph.Raster, cx: i32, baseline: i32, s: []const u8, rgb: [3]u8, o: TextOpts) void {
    var w = measure(r, o.style, s);
    if (o.max_w > 0) w = @min(w, o.max_w);
    _ = text(buf, W, H, r, cx - @divTrunc(w, 2), baseline, s, rgb, o);
}

/// Al più due righe a capo sulle parole, la seconda con l'ellissi se serve.
/// Ritorna il numero di righe usate.
pub fn text2(buf: []u8, W: u32, H: u32, r: *glyph.Raster, x: i32, baseline: i32, line_step: i32, s: []const u8, rgb: [3]u8, o: TextOpts) u8 {
    const t = std.mem.trim(u8, s, " ");
    if (o.max_w <= 0 or measure(r, o.style, t) <= o.max_w) {
        _ = text(buf, W, H, r, x, baseline, t, rgb, o);
        return 1;
    }
    var cut = fitBytes(r, o.style, t, o.max_w);
    // A capo all'ultimo spazio che entra (se non è troppo indietro).
    if (std.mem.lastIndexOfScalar(u8, t[0..cut], ' ')) |sp| {
        if (sp > cut / 2) cut = sp;
    }
    _ = text(buf, W, H, r, x, baseline, std.mem.trimEnd(u8, t[0..cut], " "), rgb, o);
    _ = text(buf, W, H, r, x, baseline + line_step, std.mem.trimStart(u8, t[cut..], " "), rgb, o);
    return 2;
}

pub fn blendPx(buf: []u8, idx: usize, rgb: [3]u8, a: u8) void {
    const av: u32 = a;
    const inv: u32 = 255 - av;
    buf[idx + 0] = @intCast((@as(u32, buf[idx + 0]) * inv + @as(u32, rgb[0]) * av) / 255);
    buf[idx + 1] = @intCast((@as(u32, buf[idx + 1]) * inv + @as(u32, rgb[1]) * av) / 255);
    buf[idx + 2] = @intCast((@as(u32, buf[idx + 2]) * inv + @as(u32, rgb[2]) * av) / 255);
    buf[idx + 3] = @max(buf[idx + 3], a);
}

// ── Miniature ────────────────────────────────────────────────────────────────

pub const Fit = enum {
    /// Riempie il riquadro tagliando l'eccesso (foto, video).
    cover,
    /// Tutta l'immagine, centrata sul fondo della tessera.
    contain,
};

/// Distanza con segno dal bordo di un rettangolo arrotondato (negativa dentro).
fn roundedSdf(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, rad: f32) f32 {
    const cx = x + w / 2;
    const cy = y + h / 2;
    const qx = @abs(px - cx) - (w / 2 - rad);
    const qy = @abs(py - cy) - (h / 2 - rad);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - rad;
}

/// Miniatura RGBA (`src`, opaca o no) nel riquadro `x,y,w,h` con angoli di raggio
/// `rad`. `cover` riempie e taglia, `contain` la centra intera: in quel caso il
/// riquadro è prima riempito con `bg`. Campionamento nearest, come le griglie.
pub fn thumb(canvas: *paint.Canvas, buf: []u8, W: u32, H: u32, x: i32, y: i32, w: i32, h: i32, src: []const u8, sw: u32, sh: u32, rad: f32, fit: Fit, bg: paint.Color, clip: ClipY) void {
    if (w <= 0 or h <= 0 or sw == 0 or sh == 0) return;
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const fsw: f32 = @floatFromInt(sw);
    const fsh: f32 = @floatFromInt(sh);
    // Rettangolo della sorgente da campionare e rettangolo di destinazione.
    var sx0: f32 = 0;
    var sy0: f32 = 0;
    var sx_w = fsw;
    var sy_h = fsh;
    var dx: i32 = x;
    var dy: i32 = y;
    var dw: i32 = w;
    var dh: i32 = h;
    switch (fit) {
        .cover => {
            const s = @max(fw / fsw, fh / fsh);
            sx_w = fw / s;
            sy_h = fh / s;
            sx0 = (fsw - sx_w) / 2;
            sy0 = (fsh - sy_h) / 2;
        },
        .contain => {
            canvas.fillRoundedRect(@floatFromInt(x), @floatFromInt(y), fw, fh, rad, bg);
            const s = @min(fw / fsw, fh / fsh);
            dw = @max(1, @as(i32, @intFromFloat(@round(fsw * s))));
            dh = @max(1, @as(i32, @intFromFloat(@round(fsh * s))));
            dx = x + @divTrunc(w - dw, 2);
            dy = y + @divTrunc(h - dh, 2);
        },
    }
    const wi: i32 = @intCast(W);
    const y_lo = @max(@max(dy, clip.y0), 0);
    const y_hi = @min(@min(dy + dh, clip.y1), @as(i32, @intCast(H)));
    const x_lo = @max(dx, 0);
    const x_hi = @min(dx + dw, wi);
    if (y_lo >= y_hi or x_lo >= x_hi) return;
    const words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buf[0 .. @as(usize, W) * H * 4]));
    const src_words: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, src[0 .. @as(usize, sw) * sh * 4]));
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const kx = sx_w / @as(f32, @floatFromInt(dw));
    const ky = sy_h / @as(f32, @floatFromInt(dh));
    var py = y_lo;
    while (py < y_hi) : (py += 1) {
        const sy: u32 = @min(sh - 1, @as(u32, @intFromFloat(sy0 + (@as(f32, @floatFromInt(py - dy)) + 0.5) * ky)));
        const srow = @as(usize, sy) * sw;
        const drow = @as(usize, @intCast(py)) * W;
        const cfy = @as(f32, @floatFromInt(py)) + 0.5;
        // Righe lontane dagli angoli: copia piena (il caso comune).
        const in_corner_rows = cfy < fy + rad or cfy > fy + fh - rad;
        var px = x_lo;
        while (px < x_hi) : (px += 1) {
            const sx: u32 = @min(sw - 1, @as(u32, @intFromFloat(sx0 + (@as(f32, @floatFromInt(px - dx)) + 0.5) * kx)));
            const sp = src_words[srow + sx];
            const di = drow + @as(usize, @intCast(px));
            const cfx = @as(f32, @floatFromInt(px)) + 0.5;
            var cov: f32 = 1.0;
            if (in_corner_rows and (cfx < fx + rad or cfx > fx + fw - rad)) {
                cov = std.math.clamp(0.5 - roundedSdf(cfx, cfy, fx, fy, fw, fh, rad), 0.0, 1.0);
                if (cov <= 0) continue;
            }
            const sa: u32 = sp >> 24;
            if (cov >= 1.0 and sa == 255) {
                words[di] = sp;
                continue;
            }
            const a: u8 = @intFromFloat(@as(f32, @floatFromInt(sa)) * cov);
            if (a == 0) continue;
            const bi = di * 4;
            blendPx(buf, bi, .{ @truncate(sp), @truncate(sp >> 8), @truncate(sp >> 16) }, a);
        }
    }
}

// ── Pezzi ricorrenti ─────────────────────────────────────────────────────────

/// Anello di selezione attorno a un riquadro (staccato di 3 px).
pub fn selectionRing(canvas: *paint.Canvas, x: i32, y: i32, w: i32, h: i32, rad: f32) void {
    canvas.strokeRoundedRect(@as(f32, @floatFromInt(x)) - 3.0, @as(f32, @floatFromInt(y)) - 3.0, @as(f32, @floatFromInt(w)) + 6.0, @as(f32, @floatFromInt(h)) + 6.0, rad + 3.0, 2.0, accent);
}

/// Badge scuro con testo piccolo, ancorato in basso a destra di `x1,y1`.
pub fn badgeBR(canvas: *paint.Canvas, buf: []u8, W: u32, H: u32, f: *glyph.Raster, x1: i32, y1: i32, s: []const u8, clip: ClipY) void {
    const tw = measure(f, .regular, s);
    const lh = Fonts.lineH(f);
    const bw = tw + 12;
    const bh = lh + 6;
    const bx = x1 - bw;
    const by = y1 - bh;
    canvas.fillRoundedRect(@floatFromInt(bx), @floatFromInt(by), @floatFromInt(bw), @floatFromInt(bh), 5.0, badge_bg);
    _ = text(buf, W, H, f, bx + 6, by + 3 + f.ascent, s, fg, .{ .clip = clip });
}

/// Lente d'ingrandimento centrata in `cx,cy` (campo di ricerca).
pub fn searchIcon(canvas: *paint.Canvas, cx: f32, cy: f32, size: f32, color: paint.Color) void {
    const r = size * 0.32;
    const ox = cx - size * 0.08;
    const oy = cy - size * 0.08;
    canvas.drawArc(ox, oy, r, 1.8, 0, std.math.tau, color);
    const d = r * 0.7071;
    canvas.strokeSegment(ox + d + 0.5, oy + d + 0.5, ox + r * 1.75, oy + r * 1.75, 2.0, color);
}

/// Cartella disegnata (linguetta + corpo) centrata nel riquadro.
pub fn folderIcon(canvas: *paint.Canvas, x: i32, y: i32, w: i32, h: i32) void {
    const fw: i32 = @min(@divTrunc(w * 2, 5), @divTrunc(h * 4, 5));
    const fh: i32 = @divTrunc(fw * 3, 4);
    const fx0 = x + @divTrunc(w - fw, 2);
    const fy0 = y + @divTrunc(h - fh, 2);
    const tab_h = @max(5, @divTrunc(fh, 6));
    canvas.fillRoundedRect(@floatFromInt(fx0), @floatFromInt(fy0), @floatFromInt(@divTrunc(fw * 2, 5)), @floatFromInt(tab_h * 2), 4.0, paint.Color.rgba(214, 170, 92, 1.0));
    canvas.fillRoundedRect(@floatFromInt(fx0), @floatFromInt(fy0 + tab_h), @floatFromInt(fw), @floatFromInt(fh - tab_h), 6.0, paint.Color.rgba(232, 188, 106, 1.0));
}

/// Fondo pieno su tutto il frame.
pub fn fillBackdrop(canvas: *paint.Canvas, W: u32, H: u32) void {
    canvas.fillRoundedRect(0, 0, @floatFromInt(W), @floatFromInt(H), 0, backdrop);
}
