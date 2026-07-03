//! Rasterizza contenuti testuali (text, markdown, tabelle CSV) in immagini RGB
//! usando ImageMagick per una resa tipografica anti-alias ad alta definizione
//! (con DejaVu Sans per markdown, e DejaVu Sans Mono per CSV e codice).

const std = @import("std");
const decoder_mod = @import("decoder.zig");

pub const max_table_col: usize = 40;

/// Parametri di rasterizzazione: larghezza in pixel dell'immagine prodotta
/// (idealmente la larghezza della finestra, per una resa 1:1 nitida) e corpo
/// del carattere (scalato dallo zoom del chiamante).
pub const RenderOpts = struct {
    width: usize = 1024,
    pointsize: usize = 15,
};

/// Rasterizza un contenuto decodificato testuale in un'immagine RGB.
pub fn render(gpa: std.mem.Allocator, io: std.Io, decoded: *const decoder_mod.Decoded, name: []const u8, opts: RenderOpts) !decoder_mod.ImageData {
    switch (decoded.*) {
        .text => |t| return renderText(gpa, io, t, name, true, false, opts),
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
    var size_arg_buf: [24]u8 = undefined;
    const size_arg = try std.fmt.bufPrint(&size_arg_buf, "{d}x", .{opts.width});
    var pointsize_buf: [16]u8 = undefined;
    const pointsize_arg = try std.fmt.bufPrint(&pointsize_buf, "{d}", .{opts.pointsize});

    // 1. Rileva le dimensioni finali dell'immagine tipografica generata da ImageMagick
    const size_result = try std.process.run(gpa, io, .{
        .argv = &.{
            "convert",
            "-depth",
            "8",
            "-background",
            "#080810",
            "-fill",
            "#e6e6e6",
            "-define",
            markup_def,
            "-size",
            size_arg,
            "-font",
            font_name,
            "-pointsize",
            pointsize_arg,
            "-gravity",
            "NorthWest",
            pango_path,
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
            "-background",
            "#080810",
            "-fill",
            "#e6e6e6",
            "-define",
            markup_def,
            "-size",
            size_arg,
            "-font",
            font_name,
            "-pointsize",
            pointsize_arg,
            "-gravity",
            "NorthWest",
            pango_path,
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
