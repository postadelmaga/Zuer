//! Parser markdown: dal sorgente a blocchi (titoli, paragrafi, liste, citazioni,
//! codice, righe, tabelle) con il testo in tratti di stile (grassetto, corsivo,
//! barrato, codice, link). Segue CommonMark e le estensioni di GitHub (tabelle,
//! barrato, liste di attività, link nudi) nei casi che si incontrano nei README e
//! nelle note; non è un'implementazione completa (niente link per riferimento,
//! né la precedenza fine fra enfasi annidate).
//!
//! Tutta la memoria viene da un'arena del chiamante: i testi sono slice del
//! sorgente o copie nell'arena (entità, escape).

const std = @import("std");

pub const Flags = packed struct(u4) {
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    code: bool = false,
};

pub const Span = struct {
    text: []const u8,
    flags: Flags = .{},
    /// Destinazione del link ("" se il tratto non è un link).
    url: []const u8 = "",
    /// Testo alternativo di un'immagine (il tratto la rappresenta).
    image: bool = false,
    /// A capo forzato (due spazi o `\` a fine riga, `<br>`): `text` è vuoto.
    hard_break: bool = false,
};

pub const Align = enum { none, left, center, right };

pub const Item = struct {
    blocks: []const Block,
    /// Lista di attività: null se l'elemento non ha la casella.
    checked: ?bool = null,
};

pub const Block = union(enum) {
    heading: struct { level: u3, spans: []const Span },
    paragraph: []const Span,
    code: struct { lang: []const u8, text: []const u8 },
    rule,
    quote: []const Block,
    list: struct { ordered: bool, start: u32, items: []const Item },
    table: struct { aligns: []const Align, header: []const []const Span, rows: []const []const []const Span },
};

pub fn parse(arena: std.mem.Allocator, src: []const u8) ![]const Block {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(arena, try expandTabs(arena, std.mem.trimEnd(u8, l, "\r")));
    return parseBlocks(arena, lines.items, 0);
}

// --- Blocchi ---------------------------------------------------------------

fn isBlank(l: []const u8) bool {
    return std.mem.trim(u8, l, " \t").len == 0;
}

fn indentOf(l: []const u8) usize {
    var n: usize = 0;
    while (n < l.len and l[n] == ' ') n += 1;
    return n;
}

/// Toglie fino a `n` spazi iniziali.
fn dedent(l: []const u8, n: usize) []const u8 {
    return l[@min(indentOf(l), n)..];
}

fn expandTabs(arena: std.mem.Allocator, l: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, l, '\t') == null) return l;
    var out: std.ArrayList(u8) = .empty;
    for (l) |ch| {
        if (ch == '\t') {
            const n = 4 - out.items.len % 4;
            try out.appendNTimes(arena, ' ', n);
        } else try out.append(arena, ch);
    }
    return out.items;
}

const Fence = struct { ch: u8, len: usize, indent: usize, info: []const u8 };

fn fenceOpen(l: []const u8) ?Fence {
    const ind = indentOf(l);
    if (ind > 3) return null;
    const t = l[ind..];
    if (t.len < 3 or (t[0] != '`' and t[0] != '~')) return null;
    var n: usize = 0;
    while (n < t.len and t[n] == t[0]) n += 1;
    if (n < 3) return null;
    const info = std.mem.trim(u8, t[n..], " ");
    if (t[0] == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    const lang_end = std.mem.indexOfAny(u8, info, " {") orelse info.len;
    return .{ .ch = t[0], .len = n, .indent = ind, .info = info[0..lang_end] };
}

fn fenceCloses(l: []const u8, f: Fence) bool {
    const ind = indentOf(l);
    if (ind > 3) return false;
    const t = std.mem.trimEnd(u8, l[ind..], " ");
    if (t.len < f.len) return false;
    for (t) |ch| if (ch != f.ch) return false;
    return true;
}

fn headingLevel(l: []const u8) ?struct { level: u3, text: []const u8 } {
    const ind = indentOf(l);
    if (ind > 3) return null;
    const t = l[ind..];
    var n: usize = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < t.len and t[n] != ' ') return null;
    var text = std.mem.trim(u8, t[n..], " ");
    // Chiusura facoltativa: `## Titolo ##`.
    const closed = std.mem.trimEnd(u8, text, "#");
    if (closed.len == 0 or closed[closed.len - 1] == ' ') text = std.mem.trimEnd(u8, closed, " ");
    return .{ .level = @intCast(n), .text = text };
}

fn isRule(l: []const u8) bool {
    if (indentOf(l) > 3) return false;
    var ch: u8 = 0;
    var n: usize = 0;
    for (l) |c| {
        if (c == ' ') continue;
        if (c != '-' and c != '*' and c != '_') return false;
        if (ch == 0) ch = c else if (c != ch) return false;
        n += 1;
    }
    return n >= 3;
}

fn setextLevel(l: []const u8) ?u3 {
    if (indentOf(l) > 3) return null;
    const t = std.mem.trim(u8, l, " ");
    if (t.len == 0) return null;
    for (t) |c| if (c != t[0]) return null;
    return switch (t[0]) {
        '=' => 1,
        '-' => 2,
        else => null,
    };
}

fn isQuote(l: []const u8) bool {
    const ind = indentOf(l);
    return ind <= 3 and ind < l.len and l[ind] == '>';
}

fn stripQuote(l: []const u8) []const u8 {
    const ind = indentOf(l);
    var t = l[ind + 1 ..];
    if (t.len > 0 and t[0] == ' ') t = t[1..];
    return t;
}

const Marker = struct {
    ordered: bool,
    number: u32 = 1,
    /// Carattere del marcatore (`-*+` o `.)` per le numerate): liste con
    /// marcatori diversi sono liste diverse.
    ch: u8,
    indent: usize,
    /// Colonna dove inizia il contenuto dell'elemento.
    content: usize,
};

fn listMarker(l: []const u8) ?Marker {
    const ind = indentOf(l);
    const t = l[ind..];
    if (t.len == 0) return null;
    if (t[0] == '-' or t[0] == '*' or t[0] == '+') {
        if (t.len == 1) return .{ .ordered = false, .ch = t[0], .indent = ind, .content = ind + 2 };
        if (t[1] != ' ') return null;
        if (isRule(l)) return null;
        const sp = @min(indentOf(t[1..]), 4);
        return .{ .ordered = false, .ch = t[0], .indent = ind, .content = ind + 1 + (if (sp == 4 or 1 + sp >= t.len) 1 else sp) };
    }
    var n: usize = 0;
    while (n < t.len and n < 9 and std.ascii.isDigit(t[n])) n += 1;
    if (n == 0 or n >= t.len or (t[n] != '.' and t[n] != ')')) return null;
    if (n + 1 < t.len and t[n + 1] != ' ') return null;
    const num = std.fmt.parseInt(u32, t[0..n], 10) catch return null;
    const sp = if (n + 1 < t.len) @min(indentOf(t[n + 1 ..]), 4) else 1;
    return .{ .ordered = true, .number = num, .ch = t[n], .indent = ind, .content = ind + n + 1 + (if (sp == 4 or n + 1 + sp >= t.len) 1 else sp) };
}

/// Una riga di tabella spezzata in celle (bordi `|` facoltativi, `\|` escluso).
fn tableCells(arena: std.mem.Allocator, l: []const u8) ![]const []const u8 {
    var t = std.mem.trim(u8, l, " ");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|' and !(t.len > 1 and t[t.len - 2] == '\\')) t = t[0 .. t.len - 1];
    var cells: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    var in_code = false;
    while (i < t.len) : (i += 1) {
        if (t[i] == '\\') {
            i += 1;
            continue;
        }
        if (t[i] == '`') in_code = !in_code;
        if (t[i] == '|' and !in_code) {
            try cells.append(arena, std.mem.trim(u8, t[start..i], " "));
            start = i + 1;
        }
    }
    try cells.append(arena, std.mem.trim(u8, t[start..], " "));
    return cells.items;
}

fn delimiterRow(arena: std.mem.Allocator, l: []const u8) !?[]const Align {
    if (std.mem.indexOfScalar(u8, l, '-') == null) return null;
    const cells = try tableCells(arena, l);
    const aligns = try arena.alloc(Align, cells.len);
    for (cells, aligns) |c, *a| {
        if (c.len == 0) return null;
        const left = c[0] == ':';
        const right = c[c.len - 1] == ':';
        const inner = c[@intFromBool(left) .. c.len - @intFromBool(right and c.len > 1)];
        if (inner.len == 0) return null;
        for (inner) |ch| if (ch != '-') return null;
        a.* = if (left and right) .center else if (right) .right else if (left) .left else .none;
    }
    return aligns;
}

fn isHtmlBlock(l: []const u8) bool {
    const t = l[indentOf(l)..];
    if (t.len < 2 or t[0] != '<') return false;
    return std.ascii.isAlphabetic(t[1]) or t[1] == '/' or t[1] == '!';
}

/// Una riga che interrompe un paragrafo (inizia un altro blocco).
fn interruptsParagraph(l: []const u8) bool {
    if (headingLevel(l) != null or fenceOpen(l) != null or isRule(l) or isQuote(l)) return true;
    if (listMarker(l)) |m| {
        // Una numerata interrompe un paragrafo solo se parte da 1 (CommonMark).
        return m.indent <= 3 and m.content < l.len and (!m.ordered or m.number == 1);
    }
    return isHtmlBlock(l);
}

/// Citazioni e liste annidate oltre questa profondità restano testo: niente
/// ricorsione senza fondo (stack) su file costruiti apposta.
const max_block_depth = 24;

fn parseBlocks(arena: std.mem.Allocator, lines: []const []const u8, depth: usize) anyerror![]const Block {
    const nest_ok = depth < max_block_depth;
    var blocks: std.ArrayList(Block) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        const l = lines[i];
        if (isBlank(l)) {
            i += 1;
            continue;
        }
        if (fenceOpen(l)) |f| {
            var body: std.ArrayList(u8) = .empty;
            i += 1;
            var first = true;
            while (i < lines.len and !fenceCloses(lines[i], f)) : (i += 1) {
                if (!first) try body.append(arena, '\n');
                first = false;
                try body.appendSlice(arena, dedent(lines[i], f.indent));
            }
            i += 1; // la chiusura (o la fine del documento)
            try blocks.append(arena, .{ .code = .{ .lang = f.info, .text = body.items } });
            continue;
        }
        if (indentOf(l) >= 4) {
            // Codice indentato: fino alla prima riga non vuota meno indentata.
            var end = i;
            var last = i;
            while (end < lines.len and (isBlank(lines[end]) or indentOf(lines[end]) >= 4)) : (end += 1) {
                if (!isBlank(lines[end])) last = end;
            }
            var body: std.ArrayList(u8) = .empty;
            for (lines[i .. last + 1], 0..) |cl, k| {
                if (k > 0) try body.append(arena, '\n');
                try body.appendSlice(arena, dedent(cl, 4));
            }
            try blocks.append(arena, .{ .code = .{ .lang = "", .text = body.items } });
            i = last + 1;
            continue;
        }
        if (headingLevel(l)) |h| {
            try blocks.append(arena, .{ .heading = .{ .level = h.level, .spans = try parseInline(arena, h.text) } });
            i += 1;
            continue;
        }
        if (isRule(l)) {
            try blocks.append(arena, .rule);
            i += 1;
            continue;
        }
        if (nest_ok and isQuote(l)) {
            var inner: std.ArrayList([]const u8) = .empty;
            while (i < lines.len and !isBlank(lines[i])) : (i += 1) {
                const ql = lines[i];
                if (isQuote(ql)) {
                    try inner.append(arena, stripQuote(ql));
                } else if (inner.items.len > 0 and !isBlank(inner.items[inner.items.len - 1]) and !interruptsParagraph(ql)) {
                    try inner.append(arena, ql); // continuazione pigra del paragrafo
                } else break;
            }
            try blocks.append(arena, .{ .quote = try parseBlocks(arena, inner.items, depth + 1) });
            continue;
        }
        if (listMarker(l)) |m0| {
            if (nest_ok and m0.indent <= 3) {
                i = try parseList(arena, lines, i, m0, &blocks, depth);
                continue;
            }
        }
        if (std.mem.indexOfScalar(u8, l, '|') != null and i + 1 < lines.len) {
            if (try delimiterRow(arena, lines[i + 1])) |aligns| {
                const head_cells = try tableCells(arena, l);
                if (head_cells.len == aligns.len) {
                    const header = try arena.alloc([]const Span, aligns.len);
                    for (header, head_cells) |*h, c| h.* = try parseInline(arena, c);
                    var rows: std.ArrayList([]const []const Span) = .empty;
                    i += 2;
                    while (i < lines.len and !isBlank(lines[i]) and !interruptsParagraph(lines[i])) : (i += 1) {
                        const cells = try tableCells(arena, lines[i]);
                        const row = try arena.alloc([]const Span, aligns.len);
                        for (row, 0..) |*r, k| r.* = if (k < cells.len) try parseInline(arena, cells[k]) else &.{};
                        try rows.append(arena, row);
                    }
                    try blocks.append(arena, .{ .table = .{ .aligns = aligns, .header = header, .rows = rows.items } });
                    continue;
                }
            }
        }
        if (isHtmlBlock(l)) {
            // HTML: se ne tiene il testo (e il testo alternativo delle immagini),
            // fino alla riga vuota; i commenti `<!-- -->` spariscono.
            var html: std.ArrayList(u8) = .empty;
            while (i < lines.len and !isBlank(lines[i])) : (i += 1) {
                if (html.items.len > 0) try html.append(arena, '\n');
                try html.appendSlice(arena, lines[i]);
            }
            const spans = try htmlText(arena, html.items);
            if (spans.len > 0) try blocks.append(arena, .{ .paragraph = spans });
            continue;
        }

        // Paragrafo, o titolo sottolineato (setext).
        var para: std.ArrayList(u8) = .empty;
        try para.appendSlice(arena, std.mem.trimStart(u8, l, " "));
        i += 1;
        var level: ?u3 = null;
        while (i < lines.len and !isBlank(lines[i])) : (i += 1) {
            if (setextLevel(lines[i])) |lv| {
                level = lv;
                i += 1;
                break;
            }
            if (interruptsParagraph(lines[i])) break;
            if (std.mem.indexOfScalar(u8, lines[i], '|') != null and i + 1 < lines.len and (try delimiterRow(arena, lines[i + 1])) != null) break;
            try para.append(arena, '\n');
            try para.appendSlice(arena, std.mem.trimStart(u8, lines[i], " "));
        }
        const spans = try parseInline(arena, std.mem.trimEnd(u8, para.items, " "));
        try blocks.append(arena, if (level) |lv| .{ .heading = .{ .level = lv, .spans = spans } } else .{ .paragraph = spans });
    }
    return blocks.items;
}

/// Raccoglie una lista che parte alla riga `start`; restituisce la prima riga dopo.
fn parseList(arena: std.mem.Allocator, lines: []const []const u8, start: usize, m0: Marker, out: *std.ArrayList(Block), depth: usize) !usize {
    var items: std.ArrayList(Item) = .empty;
    var i = start;
    while (i < lines.len) {
        const m = listMarker(lines[i]) orelse break;
        if (m.ordered != m0.ordered or m.ch != m0.ch or m.indent >= m0.content) break;
        var body: std.ArrayList([]const u8) = .empty;
        const first = lines[i];
        try body.append(arena, if (m.content <= first.len) first[m.content..] else "");
        i += 1;
        while (i < lines.len) : (i += 1) {
            const l = lines[i];
            if (isBlank(l)) {
                // Una riga vuota resta nell'elemento se la successiva non vuota
                // è indentata quanto il contenuto.
                var j = i + 1;
                while (j < lines.len and isBlank(lines[j])) j += 1;
                if (j < lines.len and indentOf(lines[j]) >= m.content) {
                    try body.append(arena, "");
                    continue;
                }
                break;
            }
            if (indentOf(l) >= m.content) {
                try body.append(arena, l[m.content..]);
                continue;
            }
            // Continuazione pigra: riga di testo che prosegue il paragrafo.
            const prev = body.items[body.items.len - 1];
            if (!isBlank(prev) and !interruptsParagraph(l) and listMarker(l) == null) {
                try body.append(arena, std.mem.trimStart(u8, l, " "));
                continue;
            }
            break;
        }
        // Casella delle liste di attività: `[ ]` o `[x]` all'inizio.
        var checked: ?bool = null;
        const b0 = body.items[0];
        if (b0.len >= 3 and b0[0] == '[' and b0[2] == ']' and (b0.len == 3 or b0[3] == ' ')) {
            if (b0[1] == ' ') checked = false else if (b0[1] == 'x' or b0[1] == 'X') checked = true;
            if (checked != null) body.items[0] = if (b0.len > 4) b0[4..] else "";
        }
        try items.append(arena, .{ .blocks = try parseBlocks(arena, body.items, depth + 1), .checked = checked });
        // Elementi separati da righe vuote restano nella stessa lista.
        var j = i;
        while (j < lines.len and isBlank(lines[j])) j += 1;
        if (j < lines.len) {
            if (listMarker(lines[j])) |mn| {
                if (mn.ordered == m0.ordered and mn.ch == m0.ch and mn.indent < m0.content) {
                    i = j;
                    continue;
                }
            }
        }
        break;
    }
    try out.append(arena, .{ .list = .{ .ordered = m0.ordered, .start = m0.number, .items = items.items } });
    return i;
}

// --- Testo in linea ----------------------------------------------------------

const none = std.math.maxInt(u32);

/// Ricerche già fatte sul testo in linea, condivise dalle chiamate annidate:
/// senza, ogni apertura senza chiusura (`*a *a *a…`, `[[[…`) riscandirebbe il
/// testo fino in fondo, con tempi quadratici su file grandi.
const Shared = struct {
    src: []const u8,
    /// Per ogni `[` / `(` l'indice della parentesi che la chiude (`none` se manca).
    bracket: []u32,
    paren: []u32,
    /// Enfasi senza chiusura: da `from` in poi, entro `end`, non c'è (per
    /// carattere `*_~` e lunghezza 1..3).
    emph_fail: [3][3]Fail = @splat(@splat(.{})),
    /// Codici in linea senza chiusura, per numero di apici (1..8).
    tick_fail: [8]usize = @splat(std.math.maxInt(usize)),
    /// Ultima `>` trovata cercando da `gt_from`.
    gt_from: usize = std.math.maxInt(usize),
    gt_at: ?usize = null,

    const Fail = struct { from: usize = std.math.maxInt(usize), end: usize = 0 };

    fn init(arena: std.mem.Allocator, src: []const u8) !Shared {
        const sh: Shared = .{ .src = src, .bracket = try arena.alloc(u32, src.len), .paren = try arena.alloc(u32, src.len) };
        @memset(sh.bracket, none);
        @memset(sh.paren, none);
        var bs: std.ArrayList(u32) = .empty;
        var ps: std.ArrayList(u32) = .empty;
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            switch (src[i]) {
                '\\' => i += 1,
                '[' => try bs.append(arena, @intCast(i)),
                ']' => if (bs.pop()) |o| {
                    sh.bracket[o] = @intCast(i);
                },
                '(' => try ps.append(arena, @intCast(i)),
                ')' => if (ps.pop()) |o| {
                    sh.paren[o] = @intCast(i);
                },
                else => {},
            }
        }
        return sh;
    }
};

const Builder = struct {
    arena: std.mem.Allocator,
    sh: *Shared,
    spans: std.ArrayList(Span) = .empty,
    buf: std.ArrayList(u8) = .empty,
    flags: Flags = .{},
    url: []const u8 = "",
    /// Enfasi e link annidati: oltre `max_inline_depth` restano testo.
    depth: usize = 0,

    fn flush(b: *Builder) !void {
        if (b.buf.items.len == 0) return;
        try b.spans.append(b.arena, .{ .text = try b.arena.dupe(u8, b.buf.items), .flags = b.flags, .url = b.url });
        b.buf.clearRetainingCapacity();
    }

    fn char(b: *Builder, c: u8) !void {
        try b.buf.append(b.arena, c);
    }

    fn str(b: *Builder, s: []const u8) !void {
        try b.buf.appendSlice(b.arena, s);
    }

    fn span(b: *Builder, s: Span) !void {
        try b.flush();
        try b.spans.append(b.arena, s);
    }

    /// Posizione di `text` (una parte del testo intero) nel testo intero.
    fn base(b: *const Builder, text: []const u8) usize {
        return @intFromPtr(text.ptr) - @intFromPtr(b.sh.src.ptr);
    }
};

const max_inline_depth = 16;

pub fn parseInline(arena: std.mem.Allocator, text: []const u8) ![]const Span {
    var sh = try Shared.init(arena, text);
    var b: Builder = .{ .arena = arena, .sh = &sh };
    try inlineInto(&b, text);
    try b.flush();
    return b.spans.items;
}

fn isPunct(c: u8) bool {
    return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
}

/// Fine di una sequenza di `n` caratteri `ch` che chiude un'enfasi aperta in
/// `from`: preceduta da un non-spazio, e per `_` non seguita da una lettera.
fn findCloser(b: *Builder, text: []const u8, from: usize, ch: u8, n: usize) ?usize {
    const off = b.base(text);
    const slot = &b.sh.emph_fail[if (ch == '*') 0 else if (ch == '_') 1 else 2][n - 1];
    if (off + from >= slot.from and off + text.len <= slot.end) return null;
    var i = from;
    while (i < text.len) {
        if (text[i] == '\\') {
            i += 2;
            continue;
        }
        if (text[i] == '`') {
            // Salta i codici in linea: dentro non si chiude nulla.
            var k = i;
            while (k < text.len and text[k] == '`') k += 1;
            if (findTicks(b, text, k, k - i)) |e| {
                i = e + (k - i);
                continue;
            }
            i = k;
            continue;
        }
        if (text[i] == ch) {
            var k = i;
            while (k < text.len and text[k] == ch) k += 1;
            const run = k - i;
            if (run >= n and i > from and text[i - 1] != ' ' and text[i - 1] != '\n') {
                const after_ok = ch != '_' or k >= text.len or !std.ascii.isAlphanumeric(text[k]);
                if (after_ok) return i + (run - n);
            }
            i = k;
            continue;
        }
        i += 1;
    }
    if (off + from < slot.from or off + text.len > slot.end) slot.* = .{ .from = off + from, .end = off + text.len };
    return null;
}

/// Inizio della chiusura di un codice in linea di `n` apici cercata da `from`.
fn findTicks(b: *Builder, text: []const u8, from: usize, n: usize) ?usize {
    const off = b.base(text);
    // Una ricerca fallita da `p` fallisce anche da ogni punto dopo `p`.
    if (n <= 8 and off + from >= b.sh.tick_fail[n - 1]) return null;
    var i = from;
    while (std.mem.indexOfScalarPos(u8, text, i, '`')) |p| {
        var k = p;
        while (k < text.len and text[k] == '`') k += 1;
        if (k - p == n) return p;
        i = k;
    }
    if (n <= 8 and off + text.len == b.sh.src.len) b.sh.tick_fail[n - 1] = @min(b.sh.tick_fail[n - 1], off + from);
    return null;
}

/// `]` che chiude la `[` in `open` (indici di `text`), se è dentro `text`.
fn closeBracket(b: *Builder, text: []const u8, open: usize) ?usize {
    const off = b.base(text);
    const c = b.sh.bracket[off + open];
    if (c == none or c - off >= text.len) return null;
    return c - off;
}

/// Destinazione `(url "titolo")` dopo la `]`: restituisce url e fine.
fn linkDest(b: *Builder, text: []const u8, open: usize) ?struct { url: []const u8, end: usize } {
    if (open >= text.len or text[open] != '(') return null;
    const off = b.base(text);
    const c = b.sh.paren[off + open];
    if (c == none or c - off >= text.len) return null;
    const i = c - off;
    var inner = std.mem.trim(u8, text[open + 1 .. i], " \n");
    if (std.mem.indexOfAny(u8, inner, " \n")) |sp| inner = inner[0..sp]; // via il titolo
    if (inner.len >= 2 and inner[0] == '<' and inner[inner.len - 1] == '>') inner = inner[1 .. inner.len - 1];
    return .{ .url = inner, .end = i + 1 };
}

/// Prossima `>` da `from` in `text` (memorizzata: `<<<<…` resta lineare).
fn nextGt(b: *Builder, text: []const u8, from: usize) ?usize {
    const off = b.base(text);
    const abs = off + from;
    if (abs >= b.sh.gt_from) {
        if (b.sh.gt_at) |g| {
            if (g >= abs) return if (g - off < text.len) g - off else null;
        } else return null;
    }
    const g = std.mem.indexOfScalarPos(u8, b.sh.src, abs, '>');
    b.sh.gt_from = abs;
    b.sh.gt_at = g;
    if (g) |v| return if (v - off < text.len) v - off else null;
    return null;
}

const entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "amp", "&" },  .{ "lt", "<" },        .{ "gt", ">" }, .{ "quot", "\"" },
    .{ "apos", "'" }, .{ "nbsp", "\u{a0}" },
    .{ "copy", "©" },
    .{ "reg", "®" },
    .{ "trade", "™" },
    .{ "hellip", "…" },
    .{ "mdash", "—" },
    .{ "ndash", "–" },
    .{ "laquo", "«" },
    .{ "raquo", "»" },
    .{ "middot", "·" },
    .{ "deg", "°" },
    .{ "euro", "€" },
    .{ "times", "×" },
    .{ "rarr", "→" },
    .{ "larr", "←" },
});

/// Un'entità HTML in `text[i..]` (`&nome;`, `&#123;`, `&#x1F;`): testo e lunghezza.
fn entity(text: []const u8, i: usize, out: *[4]u8) ?struct { s: []const u8, len: usize } {
    const window = text[i + 1 .. @min(text.len, i + 12)];
    const semi = i + 1 + (std.mem.indexOfScalar(u8, window, ';') orelse return null);
    const name = text[i + 1 .. semi];
    if (name.len > 1 and name[0] == '#') {
        const cp = (if (name[1] == 'x' or name[1] == 'X')
            std.fmt.parseInt(u21, name[2..], 16)
        else
            std.fmt.parseInt(u21, name[1..], 10)) catch return null;
        const n = std.unicode.utf8Encode(if (cp == 0) 0xFFFD else cp, out) catch return null;
        return .{ .s = out[0..n], .len = semi + 1 - i };
    }
    const s = entities.get(name) orelse return null;
    return .{ .s = s, .len = semi + 1 - i };
}

/// Lunghezza di un link nudo (`https://…`, `www.…`) che inizia in `i`.
fn bareUrl(text: []const u8, i: usize) usize {
    const t = text[i..];
    if (!(std.mem.startsWith(u8, t, "https://") or std.mem.startsWith(u8, t, "http://") or std.mem.startsWith(u8, t, "www."))) return 0;
    if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '/')) return 0;
    var n: usize = 0;
    while (n < t.len and t[n] != ' ' and t[n] != '\n' and t[n] != '<') n += 1;
    // La punteggiatura finale non fa parte del link (e una `)` senza `(`).
    while (n > 0 and std.mem.indexOfScalar(u8, ".,:;!?\"'*_~", t[n - 1]) != null) n -= 1;
    if (n > 0 and t[n - 1] == ')' and std.mem.count(u8, t[0..n], "(") < std.mem.count(u8, t[0..n], ")")) n -= 1;
    return n;
}

fn inlineInto(b: *Builder, text: []const u8) anyerror!void {
    const nest_ok = b.depth < max_inline_depth;
    b.depth += 1;
    defer b.depth -= 1;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '\\' => {
                if (i + 1 < text.len and text[i + 1] == '\n') {
                    try b.span(.{ .text = "", .hard_break = true });
                    i += 2;
                    continue;
                }
                if (i + 1 < text.len and isPunct(text[i + 1])) {
                    try b.char(text[i + 1]);
                    i += 2;
                    continue;
                }
            },
            '\n' => {
                // Due spazi prima dell'a capo: a capo forzato; altrimenti spazio.
                const hard = b.buf.items.len >= 2 and std.mem.endsWith(u8, b.buf.items, "  ");
                while (b.buf.items.len > 0 and b.buf.items[b.buf.items.len - 1] == ' ') b.buf.items.len -= 1;
                if (hard) try b.span(.{ .text = "", .hard_break = true }) else try b.char(' ');
                i += 1;
                while (i < text.len and text[i] == ' ') i += 1;
                continue;
            },
            '`' => {
                var k = i;
                while (k < text.len and text[k] == '`') k += 1;
                const ticks = text[i..k];
                if (findTicks(b, text, k, ticks.len)) |e| {
                    var code = text[k..e];
                    if (code.len >= 2 and code[0] == ' ' and code[code.len - 1] == ' ' and std.mem.trim(u8, code, " ").len > 0) code = code[1 .. code.len - 1];
                    const nl = try b.arena.dupe(u8, code);
                    std.mem.replaceScalar(u8, nl, '\n', ' ');
                    var f = b.flags;
                    f.code = true;
                    try b.span(.{ .text = nl, .flags = f, .url = b.url });
                    i = e + ticks.len;
                    continue;
                }
                try b.str(ticks);
                i = k;
                continue;
            },
            '!', '[' => {
                const img = c == '!';
                const lb = if (img) i + 1 else i;
                if (nest_ok and lb < text.len and text[lb] == '[') {
                    if (closeBracket(b, text, lb)) |rb| {
                        if (linkDest(b, text, rb + 1)) |d| {
                            const label = text[lb + 1 .. rb];
                            if (img) {
                                // Testo alternativo: il testo semplice dell'etichetta.
                                var sub: Builder = .{ .arena = b.arena, .sh = b.sh, .depth = b.depth };
                                try inlineInto(&sub, label);
                                try sub.flush();
                                var alt: std.ArrayList(u8) = .empty;
                                for (sub.spans.items) |sp| try alt.appendSlice(b.arena, sp.text);
                                try b.span(.{ .text = alt.items, .flags = b.flags, .url = d.url, .image = true });
                            } else {
                                try b.flush();
                                const saved = b.url;
                                b.url = d.url;
                                try inlineInto(b, label);
                                try b.flush();
                                b.url = saved;
                            }
                            i = d.end;
                            continue;
                        }
                    }
                }
            },
            '<' => {
                if (nextGt(b, text, i + 1)) |gt| {
                    const inner = text[i + 1 .. gt];
                    if (std.mem.indexOfScalar(u8, inner, ' ') == null and (std.mem.indexOf(u8, inner, "://") != null or (std.mem.indexOfScalar(u8, inner, '@') != null and std.mem.indexOfScalar(u8, inner, '.') != null))) {
                        try b.flush();
                        const saved = b.url;
                        b.url = if (std.mem.indexOfScalar(u8, inner, '@') != null and std.mem.indexOf(u8, inner, "://") == null) try std.fmt.allocPrint(b.arena, "mailto:{s}", .{inner}) else inner;
                        try b.str(inner);
                        try b.flush();
                        b.url = saved;
                        i = gt + 1;
                        continue;
                    }
                    if (inner.len > 0 and (std.ascii.isAlphabetic(inner[0]) or inner[0] == '/' or inner[0] == '!')) {
                        // Tag HTML in linea: `<br>` va a capo, gli altri spariscono.
                        if (std.ascii.startsWithIgnoreCase(inner, "br")) try b.span(.{ .text = "", .hard_break = true });
                        i = gt + 1;
                        continue;
                    }
                }
            },
            '&' => {
                var tmp: [4]u8 = undefined;
                if (entity(text, i, &tmp)) |e| {
                    try b.str(e.s);
                    i += e.len;
                    continue;
                }
            },
            '*', '_', '~' => {
                var k = i;
                while (k < text.len and text[k] == c) k += 1;
                const run = k - i;
                const opens = nest_ok and k < text.len and text[k] != ' ' and text[k] != '\n' and
                    (c != '_' or i == 0 or !std.ascii.isAlphanumeric(text[i - 1]));
                if (opens and (c != '~' or run == 2)) {
                    const n = @min(run, 3);
                    if (findCloser(b, text, k, c, n)) |close| {
                        try b.flush();
                        // Una sequenza più lunga di 3 lascia l'eccesso come testo.
                        if (run > n) try b.str(text[i .. i + run - n]);
                        try b.flush();
                        const saved = b.flags;
                        if (c == '~') b.flags.strike = true else {
                            if (n != 2) b.flags.italic = true;
                            if (n >= 2) b.flags.bold = true;
                        }
                        try inlineInto(b, text[k..close]);
                        try b.flush();
                        b.flags = saved;
                        i = close + n;
                        continue;
                    }
                }
                try b.str(text[i..k]);
                i = k;
                continue;
            },
            'h', 'w' => {
                const n = if (b.url.len == 0) bareUrl(text, i) else 0;
                if (n > 0) {
                    try b.flush();
                    const u = text[i .. i + n];
                    b.url = if (u[0] == 'w') try std.fmt.allocPrint(b.arena, "https://{s}", .{u}) else u;
                    try b.str(u);
                    try b.flush();
                    b.url = "";
                    i += n;
                    continue;
                }
            },
            else => {},
        }
        try b.char(c);
        i += 1;
    }
}

/// Testo di un blocco HTML: i tag spariscono (`<br>` e i blocchi vanno a capo),
/// le immagini lasciano il loro `alt`, i commenti si saltano.
fn htmlText(arena: std.mem.Allocator, html: []const u8) ![]const Span {
    var sh: Shared = .{ .src = html, .bracket = &.{}, .paren = &.{} };
    var b: Builder = .{ .arena = arena, .sh = &sh };
    // Un `<` senza `>` dopo resta testo (e non si cerca la `>` a ogni `<`).
    const last_gt = std.mem.lastIndexOfScalar(u8, html, '>') orelse 0;
    var i: usize = 0;
    while (i < html.len) {
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, html, i + 4, "-->")) |e| e + 3 else html.len;
            continue;
        }
        if (html[i] == '<' and i < last_gt) {
            const gt = std.mem.indexOfScalarPos(u8, html, i, '>').?;
            const tag = html[i + 1 .. gt];
            const name_end = std.mem.indexOfAny(u8, tag, " />\n") orelse tag.len;
            const name = std.mem.trimStart(u8, tag[0..name_end], "/");
            if (std.ascii.eqlIgnoreCase(name, "img")) {
                if (attr(tag, "alt")) |alt| if (alt.len > 0) try b.span(.{ .text = alt, .image = true, .url = attr(tag, "src") orelse "" });
            } else if (std.ascii.eqlIgnoreCase(name, "br") or std.ascii.eqlIgnoreCase(name, "p") or std.ascii.eqlIgnoreCase(name, "div") or
                std.ascii.eqlIgnoreCase(name, "h1") or std.ascii.eqlIgnoreCase(name, "h2") or std.ascii.eqlIgnoreCase(name, "h3"))
            {
                if (b.spans.items.len > 0 or b.buf.items.len > 0) try b.span(.{ .text = "", .hard_break = true });
            }
            i = gt + 1;
            continue;
        }
        if (html[i] == '\n') {
            if (b.buf.items.len > 0 and b.buf.items[b.buf.items.len - 1] != ' ') try b.char(' ');
            i += 1;
            continue;
        }
        if (html[i] == '&') {
            var tmp: [4]u8 = undefined;
            if (entity(html, i, &tmp)) |e| {
                try b.str(e.s);
                i += e.len;
                continue;
            }
        }
        try b.char(html[i]);
        i += 1;
    }
    try b.flush();
    // Via gli a capo in testa/coda e i tratti di soli spazi.
    var spans = b.spans.items;
    while (spans.len > 0 and (spans[0].hard_break or std.mem.trim(u8, spans[0].text, " ").len == 0 and !spans[0].image)) spans = spans[1..];
    while (spans.len > 0 and (spans[spans.len - 1].hard_break or std.mem.trim(u8, spans[spans.len - 1].text, " ").len == 0 and !spans[spans.len - 1].image)) spans = spans[0 .. spans.len - 1];
    return spans;
}

/// Valore dell'attributo `name` in un tag HTML (`name="…"` o `name='…'`).
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, name)) |p| {
        i = p + name.len;
        if (p > 0 and tag[p - 1] != ' ' and tag[p - 1] != '\n') continue;
        var k = i;
        while (k < tag.len and tag[k] == ' ') k += 1;
        if (k >= tag.len or tag[k] != '=') continue;
        k += 1;
        while (k < tag.len and tag[k] == ' ') k += 1;
        if (k >= tag.len) return null;
        const q = tag[k];
        if (q == '"' or q == '\'') {
            const e = std.mem.indexOfScalarPos(u8, tag, k + 1, q) orelse return null;
            return tag[k + 1 .. e];
        }
        const e = std.mem.indexOfAnyPos(u8, tag, k, " >") orelse tag.len;
        return tag[k..e];
    }
    return null;
}

// --- Test ----------------------------------------------------------------

test "titoli, paragrafi, a capo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = try parse(a, "# Uno #\n\nTesto su\ndue righe  \nforzato\n\nDue\n===\n\nTre\n---\n");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqual(@as(u3, 1), blocks[0].heading.level);
    try std.testing.expectEqualStrings("Uno", blocks[0].heading.spans[0].text);
    const p = blocks[1].paragraph;
    try std.testing.expectEqualStrings("Testo su due righe", p[0].text);
    try std.testing.expect(p[1].hard_break);
    try std.testing.expectEqualStrings("forzato", p[2].text);
    try std.testing.expectEqual(@as(u3, 1), blocks[2].heading.level);
    try std.testing.expectEqual(@as(u3, 2), blocks[3].heading.level);
}

test "enfasi, codice, link, entità" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spans = try parseInline(arena.allocator(), "a **b** *c* ***d*** ~~e~~ `f*g*` [h](http://x \"t\") &amp; snake_case_name <br> https://z.it.");
    var got: std.ArrayList(u8) = .empty;
    for (spans) |s| {
        const f = s.flags;
        try got.print(arena.allocator(), "[{s}{s}{s}{s}{s}{s}]", .{
            if (f.bold) "B" else "",        if (f.italic) "I" else "",           if (f.strike) "S" else "", if (f.code) "C" else "",
            if (s.url.len > 0) "L" else "", if (s.hard_break) "\\n" else s.text,
        });
    }
    try std.testing.expectEqualStrings("[a ][Bb][ ][Ic][ ][BId][ ][Se][ ][Cf*g*][ ][Lh][ & snake_case_name ][\\n][ ][Lhttps://z.it][.]", got.items);
}

test "liste annidate, numerate e di attività" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try parse(arena.allocator(), "- uno\n  continua\n  - dentro\n- [x] fatto\n\n3. tre\n4. quattro\n");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    const ul = blocks[0].list;
    try std.testing.expect(!ul.ordered);
    try std.testing.expectEqual(@as(usize, 2), ul.items.len);
    try std.testing.expectEqualStrings("uno continua", ul.items[0].blocks[0].paragraph[0].text);
    try std.testing.expect(ul.items[0].blocks[1] == .list);
    try std.testing.expectEqual(@as(?bool, true), ul.items[1].checked);
    const ol = blocks[1].list;
    try std.testing.expect(ol.ordered);
    try std.testing.expectEqual(@as(u32, 3), ol.start);
    try std.testing.expectEqual(@as(usize, 2), ol.items.len);
}

test "codice, citazioni, righe, tabelle, HTML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\```zig
        \\const x = 1;
        \\
        \\```
        \\> citato
        \\> - con lista
        \\
        \\***
        \\
        \\| A | B | C |
        \\|:--|:-:|--:|
        \\| 1 | `a|b` | 3 |
        \\| solo |
        \\
        \\<p align="center"><img src="x.png" alt="Logo"></p>
        \\<!-- nascosto -->
        \\
        \\    indentato
    ;
    const blocks = try parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 6), blocks.len);
    try std.testing.expectEqualStrings("zig", blocks[0].code.lang);
    try std.testing.expectEqualStrings("const x = 1;\n", blocks[0].code.text);
    try std.testing.expect(blocks[1].quote[1] == .list);
    try std.testing.expect(blocks[2] == .rule);
    const t = blocks[3].table;
    try std.testing.expectEqualSlices(Align, &.{ .left, .center, .right }, t.aligns);
    try std.testing.expectEqualStrings("a|b", t.rows[0][1][0].text);
    try std.testing.expectEqual(@as(usize, 0), t.rows[1][2].len);
    try std.testing.expect(blocks[4].paragraph[0].image);
    try std.testing.expectEqualStrings("Logo", blocks[4].paragraph[0].text);
    try std.testing.expectEqualStrings("indentato", blocks[5].code.text);
}

test "input ostili: niente panic, niente ricorsione senza fondo, tempo lineare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `<` in fondo a un blocco HTML (prima andava fuori dai limiti).
    _ = try parse(a, "<b>x <");
    _ = try parse(a, "<div>\na <\n");
    // Annidamento profondo: citazioni e liste oltre il limite restano testo.
    var deep: std.ArrayList(u8) = .empty;
    try deep.appendNTimes(a, '>', 100_000);
    _ = try parse(a, deep.items);
    deep.clearRetainingCapacity();
    for (0..20_000) |_| try deep.appendSlice(a, "- ");
    _ = try parse(a, deep.items);
    // Aperture senza chiusura: devono restare rapide (erano secondi).
    const patterns = [_][]const u8{ "*a ", "_a ", "[", "[a](", "`a ", "<a ", "&a ", "![" };
    for (patterns) |pat| {
        deep.clearRetainingCapacity();
        for (0..20_000) |_| try deep.appendSlice(a, pat);
        if (std.mem.eql(u8, pat, "[")) for (0..20_000) |_| try deep.appendSlice(a, "](u)");
        _ = try parseInline(a, deep.items);
    }
}
