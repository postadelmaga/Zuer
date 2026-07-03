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
        const bytes = [4][]const u8{ font_regular, font_bold, font_italic, font_bold_italic };
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

    fn getGlyph(self: *Raster, style: Style, cp: u32) !*const Glyph {
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

        const g = Glyph{ .w = w, .h = h, .xoff = xoff, .yoff = yoff, .bitmap = owned };
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

/// out = out*(1-a) + color*a, con a = cov/255, per canale RGB.
fn blend(dst: []u8, color: Rgb, cov: u8) void {
    const a: u32 = cov;
    const ia: u32 = 255 - a;
    dst[0] = @intCast((@as(u32, dst[0]) * ia + @as(u32, color.r) * a + 127) / 255);
    dst[1] = @intCast((@as(u32, dst[1]) * ia + @as(u32, color.g) * a + 127) / 255);
    dst[2] = @intCast((@as(u32, dst[2]) * ia + @as(u32, color.b) * a + 127) / 255);
}
