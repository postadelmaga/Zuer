//! Scrittore PDF minimo per la stampa, senza dipendenze (il PDF è il formato
//! che CUPS e Windows sanno stampare). Pagine con un contenuto libero (testo
//! con font TrueType incorporati, vedi `addTrueTypeFont`) o con un'immagine
//! (RGB, o in scala di grigi se non ha colori) compressa con FlateDecode.
//!
//! Struttura (PDF 32000-1, 7.5): oggetto 1 il catalogo, 2 l'albero delle pagine
//! (scritto per ultimo, quando i figli sono noti), poi gli oggetti nell'ordine
//! in cui li si aggiunge.

const std = @import("std");

/// Punti tipografici per millimetro (1 pt = 1/72 di pollice).
pub const pt_per_mm: f32 = 72.0 / 25.4;
/// A4 in punti.
pub const a4_w: f32 = 210.0 * pt_per_mm;
pub const a4_h: f32 = 297.0 * pt_per_mm;

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// Metriche di una faccia per il suo FontDescriptor, in millesimi del corpo.
pub const FontMetrics = struct {
    /// Nome PostScript, senza spazi.
    name: []const u8,
    bbox: [4]i32,
    ascent: i32,
    descent: i32,
    italic_angle: f32 = 0,
    fixed_pitch: bool = true,
};

/// Un glifo usato e il carattere che rappresenta (per la ToUnicode).
pub const GlyphCode = struct { glyph: u16, cp: u21 };

/// Larghezza di un glifo in millesimi del corpo (per /W).
pub const GlyphWidth = struct { glyph: u16, width: i32 };

/// `cp` in UTF-16 (una unità, o una coppia di surrogati): unità scritte.
fn utf16(cp: u21, out: *[2]u16) usize {
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

pub const Writer = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    /// Offset di ogni oggetto, indicizzati per numero (0 = voce libera).
    offsets: std.ArrayList(usize) = .empty,
    pages: std.ArrayList(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator) !Writer {
        var w: Writer = .{ .gpa = gpa };
        errdefer w.deinit();
        // Il commento binario dice ai programmi di trasferimento che il file non è testo.
        try w.out.appendSlice(gpa, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");
        try w.offsets.appendSlice(gpa, &.{ 0, 0, 0 }); // 0 libero, 1 catalogo, 2 pagine
        return w;
    }

    pub fn deinit(self: *Writer) void {
        self.out.deinit(self.gpa);
        self.offsets.deinit(self.gpa);
        self.pages.deinit(self.gpa);
    }

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.gpa, fmt, args);
    }

    fn beginObject(self: *Writer, num: u32) !void {
        self.offsets.items[num] = self.out.items.len;
        try self.print("{d} 0 obj\n", .{num});
    }

    /// Riserva il numero di un oggetto, da scrivere poi con `writeObject` o
    /// `writeStream` (anche dopo oggetti che lo citano).
    pub fn reserve(self: *Writer) !u32 {
        try self.offsets.append(self.gpa, 0);
        return @intCast(self.offsets.items.len - 1);
    }

    /// Scrive l'oggetto `num` (riservato) col corpo `fmt`.
    pub fn writeObject(self: *Writer, num: u32, comptime fmt: []const u8, args: anytype) !void {
        try self.beginObject(num);
        try self.print(fmt, args);
        try self.print("\nendobj\n", .{});
    }

    /// Scrive lo stream `num` (riservato): `dict` sono le voci del dizionario
    /// oltre a /Length (e /Filter, aggiunto se `compress`).
    pub fn writeStream(self: *Writer, num: u32, dict: []const u8, data: []const u8, compress: bool) !void {
        const body = if (compress) try deflate(self.gpa, data) else data;
        defer if (compress) self.gpa.free(body);
        try self.beginObject(num);
        try self.print("<< {s}{s} /Length {d} >>\nstream\n", .{ dict, if (compress) " /Filter /FlateDecode" else "", body.len });
        try self.out.appendSlice(self.gpa, body);
        try self.print("\nendstream\nendobj\n", .{});
    }

    /// Aggiunge una pagina `page_w`×`page_h` punti: `resources` è il corpo del
    /// dizionario /Resources (senza `<< >>`), `content` il flusso di operatori.
    pub fn addPage(self: *Writer, page_w: f32, page_h: f32, resources: []const u8, content: []const u8) !void {
        const page = try self.reserve();
        const stream = try self.reserve();
        try self.pages.append(self.gpa, page);
        try self.writeObject(page, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.2} {d:.2}] /Resources << {s} >> /Contents {d} 0 R >>", .{ page_w, page_h, resources, stream });
        try self.writeStream(stream, "", content, true);
    }

    /// Aggiunge una pagina `page_w`×`page_h` punti con l'immagine `rgb`
    /// (`w`×`h` pixel, 3 byte per pixel, riga 0 in alto) disegnata in `dst`
    /// (punti, origine in basso a sinistra). `interpolate`: chiede al
    /// dispositivo di levigare l'ingrandimento (immagini piccole).
    pub fn addImagePage(self: *Writer, page_w: f32, page_h: f32, rgb: []const u8, w: usize, h: usize, dst: Rect, interpolate: bool) !void {
        std.debug.assert(rgb.len >= w * h * 3);
        const gray = isGray(rgb[0 .. w * h * 3]);
        const samples = if (gray) try toGray(self.gpa, rgb[0 .. w * h * 3]) else rgb[0 .. w * h * 3];
        defer if (gray) self.gpa.free(samples);

        const image = try self.reserve();
        var dict_buf: [192]u8 = undefined;
        const dict = try std.fmt.bufPrint(&dict_buf, "/Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /{s} /BitsPerComponent 8{s}", .{
            w, h, if (gray) "DeviceGray" else "DeviceRGB", if (interpolate) " /Interpolate true" else "",
        });
        try self.writeStream(image, dict, samples, true);

        var res_buf: [64]u8 = undefined;
        const res = try std.fmt.bufPrint(&res_buf, "/XObject << /Im0 {d} 0 R >>", .{image});
        var cs_buf: [160]u8 = undefined;
        const cs = try std.fmt.bufPrint(&cs_buf, "q {d:.3} 0 0 {d:.3} {d:.3} {d:.3} cm /Im0 Do Q\n", .{ dst.w, dst.h, dst.x, dst.y });
        try self.addPage(page_w, page_h, res, cs);
    }

    /// Incorpora un font TrueType come font composito (Type0, codifica
    /// Identity-H: due byte per glifo, il codice è l'indice del glifo nel file;
    /// PDF 32000-1, 9.7). Ogni glifo avanza di `advance` millesimi del corpo,
    /// arrotondati (/DW è un intero): la griglia monospazio di chi impagina. `to_unicode` (indice glifo →
    /// codepoint) rende il testo copiabile e ricercabile. Restituisce il numero
    /// dell'oggetto font, da citare nelle /Resources delle pagine.
    /// `widths` (facoltativo) dà la larghezza dei glifi che non avanzano di `advance`.
    pub fn addTrueTypeFont(self: *Writer, ttf: []const u8, m: FontMetrics, advance: f32, widths: []const GlyphWidth, to_unicode: []const GlyphCode) !u32 {
        const type0 = try self.reserve();
        const cid = try self.reserve();
        const descriptor = try self.reserve();
        const file = try self.reserve();
        const cmap = try self.reserve();
        const flags: u32 = @as(u32, @intFromBool(m.fixed_pitch)) | 32 | (if (m.italic_angle != 0) @as(u32, 64) else 0); // FixedPitch, Nonsymbolic, Italic
        try self.writeObject(type0, "<< /Type /Font /Subtype /Type0 /BaseFont /{s} /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>", .{ m.name, cid, cmap });
        var w_arr: std.ArrayList(u8) = .empty;
        defer w_arr.deinit(self.gpa);
        if (widths.len > 0) {
            try w_arr.appendSlice(self.gpa, " /W [");
            for (widths) |gw| try w_arr.print(self.gpa, " {d} [{d}]", .{ gw.glyph, gw.width });
            try w_arr.appendSlice(self.gpa, " ]");
        }
        try self.writeObject(cid, "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /{s} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " ++
            "/FontDescriptor {d} 0 R /DW {d}{s} /CIDToGIDMap /Identity >>", .{ m.name, descriptor, @as(i32, @intFromFloat(@round(advance))), w_arr.items });
        try self.writeObject(descriptor, "<< /Type /FontDescriptor /FontName /{s} /Flags {d} /FontBBox [{d} {d} {d} {d}] /ItalicAngle {d:.1} " ++
            "/Ascent {d} /Descent {d} /CapHeight {d} /StemV 80 /FontFile2 {d} 0 R >>", .{
            m.name,   flags,     m.bbox[0], m.bbox[1], m.bbox[2], m.bbox[3], m.italic_angle,
            m.ascent, m.descent, m.ascent,  file,
        });
        var len_buf: [32]u8 = undefined;
        try self.writeStream(file, try std.fmt.bufPrint(&len_buf, "/Length1 {d}", .{ttf.len}), ttf, true);

        var cm: std.ArrayList(u8) = .empty;
        defer cm.deinit(self.gpa);
        try cm.appendSlice(self.gpa, "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" ++
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" ++
            "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" ++
            "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        var i: usize = 0;
        while (i < to_unicode.len) {
            const n = @min(100, to_unicode.len - i); // al più 100 voci per blocco
            try cm.print(self.gpa, "{d} beginbfchar\n", .{n});
            for (to_unicode[i .. i + n]) |g| {
                try cm.print(self.gpa, "<{X:0>4}> <", .{g.glyph});
                var units: [2]u16 = undefined;
                const nu = utf16(g.cp, &units);
                for (units[0..nu]) |u| try cm.print(self.gpa, "{X:0>4}", .{u});
                try cm.appendSlice(self.gpa, ">\n");
            }
            try cm.appendSlice(self.gpa, "endbfchar\n");
            i += n;
        }
        try cm.appendSlice(self.gpa, "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
        try self.writeStream(cmap, "", cm.items, true);
        return type0;
    }

    /// Chiude il documento (albero delle pagine, catalogo, tabella xref) e ne
    /// restituisce i byte, posseduti dal chiamante. Il writer resta da `deinit`.
    pub fn finish(self: *Writer) ![]u8 {
        try self.beginObject(2);
        try self.print("<< /Type /Pages /Count {d} /Kids [", .{self.pages.items.len});
        for (self.pages.items) |p| try self.print(" {d} 0 R", .{p});
        try self.print(" ] >>\nendobj\n", .{});
        try self.beginObject(1);
        try self.print("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n", .{});

        const xref = self.out.items.len;
        try self.print("xref\n0 {d}\n0000000000 65535 f \n", .{self.offsets.items.len});
        for (self.offsets.items[1..]) |off| try self.print("{d:0>10} 00000 n \n", .{off});
        try self.print("trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ self.offsets.items.len, xref });
        return self.out.toOwnedSlice(self.gpa);
    }
};

/// Vero se ogni pixel ha i tre canali uguali (pagina di solo testo nero/grigio).
fn isGray(rgb: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= rgb.len) : (i += 3) {
        if (rgb[i] != rgb[i + 1] or rgb[i] != rgb[i + 2]) return false;
    }
    return true;
}

fn toGray(gpa: std.mem.Allocator, rgb: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, rgb.len / 3);
    for (out, 0..) |*g, i| g.* = rgb[i * 3];
    return out;
}

/// Dati zlib (RFC 1950) di `data`, al livello più rapido: le pagine di testo sono
/// quasi tutte bianche e si comprimono bene comunque.
fn deflate(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const flate = std.compress.flate;
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, data.len / 8 + 64);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&out.writer, window, .zlib, .level_1);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

/// Rettangolo in cui disegnare un'immagine `w`×`h` pixel su una pagina
/// `page_w`×`page_h` punti: centrata dentro i margini, rimpicciolita se non ci
/// sta, mai ingrandita oltre `max_dpi` (un'icona non diventa un mosaico).
pub fn fitImage(page_w: f32, page_h: f32, margin: f32, w: usize, h: usize, max_dpi: f32) Rect {
    const iw: f32 = @floatFromInt(@max(w, 1));
    const ih: f32 = @floatFromInt(@max(h, 1));
    const aw = page_w - 2 * margin;
    const ah = page_h - 2 * margin;
    const natural = 72.0 / max_dpi; // punti per pixel alla risoluzione minima
    const scale = @min(@min(aw / iw, ah / ih), natural);
    const dw = iw * scale;
    const dh = ih * scale;
    return .{ .x = (page_w - dw) / 2, .y = (page_h - dh) / 2, .w = dw, .h = dh };
}

test "PDF di una pagina: struttura e xref coerenti" {
    const gpa = std.testing.allocator;
    var w = try Writer.init(gpa);
    defer w.deinit();
    const px = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    try w.addImagePage(a4_w, a4_h, &px, 2, 2, fitImage(a4_w, a4_h, 20, 2, 2, 96), true);
    const pdf = try w.finish();
    defer gpa.free(pdf);

    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
    // startxref punta davvero alla parola `xref`, e ogni voce in uso a "N 0 obj".
    const sx = std.mem.lastIndexOf(u8, pdf, "startxref\n").?;
    const xref_off = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, pdf[sx + 10 .. pdf.len - 6], "\n"), 10);
    try std.testing.expect(std.mem.startsWith(u8, pdf[xref_off..], "xref\n0 6\n"));
    var lines = std.mem.splitScalar(u8, pdf[xref_off..], '\n');
    _ = lines.next();
    _ = lines.next();
    _ = lines.next(); // voce 0
    for (1..6) |num| {
        const line = lines.next().?;
        const off = try std.fmt.parseInt(usize, line[0..10], 10);
        var buf: [16]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, pdf[off..], try std.fmt.bufPrint(&buf, "{d} 0 obj", .{num})));
    }
    // Lo stream dell'immagine si decomprime nei pixel originali (RGB: c'è colore).
    const s = std.mem.indexOf(u8, pdf, "/DeviceRGB").?;
    const start = std.mem.indexOfPos(u8, pdf, s, "stream\n").? + 7;
    var in: std.Io.Reader = .fixed(pdf[start..]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    var got: [12]u8 = undefined;
    try d.reader.readSliceAll(&got);
    try std.testing.expectEqualSlices(u8, &px, &got);
}

test "pagina in scala di grigi" {
    const gpa = std.testing.allocator;
    var w = try Writer.init(gpa);
    defer w.deinit();
    const px = [_]u8{ 10, 10, 10, 200, 200, 200 };
    try w.addImagePage(100, 100, &px, 2, 1, .{ .x = 0, .y = 0, .w = 100, .h = 50 }, false);
    const pdf = try w.finish();
    defer gpa.free(pdf);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/DeviceGray") != null);
}

test "fitImage non ingrandisce oltre max_dpi e rimpicciolisce ciò che non sta" {
    const small = fitImage(a4_w, a4_h, 0, 96, 96, 96);
    try std.testing.expectApproxEqAbs(@as(f32, 72), small.w, 0.01);
    const big = fitImage(a4_w, a4_h, 10, 10000, 5000, 96);
    try std.testing.expectApproxEqAbs(a4_w - 20, big.w, 0.01);
    try std.testing.expectApproxEqAbs(big.w / 2, big.h, 0.01);
}
