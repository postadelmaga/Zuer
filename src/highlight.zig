//! Evidenziazione leggera del codice: commenti di riga, stringhe fra apici e parole
//! chiave, per una manciata di linguaggi. Produce tratti con un **ruolo**; il colore
//! (e il grassetto delle parole chiave) lo sceglie chi disegna: il testo a schermo
//! (`text_render`), il markdown a schermo e su carta (`md_layout`).
//!
//! Prima stava dentro text_render.zig e produceva tratti già colorati: il markdown li
//! ritraduceva in ruoli confrontando i colori, e md_layout doveva importare tutto
//! text_render (che a sua volta importa md_layout) per arrivarci.

const std = @import("std");

/// Ruolo sintattico di un tratto di codice.
pub const Role = enum { plain, keyword, string, comment };

/// Un tratto di una riga: `text` punta dentro la riga data.
pub const Span = struct { text: []const u8, role: Role };

pub const Lang = struct {
    line_comments: []const []const u8,
    /// Insieme di keyword: mappa statica perfetta costruita a comptime — il
    /// vecchio confronto lineare su ~40 voci girava per OGNI identificatore del
    /// documento durante l'impaginazione.
    keywords: std.StaticStringMap(void),
};

/// Costruisce a comptime l'insieme di keyword da un elenco di stringhe.
fn kwSet(comptime words: []const []const u8) std.StaticStringMap(void) {
    comptime var kvs: [words.len]struct { []const u8 } = undefined;
    inline for (words, 0..) |w, i| kvs[i] = .{w};
    return std.StaticStringMap(void).initComptime(kvs);
}

const kw_zig = kwSet(&[_][]const u8{ "fn", "pub", "const", "var", "if", "else", "while", "for", "return", "try", "catch", "defer", "errdefer", "struct", "enum", "union", "switch", "break", "continue", "orelse", "and", "or", "comptime", "test", "export", "extern", "inline", "null", "undefined", "true", "false", "error", "anyerror", "unreachable", "usingnamespace" });
const kw_rust = kwSet(&[_][]const u8{ "fn", "pub", "let", "mut", "const", "if", "else", "while", "for", "loop", "return", "match", "struct", "enum", "impl", "trait", "use", "mod", "crate", "self", "super", "where", "async", "await", "move", "ref", "dyn", "true", "false", "in", "as", "break", "continue", "static", "type", "unsafe", "extern" });
const kw_c = kwSet(&[_][]const u8{ "if", "else", "while", "for", "return", "struct", "enum", "union", "typedef", "static", "const", "void", "int", "char", "long", "short", "unsigned", "signed", "float", "double", "sizeof", "switch", "case", "break", "continue", "default", "do", "goto", "extern", "inline", "volatile", "class", "public", "private", "protected", "template", "typename", "namespace", "using", "new", "delete", "virtual", "override", "nullptr", "true", "false", "auto", "this", "bool" });
const kw_py = kwSet(&[_][]const u8{ "def", "class", "if", "elif", "else", "while", "for", "return", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "global", "nonlocal", "yield", "async", "await", "in", "is", "not", "and", "or", "None", "True", "False", "del", "assert", "match", "case" });
const kw_js = kwSet(&[_][]const u8{ "function", "const", "let", "var", "if", "else", "while", "for", "return", "class", "extends", "import", "from", "export", "default", "new", "this", "typeof", "instanceof", "try", "catch", "finally", "throw", "async", "await", "yield", "switch", "case", "break", "continue", "delete", "in", "of", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "readonly", "static" });
const kw_go = kwSet(&[_][]const u8{ "func", "package", "import", "var", "const", "if", "else", "for", "range", "return", "struct", "interface", "map", "chan", "go", "defer", "select", "switch", "case", "break", "continue", "type", "nil", "true", "false", "fallthrough", "goto" });
const kw_sh = kwSet(&[_][]const u8{ "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "local", "return", "echo", "export", "in", "read", "exit", "set" });
const kw_lua = kwSet(&[_][]const u8{ "function", "local", "if", "then", "else", "elseif", "end", "while", "for", "do", "return", "nil", "true", "false", "and", "or", "not", "repeat", "until", "break", "in" });
const kw_sql = kwSet(&[_][]const u8{ "select", "from", "where", "insert", "update", "delete", "join", "left", "right", "inner", "outer", "group", "by", "order", "having", "limit", "create", "table", "drop", "alter", "index", "as", "and", "or", "not", "null", "into", "values", "set", "on", "distinct", "union" });
const kw_none = kwSet(&[_][]const u8{});

const slash_comment = [_][]const u8{"//"};
const hash_comment = [_][]const u8{"#"};
const dash_comment = [_][]const u8{"--"};
const semi_comment = [_][]const u8{";"};
const no_comment = [_][]const u8{};

pub fn langForExt(ext: []const u8) Lang {
    const Case = struct { exts: []const []const u8, lang: Lang };
    const table = [_]Case{
        .{ .exts = &.{"zig"}, .lang = .{ .line_comments = &slash_comment, .keywords = kw_zig } },
        .{ .exts = &.{"rs"}, .lang = .{ .line_comments = &slash_comment, .keywords = kw_rust } },
        .{ .exts = &.{ "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "java", "cs", "kt", "kts", "swift", "scala", "dart", "proto" }, .lang = .{ .line_comments = &slash_comment, .keywords = kw_c } },
        .{ .exts = &.{ "py", "pyi", "rb", "toml", "yaml", "yml", "cfg", "conf", "properties", "gitignore", "gitattributes", "editorconfig", "dockerfile", "mk", "make", "cmake", "r", "jl", "nim", "ex", "exs" }, .lang = .{ .line_comments = &hash_comment, .keywords = kw_py } },
        .{ .exts = &.{ "js", "mjs", "cjs", "jsx", "ts", "tsx", "php" }, .lang = .{ .line_comments = &slash_comment, .keywords = kw_js } },
        .{ .exts = &.{"go"}, .lang = .{ .line_comments = &slash_comment, .keywords = kw_go } },
        .{ .exts = &.{ "sh", "bash", "zsh", "fish", "ps1", "env" }, .lang = .{ .line_comments = &hash_comment, .keywords = kw_sh } },
        .{ .exts = &.{ "lua", "hs" }, .lang = .{ .line_comments = &dash_comment, .keywords = kw_lua } },
        .{ .exts = &.{"sql"}, .lang = .{ .line_comments = &dash_comment, .keywords = kw_sql } },
        .{ .exts = &.{ "ini", "asm", "s" }, .lang = .{ .line_comments = &semi_comment, .keywords = kw_none } },
    };
    for (table) |case| {
        for (case.exts) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return case.lang;
        }
    }
    // Testo generico: niente keyword, niente commenti — restano gutter e wrap.
    return .{ .line_comments = &no_comment, .keywords = kw_none };
}

/// Il linguaggio di un blocco di codice del markdown, dal nome dopo le ```: `zig`,
/// `rust`, `python`… o un'estensione. null per un blocco senza nome: lì non si
/// evidenzia nulla.
pub fn langForFence(name: []const u8) ?Lang {
    if (name.len == 0) return null;
    const aliases = [_][2][]const u8{
        .{ "rust", "rs" },   .{ "python", "py" },  .{ "javascript", "js" }, .{ "typescript", "ts" },
        .{ "shell", "sh" },  .{ "console", "sh" }, .{ "c++", "cpp" },       .{ "csharp", "cs" },
        .{ "kotlin", "kt" }, .{ "ruby", "rb" },    .{ "golang", "go" },     .{ "haskell", "hs" },
        .{ "elixir", "ex" }, .{ "julia", "jl" },   .{ "make", "mk" },       .{ "makefile", "mk" },
    };
    var ext = name;
    for (aliases) |a| if (std.ascii.eqlIgnoreCase(name, a[0])) {
        ext = a[1];
    };
    return langForExt(ext);
}

/// I tratti di `chunk` (un pezzo di riga), uno alla volta: `while (it.next()) |sp|`.
/// Non alloca. Senza linguaggio un tratto solo, neutro. I testi puntano in `chunk`.
pub fn iterate(chunk: []const u8, lang: ?Lang) Iterator {
    return .{ .chunk = chunk, .lang = lang };
}

pub const Iterator = struct {
    chunk: []const u8,
    lang: ?Lang,
    i: usize = 0,
    /// Inizio del testo neutro non ancora restituito.
    plain_start: usize = 0,
    /// Il tratto che segue un pezzo neutro appena restituito.
    pending: ?Span = null,
    done: bool = false,

    pub fn next(it: *Iterator) ?Span {
        if (it.pending) |p| {
            it.pending = null;
            return p;
        }
        if (it.done) return null;
        const chunk = it.chunk;
        const l = it.lang orelse {
            it.done = true;
            return if (chunk.len > 0) .{ .text = chunk, .role = .plain } else null;
        };
        while (it.i < chunk.len) {
            const i = it.i;
            // Commento di riga: fino a fine pezzo.
            for (l.line_comments) |prefix| {
                if (std.mem.startsWith(u8, chunk[i..], prefix)) {
                    it.done = true;
                    return it.after(i, .{ .text = chunk[i..], .role = .comment }, chunk.len);
                }
            }

            const c = chunk[i];

            // Stringhe tra apici (best effort, senza multilinea).
            if (c == '"' or c == '\'' or c == '`') {
                var end = i + 1;
                while (end < chunk.len) : (end += 1) {
                    if (chunk[end] == '\\') {
                        end += 1;
                        continue;
                    }
                    if (chunk[end] == c) break;
                }
                const stop = @min(end + 1, chunk.len);
                it.i = stop;
                return it.after(i, .{ .text = chunk[i..stop], .role = .string }, stop);
            }

            // Identificatori: le parole chiave hanno il loro ruolo, il resto resta neutro.
            if (std.ascii.isAlphabetic(c) or c == '_') {
                var end = i + 1;
                while (end < chunk.len and (std.ascii.isAlphanumeric(chunk[end]) or chunk[end] == '_')) end += 1;
                it.i = end;
                const word = chunk[i..end];
                if (l.keywords.get(word) != null) return it.after(i, .{ .text = word, .role = .keyword }, end);
                continue;
            }

            it.i += 1;
        }
        it.done = true;
        if (chunk.len > it.plain_start) return .{ .text = chunk[it.plain_start..], .role = .plain };
        return null;
    }

    /// `tok` comincia in `at` e il neutro riprende da `resume_at`: se prima di `at`
    /// c'è del testo neutro esce quello, e `tok` al giro dopo.
    fn after(it: *Iterator, at: usize, tok: Span, resume_at: usize) Span {
        const from = it.plain_start;
        it.plain_start = resume_at;
        if (at > from) {
            it.pending = tok;
            return .{ .text = it.chunk[from..at], .role = .plain };
        }
        return tok;
    }
};

const testing = std.testing;

fn expectSpans(line: []const u8, lang: ?Lang, want: []const Span) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(Span) = .empty;
    var it = iterate(line, lang);
    while (it.next()) |sp| try out.append(arena_state.allocator(), sp);
    testing.expectEqual(want.len, out.items.len) catch |e| {
        for (out.items) |sp| std.debug.print("  {s} «{s}»\n", .{ @tagName(sp.role), sp.text });
        return e;
    };
    for (want, out.items) |w, g| {
        try testing.expectEqual(w.role, g.role);
        try testing.expectEqualStrings(w.text, g.text);
    }
}

test "spans: parole chiave, stringhe, commenti" {
    try expectSpans("const s = \"a\\\"b\"; // fine", langForExt("zig"), &.{
        .{ .text = "const", .role = .keyword },
        .{ .text = " s = ", .role = .plain },
        .{ .text = "\"a\\\"b\"", .role = .string },
        .{ .text = "; ", .role = .plain },
        .{ .text = "// fine", .role = .comment },
    });
    // Un identificatore che contiene una parola chiave non la diventa.
    try expectSpans("constant", langForExt("zig"), &.{.{ .text = "constant", .role = .plain }});
    // Stringa non chiusa: fino a fine pezzo.
    try expectSpans("x = 'aperta", langForExt("py"), &.{
        .{ .text = "x = ", .role = .plain },
        .{ .text = "'aperta", .role = .string },
    });
    try expectSpans("", langForExt("zig"), &.{});
}

test "spans: tratti speciali attaccati, e i pezzi ricompongono la riga" {
    try expectSpans("\"a\"\"b\"if//c", langForExt("c"), &.{
        .{ .text = "\"a\"", .role = .string },
        .{ .text = "\"b\"", .role = .string },
        .{ .text = "if", .role = .keyword },
        .{ .text = "//c", .role = .comment },
    });
    const line = "  for (x in y) { s = 'q'; } -- fine";
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for ([_][]const u8{ "lua", "py", "zig", "sql", "" }) |ext| {
        joined.clearRetainingCapacity();
        var it = iterate(line, langForExt(ext));
        while (it.next()) |sp| try joined.appendSlice(testing.allocator, sp.text);
        try testing.expectEqualStrings(line, joined.items);
    }
}

test "spans: senza linguaggio un tratto solo; i nomi dei blocchi markdown" {
    try expectSpans("if x // no", null, &.{.{ .text = "if x // no", .role = .plain }});
    try testing.expect(langForFence("") == null);
    try expectSpans("def f(): # c", langForFence("Python"), &.{
        .{ .text = "def", .role = .keyword },
        .{ .text = " f(): ", .role = .plain },
        .{ .text = "# c", .role = .comment },
    });
    // Un linguaggio sconosciuto: niente parole chiave né commenti, ma le stringhe sì
    // (come per i file di testo generico).
    try expectSpans("if \"x\"", langForFence("boh"), &.{
        .{ .text = "if ", .role = .plain },
        .{ .text = "\"x\"", .role = .string },
    });
}
