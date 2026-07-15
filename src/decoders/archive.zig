const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;

/// Oltre questa soglia il listato viene troncato: mantiene istantanea
/// l'apertura di archivi con centinaia di migliaia di voci.
const max_entries: usize = 10_000;

/// La central directory è proporzionale al NUMERO di voci, non ai dati compressi.
/// 256 MiB coprono qualche milione di entry: oltre, si legge solo questo prefisso
/// della CD (il conteggio totale resta esatto, dall'EOCD). Così un archivio da
/// molti GB si apre leggendo solo la coda + la CD, mai i dati.
const max_cd_bytes: u64 = 256 * 1024 * 1024;

/// Decodifica lavorando dal PATH (mai caricando l'intero file): individua la
/// central directory con il seeking dello stdlib e ne legge solo i byte.
pub fn decode(path: []const u8, io: std.Io, allocator: std.mem.Allocator) Decoded {
    var clean_path = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| clean_path = path[0..h];
    return decodeZip(clean_path, io, allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Errore lettura archivio ZIP: {s}", .{@errorName(err)}) catch "Errore archivio";
        return .{ .err = msg };
    };
}

fn decodeZip(path: []const u8, io: std.Io, allocator: std.mem.Allocator) !Decoded {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var rbuf: [8192]u8 = undefined;
    var reader = file.reader(io, &rbuf);

    // Individua la central directory (EOCD classico o ZIP64) col seeking dello
    // stdlib — nessun caricamento del file. Servono solo posizione, dimensione e
    // conteggio; l'iterazione vera e propria la fa il parser lenient sotto, che
    // gestisce anche entry cifrate/insolite senza abortire tutto il listato.
    const iter = try std.zip.Iterator.init(&reader);
    const entry_count: u64 = iter.cd_record_count;
    const cd_offset: u64 = iter.cd_zip_offset;
    const cd_total: u64 = iter.cd_size;

    // Legge SOLO la central directory (con tetto): proporzionale alle voci.
    const cd_read: usize = @intCast(@min(cd_total, max_cd_bytes));
    const cd = try allocator.alloc(u8, cd_read);
    defer allocator.free(cd);
    try reader.seekTo(cd_offset);
    reader.interface.readSliceAll(cd) catch |err| switch (err) {
        // Coda troncata rispetto a quanto dichiarato dall'EOCD: si parsa quel che c'è.
        error.EndOfStream => {},
        else => return error.ZipReadFailed,
    };

    return listFromCd(cd, entry_count, allocator);
}

/// Parsa la central directory (buffer che inizia esattamente a `cd_offset`) e
/// produce la tabella. `entry_count` è il totale reale dall'EOCD: se il buffer è
/// troncato dal tetto `max_cd_bytes` si mostra comunque il conteggio corretto.
fn listFromCd(cd: []const u8, entry_count: u64, allocator: std.mem.Allocator) !Decoded {
    var rows = std.ArrayList([][]const u8).empty;
    errdefer {
        for (rows.items) |row| freeRow(allocator, row);
        rows.deinit(allocator);
    }

    var total_size: u64 = 0;
    var total_comp: u64 = 0;
    var listed: usize = 0;
    var pos: usize = 0;

    var i: u64 = 0;
    while (i < entry_count) : (i += 1) {
        if (pos + 46 > cd.len) break;
        if (!std.mem.eql(u8, cd[pos..][0..4], &std.zip.central_file_header_sig)) break;

        const method = std.mem.readInt(u16, cd[pos + 10 ..][0..2], .little);
        var comp_size: u64 = std.mem.readInt(u32, cd[pos + 20 ..][0..4], .little);
        var unc_size: u64 = std.mem.readInt(u32, cd[pos + 24 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, cd[pos + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, cd[pos + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, cd[pos + 32 ..][0..2], .little);

        const entry_end = pos + 46 + @as(usize, name_len) + extra_len + comment_len;
        if (entry_end > cd.len) break;
        const name = cd[pos + 46 ..][0..name_len];

        // Dimensioni saturate a 0xFFFFFFFF: i valori reali sono nell'extra field ZIP64 (id 0x0001).
        if (unc_size == std.math.maxInt(u32) or comp_size == std.math.maxInt(u32)) {
            var extra = cd[pos + 46 + name_len ..][0..extra_len];
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

    // Voci non mostrate = totale reale (EOCD) meno quelle elencate. Conta sia le
    // saltate per il tetto `max_entries`, sia quelle oltre il prefisso di CD letto
    // (`i` si ferma al buffer): `i - listed` da solo le ometterebbe.
    if (entry_count > listed) {
        const note = try std.fmt.allocPrint(allocator, "… altre {d} voci", .{entry_count - listed});
        errdefer allocator.free(note);
        const row = try makeRawRow(allocator, note, "", "", "");
        try rows.append(allocator, row);
    }

    {
        const label = try std.fmt.allocPrint(allocator, "TOTALE ({d} voci)", .{entry_count});
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

fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    const io = @as(*const std.Io, @ptrCast(@alignCast(io_ptr))).*;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    // Path-based (`zuer_content_prefix = 0`): l'host non ha caricato il file, ma
    // per contratto il plugin libera comunque `content` (qui vuoto).
    allocator.free(content.toSlice());

    const decoded = decode(path.toSlice(), io, allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

const extensions = "zip,jar,apk,cbz,epub,xpi,whl";

fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// L'archivio si legge dal path via seeking (coda EOCD + sola central directory):
/// l'host non deve caricare in RAM alcun byte del contenuto. Così anche archivi
/// da molti GB si aprono istantaneamente.
fn zuer_content_prefix() callconv(.c) usize {
    return 0;
}

/// Versione dell'ABI plugin con cui questo decoder è compilato: l'host la
/// confronta con la propria `decoder.abi_version` e scarta i mismatch.
fn zuer_abi_version() callconv(.c) u32 {
    return decoder.abi_version;
}

// Gli export dell'ABI plugin esistono solo dove i decoder SONO plugin (vedi
// decoder.plugin_abi): su Android sono linkati dentro l'unica libreria dell'APK e i loro
// nomi colliderebbero.
comptime {
    if (decoder.plugin_abi) {
        @export(&zuer_decode, .{ .name = "zuer_decode", .linkage = .strong });
        @export(&zuer_extensions, .{ .name = "zuer_extensions", .linkage = .strong });
        @export(&zuer_content_prefix, .{ .name = "zuer_content_prefix", .linkage = .strong });
        @export(&zuer_abi_version, .{ .name = "zuer_abi_version", .linkage = .strong });
    }
}
