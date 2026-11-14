//! Impaginazione del markdown (`md_parse`): righe di testo posizionate e
//! rettangoli (sfondi del codice, barre delle citazioni, bordi delle tabelle,
//! righe orizzontali), in unità del chiamante — pixel a schermo, punti in
//! stampa. Non disegna nulla: le misure dei glifi vengono da un `Measurer`, i
//! colori da un `Theme`, e lo stesso risultato lo dipingono lo schermo
//! (`text_render.paintMdViewport`) e la stampa (`print_pdf`).
//!
//! Ogni riga ha anche il suo testo semplice e la posizione di ogni carattere:
//! servono alla selezione, alla copia e alla ricerca nel PDF.

const std = @import("std");
const glyph = @import("glyph.zig");
const md = @import("md_parse.zig");
const text_render = @import("text_render.zig");
const Rgb = glyph.Rgb;

pub const Family = enum(u1) { prose, mono };

/// Un carattere tipografico: famiglia, faccia e corpo (per la famiglia `prose`
/// l'em, per `mono` l'altezza ascent−descent, come `glyph.Raster`).
pub const FontSpec = struct { family: Family, style: glyph.Style, size: f32 };

pub const VMetrics = struct { ascent: f32, descent: f32 };

/// Misure dei glifi. `font` registra (o ritrova) un carattere e ne restituisce
/// l'indice; gli indici partono da 0 e sono quelli di `Doc.fonts`.
pub const Measurer = struct {
    ctx: *anyopaque,
    fontFn: *const fn (ctx: *anyopaque, spec: FontSpec) anyerror!u16,
    advanceFn: *const fn (ctx: *anyopaque, font: u16, cp: u21) anyerror!f32,
    vmetricsFn: *const fn (ctx: *anyopaque, font: u16) VMetrics,
    hasFn: *const fn (ctx: *anyopaque, font: u16, cp: u21) bool,

    fn font(m: Measurer, spec: FontSpec) !u16 {
        return m.fontFn(m.ctx, spec);
    }
    fn advance(m: Measurer, f: u16, cp: u21) !f32 {
        return m.advanceFn(m.ctx, f, cp);
    }
    fn vmetrics(m: Measurer, f: u16) VMetrics {
        return m.vmetricsFn(m.ctx, f);
    }
    fn has(m: Measurer, f: u16, cp: u21) bool {
        return m.hasFn(m.ctx, f, cp);
    }
};

pub const Theme = struct {
    text: Rgb,
    heading: Rgb,
    muted: Rgb,
    link: Rgb,
    inline_code: Rgb,
    inline_code_bg: Rgb,
    code: Rgb,
    code_bg: Rgb,
    keyword: Rgb,
    string: Rgb,
    comment: Rgb,
    quote_bar: Rgb,
    quote_text: Rgb,
    rule: Rgb,
    table_border: Rgb,
    table_head_bg: Rgb,
    table_zebra: Rgb,
    marker: Rgb,
    check: Rgb,
};

pub const Run = struct {
    x: f32,
    text: []const u8,
    font: u16,
    color: Rgb,
    /// Fa parte del testo della riga (selezione, copia) ma non si disegna: le
    /// caselle delle liste di attività, disegnate coi rettangoli.
    hidden: bool = false,
};

pub const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: Rgb,
    radius: f32 = 0,
    /// Sopra il testo (barrato) invece che sotto.
    over: bool = false,
};

pub const Line = struct {
    y: f32,
    h: f32,
    baseline: f32,
    runs: []const Run,
    /// Testo semplice della riga (celle di tabella separate da TAB).
    text: []const u8,
    /// Ascissa di ogni confine fra caratteri: `xs.len` = codepoint di `text` + 1.
    xs: []const f32,
    /// Un titolo: in stampa non resta da solo in fondo alla pagina.
    keep_with_next: bool = false,
};

pub const Doc = struct {
    lines: []const Line,
    boxes: []const Box,
    fonts: []const FontSpec,
    width: f32,
    height: f32,
};

pub const Options = struct {
    /// Larghezza disponibile (bordi compresi).
    width: f32,
    /// Corpo del testo corrente (em della famiglia `prose`).
    body: f32,
    /// Margine attorno al testo.
    pad_x: f32,
    pad_y: f32,
    /// Oltre questa larghezza il testo si centra (righe leggibili); 0 = mai.
    max_text_width: f32 = 0,
};

/// Impagina `src`. Tutta la memoria (righe, testi, rettangoli) è dell'arena.
pub fn layout(arena: std.mem.Allocator, src: []const u8, opts: Options, theme: Theme, m: Measurer) !Doc {
    const blocks = try md.parse(arena, src);
    var l: Layouter = .{ .arena = arena, .m = m, .t = theme, .b = opts.body, .fonts = .empty };
    var text_w = opts.width - 2 * opts.pad_x;
    if (text_w < 8 * opts.body) text_w = 8 * opts.body;
    var x0 = opts.pad_x;
    if (opts.max_text_width > 0 and text_w > opts.max_text_width) {
        x0 += (text_w - opts.max_text_width) / 2;
        text_w = opts.max_text_width;
    }
    l.y = opts.pad_y;
    l.max_x = opts.width;
    try l.blocks(blocks, x0, text_w, .{});
    return .{
        .lines = l.lines.items,
        .boxes = l.boxes.items,
        .fonts = l.fonts.items,
        .width = @max(opts.width, l.max_x + opts.pad_x),
        .height = l.y + opts.pad_y,
    };
}

// --- Impaginazione -------------------------------------------------------------

const heading_scale = [6]f32{ 1.9, 1.5, 1.25, 1.1, 1.0, 0.9 };

/// Stile di base di un flusso di testo (il paragrafo, il titolo, la cella).
const Base = struct {
    size_scale: f32 = 1,
    bold: bool = false,
    color: ?Rgb = null,
};

/// Contesto dei blocchi: dentro una citazione il testo è attenuato; in una
/// lista l'elemento è stretto (niente righe vuote fra i paragrafi).
const Ctx = struct {
    quote: bool = false,
    tight: bool = false,
};

/// Marcatore di un elemento di lista, attaccato alla prima riga del suo contenuto.
const Marker = struct {
    text: []const u8,
    /// Bordo destro del marcatore (i numeri sono allineati a destra).
    right: f32,
    checkbox: ?bool = null,
};

/// Un pezzo indivisibile di una riga: una parola, uno spazio, un codice.
const Atom = struct {
    text: []const u8,
    font: u16,
    color: Rgb,
    w: f32,
    space: bool = false,
    code: bool = false,
    strike: bool = false,
    hard_break: bool = false,
};

const Layouter = struct {
    arena: std.mem.Allocator,
    m: Measurer,
    t: Theme,
    b: f32,
    fonts: std.ArrayList(FontSpec),
    lines: std.ArrayList(Line) = .empty,
    boxes: std.ArrayList(Box) = .empty,
    y: f32 = 0,
    max_x: f32 = 0,
    marker: ?Marker = null,
    /// Il prossimo blocco è il primo di un contenitore: niente spazio sopra.
    at_start: bool = true,
    /// Liste annidate attorno al blocco corrente (sceglie il pallino).
    depth: usize = 0,

    fn font(l: *Layouter, family: Family, style: glyph.Style, size: f32) !u16 {
        const id = try l.m.font(.{ .family = family, .style = style, .size = size });
        while (l.fonts.items.len <= id) try l.fonts.append(l.arena, .{ .family = family, .style = style, .size = size });
        l.fonts.items[id] = .{ .family = family, .style = style, .size = size };
        return id;
    }

    fn textWidth(l: *Layouter, f: u16, s: []const u8) !f32 {
        var w: f32 = 0;
        var it = utf8(s);
        while (it.nextCodepoint()) |cp| w += try l.m.advance(f, cp);
        return w;
    }

    /// Spazio verticale fra blocchi: una riga vuota (per la copia) di `h`.
    fn gap(l: *Layouter, h: f32, x: f32) !void {
        if (l.at_start) return;
        // Uno spazio piccolo (fra elementi di una lista stretta) non è una riga
        // vuota del testo: si lascia solo il vuoto.
        if (h < l.b * 0.5) {
            l.y += h;
            return;
        }
        try l.lines.append(l.arena, .{ .y = l.y, .h = h, .baseline = l.y + h, .runs = &.{}, .text = "", .xs = try l.arena.dupe(f32, &.{x}) });
        l.y += h;
    }

    fn blocks(l: *Layouter, bs: []const md.Block, x0: f32, w_in: f32, ctx: Ctx) anyerror!void {
        // Rientri annidati (citazioni, liste) non riducono il testo sotto 4 em:
        // oltre, il contenuto sporge a destra invece di avere larghezza negativa.
        const w = @max(w_in, l.b * 4);
        for (bs) |blk| {
            try l.block(blk, x0, w, ctx);
            l.at_start = false;
        }
    }

    fn block(l: *Layouter, blk: md.Block, x0: f32, w: f32, ctx: Ctx) !void {
        const para_gap = if (ctx.tight) l.b * 0.25 else l.b * 0.8;
        switch (blk) {
            .paragraph => |spans| {
                try l.gap(para_gap, x0);
                try l.flow(spans, x0, w, .{ .color = if (ctx.quote) l.t.quote_text else null }, .left);
            },
            .heading => |h| {
                const s = heading_scale[@min(h.level, 6) - 1];
                try l.gap(if (h.level <= 2) l.b * 1.4 else l.b * 1.1, x0);
                const first = l.lines.items.len;
                try l.flow(h.spans, x0, w, .{ .size_scale = s, .bold = true, .color = if (h.level == 6) l.t.muted else l.t.heading }, .left);
                for (l.lines.items[first..]) |*ln| ln.keep_with_next = true;
                if (h.level <= 2) {
                    l.y += l.b * 0.3;
                    try l.boxes.append(l.arena, .{ .x = x0, .y = l.y, .w = w, .h = @max(1, l.b * 0.06), .color = l.t.rule });
                    l.y += @max(1, l.b * 0.06);
                }
            },
            .code => |c| {
                try l.gap(para_gap, x0);
                try l.codeBlock(c.text, c.lang, x0, w);
            },
            .rule => {
                try l.gap(para_gap, x0);
                const th = @max(1, l.b * 0.12);
                l.y += l.b * 0.5;
                try l.boxes.append(l.arena, .{ .x = x0, .y = l.y, .w = w, .h = th, .color = l.t.rule });
                l.y += th + l.b * 0.5;
            },
            .quote => |inner| {
                try l.gap(para_gap, x0);
                const top = l.y;
                const bar = @max(2, l.b * 0.25);
                const saved = l.at_start;
                l.at_start = true;
                try l.blocks(inner, x0 + l.b * 1.1, w - l.b * 1.1, .{ .quote = true, .tight = ctx.tight });
                l.at_start = saved;
                try l.boxes.append(l.arena, .{ .x = x0, .y = top, .w = bar, .h = l.y - top, .color = l.t.quote_bar });
            },
            .list => |list| try l.listBlock(list, x0, w, ctx, para_gap),
            .table => |t| {
                try l.gap(para_gap, x0);
                try l.table(t, x0, w);
            },
        }
    }

    fn listBlock(l: *Layouter, list: anytype, x0: f32, w: f32, ctx: Ctx, para_gap: f32) !void {
        try l.gap(para_gap, x0);
        // Rientro: il marcatore più largo (numeri lunghi) più uno spazio.
        const f = try l.font(.prose, .regular, l.b);
        var indent = l.b * 1.6;
        if (list.ordered) {
            var buf: [16]u8 = undefined;
            const last = std.fmt.bufPrint(&buf, "{d}.", .{list.start + @as(u32, @intCast(list.items.len)) - 1}) catch "0.";
            indent = @max(indent, try l.textWidth(f, last) + l.b * 0.6);
        }
        const depth = l.depth;
        l.depth += 1;
        defer l.depth -= 1;
        const bullets = [_][]const u8{ "•", "◦", "▪" };
        var bullet = bullets[@min(depth, bullets.len - 1)];
        if (!l.m.has(f, std.unicode.utf8Decode(bullet) catch '*')) bullet = "•";
        for (list.items, 0..) |item, i| {
            var mtext: []const u8 = bullet;
            if (list.ordered) mtext = try std.fmt.allocPrint(l.arena, "{d}.", .{list.start + @as(u32, @intCast(i))});
            if (i > 0) l.y += l.b * 0.25;
            l.marker = .{ .text = mtext, .right = x0 + indent - l.b * 0.45, .checkbox = item.checked };
            // Con la casella il contenuto parte dopo di essa.
            // (nelle liste puntate la casella prende il posto del pallino).
            const box: f32 = if (item.checked != null and list.ordered) l.m.vmetrics(f).ascent * 0.85 + l.b * 0.45 else 0;
            const saved = l.at_start;
            l.at_start = true;
            if (item.blocks.len == 0) {
                try l.flow(&.{}, x0 + indent + box, w - indent - box, .{}, .left);
            } else {
                try l.blocks(item.blocks, x0 + indent + box, w - indent - box, .{ .quote = ctx.quote, .tight = true });
            }
            l.at_start = saved;
            l.marker = null;
        }
    }

    // --- Testo che va a capo ------------------------------------------------

    const Align = enum { left, center, right };

    fn atomsOf(l: *Layouter, spans: []const md.Span, base: Base, out: *std.ArrayList(Atom)) !void {
        const size = l.b * base.size_scale;
        for (spans) |s| {
            if (s.hard_break) {
                try out.append(l.arena, .{ .text = "", .font = 0, .color = l.t.text, .w = 0, .hard_break = true });
                continue;
            }
            const bold = base.bold or s.flags.bold;
            const italic = s.flags.italic or s.image;
            const style: glyph.Style = if (bold and italic) .bold_italic else if (bold) .bold else if (italic) .italic else .regular;
            const f = if (s.flags.code)
                try l.font(.mono, if (bold) .bold else .regular, size)
            else
                try l.font(.prose, style, size);
            const color = if (s.url.len > 0 and !s.image)
                l.t.link
            else if (s.flags.code)
                l.t.inline_code
            else if (s.image)
                l.t.muted
            else
                base.color orelse l.t.text;
            const text = if (s.image) try std.fmt.allocPrint(l.arena, "[{s}]", .{if (s.text.len > 0) s.text else std.fs.path.basename(s.url)}) else s.text;
            if (s.flags.code) {
                // Un codice in linea resta intero se ci sta (sfondo continuo).
                try out.append(l.arena, .{ .text = text, .font = f, .color = color, .w = try l.textWidth(f, text), .code = true, .strike = s.flags.strike });
                continue;
            }
            // Parole e spazi.
            var i: usize = 0;
            while (i < text.len) {
                const sp = text[i] == ' ';
                var j = i;
                while (j < text.len and (text[j] == ' ') == sp) j += 1;
                const piece = text[i..j];
                try out.append(l.arena, .{ .text = piece, .font = f, .color = color, .w = try l.textWidth(f, piece), .space = sp, .strike = s.flags.strike });
                i = j;
            }
        }
    }

    /// Dispone `spans` in righe larghe al più `w` a partire da `x0`, dalla
    /// quota corrente; l'eventuale marcatore di lista va sulla prima riga.
    fn flow(l: *Layouter, spans: []const md.Span, x0: f32, w: f32, base: Base, alignment: Align) !void {
        var atoms: std.ArrayList(Atom) = .empty;
        try l.atomsOf(spans, base, &atoms);
        const body_font = try l.font(.prose, if (base.bold) .bold else .regular, l.b * base.size_scale);

        var line: std.ArrayList(Atom) = .empty;
        var width: f32 = 0;
        var i: usize = 0;
        var emitted = false;
        while (i < atoms.items.len) {
            const a = atoms.items[i];
            if (a.hard_break) {
                try l.emit(line.items, x0, w, body_font, alignment);
                emitted = true;
                line.clearRetainingCapacity();
                width = 0;
                i += 1;
                continue;
            }
            if (a.space and line.items.len == 0) {
                i += 1; // niente spazi a inizio riga
                continue;
            }
            if (width + a.w <= w or a.space) {
                try line.append(l.arena, a);
                width += a.w;
                i += 1;
                continue;
            }
            if (line.items.len > 0) {
                try l.emit(line.items, x0, w, body_font, alignment);
                emitted = true;
                line.clearRetainingCapacity();
                width = 0;
                continue;
            }
            // Parola più larga della riga: si spezza fra i caratteri.
            var k: usize = 0;
            var acc: f32 = 0;
            var it = utf8(a.text);
            while (it.nextCodepoint()) |cp| {
                const cw = try l.m.advance(a.font, cp);
                if (acc + cw > w and k > 0) break;
                acc += cw;
                k = it.i;
            }
            if (k == 0) k = a.text.len;
            var head = a;
            head.text = a.text[0..k];
            head.w = acc;
            try l.emit(&.{head}, x0, w, body_font, alignment);
            emitted = true;
            atoms.items[i].text = a.text[k..];
            atoms.items[i].w = try l.textWidth(a.font, a.text[k..]);
            if (atoms.items[i].text.len == 0) i += 1;
        }
        if (line.items.len > 0 or !emitted) try l.emit(line.items, x0, w, body_font, alignment);
    }

    /// Una riga visiva dagli atomi `atoms` (spazi finali esclusi).
    fn emit(l: *Layouter, atoms_in: []const Atom, x0: f32, w: f32, body_font: u16, alignment: Align) !void {
        var atoms = atoms_in;
        while (atoms.len > 0 and atoms[atoms.len - 1].space) atoms = atoms[0 .. atoms.len - 1];
        var asc: f32 = l.m.vmetrics(body_font).ascent;
        var desc: f32 = l.m.vmetrics(body_font).descent;
        var width: f32 = 0;
        for (atoms) |a| {
            const vm = l.m.vmetrics(a.font);
            asc = @max(asc, vm.ascent);
            desc = @min(desc, vm.descent);
            width += a.w;
        }
        const h = (asc - desc) * 1.32;
        const baseline = l.y + (h - (asc - desc)) / 2 + asc;
        var x = switch (alignment) {
            .left => x0,
            .center => x0 + @max(0, (w - width) / 2),
            .right => x0 + @max(0, w - width),
        };

        var runs: std.ArrayList(Run) = .empty;
        var text: std.ArrayList(u8) = .empty;
        var xs: std.ArrayList(f32) = .empty;
        try l.attachMarker(&runs, &text, &xs, baseline, body_font);
        for (atoms) |a| {
            if (a.code) {
                const vm = l.m.vmetrics(a.font);
                const pad = l.b * 0.18;
                try l.boxes.append(l.arena, .{ .x = x - pad * 0.5, .y = baseline - vm.ascent - pad * 0.4, .w = a.w + pad, .h = vm.ascent - vm.descent + pad * 0.8, .color = l.t.inline_code_bg, .radius = l.b * 0.2 });
            }
            if (a.strike) {
                const vm = l.m.vmetrics(a.font);
                try l.boxes.append(l.arena, .{ .x = x, .y = baseline - vm.ascent * 0.3, .w = a.w, .h = @max(1, l.b * 0.06), .color = a.color, .over = true });
            }
            try l.addRun(&runs, &text, &xs, a.text, x, a.font, a.color, false);
            x += a.w;
        }
        if (xs.items.len == 0) try xs.append(l.arena, x);
        l.max_x = @max(l.max_x, x);
        try l.lines.append(l.arena, .{ .y = l.y, .h = h, .baseline = baseline, .runs = runs.items, .text = text.items, .xs = xs.items });
        l.y += h;
    }

    /// Accoda un tratto alla riga: unito al precedente se ha lo stesso carattere
    /// e colore ed è contiguo; aggiorna testo e posizioni dei caratteri.
    fn addRun(l: *Layouter, runs: *std.ArrayList(Run), text: *std.ArrayList(u8), xs: *std.ArrayList(f32), s: []const u8, x: f32, f: u16, color: Rgb, hidden: bool) !void {
        if (s.len == 0) return;
        // Un salto (cella, marcatore) ha come confine sinistro l'inizio del tratto.
        if (xs.items.len == 0) try xs.append(l.arena, x) else xs.items[xs.items.len - 1] = @min(xs.items[xs.items.len - 1], x);
        var cx = x;
        var it = utf8(s);
        while (it.nextCodepoint()) |cp| {
            cx += try l.m.advance(f, cp);
            try xs.append(l.arena, cx);
        }
        try text.appendSlice(l.arena, s);
        if (runs.items.len > 0) {
            const last = &runs.items[runs.items.len - 1];
            if (last.font == f and std.meta.eql(last.color, color) and last.hidden == hidden and @abs(last.x + try l.textWidth(f, last.text) - x) < 0.01) {
                last.text = try std.mem.concat(l.arena, u8, &.{ last.text, s });
                return;
            }
        }
        try runs.append(l.arena, .{ .x = x, .text = try l.arena.dupe(u8, s), .font = f, .color = color, .hidden = hidden });
    }

    fn attachMarker(l: *Layouter, runs: *std.ArrayList(Run), text: *std.ArrayList(u8), xs: *std.ArrayList(f32), baseline: f32, body_font: u16) !void {
        const mk = l.marker orelse return;
        l.marker = null;
        const f = try l.font(.prose, .regular, l.b);
        const mw = try l.textWidth(f, mk.text);
        // Elemento con casella: la casella prende il posto del pallino.
        const bullet_item = !std.ascii.isDigit(mk.text[0]);
        if (mk.checkbox != null and bullet_item) {
            try l.checkbox(runs, text, xs, mk, baseline, body_font, f, true);
            return;
        }
        const mx = if (std.mem.eql(u8, mk.text, "•") or std.mem.eql(u8, mk.text, "◦") or std.mem.eql(u8, mk.text, "▪")) mk.right - mw - l.b * 0.1 else mk.right - mw;
        try l.addRun(runs, text, xs, mk.text, mx, f, l.t.marker, false);
        try l.addRun(runs, text, xs, " ", mk.right, f, l.t.marker, true);
        if (mk.checkbox != null) try l.checkbox(runs, text, xs, mk, baseline, body_font, f, false);
    }

    /// Casella di un elemento di lista di attività: quadrato vuoto o pieno
    /// all'inizio del contenuto dell'elemento.
    /// `in_gutter`: al posto del pallino (liste puntate), altrimenti dopo il numero.
    fn checkbox(l: *Layouter, runs: *std.ArrayList(Run), text: *std.ArrayList(u8), xs: *std.ArrayList(f32), mk: Marker, baseline: f32, body_font: u16, f: u16, in_gutter: bool) !void {
        const checked = mk.checkbox.?;
        {
            const vm = l.m.vmetrics(body_font);
            const side = (vm.ascent) * 0.85;
            const bx = if (in_gutter) mk.right - side + l.b * 0.1 else mk.right + l.b * 0.45;
            const by = baseline - side;
            const th = @max(1, l.b * 0.08);
            const c = l.t.marker;
            try l.boxes.append(l.arena, .{ .x = bx, .y = by, .w = side, .h = th, .color = c });
            try l.boxes.append(l.arena, .{ .x = bx, .y = by + side - th, .w = side, .h = th, .color = c });
            try l.boxes.append(l.arena, .{ .x = bx, .y = by, .w = th, .h = side, .color = c });
            try l.boxes.append(l.arena, .{ .x = bx + side - th, .y = by, .w = th, .h = side, .color = c });
            if (checked) try l.boxes.append(l.arena, .{ .x = bx + th * 2, .y = by + th * 2, .w = side - th * 4, .h = side - th * 4, .color = l.t.check });
            try l.addRun(runs, text, xs, if (checked) "[x]" else "[ ]", bx, f, c, true);
            try l.addRun(runs, text, xs, " ", if (in_gutter) mk.right + l.b * 0.45 else bx + side, f, c, true);
        }
    }

    // --- Codice -------------------------------------------------------------

    fn codeBlock(l: *Layouter, src: []const u8, lang: []const u8, x0: f32, w: f32) !void {
        l.marker = null; // un elemento di lista che inizia col codice resta senza pallino
        const pad = l.b * 0.75;
        const f = try l.font(.mono, .regular, l.b);
        const fb = try l.font(.mono, .bold, l.b);
        const vm = l.m.vmetrics(f);
        const lh = (vm.ascent - vm.descent) * 1.25;
        const cell = try l.m.advance(f, 'M');
        const inner_w = @max(w - 2 * pad, cell);
        const cols: usize = if (cell > 0) @max(8, @as(usize, @intFromFloat(inner_w / cell))) else 80;
        const top = l.y;
        l.y += pad;
        const box_index = l.boxes.items.len;
        const first_index = l.lines.items.len;
        try l.boxes.append(l.arena, .{ .x = x0, .y = top, .w = w, .h = 0, .color = l.t.code_bg, .radius = l.b * 0.35 });

        var lines_it = std.mem.splitScalar(u8, src, '\n');
        while (lines_it.next()) |src_line| {
            const spans = try text_render.codeSpans(l.arena, src_line, lang);
            // A capo per colonne: tutti i glifi Hack hanno la stessa larghezza.
            var runs: std.ArrayList(Run) = .empty;
            var text: std.ArrayList(u8) = .empty;
            var xs: std.ArrayList(f32) = .empty;
            var col: usize = 0;
            const baseline_of = struct {
                fn calc(y: f32, h: f32, v: VMetrics) f32 {
                    return y + (h - (v.ascent - v.descent)) / 2 + v.ascent;
                }
            }.calc;
            for (spans) |sp| {
                const color = switch (sp.role) {
                    .plain => l.t.code,
                    .keyword => l.t.keyword,
                    .string => l.t.string,
                    .comment => l.t.comment,
                };
                const font_id = if (sp.role == .keyword) fb else f;
                var rest = sp.text;
                while (rest.len > 0) {
                    if (col >= cols) {
                        try l.lines.append(l.arena, .{ .y = l.y, .h = lh, .baseline = baseline_of(l.y, lh, vm), .runs = runs.items, .text = text.items, .xs = if (xs.items.len > 0) xs.items else try l.arena.dupe(f32, &.{x0 + pad}) });
                        l.y += lh;
                        runs = .empty;
                        text = .empty;
                        xs = .empty;
                        col = 0;
                    }
                    var n: usize = 0;
                    var k: usize = 0;
                    var it = utf8(rest);
                    while (col + n < cols) {
                        _ = it.nextCodepoint() orelse break;
                        n += 1;
                        k = it.i;
                    }
                    try l.addRun(&runs, &text, &xs, rest[0..k], x0 + pad + @as(f32, @floatFromInt(col)) * cell, font_id, color, false);
                    col += n;
                    rest = rest[k..];
                }
            }
            try l.lines.append(l.arena, .{ .y = l.y, .h = lh, .baseline = baseline_of(l.y, lh, vm), .runs = runs.items, .text = text.items, .xs = if (xs.items.len > 0) xs.items else try l.arena.dupe(f32, &.{x0 + pad}) });
            l.y += lh;
        }
        l.y += pad;
        l.boxes.items[box_index].h = l.y - top;
        // La prima riga comprende il margine superiore del riquadro, l'ultima
        // quello inferiore: in stampa il riquadro non si separa dal suo testo.
        const first_line = first_index;
        l.lines.items[first_line].h += l.lines.items[first_line].y - top;
        l.lines.items[first_line].y = top;
        l.lines.items[l.lines.items.len - 1].h += pad;
    }

    // --- Tabelle ------------------------------------------------------------

    fn table(l: *Layouter, t: anytype, x0: f32, w: f32) !void {
        l.marker = null;
        const n = t.aligns.len;
        if (n == 0) return;
        const pad_x = l.b * 0.6;
        const pad_y = l.b * 0.3;
        const border = @max(1, l.b * 0.06);
        // Larghezza naturale (senza a capo) e minima (la parola più lunga).
        const natural = try l.arena.alloc(f32, n);
        const minimal = try l.arena.alloc(f32, n);
        @memset(natural, 0);
        @memset(minimal, l.b * 2);
        var rows: std.ArrayList([]const []const md.Span) = .empty;
        try rows.append(l.arena, t.header);
        try rows.appendSlice(l.arena, t.rows);
        for (rows.items, 0..) |row, r| {
            for (row, 0..) |cell, c| {
                var atoms: std.ArrayList(Atom) = .empty;
                try l.atomsOf(cell, .{ .bold = r == 0 }, &atoms);
                var total: f32 = 0;
                for (atoms.items) |a| {
                    total += a.w;
                    if (!a.space) minimal[c] = @max(minimal[c], @min(a.w, l.b * 12));
                }
                natural[c] = @max(natural[c], total);
            }
        }
        const avail = w - border * @as(f32, @floatFromInt(n + 1)) - 2 * pad_x * @as(f32, @floatFromInt(n));
        var sum_nat: f32 = 0;
        var sum_min: f32 = 0;
        for (natural, minimal) |a, b| {
            sum_nat += a;
            sum_min += @min(a, b);
        }
        const cols = try l.arena.alloc(f32, n);
        if (sum_nat <= avail) {
            @memcpy(cols, natural);
        } else if (sum_min >= avail) {
            for (cols, natural, minimal) |*c, a, b| c.* = @min(a, b);
        } else {
            // Ogni colonna ha la sua minima, il resto in proporzione a quanto le manca.
            const extra = avail - sum_min;
            const want = sum_nat - sum_min;
            for (cols, natural, minimal) |*c, a, b| {
                const lo = @min(a, b);
                c.* = lo + (a - lo) / want * extra;
            }
        }

        const top = l.y;
        var total_w: f32 = border;
        for (cols) |c| total_w += c + 2 * pad_x + border;
        try l.boxes.append(l.arena, .{ .x = x0, .y = top, .w = total_w, .h = border, .color = l.t.table_border });
        l.y += border;
        for (rows.items, 0..) |row, r| {
            const row_top = l.y;
            const bg_index = l.boxes.items.len;
            if (r == 0 or r % 2 == 0) try l.boxes.append(l.arena, .{ .x = x0, .y = row_top, .w = total_w, .h = 0, .color = if (r == 0) l.t.table_head_bg else l.t.table_zebra });
            // Ogni cella in un impaginatore a parte, poi riga per riga insieme.
            var cell_lines: std.ArrayList([]const Line) = .empty;
            var cell_boxes: std.ArrayList([]const Box) = .empty;
            var max_h: f32 = 0;
            var cx = x0 + border;
            for (0..n) |c| {
                var sub: Layouter = .{ .arena = l.arena, .m = l.m, .t = l.t, .b = l.b, .fonts = l.fonts, .y = 0 };
                const al: Align = switch (t.aligns[c]) {
                    .center => .center,
                    .right => .right,
                    else => .left,
                };
                const cell = if (c < row.len) row[c] else &.{};
                try sub.flow(cell, cx + pad_x, cols[c], .{ .bold = r == 0, .color = if (r == 0) l.t.heading else null }, al);
                l.fonts = sub.fonts;
                l.max_x = @max(l.max_x, sub.max_x);
                try cell_lines.append(l.arena, sub.lines.items);
                try cell_boxes.append(l.arena, sub.boxes.items);
                max_h = @max(max_h, sub.y);
                cx += cols[c] + 2 * pad_x + border;
            }
            const row_h = max_h + 2 * pad_y;
            for (cell_boxes.items) |bs| for (bs) |bx| {
                var b2 = bx;
                b2.y += row_top + pad_y;
                try l.boxes.append(l.arena, b2);
            };
            // Righe visive della fila: la k-esima riga di ogni cella, unite (TAB).
            var k: usize = 0;
            while (true) : (k += 1) {
                var any = false;
                var runs: std.ArrayList(Run) = .empty;
                var text: std.ArrayList(u8) = .empty;
                var xs: std.ArrayList(f32) = .empty;
                var y_min: f32 = std.math.floatMax(f32);
                var y_max: f32 = 0;
                var baseline: f32 = 0;
                for (cell_lines.items, 0..) |cl, c| {
                    if (c > 0) {
                        if (xs.items.len == 0) try xs.append(l.arena, x0 + border);
                        try text.append(l.arena, '\t');
                        try xs.append(l.arena, xs.items[xs.items.len - 1]);
                    }
                    if (k >= cl.len) continue;
                    any = true;
                    const ln = cl[k];
                    y_min = @min(y_min, ln.y);
                    y_max = @max(y_max, ln.y + ln.h);
                    baseline = @max(baseline, ln.baseline);
                    try runs.appendSlice(l.arena, ln.runs);
                    // Testo e posizioni della cella in coda a quelli della riga.
                    if (xs.items.len == 0) {
                        try xs.appendSlice(l.arena, ln.xs);
                    } else {
                        xs.items[xs.items.len - 1] = if (ln.xs.len > 0) ln.xs[0] else xs.items[xs.items.len - 1];
                        if (ln.xs.len > 1) try xs.appendSlice(l.arena, ln.xs[1..]);
                    }
                    try text.appendSlice(l.arena, ln.text);
                }
                if (!any) break;
                // Le celle possono avere righe di altezza diversa: si usa la
                // quota della cella più bassa per la riga selezionabile.
                const off = row_top + pad_y;
                // La prima riga di una fila parte dal suo bordo (dal bordo della
                // tabella per l'intestazione): una pagina nuova li porta con sé.
                const line_top = if (k == 0) (if (r == 0) top else row_top - border) else off + y_min;
                try l.lines.append(l.arena, .{
                    .y = line_top,
                    .h = (off + y_max) - line_top,
                    .baseline = off + baseline,
                    .runs = runs.items,
                    .text = text.items,
                    .xs = xs.items,
                });
            }
            l.y = row_top + row_h;
            if (r == 0 or r % 2 == 0) l.boxes.items[bg_index].h = row_h;
            try l.boxes.append(l.arena, .{ .x = x0, .y = l.y, .w = total_w, .h = border, .color = l.t.table_border });
            l.y += border;
        }
        // Bordi verticali.
        var vx = x0;
        try l.boxes.append(l.arena, .{ .x = vx, .y = top, .w = border, .h = l.y - top, .color = l.t.table_border });
        for (cols) |c| {
            vx += border + c + 2 * pad_x;
            try l.boxes.append(l.arena, .{ .x = vx, .y = top, .w = border, .h = l.y - top, .color = l.t.table_border });
        }
        l.max_x = @max(l.max_x, x0 + total_w);
    }
};

fn utf8(s: []const u8) std.unicode.Utf8Iterator {
    return .{ .bytes = s, .i = 0 };
}
