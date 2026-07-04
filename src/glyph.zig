//! Motore di rasterizzazione glifi nativo, basato su stb_truetype e sui font
//! Hack embeddati nel binario (le stesse facce del monospace di default di egui,
//! per parità con viewer). Rasterizza i glifi alla dimensione esatta dei pixel
//! (niente scaling → nitido) e li memorizza in cache; è condiviso dal percorso
//! CPU (blend diretto in un buffer RGB) e da quello GPU (atlante di texture).

const std = @import("std");
const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// Facce disponibili (Hack): il codice usa regular+bold, il markdown anche i corsivi.
pub const Style = enum(u2) { regular = 0, bold = 1, italic = 2, bold_italic = 3 };

const font_regular = @embedFile("assets/Hack-Regular.ttf");
const font_bold = @embedFile("assets/Hack-Bold.ttf");
const font_italic = @embedFile("assets/Hack-Italic.ttf");
const font_bold_italic = @embedFile("assets/Hack-BoldItalic.ttf");

// Famiglia proporzionale (Liberation Sans, metrica-compatibile con Arial) per il
// rendering "foglio di calcolo" delle tabelle. Corsivi non necessari: ripiegano
// su regular/bold.
const font_sans_regular = @embedFile("assets/LiberationSans-Regular.ttf");
const font_sans_bold = @embedFile("assets/LiberationSans-Bold.ttf");

/// Famiglia tipografica: `mono` (Hack, per codice/testo, resa a griglia) oppure
/// `sans` (Liberation Sans, proporzionale, per le tabelle).
pub const Family = enum { mono, sans };

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromHex(comptime hex: []const u8) Rgb {
        return .{
            .r = parseHexByte(hex[1..3]),
            .g = parseHexByte(hex[3..5]),
            .b = parseHexByte(hex[5..7]),
        };
    }
};

fn parseHexByte(comptime s: []const u8) u8 {
    return std.fmt.parseInt(u8, s, 16) catch unreachable;
}

/// Glifo rasterizzato: copertura (alpha 0..255) di dimensione w*h, con offset dal
/// punto di penna e la baseline. bitmap è di proprietà della cache (allocatore gpa).
const Glyph = struct {
    w: i32,
    h: i32,
    xoff: i32,
    yoff: i32,
    /// Avanzamento orizzontale in pixel del glifo (per il layout proporzionale;
    /// con Hack coincide con `Raster.advance`).
    advance: i32,
    bitmap: []const u8,
};

const CacheKey = struct { style: Style, cp: u32 };

/// Rasterizzatore legato a una dimensione in pixel: risolve font, metriche e cache
/// dei glifi. Un'istanza per documento (una sola dimensione alla volta).
pub const Raster = struct {
    gpa: std.mem.Allocator,
    infos: [4]c.stbtt_fontinfo,
    scale: [4]f32,
    /// Metriche di riga in pixel (dalla faccia regular).
    ascent: i32,
    descent: i32,
    line_gap: i32,
    /// Avanzamento di cella monospazio in pixel (tutte le facce Hack coincidono).
    advance: i32,
    cache: std.AutoHashMapUnmanaged(CacheKey, Glyph),

    pub fn init(gpa: std.mem.Allocator, px_height: f32) !Raster {
        return initFamily(gpa, px_height, .mono);
    }

    pub fn initFamily(gpa: std.mem.Allocator, px_height: f32, family: Family) !Raster {
        const bytes: [4][]const u8 = switch (family) {
            .mono => .{ font_regular, font_bold, font_italic, font_bold_italic },
            // Sans: corsivi ripiegano su regular/bold (le tabelle non li usano).
            .sans => .{ font_sans_regular, font_sans_bold, font_sans_regular, font_sans_bold },
        };
        var infos: [4]c.stbtt_fontinfo = undefined;
        var scale: [4]f32 = undefined;
        for (bytes, 0..) |data, i| {
            const p: [*c]const u8 = @ptrCast(data.ptr);
            const off = c.stbtt_GetFontOffsetForIndex(p, 0);
            if (c.stbtt_InitFont(&infos[i], p, off) == 0) return error.FontInit;
            scale[i] = c.stbtt_ScaleForPixelHeight(&infos[i], px_height);
        }

        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&infos[0], &asc, &desc, &gap);

        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(&infos[0], 'M', &adv, &lsb);

        const s0 = scale[0];
        return .{
            .gpa = gpa,
            .infos = infos,
            .scale = scale,
            .ascent = @intFromFloat(@round(@as(f32, @floatFromInt(asc)) * s0)),
            .descent = @intFromFloat(@round(@as(f32, @floatFromInt(desc)) * s0)),
            .line_gap = @intFromFloat(@round(@as(f32, @floatFromInt(gap)) * s0)),
            .advance = @intFromFloat(@round(@as(f32, @floatFromInt(adv)) * s0)),
            .cache = .empty,
        };
    }

    pub fn deinit(self: *Raster) void {
        var it = self.cache.valueIterator();
        while (it.next()) |g| if (g.bitmap.len > 0) self.gpa.free(g.bitmap);
        self.cache.deinit(self.gpa);
    }

    /// Altezza di riga (avanzamento verticale) in pixel.
    pub fn lineHeight(self: *const Raster) i32 {
        return self.ascent - self.descent + self.line_gap;
    }

    pub fn getGlyph(self: *Raster, style: Style, cp: u32) !*const Glyph {
        const key = CacheKey{ .style = style, .cp = cp };
        if (self.cache.getPtr(key)) |g| return g;

        const si = @intFromEnum(style);
        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const bmp = c.stbtt_GetCodepointBitmap(&self.infos[si], 0, self.scale[si], @intCast(cp), &w, &h, &xoff, &yoff);
        // Glifo vuoto (spazio, .notdef senza pixel): copertura nulla in cache.
        const owned = if (bmp != null and w > 0 and h > 0) blk: {
            const n: usize = @intCast(w * h);
            const dup = try self.gpa.dupe(u8, bmp[0..n]);
            break :blk dup;
        } else &[_]u8{};
        if (bmp != null) c.stbtt_FreeBitmap(bmp, null);

        // Avanzamento orizzontale del glifo (per il layout proporzionale).
        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(&self.infos[si], @intCast(cp), &adv, &lsb);
        const advance: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(adv)) * self.scale[si]));

        const g = Glyph{ .w = w, .h = h, .xoff = xoff, .yoff = yoff, .advance = advance, .bitmap = owned };
        try self.cache.put(self.gpa, key, g);
        return self.cache.getPtr(key).?;
    }

    /// Disegna un codepoint dentro il buffer RGB (buf_w*buf_h*3) fondendo il
    /// colore sopra lo sfondo esistente secondo la copertura del glifo. pen_x è il
    /// bordo sinistro della cella, baseline_y la baseline. Non avanza la penna: in
    /// modalità monospazio il chiamante usa `advance` per la griglia.
    pub fn drawCodepoint(
        self: *Raster,
        buf: []u8,
        buf_w: i32,
        buf_h: i32,
        pen_x: i32,
        baseline_y: i32,
        style: Style,
        cp: u32,
        color: Rgb,
    ) !void {
        const g = try self.getGlyph(style, cp);
        if (g.bitmap.len == 0) return;
        const gx0 = pen_x + g.xoff;
        const gy0 = baseline_y + g.yoff;
        var gy: i32 = 0;
        while (gy < g.h) : (gy += 1) {
            const py = gy0 + gy;
            if (py < 0 or py >= buf_h) continue;
            var gx: i32 = 0;
            while (gx < g.w) : (gx += 1) {
                const px = gx0 + gx;
                if (px < 0 or px >= buf_w) continue;
                const cov = g.bitmap[@intCast(gy * g.w + gx)];
                if (cov == 0) continue;
                const idx: usize = @intCast((py * buf_w + px) * 3);
                blend(buf[idx .. idx + 3], color, cov);
            }
        }
    }
};

/// Posizione e metriche di un glifo dentro l'atlante (coordinate in pixel).
pub const AtlasGlyph = struct {
    ax: u32,
    ay: u32,
    w: u32,
    h: u32,
    xoff: i32,
    yoff: i32,
};

/// Atlante di glifi a canale singolo (copertura): tutti i glifi rasterizzati
/// impacchettati in una bitmap, per il percorso GPU (una texture, un quad per
/// glifo). Costruito dai glifi già in cache nel `Raster`.
pub const Atlas = struct {
    gpa: std.mem.Allocator,
    pixels: []u8, // copertura 0..255, w*h
    w: usize,
    h: usize,
    map: std.AutoHashMapUnmanaged(CacheKey, AtlasGlyph),

    pub fn deinit(self: *Atlas) void {
        self.gpa.free(self.pixels);
        self.map.deinit(self.gpa);
    }

    pub fn get(self: *const Atlas, style: Style, cp: u32) ?AtlasGlyph {
        return self.map.get(.{ .style = style, .cp = cp });
    }
};

/// Impacchetta tutti i glifi attualmente in cache nel `Raster` in un atlante
/// (packer a scaffali). Larghezza fissa, altezza cresce con gli scaffali.
pub fn buildAtlas(raster: *Raster) !Atlas {
    const gpa = raster.gpa;
    const atlas_w: usize = 1024;
    const pad: usize = 1;

    var map: std.AutoHashMapUnmanaged(CacheKey, AtlasGlyph) = .empty;
    errdefer map.deinit(gpa);

    // Passo 1: posizioni a scaffali, calcola l'altezza necessaria.
    var x: usize = pad;
    var y: usize = pad;
    var shelf_h: usize = 0;
    var it = raster.cache.iterator();
    while (it.next()) |e| {
        const g = e.value_ptr.*;
        const gw: usize = @intCast(@max(g.w, 0));
        const gh: usize = @intCast(@max(g.h, 0));
        if (g.bitmap.len == 0 or gw == 0 or gh == 0) {
            try map.put(gpa, e.key_ptr.*, .{ .ax = 0, .ay = 0, .w = 0, .h = 0, .xoff = g.xoff, .yoff = g.yoff });
            continue;
        }
        if (x + gw + pad > atlas_w) {
            x = pad;
            y += shelf_h + pad;
            shelf_h = 0;
        }
        try map.put(gpa, e.key_ptr.*, .{
            .ax = @intCast(x),
            .ay = @intCast(y),
            .w = @intCast(gw),
            .h = @intCast(gh),
            .xoff = g.xoff,
            .yoff = g.yoff,
        });
        x += gw + pad;
        shelf_h = @max(shelf_h, gh);
    }
    const atlas_h: usize = y + shelf_h + pad;

    const pixels = try gpa.alloc(u8, atlas_w * atlas_h);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);

    // Passo 2: copia le coperture dei glifi nelle posizioni assegnate.
    var it2 = raster.cache.iterator();
    while (it2.next()) |e| {
        const g = e.value_ptr.*;
        if (g.bitmap.len == 0) continue;
        const ag = map.get(e.key_ptr.*).?;
        const gw: usize = ag.w;
        const gh: usize = ag.h;
        var row: usize = 0;
        while (row < gh) : (row += 1) {
            const src = g.bitmap[row * gw .. row * gw + gw];
            const dst_off = (ag.ay + row) * atlas_w + ag.ax;
            @memcpy(pixels[dst_off .. dst_off + gw], src);
        }
    }

    return .{ .gpa = gpa, .pixels = pixels, .w = atlas_w, .h = atlas_h, .map = map };
}

// Blending gamma-corretto (in luce lineare) per una resa tipografica. Fondere la
// copertura del glifo direttamente in sRGB (come faceva la vecchia `blend`) rende
// i bordi troppo scuri/frastagliati su fondo scuro; convertendo in lineare, fondendo
// e riconvertendo in sRGB le sfumature dell'antialiasing hanno il peso corretto.

/// LUT sRGB(0..255) → lineare(0..1), calcolata a compile-time (formula sRGB standard).
const srgb_to_linear: [256]f32 = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| {
        const u = @as(f64, @floatFromInt(i)) / 255.0;
        v.* = @floatCast(if (u <= 0.04045) u / 12.92 else std.math.pow(f64, (u + 0.055) / 1.055, 2.4));
    }
    break :blk t;
};

/// lineare(0..1) → sRGB(0..255).
fn linearToSrgb(x: f32) u8 {
    const u: f64 = std.math.clamp(@as(f64, x), 0.0, 1.0);
    const s = if (u <= 0.0031308) u * 12.92 else 1.055 * std.math.pow(f64, u, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(s, 0.0, 1.0) * 255.0));
}

/// "Font smoothing" in stile macOS: solleva la copertura media per ingrassare i
/// tratti (macOS rende il testo più pieno del grayscale grezzo). Esponente < 1.
fn smoothCoverage(a: f32) f32 {
    return std.math.pow(f32, a, 0.72);
}

/// out = srgb(lin(out)*(1-a) + lin(color)*a), con a = smoothing(cov/255), per canale.
fn blend(dst: []u8, color: Rgb, cov: u8) void {
    const a: f32 = smoothCoverage(@as(f32, @floatFromInt(cov)) / 255.0);
    const ia: f32 = 1.0 - a;
    const cr = [3]u8{ color.r, color.g, color.b };
    inline for (0..3) |ch| {
        const out = srgb_to_linear[dst[ch]] * ia + srgb_to_linear[cr[ch]] * a;
        dst[ch] = linearToSrgb(out);
    }
}
