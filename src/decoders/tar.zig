//! Decoder di archivi tar e tar.gz/tgz. Lavora dal PATH senza caricare il file:
//! itera solo gli header 512B con `std.tar.Iterator`. Per il tar NON compresso il
//! reader posizionale salta i dati di ogni entry con un seek (discard = avanzamento
//! della posizione, nessuna lettura) → listato istantaneo anche su archivi da GB.
//! Per tar.gz/tgz serve una passata di decompressione (nessun seek possibile nello
//! stream compresso), ma a memoria costante: si leggono gli header e si scartano i
//! dati. Il formato compresso è riconosciuto dai magic byte (0x1f 0x8b), non
//! dall'estensione, così anche un `.tar` gzippato viene gestito.

const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;

/// Oltre questa soglia il listato viene troncato: mantiene istantanea l'apertura
/// di archivi con moltissime voci (per tar.gz limita anche la decompressione).
const max_entries: usize = 10_000;

pub fn decode(path: []const u8, io: std.Io, allocator: std.mem.Allocator) Decoded {
    var clean_path = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| clean_path = path[0..h];
    return decodeTar(clean_path, io, allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Errore lettura archivio tar: {s}", .{@errorName(err)}) catch "Errore archivio";
        return .{ .err = msg };
    };
}

fn decodeTar(path: []const u8, io: std.Io, allocator: std.mem.Allocator) !Decoded {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var rbuf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &rbuf);

    // Sniff dei magic byte gzip: robusto rispetto all'estensione.
    var magic: [2]u8 = .{ 0, 0 };
    _ = try file.readPositionalAll(io, &magic, 0);
    const is_gzip = magic[0] == 0x1f and magic[1] == 0x8b;

    if (is_gzip) {
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var dec = std.compress.flate.Decompress.init(&reader.interface, .gzip, &window);
        return listFromTar(&dec.reader, allocator);
    }
    return listFromTar(&reader.interface, allocator);
}

/// Itera gli header tar dallo stream `src` (file grezzo o output gzip) e produce
/// la tabella Nome/Dimensione/Compressa/Metodo.
fn listFromTar(src: *std.Io.Reader, allocator: std.mem.Allocator) !Decoded {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(src, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    var rows = std.ArrayList([][]const u8).empty;
    errdefer {
        for (rows.items) |row| freeRow(allocator, row);
        rows.deinit(allocator);
    }

    var total_size: u64 = 0;
    var count: u64 = 0;
    var truncated = false;

    while (true) {
        const entry = it.next() catch |err| {
            // Stream troncato/entry insolita: se abbiamo già voci mostriamo il
            // parziale, altrimenti propaghiamo l'errore.
            if (count == 0) return err;
            truncated = true;
            break;
        } orelse break;

        total_size += entry.size;

        if (count < max_entries) {
            const row = try makeRow(allocator, entry.name, entry.size, kindLabel(entry.kind));
            try rows.append(allocator, row);
        } else {
            // Superato il tetto: fermiamo la scansione per restare istantanei
            // (soprattutto su tar.gz, dove ogni entry costa decompressione).
            truncated = true;
            break;
        }
        count += 1;
    }

    if (truncated) {
        const note = try makeRawRow(allocator, try allocator.dupe(u8, "… elenco troncato"), "", "");
        try rows.append(allocator, note);
    }

    {
        const label = if (truncated)
            try std.fmt.allocPrint(allocator, "TOTALE (≥ {d} voci)", .{count})
        else
            try std.fmt.allocPrint(allocator, "TOTALE ({d} voci)", .{count});
        errdefer allocator.free(label);
        const size_str = try formatSize(allocator, total_size);
        errdefer allocator.free(size_str);
        const row = try makeRawRow(allocator, label, size_str, "");
        try rows.append(allocator, row);
    }

    var headers = try allocator.alloc([]const u8, 4);
    errdefer allocator.free(headers);
    headers[0] = try allocator.dupe(u8, "Nome");
    headers[1] = try allocator.dupe(u8, "Dimensione");
    headers[2] = try allocator.dupe(u8, "Compressa");
    headers[3] = try allocator.dupe(u8, "Tipo");

    return .{ .csv = .{
        .headers = headers,
        .rows = try rows.toOwnedSlice(allocator),
    } };
}

fn kindLabel(k: std.tar.FileKind) []const u8 {
    return switch (k) {
        .directory => "cartella",
        .sym_link => "link",
        .file => "file",
    };
}

/// Riga di una entry: Nome, Dimensione, Compressa ("—": il tar non comprime per
/// entry), Tipo.
fn makeRow(allocator: std.mem.Allocator, name: []const u8, size: u64, kind: []const u8) ![][]const u8 {
    const size_str = try formatSize(allocator, size);
    errdefer allocator.free(size_str);
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const dash = try allocator.dupe(u8, "—");
    errdefer allocator.free(dash);
    const kind_dup = try allocator.dupe(u8, kind);
    errdefer allocator.free(kind_dup);

    const row = try allocator.alloc([]const u8, 4);
    row[0] = name_dup;
    row[1] = size_str;
    row[2] = dash;
    row[3] = kind_dup;
    return row;
}

/// Riga con celle già formattate; `label` è adottato (non duplicato).
fn makeRawRow(allocator: std.mem.Allocator, label: []const u8, c1: []const u8, c3: []const u8) ![][]const u8 {
    const d1 = if (c1.len == 0) try allocator.dupe(u8, "") else c1;
    errdefer if (c1.len == 0) allocator.free(d1);
    const d2 = try allocator.dupe(u8, "");
    errdefer allocator.free(d2);
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

const extensions = "tar,tgz,tar.gz";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// Come archive.zig: si legge dal path in streaming, nessun byte caricato dall'host.
export fn zuer_content_prefix() callconv(.c) usize {
    return 0;
}

export fn zuer_abi_version() callconv(.c) u32 {
    return decoder.abi_version;
}
