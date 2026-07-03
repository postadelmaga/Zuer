//! Rasterizza contenuti testuali (text, markdown, tabelle CSV) in immagini RGB
//! usando ImageMagick per una resa tipografica anti-alias ad alta definizione
//! (con DejaVu Sans per markdown, e DejaVu Sans Mono per CSV e codice).

const std = @import("std");
const decoder_mod = @import("decoder.zig");

pub const max_table_col: usize = 40;

// Margini tipografici del documento rasterizzato (aggiunti con -border,
// quindi già compresi nella larghezza finale richiesta).
const pad_x: usize = 20;
const pad_y: usize = 14;

/// Parametri di rasterizzazione: larghezza in pixel dell'immagine prodotta
/// (idealmente la larghezza della finestra, per una resa 1:1 nitida) e corpo
/// del carattere (scalato dallo zoom del chiamante).
pub const RenderOpts = struct {
    width: usize = 1024,
    pointsize: usize = 15,
};

/// Oltre questa dimensione il file viene mostrato in modalità plain-text
/// veloce (niente numeri di riga né colori): il markup Pango di un sorgente
/// enorme costerebbe più della sua utilità.
const max_rich_bytes: usize = 2 * 1024 * 1024;

/// Rasterizza un contenuto decodificato testuale in un'immagine RGB.
pub fn render(gpa: std.mem.Allocator, io: std.Io, decoded: *const decoder_mod.Decoded, name: []const u8, opts: RenderOpts) !decoder_mod.ImageData {
    switch (decoded.*) {
        .text => |t| {
            // File di testo/codice: documento tipografico con numeri di riga,
            // righello e syntax highlighting leggero. Le schede informative
            // (media, archivi) non hanno un'estensione testuale e restano pulite.
            if (t.len <= max_rich_bytes and isCodeLike(name)) {
                if (buildCodeDocument(gpa, t, name, opts)) |doc| {
                    defer gpa.free(doc);
                    return renderText(gpa, io, doc, name, true, true, opts);
                } else |_| {}
            }
            return renderText(gpa, io, t, name, true, false, opts);
        },
        .markdown => |m| {
            // Il markdown viene convertito in markup Pango: la resa torna
            // formattata (header, grassetto, codice…) mantenendo il percorso
            // veloce plain-text per tutto il resto.
            const pango = try mdToPango(gpa, m.content);
            defer gpa.free(pango);
            return renderText(gpa, io, pango, name, false, true, opts);
        },
        .csv => |c| {
            const table = try formatTable(gpa, c);
            defer gpa.free(table);
            return renderText(gpa, io, table, name, true, false, opts);
        },
        else => return error.UnsupportedContent,
    }
}

const TimeVal = extern struct {
    tv_sec: c_long,
    tv_usec: c_long,
};
extern fn gettimeofday(tv: *TimeVal, tz: ?*anyopaque) c_int;

fn getMicroseconds() u64 {
    var tv: TimeVal = undefined;
    _ = gettimeofday(&tv, null);
    return @intCast(tv.tv_sec * 1_000_000 + tv.tv_usec);
}

extern fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn getpid() c_int;
extern fn fclose(stream: ?*anyopaque) c_int;
extern fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: ?*anyopaque) usize;
extern fn unlink(filename: [*:0]const u8) c_int;

fn renderText(gpa: std.mem.Allocator, io: std.Io, content: []const u8, name: []const u8, is_mono: bool, markup: bool, opts: RenderOpts) !decoder_mod.ImageData {
    const us = getMicroseconds();
    var tmp_filename: [64]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_filename, "/tmp/zuer_txt_{d}_{d}.txt", .{ getpid(), us });
    tmp_filename[tmp_path.len] = 0;

    const path_c = @as([*:0]const u8, @ptrCast(tmp_path.ptr));
    // "x" (C11): fallisce se il percorso esiste già, quindi un symlink
    // pre-creato in /tmp non può dirottare la scrittura.
    const file_ptr = fopen(path_c, "wbx") orelse return error.CreateFileFailed;
    const written = fwrite(content.ptr, 1, content.len, file_ptr);
    const close_res = fclose(file_ptr);
    if (written < content.len or close_res != 0) {
        _ = unlink(path_c);
        return error.WriteFileFailed;
    }
    defer _ = unlink(path_c);

    const font_name = if (is_mono) "DejaVu-Sans-Mono" else "DejaVu-Sans";
    const pango_path = try std.fmt.allocPrint(gpa, "pango:@{s}", .{tmp_path});
    defer gpa.free(pango_path);

    const markup_def = if (markup) "pango:markup=true" else "pango:markup=false";
    const border_arg = std.fmt.comptimePrint("{d}x{d}", .{ pad_x, pad_y });
    var size_arg_buf: [24]u8 = undefined;
    const size_arg = try std.fmt.bufPrint(&size_arg_buf, "{d}x", .{opts.width -| 2 * pad_x});
    var pointsize_buf: [16]u8 = undefined;
    const pointsize_arg = try std.fmt.bufPrint(&pointsize_buf, "{d}", .{opts.pointsize});

    // 1. Rileva le dimensioni finali dell'immagine tipografica generata da ImageMagick
    const size_result = try std.process.run(gpa, io, .{
        .argv = &.{
            "convert",
            "-depth",
            "8",
            "-density",
            "96",
            "-background",
            "#080810",
            "-fill",
            "#e6e6e6",
            "-define",
            "pango:align=left",
            "-define",
            "pango:wrap=word-char",
            "-define",
            markup_def,
            "-size",
            size_arg,
            "-font",
            font_name,
            "-pointsize",
            pointsize_arg,
            pango_path,
            "-bordercolor",
            "#080810",
            "-border",
            border_arg,
            "-format",
            "%w %h",
            "info:",
        },
    });
    defer gpa.free(size_result.stdout);
    defer gpa.free(size_result.stderr);

    switch (size_result.term) {
        .exited => |code| {
            if (code != 0) return error.ConvertSizeFailed;
        },
        else => return error.ConvertSizeFailed,
    }

    var size_tokens = std.mem.tokenizeAny(u8, size_result.stdout, " \n\r\t");
    const w_str = size_tokens.next() orelse return error.InvalidImageMetadata;
    const h_str = size_tokens.next() orelse return error.InvalidImageMetadata;

    const width = try std.fmt.parseInt(usize, w_str, 10);
    const height = try std.fmt.parseInt(usize, h_str, 10);

    if (width == 0 or height == 0) return error.EmptyResizedImage;

    // 2. Renderizza il testo direttamente a stdout come stream di pixel RGB grezzi
    const convert_result = try std.process.run(gpa, io, .{
        .argv = &.{
            "convert",
            "-depth",
            "8",
            "-density",
            "96",
            "-background",
            "#080810",
            "-fill",
            "#e6e6e6",
            "-define",
            "pango:align=left",
            "-define",
            "pango:wrap=word-char",
            "-define",
            markup_def,
            "-size",
            size_arg,
            "-font",
            font_name,
            "-pointsize",
            pointsize_arg,
            pango_path,
            "-bordercolor",
            "#080810",
            "-border",
            border_arg,
            "rgb:-",
        },
    });
    errdefer gpa.free(convert_result.stdout);
    defer gpa.free(convert_result.stderr);

    switch (convert_result.term) {
        .exited => |code| {
            if (code != 0) {
                gpa.free(convert_result.stdout);
                return error.ConvertRenderFailed;
            }
        },
        else => {
            gpa.free(convert_result.stdout);
            return error.ConvertRenderFailed;
        },
    }

    const expected_bytes = width * height * 3;
    if (convert_result.stdout.len < expected_bytes) {
        gpa.free(convert_result.stdout);
        return error.IncompleteImagePixels;
    }

    const name_dup = try gpa.dupe(u8, name);
    errdefer gpa.free(name_dup);

    // La slice dei pixel deve coincidere con l'allocazione: liberarne una
    // porzione corromperebbe l'allocator. Se convert emette byte extra si
    // copia la parte utile e si libera l'originale.
    const pixels = if (convert_result.stdout.len == expected_bytes)
        convert_result.stdout
    else blk: {
        const exact = try gpa.dupe(u8, convert_result.stdout[0..expected_bytes]);
        gpa.free(convert_result.stdout);
        break :blk exact;
    };

    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
        .name = name_dup,
    };
}

// --- Documento codice: gutter, wrap e highlighting ---------------------------

// Palette sobria, armonizzata con lo sfondo #080810 (stessa filosofia di viewer:
// identificatori quasi neutri, accenti desaturati).
const col_line_no = "#565664";
const col_rule = "#32323e";
const col_keyword = "#96aae1";
const col_string = "#9ebe96";
const col_comment = "#6c6c76";

/// Avanzamento medio di DejaVu Sans Mono in px per punto: 0.602 em, alla
/// densità di 96 dpi fissata nelle invocazioni di convert (96/72 px per pt).
const mono_advance_px_per_pt: f32 = 0.615 * 96.0 / 72.0;

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
        .{ .exts = &.{ "js", "mjs", "cjs", "jsx", "ts", "tsx", "php", "go" }, .lang = .{ .line_comments = &slash_comment, .keywords = &kw_js } },
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
    // Testo generico: niente keyword, niente commenti — restano gutter e wrap
    return .{ .line_comments = &no_comment, .keywords = &kw_none };
}

fn extOf(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        return name[dot + 1 ..];
    }
    return "";
}

/// Il documento con gutter ha senso per testo e codice aperti da file; le
/// schede informative sintetiche (media, archivi) non passano di qui.
fn isCodeLike(name: []const u8) bool {
    const ext = extOf(name);
    if (ext.len == 0) return true; // file senza estensione: quasi sempre testo
    const text_exts = [_][]const u8{ "txt", "text", "log", "nfo", "rst", "adoc", "asciidoc", "org", "tex", "bib", "srt", "vtt", "diff", "patch", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties", "env", "plist", "editorconfig", "gitignore", "gitattributes", "lock", "xml", "html", "htm", "xhtml", "css", "scss", "sass", "less", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "mk", "make", "cmake", "gradle", "dockerfile", "rs", "py", "pyi", "js", "mjs", "cjs", "jsx", "ts", "tsx", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "cs", "java", "kt", "kts", "go", "rb", "php", "swift", "scala", "lua", "pl", "pm", "r", "sql", "dart", "ex", "exs", "erl", "hrl", "hs", "clj", "cljs", "vim", "asm", "s", "zig", "jl", "nim", "proto", "graphql", "gql" };
    for (text_exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// Costruisce il markup Pango del documento: numeri di riga in colonna
/// (allineati a destra, colore attenuato), righello verticale, contenuto
/// evidenziato e a-capo manuale con rientro allineato al gutter.
fn buildCodeDocument(gpa: std.mem.Allocator, text: []const u8, name: []const u8, opts: RenderOpts) ![]u8 {
    const lang = langFor(extOf(name));

    // Colonne disponibili alla larghezza richiesta (al netto dei margini)
    const inner_px: f32 = @floatFromInt(opts.width -| 2 * pad_x);
    const px_per_char = @as(f32, @floatFromInt(opts.pointsize)) * mono_advance_px_per_pt;
    const total_cols: usize = @intFromFloat(@max(inner_px / px_per_char, 24));

    var total_lines: usize = 1;
    for (text) |c| {
        if (c == '\n') total_lines += 1;
    }
    var digits: usize = 1;
    var n = total_lines;
    while (n >= 10) : (n /= 10) digits += 1;
    if (digits < 3) digits = 3;

    const code_cols = if (total_cols > digits + 3 + 16) total_cols - digits - 3 else 16;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line_trimmed = std.mem.trimEnd(u8, raw_line, "\r");

        // I tab spostano i tab-stop di Pango e romperebbero il gutter
        const line = try expandTabs(gpa, line_trimmed);
        defer gpa.free(line);

        var start: usize = 0;
        var first = true;
        while (true) {
            const end = sliceByColumns(line, start, code_cols);
            const chunk = line[start..end];

            if (first) {
                try w.print("<span foreground=\"{s}\">", .{col_line_no});
                var d: usize = countDigits(line_no);
                while (d < digits) : (d += 1) try w.writeByte(' ');
                try w.print("{d}</span> <span foreground=\"{s}\">│</span> ", .{ line_no, col_rule });
            } else {
                var d: usize = 0;
                while (d < digits + 1) : (d += 1) try w.writeByte(' ');
                try w.print("<span foreground=\"{s}\">│</span> ", .{col_rule});
            }
            try highlightChunk(w, chunk, lang);
            try w.writeByte('\n');

            first = false;
            start = end;
            if (start >= line.len) break;
        }
    }

    return out.toOwnedSlice();
}

fn countDigits(v: usize) usize {
    var d: usize = 1;
    var n = v;
    while (n >= 10) : (n /= 10) d += 1;
    return d;
}

fn expandTabs(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (line) |c| {
        if (c == '\t') {
            try out.writer.writeAll("    ");
        } else {
            try out.writer.writeByte(c);
        }
    }
    return out.toOwnedSlice();
}

/// Fine del segmento che copre al massimo `cols` codepoint da `start`,
/// senza spezzare le sequenze UTF-8.
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

/// Evidenziazione leggera di un segmento: commenti di riga, stringhe e
/// keyword. Tutto il resto è testo neutro, sempre escapato.
fn highlightChunk(w: *std.Io.Writer, chunk: []const u8, lang: Lang) !void {
    var i: usize = 0;
    while (i < chunk.len) {
        const c = chunk[i];

        // Commento di riga: colora fino a fine segmento
        var is_comment = false;
        for (lang.line_comments) |prefix| {
            if (std.mem.startsWith(u8, chunk[i..], prefix)) {
                is_comment = true;
                break;
            }
        }
        if (is_comment) {
            try w.print("<span foreground=\"{s}\">", .{col_comment});
            try writeEscaped(w, chunk[i..]);
            try w.writeAll("</span>");
            return;
        }

        // Stringhe tra apici (senza escape multilinea: best effort)
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
            try w.print("<span foreground=\"{s}\">", .{col_string});
            try writeEscaped(w, chunk[i..stop]);
            try w.writeAll("</span>");
            i = stop;
            continue;
        }

        // Identificatori: keyword colorate, il resto neutro
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
                try w.print("<span foreground=\"{s}\" weight=\"600\">", .{col_keyword});
                try writeEscaped(w, word);
                try w.writeAll("</span>");
            } else {
                try writeEscaped(w, word);
            }
            i = end;
            continue;
        }

        try writeEscapedByte(w, c);
        i += 1;
    }
}

/// Converte un sottoinsieme di Markdown in markup Pango: header, grassetto,
/// corsivo, codice inline, blocchi recintati, liste puntate e link. Il testo
/// viene sempre escapato, quindi qualsiasi input è sicuro per il parser Pango.
fn mdToPango(gpa: std.mem.Allocator, md: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    var in_fence = false;
    var lines = std.mem.splitScalar(u8, md, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) {
            try w.writeAll("<span font_family=\"monospace\" foreground=\"#9ece6a\">");
            try writeEscaped(w, line);
            try w.writeAll("</span>\n");
            continue;
        }

        // Header: da # a ####, corpo decrescente
        var level: usize = 0;
        while (level < trimmed.len and level < 4 and trimmed[level] == '#') level += 1;
        if (level > 0 and level < trimmed.len and trimmed[level] == ' ') {
            const size = switch (level) {
                1 => "xx-large",
                2 => "x-large",
                else => "large",
            };
            try w.print("<span weight=\"bold\" size=\"{s}\">", .{size});
            try writeInline(w, trimmed[level + 1 ..]);
            try w.writeAll("</span>\n");
            continue;
        }

        // Liste puntate, conservando l'indentazione
        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            try w.splatByteAll(' ', line.len - trimmed.len);
            try w.writeAll("• ");
            try writeInline(w, trimmed[2..]);
            try w.writeAll("\n");
            continue;
        }

        try writeInline(w, line);
        try w.writeAll("\n");
    }

    return out.toOwnedSlice();
}

/// Markup inline: `codice`, **grassetto**, *corsivo* e [testo](url).
/// I marcatori senza chiusura vengono emessi letteralmente.
fn writeInline(w: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                try w.writeAll("<span font_family=\"monospace\" foreground=\"#9ece6a\">");
                try writeEscaped(w, text[i + 1 .. end]);
                try w.writeAll("</span>");
                i = end + 1;
                continue;
            }
        } else if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                try w.writeAll("<b>");
                try writeEscaped(w, text[i + 2 .. end]);
                try w.writeAll("</b>");
                i = end + 2;
                continue;
            }
        } else if (c == '*') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |end| {
                if (end > i + 1) {
                    try w.writeAll("<i>");
                    try writeEscaped(w, text[i + 1 .. end]);
                    try w.writeAll("</i>");
                    i = end + 1;
                    continue;
                }
            }
        } else if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close| {
                if (close + 1 < text.len and text[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |paren| {
                        try w.writeAll("<span foreground=\"#7aa2f7\" underline=\"single\">");
                        try writeEscaped(w, text[i + 1 .. close]);
                        try w.writeAll("</span>");
                        i = paren + 1;
                        continue;
                    }
                }
            }
        }
        try writeEscapedByte(w, c);
        i += 1;
    }
}

fn writeEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| try writeEscapedByte(w, c);
}

fn writeEscapedByte(w: *std.Io.Writer, c: u8) !void {
    switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    }
}

/// Formatta una tabella CSV come testo monospazio con colonne allineate.
fn formatTable(gpa: std.mem.Allocator, c: decoder_mod.CsvData) ![]u8 {
    const ncols = c.headers.len;
    if (ncols == 0) return gpa.dupe(u8, "(tabella vuota)");

    const widths = try gpa.alloc(usize, ncols);
    defer gpa.free(widths);
    for (c.headers, 0..) |h, i| widths[i] = @min(h.len, max_table_col);
    for (c.rows) |row| {
        for (row, 0..) |cell_text, i| {
            if (i >= ncols) break;
            widths[i] = @max(widths[i], @min(cell_text.len, max_table_col));
        }
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    try writeTableRow(w, c.headers, widths);
    for (widths, 0..) |wd, i| {
        try w.splatByteAll('-', wd);
        if (i + 1 < ncols) try w.writeAll("  ");
    }
    try w.writeAll("\n");
    for (c.rows) |row| {
        try writeTableRow(w, row, widths);
    }

    return out.toOwnedSlice();
}

fn writeTableRow(w: *std.Io.Writer, cells: []const []const u8, widths: []const usize) !void {
    for (widths, 0..) |wd, i| {
        const cell = if (i < cells.len) cells[i] else "";
        const shown = cell[0..@min(cell.len, wd)];
        try w.writeAll(shown);
        if (i + 1 < widths.len) {
            try w.splatByteAll(' ', wd - shown.len + 2);
        }
    }
    try w.writeAll("\n");
}
