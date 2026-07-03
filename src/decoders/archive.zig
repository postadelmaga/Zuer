const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;

/// Oltre questa soglia il listato viene troncato: mantiene istantanea
/// l'apertura di archivi con centinaia di migliaia di voci.
const max_entries: usize = 10_000;

pub fn decode(bytes: []const u8, allocator: std.mem.Allocator) Decoded {
    defer allocator.free(bytes);
    return decodeZip(bytes, allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Errore lettura archivio ZIP: {s}", .{@errorName(err)}) catch "Errore archivio";
        return .{ .err = msg };
    };
}

/// Legge la central directory ZIP direttamente dal buffer in memoria e produce
/// una tabella (stesso render dei CSV): nome, dimensione, compressa, metodo.
fn decodeZip(bytes: []const u8, allocator: std.mem.Allocator) !Decoded {
    // End of central directory: si cerca la signature dal fondo. Non si usa
    // std.zip.EndRecord.findBuffer perché in questa stdlib non compila
    // (ritorna error.EndOfStream fuori dal proprio error set).
    const end_pos = std.mem.lastIndexOf(u8, bytes, &std.zip.end_record_sig) orelse return error.ZipNoEndRecord;
    if (end_pos + 22 > bytes.len) return error.ZipTruncated;

    var entry_count: u64 = std.mem.readInt(u16, bytes[end_pos + 10 ..][0..2], .little);
    var cd_offset: u64 = std.mem.readInt(u32, bytes[end_pos + 16 ..][0..4], .little);

    if (entry_count == std.math.maxInt(u16) or cd_offset == std.math.maxInt(u32)) {
        // ZIP64: l'end record classico satura i campi, i valori reali sono nell'EndRecord64.
        const pos64 = std.mem.lastIndexOf(u8, bytes, &std.zip.end_record64_sig) orelse return error.Zip64RecordMissing;
        if (pos64 + 56 > bytes.len) return error.ZipTruncated;
        entry_count = std.mem.readInt(u64, bytes[pos64 + 32 ..][0..8], .little);
        cd_offset = std.mem.readInt(u64, bytes[pos64 + 48 ..][0..8], .little);
    }

    var rows = std.ArrayList([][]const u8).empty;
    errdefer {
        for (rows.items) |row| freeRow(allocator, row);
        rows.deinit(allocator);
    }

    var total_size: u64 = 0;
    var total_comp: u64 = 0;
    var listed: usize = 0;
    var pos = std.math.cast(usize, cd_offset) orelse return error.ZipTruncated;

    var i: u64 = 0;
    while (i < entry_count) : (i += 1) {
        if (pos + 46 > bytes.len) break;
        if (!std.mem.eql(u8, bytes[pos..][0..4], &std.zip.central_file_header_sig)) break;

        const method = std.mem.readInt(u16, bytes[pos + 10 ..][0..2], .little);
        var comp_size: u64 = std.mem.readInt(u32, bytes[pos + 20 ..][0..4], .little);
        var unc_size: u64 = std.mem.readInt(u32, bytes[pos + 24 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, bytes[pos + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, bytes[pos + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, bytes[pos + 32 ..][0..2], .little);

        const entry_end = pos + 46 + @as(usize, name_len) + extra_len + comment_len;
        if (entry_end > bytes.len) break;
        const name = bytes[pos + 46 ..][0..name_len];

        // Dimensioni saturate a 0xFFFFFFFF: i valori reali sono nell'extra field ZIP64 (id 0x0001).
        if (unc_size == std.math.maxInt(u32) or comp_size == std.math.maxInt(u32)) {
            var extra = bytes[pos + 46 + name_len ..][0..extra_len];
            while (extra.len >= 4) {
                const id = std.mem.readInt(u16, extra[0..2], .little);
                const sz = std.mem.readInt(u16, extra[2..4], .little);
                if (4 + @as(usize, sz) > extra.len) break;
                if (id == 0x0001) {
                    var f = extra[4 .. 4 + sz];
                    if (unc_size == std.math.maxInt(u32) and f.len >= 8) {
                        unc_size = std.mem.readInt(u64, f[0..8], .little);
                        f = f[8..];
                    }
                    if (comp_size == std.math.maxInt(u32) and f.len >= 8) {
                        comp_size = std.mem.readInt(u64, f[0..8], .little);
                    }
                    break;
                }
                extra = extra[4 + sz ..];
            }
        }

        total_size += unc_size;
        total_comp += comp_size;

        if (listed < max_entries) {
            const row = try makeRow(allocator, name, unc_size, comp_size, methodName(method, name));
            try rows.append(allocator, row);
            listed += 1;
        }

        pos = entry_end;
    }

    if (i < entry_count and listed < max_entries) return error.ZipCentralDirectoryCorrupt;

    if (i > listed) {
        const note = try std.fmt.allocPrint(allocator, "… altre {d} voci", .{i - listed});
        errdefer allocator.free(note);
        const row = try makeRawRow(allocator, note, "", "", "");
        try rows.append(allocator, row);
    }

    {
        const label = try std.fmt.allocPrint(allocator, "TOTALE ({d} voci)", .{i});
        errdefer allocator.free(label);
        const size_str = try formatSize(allocator, total_size);
        errdefer allocator.free(size_str);
        const comp_str = try formatSize(allocator, total_comp);
        errdefer allocator.free(comp_str);
        const row = try makeRawRow(allocator, label, size_str, comp_str, "");
        try rows.append(allocator, row);
    }

    var headers = try allocator.alloc([]const u8, 4);
    errdefer allocator.free(headers);
    headers[0] = try allocator.dupe(u8, "Nome");
    headers[1] = try allocator.dupe(u8, "Dimensione");
    headers[2] = try allocator.dupe(u8, "Compressa");
    headers[3] = try allocator.dupe(u8, "Metodo");

    return .{ .csv = .{
        .headers = headers,
        .rows = try rows.toOwnedSlice(allocator),
    } };
}

fn makeRow(allocator: std.mem.Allocator, name: []const u8, size: u64, comp: u64, method: []const u8) ![][]const u8 {
    const size_str = try formatSize(allocator, size);
    errdefer allocator.free(size_str);
    const comp_str = try formatSize(allocator, comp);
    errdefer allocator.free(comp_str);
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const method_dup = try allocator.dupe(u8, method);
    errdefer allocator.free(method_dup);

    const row = try allocator.alloc([]const u8, 4);
    row[0] = name_dup;
    row[1] = size_str;
    row[2] = comp_str;
    row[3] = method_dup;
    return row;
}

/// Come makeRow ma con celle già formattate; `label` è adottato (non duplicato).
fn makeRawRow(allocator: std.mem.Allocator, label: []const u8, c1: []const u8, c2: []const u8, c3: []const u8) ![][]const u8 {
    const d1 = if (c1.len == 0) try allocator.dupe(u8, "") else c1;
    const d2 = if (c2.len == 0) try allocator.dupe(u8, "") else c2;
    const d3 = try allocator.dupe(u8, c3);
    errdefer allocator.free(d3);

    const row = try allocator.alloc([]const u8, 4);
    row[0] = label;
    row[1] = d1;
    row[2] = d2;
    row[3] = d3;
    return row;
}

fn freeRow(allocator: std.mem.Allocator, row: [][]const u8) void {
    for (row) |cell| allocator.free(cell);
    allocator.free(row);
}

fn methodName(method: u16, name: []const u8) []const u8 {
    if (name.len > 0 and name[name.len - 1] == '/') return "cartella";
    return switch (method) {
        0 => "store",
        8 => "deflate",
        9 => "deflate64",
        12 => "bzip2",
        14 => "lzma",
        93 => "zstd",
        95 => "xz",
        99 => "aes",
        else => "?",
    };
}

fn formatSize(allocator: std.mem.Allocator, n: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1024.0 and u < units.len - 1) : (u += 1) v /= 1024.0;
    if (u == 0) return std.fmt.allocPrint(allocator, "{d} B", .{n});
    return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ v, units[u] });
}

export fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = path;
    _ = io_ptr;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;

    const decoded = decode(content.toSlice(), allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

const extensions = "zip,jar,apk,cbz,epub,xpi,whl";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}
