//! Rasterizza contenuti testuali (text, markdown, tabelle CSV) in immagini RGB
//! usando ImageMagick per una resa tipografica anti-alias ad alta definizione
//! (con DejaVu Sans per markdown, e DejaVu Sans Mono per CSV e codice).

const std = @import("std");
const decoder_mod = @import("decoder.zig");

pub const max_table_col: usize = 40;

/// Rasterizza un contenuto decodificato testuale in un'immagine RGB.
pub fn render(gpa: std.mem.Allocator, io: std.Io, decoded: *const decoder_mod.Decoded, name: []const u8) !decoder_mod.ImageData {
    switch (decoded.*) {
        .text => |t| return renderText(gpa, io, t, name, true),
        .markdown => |m| return renderText(gpa, io, m.content, name, false),
        .csv => |c| {
            const table = try formatTable(gpa, c);
            defer gpa.free(table);
            return renderText(gpa, io, table, name, true);
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
extern fn fclose(stream: ?*anyopaque) c_int;
extern fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: ?*anyopaque) usize;
extern fn unlink(filename: [*:0]const u8) c_int;

fn renderText(gpa: std.mem.Allocator, io: std.Io, content: []const u8, name: []const u8, is_mono: bool) !decoder_mod.ImageData {
    const us = getMicroseconds();
    var tmp_filename: [64]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_filename, "/tmp/zuer_txt_{d}.txt", .{us});
    tmp_filename[tmp_path.len] = 0;

    const path_c = @as([*:0]const u8, @ptrCast(tmp_path.ptr));
    const file_ptr = fopen(path_c, "wb") orelse return error.CreateFileFailed;
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

    // 1. Rileva le dimensioni finali dell'immagine tipografica generata da ImageMagick
    const size_result = try std.process.run(gpa, io, .{
        .argv = &.{
            "convert",
            "-background",
            "#080810",
            "-fill",
            "#e6e6e6",
            "-define",
            "pango:markup=false",
            "-size",
            "1024x",
            "-font",
            font_name,
            "-pointsize",
            "15",
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
            "-background",
            "#080810",
            "-fill",
            "#e6e6e6",
            "-define",
            "pango:markup=false",
            "-size",
            "1024x",
            "-font",
            font_name,
            "-pointsize",
            "15",
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
    return .{
        .width = width,
        .height = height,
        .pixels = convert_result.stdout[0..expected_bytes],
        .name = name_dup,
    };
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
