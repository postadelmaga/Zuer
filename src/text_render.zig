//! Rende contenuti testuali (testo, codice, markdown, tabelle CSV) in immagini
//! RGB usando un motore di glifi nativo (stb_truetype + font Hack embeddati, vedi
//! `glyph.zig`): i glifi sono rasterizzati alla dimensione esatta dei pixel e
//! composti direttamente nel buffer, senza processi esterni (niente ImageMagick).
//! È la stessa tecnica di egui/viewer (glyph raster → composizione), quindi la
//! resa combacia con il viewer di riferimento.

const std = @import("std");
const decoder_mod = @import("decoder.zig");
const glyph = @import("glyph.zig");
const Rgb = glyph.Rgb;

pub const max_table_col: usize = 40;

// Margini tipografici del documento (bordo attorno al testo).
const pad_x: i32 = 20;
const pad_y: i32 = 14;

// Palette: primo piano allineato a viewer (funzione `harmonize`); lo sfondo
// resta #080810 perché il compositore della GUI lo rende trasparente (effetto
// vetro della finestra, vedi composeFrame) — sotto vetro il valore non si vede.
const bg = Rgb.fromHex("#080810"); // key di trasparenza del compositore (8,8,16)
const fg = Rgb.fromHex("#cdcdcd"); // corpo del testo (viewer: ~gray 205)
const c_line_no = Rgb.fromHex("#606060"); // numeri di riga (viewer: gray 96)
const c_keyword = Rgb.fromHex("#96aaeb"); // keyword (viewer: rgb 150,170,235)
const c_string = Rgb.fromHex("#9ebc96"); // stringhe (viewer: rgb 158,188,150)
const c_comment = Rgb.fromHex("#707070"); // commenti (viewer: gray 112)
const c_md_code = Rgb.fromHex("#9ece6a"); // codice inline/blocchi markdown
const c_md_link = Rgb.fromHex("#7aa2f7"); // link markdown

/// Parametri di resa: larghezza in pixel dell'immagine prodotta (idealmente la
/// larghezza della finestra) e corpo del carattere (scalato dallo zoom del
/// chiamante). L'altezza è determinata dal contenuto.
pub const RenderOpts = struct {
    width: usize = 1024,
    pointsize: usize = 15,
};

/// Oltre questa dimensione il file è mostrato in modalità plain (niente numeri
/// di riga né colori): l'evidenziazione di un sorgente enorme non ripaga.
const max_rich_bytes: usize = 2 * 1024 * 1024;

/// Altezza in pixel del carattere a partire dal corpo in punti, alla densità 96
/// dpi storicamente usata dal renderer (96/72 px per punto).
fn pxHeight(pointsize: usize) f32 {
    return @as(f32, @floatFromInt(pointsize)) * 96.0 / 72.0;
}

/// Un tratto di testo omogeneo (stesso colore e stile) su una riga visiva.
const Run = struct {
    text: []const u8,
    color: Rgb,
    style: glyph.Style = .regular,
};

const Row = []const Run;

/// Rende un contenuto decodificato testuale in un'immagine RGB. `io` non è più
/// necessario (nessun processo esterno) ma resta nella firma per i chiamanti.
pub fn render(gpa: std.mem.Allocator, io: std.Io, decoded: *const decoder_mod.Decoded, name: []const u8, opts: RenderOpts) !decoder_mod.ImageData {
    _ = io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var raster = try glyph.Raster.init(gpa, pxHeight(opts.pointsize));
    defer raster.deinit();

    var rows: std.ArrayList(Row) = .empty;
    try buildRows(arena, &rows, &raster, decoded, name, opts);

    return paint(gpa, &raster, rows.items, name, opts);
}

/// Costruisce le righe visive (run posizionati) del contenuto decodificato.
/// Condiviso dal percorso CPU (composizione diretta) e da quello GPU (quad).
fn buildRows(arena: std.mem.Allocator, rows: *std.ArrayList(Row), raster: *glyph.Raster, decoded: *const decoder_mod.Decoded, name: []const u8, opts: RenderOpts) !void {
    switch (decoded.*) {
        .text => |t| {
            const rich = t.len <= max_rich_bytes and isCodeLike(name);
            const lang: ?Lang = if (rich) langFor(extOf(name)) else null;
            try layoutCode(arena, rows, raster, t, opts, rich, lang);
        },
        .csv => |c| {
            const table = try formatTable(arena, c);
            try layoutCode(arena, rows, raster, table, opts, false, null);
        },
        .markdown => |m| {
            try layoutMarkdown(arena, rows, raster, m.content, opts);
        },
        else => return error.UnsupportedContent,
    }
}

// --- Percorso GPU: atlante + quad texturati ---------------------------------

/// Vertice per la pipeline testo: posizione schermo (px), UV nell'atlante e
/// colore. Corrisponde a `src/shaders/text.vert`.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// Geometria del testo per la GPU: due triangoli per glifo, l'atlante da caricare
/// come texture, e le dimensioni finali dell'immagine.
pub const TextMesh = struct {
    vertices: []Vertex,
    atlas: glyph.Atlas,
    width: usize,
    height: usize,

    pub fn deinit(self: *TextMesh, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        self.atlas.deinit();
    }
};

/// Colore di sfondo del documento come clear color RGBA normalizzato.
pub const clear_bg = [4]f32{
    @as(f32, @floatFromInt(bg.r)) / 255.0,
    @as(f32, @floatFromInt(bg.g)) / 255.0,
    @as(f32, @floatFromInt(bg.b)) / 255.0,
    1.0,
};

/// Costruisce la geometria dei quad glifo per il rendering su GPU: stesso layout
/// del percorso CPU, ma emette vertici texturati anziché comporre i pixel.
pub fn buildTextMesh(gpa: std.mem.Allocator, decoded: *const decoder_mod.Decoded, name: []const u8, opts: RenderOpts) !TextMesh {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var raster = try glyph.Raster.init(gpa, pxHeight(opts.pointsize));
    defer raster.deinit();

    var rows: std.ArrayList(Row) = .empty;
    try buildRows(arena, &rows, &raster, decoded, name, opts);

    // Assicura che tutti i glifi usati siano in cache prima di impacchettarli.
    for (rows.items) |row| {
        for (row) |run| {
            var i: usize = 0;
            while (i < run.text.len) {
                const seq = std.unicode.utf8ByteSequenceLength(run.text[i]) catch 1;
                const end = @min(i + seq, run.text.len);
                const cp: u32 = std.unicode.utf8Decode(run.text[i..end]) catch run.text[i];
                _ = try raster.getGlyph(run.style, cp);
                i = end;
            }
        }
    }

    var atlas = try glyph.buildAtlas(&raster);
    errdefer atlas.deinit();

    const line_h = raster.lineHeight();
    const advance = raster.advance;
    const width: usize = @max(opts.width, 2 * @as(usize, @intCast(pad_x)) + 1);
    const n_rows: usize = @max(rows.items.len, 1);
    const height: usize = @as(usize, @intCast(2 * pad_y)) + n_rows * @as(usize, @intCast(line_h));

    const aw: f32 = @floatFromInt(atlas.w);
    const ah: f32 = @floatFromInt(atlas.h);

    var verts: std.ArrayList(Vertex) = .empty;
    errdefer verts.deinit(gpa);

    for (rows.items, 0..) |row, r| {
        const baseline = pad_y + @as(i32, @intCast(r)) * line_h + raster.ascent;
        var col: i32 = 0;
        for (row) |run| {
            const cr: f32 = @as(f32, @floatFromInt(run.color.r)) / 255.0;
            const cg: f32 = @as(f32, @floatFromInt(run.color.g)) / 255.0;
            const cb: f32 = @as(f32, @floatFromInt(run.color.b)) / 255.0;
            var i: usize = 0;
            while (i < run.text.len) {
                const seq = std.unicode.utf8ByteSequenceLength(run.text[i]) catch 1;
                const end = @min(i + seq, run.text.len);
                const cp: u32 = std.unicode.utf8Decode(run.text[i..end]) catch run.text[i];
                i = end;
                const pen_x = pad_x + col * advance;
                col += 1;
                const ag = atlas.get(run.style, cp) orelse continue;
                if (ag.w == 0 or ag.h == 0) continue;

                const x0: f32 = @floatFromInt(pen_x + ag.xoff);
                const y0: f32 = @floatFromInt(baseline + ag.yoff);
                const x1 = x0 + @as(f32, @floatFromInt(ag.w));
                const y1 = y0 + @as(f32, @floatFromInt(ag.h));
                const su0: f32 = @as(f32, @floatFromInt(ag.ax)) / aw;
                const sv0: f32 = @as(f32, @floatFromInt(ag.ay)) / ah;
                const su1: f32 = @as(f32, @floatFromInt(ag.ax + ag.w)) / aw;
                const sv1: f32 = @as(f32, @floatFromInt(ag.ay + ag.h)) / ah;

                const tl = Vertex{ .x = x0, .y = y0, .u = su0, .v = sv0, .r = cr, .g = cg, .b = cb };
                const tr = Vertex{ .x = x1, .y = y0, .u = su1, .v = sv0, .r = cr, .g = cg, .b = cb };
                const bl = Vertex{ .x = x0, .y = y1, .u = su0, .v = sv1, .r = cr, .g = cg, .b = cb };
                const br = Vertex{ .x = x1, .y = y1, .u = su1, .v = sv1, .r = cr, .g = cg, .b = cb };
                try verts.appendSlice(gpa, &.{ tl, tr, bl, tr, br, bl });
            }
        }
    }

    return .{
        .vertices = try verts.toOwnedSlice(gpa),
        .atlas = atlas,
        .width = width,
        .height = height,
    };
}

// --- Composizione dell'immagine ---------------------------------------------

/// Dipinge le righe visive in un buffer RGB: sfondo pieno, poi i glifi di ogni
/// run fusi sopra secondo la loro copertura. Griglia monospazio (una colonna per
/// codepoint), altezza determinata dal numero di righe.
fn paint(gpa: std.mem.Allocator, raster: *glyph.Raster, rows: []const Row, name: []const u8, opts: RenderOpts) !decoder_mod.ImageData {
    const line_h = raster.lineHeight();
    const advance = raster.advance;
    const width: usize = @max(opts.width, 2 * @as(usize, @intCast(pad_x)) + 1);
    const n_rows: usize = @max(rows.len, 1);
    const height: usize = @as(usize, @intCast(2 * pad_y)) + n_rows * @as(usize, @intCast(line_h));

    const pixels = try gpa.alloc(u8, width * height * 3);
    errdefer gpa.free(pixels);
    fillBackground(pixels, bg);

    const w_i: i32 = @intCast(width);
    const h_i: i32 = @intCast(height);
    for (rows, 0..) |row, r| {
        const baseline = pad_y + @as(i32, @intCast(r)) * line_h + raster.ascent;
        var col: i32 = 0;
        for (row) |run| {
            var i: usize = 0;
            while (i < run.text.len) {
                const seq = std.unicode.utf8ByteSequenceLength(run.text[i]) catch 1;
                const end = @min(i + seq, run.text.len);
                const cp: u32 = std.unicode.utf8Decode(run.text[i..end]) catch run.text[i];
                const pen_x = pad_x + col * advance;
                try raster.drawCodepoint(pixels, w_i, h_i, pen_x, baseline, run.style, cp, run.color);
                col += 1;
                i = end;
            }
        }
    }

    const name_dup = try gpa.dupe(u8, name);
    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
        .name = name_dup,
    };
}

fn fillBackground(pixels: []u8, color: Rgb) void {
    var i: usize = 0;
    while (i + 3 <= pixels.len) : (i += 3) {
        pixels[i + 0] = color.r;
        pixels[i + 1] = color.g;
        pixels[i + 2] = color.b;
    }
}

/// Colonne di testo disponibili alla larghezza richiesta (al netto dei margini).
fn totalColumns(raster: *const glyph.Raster, opts: RenderOpts) usize {
    const inner: i32 = @as(i32, @intCast(opts.width)) - 2 * pad_x;
    if (raster.advance <= 0 or inner <= 0) return 24;
    return @intCast(@max(@divTrunc(inner, raster.advance), 24));
}

// --- Documento testo/codice: gutter, wrap ed evidenziazione ------------------

/// Costruisce le righe visive di un documento testuale. Con `gutter` attivo
/// aggiunge i numeri di riga (allineati a destra, senza righello — come viewer);
/// con `lang` non nullo evidenzia keyword/stringhe/commenti. Il testo va a capo
/// per colonne, con rientro allineato al gutter sulle continuazioni.
fn layoutCode(arena: std.mem.Allocator, rows: *std.ArrayList(Row), raster: *glyph.Raster, text: []const u8, opts: RenderOpts, gutter: bool, lang: ?Lang) !void {
    const total_cols = totalColumns(raster, opts);

    var total_lines: usize = 1;
    for (text) |ch| {
        if (ch == '\n') total_lines += 1;
    }
    var digits: usize = 1;
    var n = total_lines;
    while (n >= 10) : (n /= 10) digits += 1;
    if (digits < 3) digits = 3;

    const gutter_cols: usize = if (gutter) digits + 2 else 0;
    const code_cols = if (total_cols > gutter_cols + 16) total_cols - gutter_cols else 16;

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line_trimmed = std.mem.trimEnd(u8, raw_line, "\r");
        // I tab spostano l'allineamento a colonne: li espandiamo a spazi.
        const line = try expandTabs(arena, line_trimmed);

        var start: usize = 0;
        var first = true;
        while (true) {
            const end = sliceByColumns(line, start, code_cols);
            const chunk = line[start..end];

            var run_list: std.ArrayList(Run) = .empty;
            if (gutter) {
                const g = if (first)
                    try gutterNumber(arena, line_no, digits)
                else
                    try blankGutter(arena, gutter_cols);
                try run_list.append(arena, .{ .text = g, .color = c_line_no });
            }
            if (lang) |l| {
                try tokenize(arena, &run_list, chunk, l);
            } else if (chunk.len > 0) {
                try run_list.append(arena, .{ .text = chunk, .color = fg });
            }
            try rows.append(arena, try run_list.toOwnedSlice(arena));

            first = false;
            start = end;
            if (start >= line.len) break;
        }
    }
}

/// Numero di riga allineato a destra su `digits` cifre, seguito da due spazi.
fn gutterNumber(arena: std.mem.Allocator, line_no: usize, digits: usize) ![]u8 {
    const buf = try arena.alloc(u8, digits + 2);
    @memset(buf, ' ');
    var v = line_no;
    var i = digits;
    if (v == 0) {
        buf[digits - 1] = '0';
    } else {
        while (v > 0) : (v /= 10) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(v % 10));
        }
    }
    return buf;
}

fn blankGutter(arena: std.mem.Allocator, cols: usize) ![]u8 {
    const buf = try arena.alloc(u8, cols);
    @memset(buf, ' ');
    return buf;
}

/// Evidenziazione leggera di un segmento in run colorati: commenti di riga,
/// stringhe tra apici e keyword. Il resto è testo neutro. I run puntano dentro
/// `chunk` (memoria dell'arena, viva fino alla composizione).
fn tokenize(arena: std.mem.Allocator, runs: *std.ArrayList(Run), chunk: []const u8, lang: Lang) !void {
    var i: usize = 0;
    var plain_start: usize = 0;

    while (i < chunk.len) {
        // Commento di riga: colora fino a fine segmento.
        var is_comment = false;
        for (lang.line_comments) |prefix| {
            if (std.mem.startsWith(u8, chunk[i..], prefix)) {
                is_comment = true;
                break;
            }
        }
        if (is_comment) {
            try flushPlain(arena, runs, chunk, plain_start, i);
            try runs.append(arena, .{ .text = chunk[i..], .color = c_comment });
            return;
        }

        const c = chunk[i];

        // Stringhe tra apici (best effort, senza multilinea).
        if (c == '"' or c == '\'' or c == '`') {
            try flushPlain(arena, runs, chunk, plain_start, i);
            var end = i + 1;
            while (end < chunk.len) : (end += 1) {
                if (chunk[end] == '\\') {
                    end += 1;
                    continue;
                }
                if (chunk[end] == c) break;
            }
            const stop = @min(end + 1, chunk.len);
            try runs.append(arena, .{ .text = chunk[i..stop], .color = c_string });
            i = stop;
            plain_start = i;
            continue;
        }

        // Identificatori: keyword colorate (grassetto), il resto resta neutro.
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var end = i + 1;
            while (end < chunk.len and (std.ascii.isAlphanumeric(chunk[end]) or chunk[end] == '_')) end += 1;
            const word = chunk[i..end];
            var is_kw = false;
            for (lang.keywords) |kw| {
                if (std.mem.eql(u8, word, kw)) {
                    is_kw = true;
                    break;
                }
            }
            if (is_kw) {
                try flushPlain(arena, runs, chunk, plain_start, i);
                try runs.append(arena, .{ .text = word, .color = c_keyword, .style = .bold });
                plain_start = end;
            }
            i = end;
            continue;
        }

        i += 1;
    }
    try flushPlain(arena, runs, chunk, plain_start, chunk.len);
}

fn flushPlain(arena: std.mem.Allocator, runs: *std.ArrayList(Run), chunk: []const u8, from: usize, to: usize) !void {
    if (to > from) try runs.append(arena, .{ .text = chunk[from..to], .color = fg });
}

// --- Markdown: header, grassetto, corsivo, codice, liste ---------------------

/// Costruisce le righe visive del markdown. Header in grassetto, blocchi e
/// codice inline in verde, grassetto/corsivo, liste puntate e link. Le righe
/// logiche vanno a capo per colonne conservando lo stile dei run.
fn layoutMarkdown(arena: std.mem.Allocator, rows: *std.ArrayList(Row), raster: *glyph.Raster, md: []const u8, opts: RenderOpts) !void {
    const total_cols = totalColumns(raster, opts);
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, md, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");

        var line_runs: std.ArrayList(Run) = .empty;

        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) {
            try line_runs.append(arena, .{ .text = try arena.dupe(u8, line), .color = c_md_code });
            try wrapRuns(arena, rows, line_runs.items, total_cols);
            continue;
        }

        // Header: da # a ####, in grassetto (stessa griglia monospazio).
        var level: usize = 0;
        while (level < trimmed.len and level < 4 and trimmed[level] == '#') level += 1;
        if (level > 0 and level < trimmed.len and trimmed[level] == ' ') {
            try mdInline(arena, &line_runs, trimmed[level + 1 ..], .bold, fg);
            try wrapRuns(arena, rows, line_runs.items, total_cols);
            continue;
        }

        // Liste puntate, conservando l'indentazione.
        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            const indent = try blankGutter(arena, line.len - trimmed.len);
            try line_runs.append(arena, .{ .text = indent, .color = fg });
            try line_runs.append(arena, .{ .text = "• ", .color = fg });
            try mdInline(arena, &line_runs, trimmed[2..], .regular, fg);
            try wrapRuns(arena, rows, line_runs.items, total_cols);
            continue;
        }

        try mdInline(arena, &line_runs, line, .regular, fg);
        try wrapRuns(arena, rows, line_runs.items, total_cols);
    }
}

/// Analizza lo stile inline (`codice`, **grassetto**, *corsivo*, [testo](url)) e
/// accoda run. `base_style` è lo stile di fondo (grassetto per gli header).
fn mdInline(arena: std.mem.Allocator, runs: *std.ArrayList(Run), text: []const u8, base_style: glyph.Style, base_color: Rgb) !void {
    var i: usize = 0;
    var plain_start: usize = 0;
    const flush = struct {
        fn f(a: std.mem.Allocator, rs: *std.ArrayList(Run), t: []const u8, from: usize, to: usize, st: glyph.Style, col: Rgb) !void {
            if (to > from) try rs.append(a, .{ .text = t[from..to], .color = col, .style = st });
        }
    }.f;

    while (i < text.len) {
        const c = text[i];
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                try flush(arena, runs, text, plain_start, i, base_style, base_color);
                try runs.append(arena, .{ .text = text[i + 1 .. end], .color = c_md_code });
                i = end + 1;
                plain_start = i;
                continue;
            }
        } else if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                try flush(arena, runs, text, plain_start, i, base_style, base_color);
                try runs.append(arena, .{ .text = text[i + 2 .. end], .color = base_color, .style = .bold });
                i = end + 2;
                plain_start = i;
                continue;
            }
        } else if (c == '*') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |end| {
                if (end > i + 1) {
                    try flush(arena, runs, text, plain_start, i, base_style, base_color);
                    try runs.append(arena, .{ .text = text[i + 1 .. end], .color = base_color, .style = .italic });
                    i = end + 1;
                    plain_start = i;
                    continue;
                }
            }
        } else if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close| {
                if (close + 1 < text.len and text[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |paren| {
                        try flush(arena, runs, text, plain_start, i, base_style, base_color);
                        try runs.append(arena, .{ .text = text[i + 1 .. close], .color = c_md_link });
                        i = paren + 1;
                        plain_start = i;
                        continue;
                    }
                }
            }
        }
        i += 1;
    }
    try flush(arena, runs, text, plain_start, text.len, base_style, base_color);
}

/// Manda a capo una riga logica (lista di run) in righe visive larghe al più
/// `max_cols` colonne, spezzando i run e conservandone colore e stile.
fn wrapRuns(arena: std.mem.Allocator, rows: *std.ArrayList(Row), line_runs: []const Run, max_cols: usize) !void {
    var cur: std.ArrayList(Run) = .empty;
    var col: usize = 0;

    for (line_runs) |run| {
        var seg_start: usize = 0;
        var i: usize = 0;
        while (i < run.text.len) {
            const seq = std.unicode.utf8ByteSequenceLength(run.text[i]) catch 1;
            const end = @min(i + seq, run.text.len);
            col += 1;
            i = end;
            if (col >= max_cols) {
                try cur.append(arena, .{ .text = run.text[seg_start..i], .color = run.color, .style = run.style });
                try rows.append(arena, try cur.toOwnedSlice(arena));
                cur = .empty;
                col = 0;
                seg_start = i;
            }
        }
        if (i > seg_start) {
            try cur.append(arena, .{ .text = run.text[seg_start..i], .color = run.color, .style = run.style });
        }
    }
    // Riga finale (anche vuota, per preservare le righe bianche del sorgente).
    try rows.append(arena, try cur.toOwnedSlice(arena));
}

// --- Tabelle / helper --------------------------------------------------------

fn expandTabs(arena: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (line) |c| {
        if (c == '\t') {
            try out.appendSlice(arena, "    ");
        } else {
            try out.append(arena, c);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Fine del segmento che copre al più `cols` codepoint da `start`, senza
/// spezzare le sequenze UTF-8.
fn sliceByColumns(line: []const u8, start: usize, cols: usize) usize {
    var i = start;
    var count: usize = 0;
    while (i < line.len and count < cols) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        i = @min(i + len, line.len);
        count += 1;
    }
    return i;
}

const Lang = struct {
    line_comments: []const []const u8,
    keywords: []const []const u8,
};

const kw_zig = [_][]const u8{ "fn", "pub", "const", "var", "if", "else", "while", "for", "return", "try", "catch", "defer", "errdefer", "struct", "enum", "union", "switch", "break", "continue", "orelse", "and", "or", "comptime", "test", "export", "extern", "inline", "null", "undefined", "true", "false", "error", "anyerror", "unreachable", "usingnamespace" };
const kw_rust = [_][]const u8{ "fn", "pub", "let", "mut", "const", "if", "else", "while", "for", "loop", "return", "match", "struct", "enum", "impl", "trait", "use", "mod", "crate", "self", "super", "where", "async", "await", "move", "ref", "dyn", "true", "false", "in", "as", "break", "continue", "static", "type", "unsafe", "extern" };
const kw_c = [_][]const u8{ "if", "else", "while", "for", "return", "struct", "enum", "union", "typedef", "static", "const", "void", "int", "char", "long", "short", "unsigned", "signed", "float", "double", "sizeof", "switch", "case", "break", "continue", "default", "do", "goto", "extern", "inline", "volatile", "class", "public", "private", "protected", "template", "typename", "namespace", "using", "new", "delete", "virtual", "override", "nullptr", "true", "false", "auto", "this", "bool" };
const kw_py = [_][]const u8{ "def", "class", "if", "elif", "else", "while", "for", "return", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "global", "nonlocal", "yield", "async", "await", "in", "is", "not", "and", "or", "None", "True", "False", "del", "assert", "match", "case" };
const kw_js = [_][]const u8{ "function", "const", "let", "var", "if", "else", "while", "for", "return", "class", "extends", "import", "from", "export", "default", "new", "this", "typeof", "instanceof", "try", "catch", "finally", "throw", "async", "await", "yield", "switch", "case", "break", "continue", "delete", "in", "of", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "readonly", "static" };
const kw_go = [_][]const u8{ "func", "package", "import", "var", "const", "if", "else", "for", "range", "return", "struct", "interface", "map", "chan", "go", "defer", "select", "switch", "case", "break", "continue", "type", "nil", "true", "false", "fallthrough", "goto" };
const kw_sh = [_][]const u8{ "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "local", "return", "echo", "export", "in", "read", "exit", "set" };
const kw_lua = [_][]const u8{ "function", "local", "if", "then", "else", "elseif", "end", "while", "for", "do", "return", "nil", "true", "false", "and", "or", "not", "repeat", "until", "break", "in" };
const kw_sql = [_][]const u8{ "select", "from", "where", "insert", "update", "delete", "join", "left", "right", "inner", "outer", "group", "by", "order", "having", "limit", "create", "table", "drop", "alter", "index", "as", "and", "or", "not", "null", "into", "values", "set", "on", "distinct", "union" };
const kw_none = [_][]const u8{};

const slash_comment = [_][]const u8{"//"};
const hash_comment = [_][]const u8{"#"};
const dash_comment = [_][]const u8{"--"};
const semi_comment = [_][]const u8{";"};
const no_comment = [_][]const u8{};

fn langFor(ext: []const u8) Lang {
    const Case = struct { exts: []const []const u8, lang: Lang };
    const table = [_]Case{
        .{ .exts = &.{"zig"}, .lang = .{ .line_comments = &slash_comment, .keywords = &kw_zig } },
        .{ .exts = &.{"rs"}, .lang = .{ .line_comments = &slash_comment, .keywords = &kw_rust } },
        .{ .exts = &.{ "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "java", "cs", "kt", "kts", "swift", "scala", "dart", "proto" }, .lang = .{ .line_comments = &slash_comment, .keywords = &kw_c } },
        .{ .exts = &.{ "py", "pyi", "rb", "toml", "yaml", "yml", "cfg", "conf", "properties", "gitignore", "gitattributes", "editorconfig", "dockerfile", "mk", "make", "cmake", "r", "jl", "nim", "ex", "exs" }, .lang = .{ .line_comments = &hash_comment, .keywords = &kw_py } },
        .{ .exts = &.{ "js", "mjs", "cjs", "jsx", "ts", "tsx", "php" }, .lang = .{ .line_comments = &slash_comment, .keywords = &kw_js } },
        .{ .exts = &.{"go"}, .lang = .{ .line_comments = &slash_comment, .keywords = &kw_go } },
        .{ .exts = &.{ "sh", "bash", "zsh", "fish", "ps1", "env" }, .lang = .{ .line_comments = &hash_comment, .keywords = &kw_sh } },
        .{ .exts = &.{ "lua", "sql", "hs" }, .lang = .{ .line_comments = &dash_comment, .keywords = &kw_lua } },
        .{ .exts = &.{ "ini", "asm", "s" }, .lang = .{ .line_comments = &semi_comment, .keywords = &kw_none } },
    };
    for (table) |case| {
        for (case.exts) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return case.lang;
        }
    }
    // Testo generico: niente keyword, niente commenti — restano gutter e wrap.
    return .{ .line_comments = &no_comment, .keywords = &kw_none };
}

fn extOf(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        return name[dot + 1 ..];
    }
    return "";
}

/// Il documento con gutter ha senso per testo e codice aperti da file; le schede
/// informative sintetiche (media, archivi) non passano di qui.
fn isCodeLike(name: []const u8) bool {
    const ext = extOf(name);
    if (ext.len == 0) return true; // file senza estensione: quasi sempre testo
    const text_exts = [_][]const u8{ "txt", "text", "log", "nfo", "rst", "adoc", "asciidoc", "org", "tex", "bib", "srt", "vtt", "diff", "patch", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties", "env", "plist", "editorconfig", "gitignore", "gitattributes", "lock", "xml", "html", "htm", "xhtml", "css", "scss", "sass", "less", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "mk", "make", "cmake", "gradle", "dockerfile", "rs", "py", "pyi", "js", "mjs", "cjs", "jsx", "ts", "tsx", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "cs", "java", "kt", "kts", "go", "rb", "php", "swift", "scala", "lua", "pl", "pm", "r", "sql", "dart", "ex", "exs", "erl", "hrl", "hs", "clj", "cljs", "vim", "asm", "s", "zig", "jl", "nim", "proto", "graphql", "gql" };
    for (text_exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// Formatta una tabella CSV come testo monospazio con colonne allineate.
fn formatTable(arena: std.mem.Allocator, c: decoder_mod.CsvData) ![]u8 {
    const ncols = c.headers.len;
    if (ncols == 0) return arena.dupe(u8, "(tabella vuota)");

    const widths = try arena.alloc(usize, ncols);
    for (c.headers, 0..) |h, i| widths[i] = @min(h.len, max_table_col);
    for (c.rows) |row| {
        for (row, 0..) |cell_text, i| {
            if (i >= ncols) break;
            widths[i] = @max(widths[i], @min(cell_text.len, max_table_col));
        }
    }

    var out: std.ArrayList(u8) = .empty;
    try writeTableRow(arena, &out, c.headers, widths);
    for (widths, 0..) |wd, i| {
        try out.appendNTimes(arena, '-', wd);
        if (i + 1 < ncols) try out.appendSlice(arena, "  ");
    }
    try out.append(arena, '\n');
    for (c.rows) |row| {
        try writeTableRow(arena, &out, row, widths);
    }
    return out.toOwnedSlice(arena);
}

fn writeTableRow(arena: std.mem.Allocator, out: *std.ArrayList(u8), cells: []const []const u8, widths: []const usize) !void {
    for (widths, 0..) |wd, i| {
        const cell = if (i < cells.len) cells[i] else "";
        const shown = cell[0..@min(cell.len, wd)];
        try out.appendSlice(arena, shown);
        if (i + 1 < widths.len) {
            try out.appendNTimes(arena, ' ', wd - shown.len + 2);
        }
    }
    try out.append(arena, '\n');
}
