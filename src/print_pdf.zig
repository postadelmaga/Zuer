//! PDF della stampa (vedi `print.zig`): immagini centrate su un A4 nel verso
//! che le si addice, testi impaginati con le righe del viewer, markdown con la
//! stessa impaginazione dello schermo (`md_layout`). Il testo è testo vero, coi
//! font incorporati: nitido, leggero, copiabile.
//! Niente GUI qui: lo usano anche i test e lo strumento `print-debug`.

const std = @import("std");
const decoder_mod = @import("decoder.zig");
const text_render = @import("text_render.zig");
const pdf_writer = @import("pdf_writer.zig");
const glyph = @import("glyph.zig");
const stb = glyph.stb;

/// Unità di impaginazione dei testi: pixel a questa risoluzione. La griglia
/// monospazio ha celle di pixel interi, come a schermo; nel PDF diventano punti.
const layout_dpi: f32 = 300;
/// Corpo del testo su carta, in punti (altezza ascent−descent, come `glyph`).
const body_pt: f32 = 11;

/// PDF da stampare per `content` (immagine, testo o markdown): byte posseduti
/// dal chiamante. `name` va nel piè di pagina dei testi; `rotation` sono i
/// quarti di giro orari della vista, applicati alle immagini.
pub fn build(gpa: std.mem.Allocator, content: *const decoder_mod.Decoded, name_in: []const u8, rotation: u2) ![]u8 {
    // Il nome va nel piè di pagina: un nome di file non UTF-8 (Latin-1 su
    // Linux) diventa UTF-8 valido, coi caratteri illeggibili come U+FFFD.
    const name = try validUtf8(gpa, name_in);
    defer gpa.free(name);
    var w = try pdf_writer.Writer.init(gpa);
    defer w.deinit();
    switch (content.*) {
        .image => |img| {
            const rot = try rotate(gpa, img.pixels, img.width, img.height, rotation);
            defer if (rot.owned) gpa.free(rot.px);
            const landscape = rot.w > rot.h;
            const pw = if (landscape) pdf_writer.a4_h else pdf_writer.a4_w;
            const ph = if (landscape) pdf_writer.a4_w else pdf_writer.a4_h;
            const dst = pdf_writer.fitImage(pw, ph, 10 * pdf_writer.pt_per_mm, rot.w, rot.h, 96);
            // Meno di 300 punti per pollice sulla carta: si chiede di levigare.
            const dpi = @as(f32, @floatFromInt(rot.w)) / (dst.w / 72.0);
            try w.addImagePage(pw, ph, rot.px, rot.w, rot.h, dst, dpi < 300);
        },
        .text => try buildText(gpa, &w, content, name),
        .markdown => |m| try buildMarkdown(gpa, &w, m.content, name),
        else => return error.UnsupportedContent,
    }
    return w.finish();
}

/// Copia di `s` in UTF-8 valido: ogni byte che non inizia una sequenza
/// corretta diventa U+FFFD.
pub fn validUtf8(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        const ok = n > 0 and i + n <= s.len and if (std.unicode.utf8Decode(s[i .. i + n])) |_| true else |_| false;
        if (ok) {
            try out.appendSlice(gpa, s[i .. i + n]);
            i += n;
        } else {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Una faccia Hack usata dal documento: metriche stb, corpo e glifi usati.
const Face = struct {
    info: stb.stbtt_fontinfo = undefined,
    /// Unità del font per em.
    upem: f32 = 1000,
    size_pt: f32 = 0,
    used: std.AutoArrayHashMapUnmanaged(u16, u21) = .empty,
    ready: bool = false,

    fn init(self: *Face, style: usize, body_px: f32, k: f32) !void {
        const data = glyph.mono_fonts[style];
        const p: [*c]const u8 = @ptrCast(data.ptr);
        if (stb.stbtt_InitFont(&self.info, p, stb.stbtt_GetFontOffsetForIndex(p, 0)) == 0) return error.FontInit;
        self.upem = 1.0 / stb.stbtt_ScaleForMappingEmToPixels(&self.info, 1);
        // Stessa scala di `glyph.Raster` (per altezza in pixel), in punti.
        self.size_pt = stb.stbtt_ScaleForPixelHeight(&self.info, body_px) * self.upem * k;
        self.ready = true;
    }

    fn units(self: *const Face, v: c_int) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * 1000 / self.upem));
    }
};

const face_names = [4][]const u8{ "Hack-Regular", "Hack-Bold", "Hack-Italic", "Hack-BoldItalic" };

/// Testo, codice o markdown: le righe del viewer (`text_render.PrintDoc`) come
/// testo PDF, coi glifi Hack incorporati. Una cella della griglia per
/// codepoint, come a schermo: la larghezza di ogni glifo nel font è la cella.
fn buildText(gpa: std.mem.Allocator, w: *pdf_writer.Writer, content: *const decoder_mod.Decoded, name: []const u8) !void {
    const px_per_mm = layout_dpi / 25.4;
    const page: text_render.PrintPage = .{
        .width = @intFromFloat(@round(210 * px_per_mm)),
        .height = @intFromFloat(@round(297 * px_per_mm)),
        .margin = @intFromFloat(@round(15 * px_per_mm)),
        .body_px = body_pt * layout_dpi / 72.0,
    };
    const k: f32 = 72.0 / layout_dpi; // punti per pixel
    const page_h: f32 = @floatFromInt(page.height);

    var doc = try text_render.PrintDoc.init(gpa, content, name, page);
    defer doc.deinit();
    var faces: [4]Face = .{ .{}, .{}, .{}, .{} };
    defer for (&faces) |*f| f.used.deinit(gpa);

    // Prima i flussi delle pagine (raccolgono i glifi usati), poi i font
    // (servono le ToUnicode complete), infine le pagine che li citano.
    var streams: std.ArrayList([]u8) = .empty;
    defer {
        for (streams.items) |st| gpa.free(st);
        streams.deinit(gpa);
    }
    var runs: std.ArrayList(text_render.PrintRun) = .empty;
    defer runs.deinit(gpa);
    for (0..doc.pageCount()) |i| {
        runs.clearRetainingCapacity();
        try doc.pageRuns(i, name, &runs, gpa);
        var cs: std.ArrayList(u8) = .empty;
        errdefer cs.deinit(gpa);
        try cs.appendSlice(gpa, "BT\n");
        var cur_style: ?usize = null;
        var cur_color: ?glyph.Rgb = null;
        for (runs.items) |run| {
            const st: usize = @backingInt(run.style);
            const f = &faces[st];
            if (!f.ready) try f.init(st, page.body_px, k);
            if (cur_style != st) {
                try cs.print(gpa, "/F{d} {d:.3} Tf\n", .{ st, f.size_pt });
                cur_style = st;
            }
            if (cur_color == null or !std.meta.eql(cur_color.?, run.color)) {
                try cs.print(gpa, "{d:.3} {d:.3} {d:.3} rg\n", .{
                    @as(f32, @floatFromInt(run.color.r)) / 255.0,
                    @as(f32, @floatFromInt(run.color.g)) / 255.0,
                    @as(f32, @floatFromInt(run.color.b)) / 255.0,
                });
                cur_color = run.color;
            }
            const x = @as(f32, @floatFromInt(run.x)) * k;
            const y = (page_h - @as(f32, @floatFromInt(run.baseline))) * k;
            try cs.print(gpa, "1 0 0 1 {d:.3} {d:.3} Tm <", .{ x, y });
            var it = (std.unicode.Utf8View.init(run.text) catch std.unicode.Utf8View.initUnchecked(run.text)).iterator();
            while (it.nextCodepoint()) |cp| {
                const gid: u16 = @intCast(@max(0, stb.stbtt_FindGlyphIndex(&f.info, @intCast(cp))));
                if (gid != 0) try f.used.put(gpa, gid, cp);
                try cs.print(gpa, "{X:0>4}", .{gid});
            }
            try cs.appendSlice(gpa, "> Tj\n");
        }
        try cs.appendSlice(gpa, "ET\n");
        try streams.append(gpa, try cs.toOwnedSlice(gpa));
    }

    var res: std.ArrayList(u8) = .empty;
    defer res.deinit(gpa);
    try res.appendSlice(gpa, "/Font <<");
    const advance_pt = @as(f32, @floatFromInt(doc.raster.advance)) * k;
    for (&faces, 0..) |*f, st| {
        if (!f.ready) continue;
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stb.stbtt_GetFontBoundingBox(&f.info, &x0, &y0, &x1, &y1);
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(&f.info, &asc, &desc, &gap);
        const codes = try gpa.alloc(pdf_writer.GlyphCode, f.used.count());
        defer gpa.free(codes);
        for (f.used.keys(), f.used.values(), codes) |g, cp, *out| out.* = .{ .glyph = g, .cp = cp };
        const obj = try w.addTrueTypeFont(glyph.mono_fonts[st], .{
            .name = face_names[st],
            .bbox = .{ f.units(x0), f.units(y0), f.units(x1), f.units(y1) },
            .ascent = f.units(asc),
            .descent = f.units(desc),
            .italic_angle = if (st >= 2) -11 else 0,
        }, advance_pt / f.size_pt * 1000, &.{}, codes);
        try res.print(gpa, " /F{d} {d} 0 R", .{ st, obj });
    }
    try res.appendSlice(gpa, " >>");
    for (streams.items) |st| try w.addPage(pdf_writer.a4_w, pdf_writer.a4_h, res.items, st);
}

// --- Markdown: la stessa impaginazione dello schermo, in punti --------------

const md_layout = @import("md_layout.zig");

/// Misure esatte (in punti) dalle facce TrueType incorporate: le larghezze
/// /W del PDF sono le stesse, quindi il testo cade dove l'ha messo il layout.
const PrintMeasurer = struct {
    arena: std.mem.Allocator,
    faces: [2][4]stb.stbtt_fontinfo = undefined,
    upem: [2][4]f32 = undefined,
    specs: std.ArrayList(md_layout.FontSpec) = .empty,
    /// Punti per unità del font, per carattere registrato.
    scales: std.ArrayList(f32) = .empty,

    fn init(arena: std.mem.Allocator) !PrintMeasurer {
        var pm: PrintMeasurer = .{ .arena = arena };
        for (0..2) |fam| for (0..4) |st| {
            const data = if (fam == 0) glyph.prose_fonts[st] else glyph.mono_fonts[st];
            const p: [*c]const u8 = @ptrCast(data.ptr);
            if (stb.stbtt_InitFont(&pm.faces[fam][st], p, stb.stbtt_GetFontOffsetForIndex(p, 0)) == 0) return error.FontInit;
            pm.upem[fam][st] = 1.0 / stb.stbtt_ScaleForMappingEmToPixels(&pm.faces[fam][st], 1);
        };
        return pm;
    }

    fn measurer(self: *PrintMeasurer) md_layout.Measurer {
        return .{ .ctx = self, .fontFn = font, .advanceFn = advance, .vmetricsFn = vmetrics, .hasFn = has };
    }

    fn get(ctx: *anyopaque) *PrintMeasurer {
        return @ptrCast(@alignCast(ctx));
    }

    fn info(self: *PrintMeasurer, f: u16) *stb.stbtt_fontinfo {
        const sp = self.specs.items[f];
        return &self.faces[@backingInt(sp.family)][@backingInt(sp.style)];
    }

    fn font(ctx: *anyopaque, spec: md_layout.FontSpec) anyerror!u16 {
        const self = get(ctx);
        for (self.specs.items, 0..) |e, i| if (std.meta.eql(e, spec)) return @intCast(i);
        try self.specs.append(self.arena, spec);
        const fi = &self.faces[@backingInt(spec.family)][@backingInt(spec.style)];
        // Come `glyph.Raster`: per em la prosa, per altezza ascent−descent il mono.
        try self.scales.append(self.arena, if (spec.family == .prose) stb.stbtt_ScaleForMappingEmToPixels(fi, spec.size) else stb.stbtt_ScaleForPixelHeight(fi, spec.size));
        return @intCast(self.specs.items.len - 1);
    }

    fn advance(ctx: *anyopaque, f: u16, cp: u21) anyerror!f32 {
        const self = get(ctx);
        var adv: c_int = 0;
        var lsb: c_int = 0;
        stb.stbtt_GetCodepointHMetrics(self.info(f), @intCast(cp), &adv, &lsb);
        return @as(f32, @floatFromInt(adv)) * self.scales.items[f];
    }

    fn vmetrics(ctx: *anyopaque, f: u16) md_layout.VMetrics {
        const self = get(ctx);
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(self.info(f), &asc, &desc, &gap);
        const sc = self.scales.items[f];
        return .{ .ascent = @as(f32, @floatFromInt(asc)) * sc, .descent = @as(f32, @floatFromInt(desc)) * sc };
    }

    fn has(ctx: *anyopaque, f: u16, cp: u21) bool {
        return stb.stbtt_FindGlyphIndex(get(ctx).info(f), @intCast(cp)) != 0;
    }

    /// Corpo (em, in punti) del carattere `f` per l'operatore Tf.
    fn emSize(self: *PrintMeasurer, f: u16) f32 {
        const sp = self.specs.items[f];
        return self.scales.items[f] * self.upem[@backingInt(sp.family)][@backingInt(sp.style)];
    }
};

const md_face_names = [2][4][]const u8{
    .{ "LiberationSans", "LiberationSans-Bold", "LiberationSans-Italic", "LiberationSans-BoldItalic" },
    .{ "Hack-Regular", "Hack-Bold", "Hack-Italic", "Hack-BoldItalic" },
};

/// Corpo del markdown su carta, in punti.
const md_body_pt: f32 = 10.5;
const md_margin_mm: f32 = 16;

fn buildMarkdown(gpa: std.mem.Allocator, w: *pdf_writer.Writer, src: []const u8, name: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pm = try PrintMeasurer.init(arena);
    const page_w = pdf_writer.a4_w;
    const page_h = pdf_writer.a4_h;
    const margin = md_margin_mm * pdf_writer.pt_per_mm;
    const doc = try md_layout.layout(arena, src, .{ .width = page_w, .body = md_body_pt, .pad_x = margin, .pad_y = 0 }, text_render.md_paper_theme, pm.measurer());
    const footer_font = try pm.measurer().fontFn(&pm, .{ .family = .prose, .style = .regular, .size = md_body_pt * 0.85 });

    // Pagine: si va a pagina nuova prima della riga che non ci sta; un titolo
    // non resta da solo in fondo; le righe vuote in cima a una pagina spariscono.
    const avail = page_h - 2 * margin - md_body_pt * 2;
    var starts: std.ArrayList(f32) = .empty;
    try starts.append(arena, 0);
    for (doc.lines, 0..) |ln, i| {
        const top = starts.items[starts.items.len - 1];
        const first_on_page = i == 0 or doc.lines[i - 1].y < top;
        var need = ln.y + ln.h - top;
        if (ln.keep_with_next) {
            var j = i + 1;
            while (j < doc.lines.len and doc.lines[j].keep_with_next) j += 1;
            if (j + 1 < doc.lines.len) need = @max(need, doc.lines[j + 1].y - top);
            if (j < doc.lines.len) need = @max(need, doc.lines[j].y + doc.lines[j].h - top);
        }
        if (need > avail and !first_on_page) try starts.append(arena, ln.y);
        if (ln.runs.len == 0 and ln.y == starts.items[starts.items.len - 1]) starts.items[starts.items.len - 1] = ln.y + ln.h;
    }
    const n_pages = starts.items.len;

    // Glifi usati per faccia (larghezze e ToUnicode), poi i flussi delle pagine.
    var used: [2][4]std.AutoArrayHashMapUnmanaged(u16, u21) = undefined;
    for (&used) |*fam| for (fam) |*m| {
        m.* = .empty;
    };
    var streams: std.ArrayList([]const u8) = .empty;
    for (0..n_pages) |p| {
        const top = starts.items[p];
        const bottom = if (p + 1 < n_pages) starts.items[p + 1] else std.math.floatMax(f32);
        var cs: std.ArrayList(u8) = .empty;
        const Y = struct {
            fn at(y: f32, t: f32, m: f32, ph: f32) f32 {
                return ph - (y - t + m);
            }
        };
        for ([_]bool{ false, true }) |over| {
            for (doc.boxes) |bx| {
                if (bx.over != over) continue;
                const y0 = @max(bx.y, top);
                const y1 = @min(bx.y + bx.h, bottom);
                if (y1 <= y0) continue;
                try cs.print(arena, "{d:.3} {d:.3} {d:.3} rg {d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{
                    rgbF(bx.color.r), rgbF(bx.color.g),              rgbF(bx.color.b),
                    bx.x,             Y.at(y1, top, margin, page_h), bx.w,
                    y1 - y0,
                });
            }
            if (over) break;
            try cs.appendSlice(arena, "BT\n");
            for (doc.lines) |ln| {
                if (ln.y < top or ln.y >= bottom) continue;
                for (ln.runs) |run| {
                    if (run.hidden) continue;
                    try textRun(arena, &cs, &pm, &used, run.font, run.color, run.x, Y.at(ln.baseline, top, margin, page_h), run.text);
                }
            }
            // Piè di pagina: nome e numero, allineati a destra.
            const label = try std.fmt.allocPrint(arena, "{s} · {d} / {d}", .{ name, p + 1, n_pages });
            var lw: f32 = 0;
            var it = std.unicode.Utf8View.initUnchecked(label).iterator();
            while (it.nextCodepoint()) |cp| lw += try PrintMeasurer.advance(&pm, footer_font, cp);
            try textRun(arena, &cs, &pm, &used, footer_font, text_render.md_paper_theme.muted, page_w - margin - lw, margin * 0.6, label);
            try cs.appendSlice(arena, "ET\n");
        }
        try streams.append(arena, cs.items);
    }

    var res: std.ArrayList(u8) = .empty;
    try res.appendSlice(arena, "/Font <<");
    for (0..2) |fam| for (0..4) |st| {
        const u = &used[fam][st];
        if (u.count() == 0) continue;
        const fi = &pm.faces[fam][st];
        const upem = pm.upem[fam][st];
        const units = struct {
            fn f(v: c_int, up: f32) i32 {
                return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * 1000 / up));
            }
        }.f;
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stb.stbtt_GetFontBoundingBox(fi, &x0, &y0, &x1, &y1);
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(fi, &asc, &desc, &gap);
        const codes = try arena.alloc(pdf_writer.GlyphCode, u.count());
        // Anche il glifo 0 (carattere assente dal font, disegnato come
        // .notdef): deve avanzare quanto nel layout, non del /DW.
        const widths = try arena.alloc(pdf_writer.GlyphWidth, u.count() + 1);
        for (widths, 0..) |*gw, k| {
            const g: u16 = if (k == 0) 0 else u.keys()[k - 1];
            var adv: c_int = 0;
            var lsb: c_int = 0;
            stb.stbtt_GetGlyphHMetrics(fi, g, &adv, &lsb);
            gw.* = .{ .glyph = g, .width = units(adv, upem) };
        }
        for (u.keys(), u.values(), codes) |g, cp, *c| c.* = .{ .glyph = g, .cp = cp };
        const obj = try w.addTrueTypeFont(if (fam == 0) glyph.prose_fonts[st] else glyph.mono_fonts[st], .{
            .name = md_face_names[fam][st],
            .bbox = .{ units(x0, upem), units(y0, upem), units(x1, upem), units(y1, upem) },
            .ascent = units(asc, upem),
            .descent = units(desc, upem),
            .italic_angle = if (st >= 2) -12 else 0,
            .fixed_pitch = fam == 1,
        }, 1000, widths, codes);
        try res.print(arena, " /F{d}{d} {d} 0 R", .{ fam, st, obj });
    };
    try res.appendSlice(arena, " >>");
    for (streams.items) |st| try w.addPage(page_w, page_h, res.items, st);
}

fn rgbF(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) / 255.0;
}

/// Un tratto di testo nel flusso di una pagina: carattere, colore, posizione
/// (punti PDF) e i glifi in esadecimale; registra i glifi usati.
fn textRun(arena: std.mem.Allocator, cs: *std.ArrayList(u8), pm: *PrintMeasurer, used: *[2][4]std.AutoArrayHashMapUnmanaged(u16, u21), f: u16, color: glyph.Rgb, x: f32, y: f32, text: []const u8) !void {
    const sp = pm.specs.items[f];
    const fam = @backingInt(sp.family);
    const st = @backingInt(sp.style);
    try cs.print(arena, "/F{d}{d} {d:.3} Tf {d:.3} {d:.3} {d:.3} rg 1 0 0 1 {d:.3} {d:.3} Tm <", .{ fam, st, pm.emSize(f), rgbF(color.r), rgbF(color.g), rgbF(color.b), x, y });
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        const gid: u16 = @intCast(@max(0, stb.stbtt_FindGlyphIndex(&pm.faces[fam][st], @intCast(cp))));
        if (gid != 0) try used[fam][st].put(arena, gid, cp);
        if (gid == 0 and used[fam][st].count() == 0) try used[fam][st].put(arena, 0, 0xFFFD);
        try cs.print(arena, "{X:0>4}", .{gid});
    }
    try cs.appendSlice(arena, "> Tj\n");
}

const Rotated = struct { px: []const u8, w: usize, h: usize, owned: bool };

/// Ruota un'immagine RGB di `quarters` quarti di giro orari.
fn rotate(gpa: std.mem.Allocator, px: []const u8, w: usize, h: usize, quarters: u2) !Rotated {
    if (quarters == 0) return .{ .px = px, .w = w, .h = h, .owned = false };
    const out = try gpa.alloc(u8, w * h * 3);
    const nw = if (quarters == 2) w else h;
    const nh = if (quarters == 2) h else w;
    for (0..h) |y| for (0..w) |x| {
        const d: [2]usize = switch (quarters) {
            1 => .{ h - 1 - y, x },
            2 => .{ w - 1 - x, h - 1 - y },
            3 => .{ y, w - 1 - x },
            0 => unreachable,
        };
        const si = (y * w + x) * 3;
        const di = (d[1] * nw + d[0]) * 3;
        @memcpy(out[di..][0..3], px[si..][0..3]);
    };
    return .{ .px = out, .w = nw, .h = nh, .owned = true };
}

test "rotate: quarti di giro" {
    const gpa = std.testing.allocator;
    // 2×1: A B  →  orario: colonna A sopra B.
    const px = [_]u8{ 1, 1, 1, 2, 2, 2 };
    const r1 = try rotate(gpa, &px, 2, 1, 1);
    defer gpa.free(r1.px);
    try std.testing.expectEqual(@as(usize, 1), r1.w);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 2, 2, 2 }, r1.px);
    const r3 = try rotate(gpa, &px, 2, 1, 3);
    defer gpa.free(r3.px);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 1, 1, 1 }, r3.px);
    const r2 = try rotate(gpa, &px, 2, 1, 2);
    defer gpa.free(r2.px);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 1, 1, 1 }, r2.px);
}

test "markdown e testo: pagine A4 senza perdite di memoria" {
    const gpa = std.testing.allocator;
    var md_src: std.ArrayList(u8) = .empty;
    defer md_src.deinit(gpa);
    try md_src.appendSlice(gpa, "# Titolo\n\nTesto **grassetto**, *corsivo*, `codice` e [link](https://x).\n\n- voce\n");
    for (0..150) |i| try md_src.print(gpa, "riga {d} con accenti àèìòù\n\n", .{i});
    const md: decoder_mod.Decoded = .{ .markdown = .{ .content = md_src.items } };
    const pdf = try build(gpa, &md, "prova.md", 0);
    defer gpa.free(pdf);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    // 150 paragrafi a 10,5 pt non stanno in una pagina; testo vero, coi font.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Count 1 ") == null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /LiberationSans-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Hack-Regular") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, " /W [") != null);

    const code: decoder_mod.Decoded = .{ .text = "const x = \"stringa\"; // commento\n" };
    const pdf2 = try build(gpa, &code, "a.zig", 0);
    defer gpa.free(pdf2);
    // Testo vero, col font incorporato e la mappa per copiarlo.
    try std.testing.expect(std.mem.indexOf(u8, pdf2, "/FontFile2") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf2, "/Encoding /Identity-H") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf2, "/ToUnicode") != null);
}

test "nome di file non UTF-8 nel piè di pagina" {
    const gpa = std.testing.allocator;
    const code: decoder_mod.Decoded = .{ .text = "x\n" };
    const pdf = try build(gpa, &code, "caff\xe8.txt", 0);
    defer gpa.free(pdf);
    const md: decoder_mod.Decoded = .{ .markdown = .{ .content = "# x\n" } };
    const pdf2 = try build(gpa, &md, "caff\xe8.md", 0);
    defer gpa.free(pdf2);
    const fixed = try validUtf8(gpa, "a\xe8b\xc3");
    defer gpa.free(fixed);
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}", fixed);
}

test "markdown annidato oltre la larghezza della pagina" {
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendNTimes(gpa, '>', 60);
    try src.appendSlice(gpa, "     codice\n");
    for (0..23) |d| {
        try src.appendNTimes(gpa, ' ', d * 2);
        try src.appendSlice(gpa, "- livello\n");
    }
    const md: decoder_mod.Decoded = .{ .markdown = .{ .content = src.items } };
    const pdf = try build(gpa, &md, "a.md", 0);
    defer gpa.free(pdf);
}

test "immagine larga: A4 orizzontale" {
    const gpa = std.testing.allocator;
    const px = try gpa.alloc(u8, 40 * 10 * 3);
    @memset(px, 128);
    px[0] = 255;
    const img: decoder_mod.Decoded = .{ .image = .{ .width = 40, .height = 10, .pixels = px, .name = "x" } };
    defer gpa.free(px);
    const pdf = try build(gpa, &img, "x.png", 0);
    defer gpa.free(pdf);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/MediaBox [0 0 841.89 595.28]") != null);
    // Ruotata di un quarto di giro diventa alta: A4 verticale.
    const pdf2 = try build(gpa, &img, "x.png", 1);
    defer gpa.free(pdf2);
    try std.testing.expect(std.mem.indexOf(u8, pdf2, "/MediaBox [0 0 595.28 841.89]") != null);
}
