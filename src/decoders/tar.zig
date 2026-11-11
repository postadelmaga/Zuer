//! Decoder di archivi tar e tar.gz/tgz. Lavora dal PATH senza caricare il file:
//! itera solo gli header 512B con `std.tar.Iterator`. Per il tar NON compresso il
//! reader posizionale salta i dati di ogni entry con un seek (discard = avanzamento
//! della posizione, nessuna lettura) → listato istantaneo anche su archivi da GB.
//! Per tar.gz/tgz serve una passata di decompressione (nessun seek possibile nello
//! stream compresso), ma a memoria costante: si leggono gli header e si scartano i
//! dati. Il formato compresso è riconosciuto dai magic byte (0x1f 0x8b), non
//! dall'estensione, così anche un `.tar` gzippato viene gestito.
//!
//! Tutto il resto (7z, RAR, tar.xz/bz2/zst, ISO, CAB, CPIO, XAR/pkg, RPM, LHA) lo
//! elenca il `tar` di sistema quando è bsdtar (libarchive): `/usr/bin/tar` su
//! macOS, `System32\tar.exe` su Windows 10+, `bsdtar` su Linux se installato.
//! Si legge `bsdtar -tv`: elenca dagli header senza decomprimere i dati (un 7z
//! solido o una ISO da GB si aprono subito).

const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;

/// Oltre questa soglia il listato viene troncato: mantiene istantanea l'apertura
/// di archivi con moltissime voci (per tar.gz limita anche la decompressione).
const max_entries: usize = 10_000;

const builtin = @import("builtin");

pub fn decode(path: []const u8, io: std.Io, allocator: std.mem.Allocator) Decoded {
    var clean_path = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| clean_path = path[0..h];
    return decodeTar(clean_path, io, allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Errore lettura archivio tar: {s}", .{@errorName(err)}) catch "";
        return .{ .err = msg };
    };
}

fn decodeTar(path: []const u8, io: std.Io, allocator: std.mem.Allocator) !Decoded {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var rbuf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &rbuf);

    // Sniff dei magic byte: robusto rispetto all'estensione.
    var head: [263]u8 = @splat(0);
    const n_head = try file.readPositionalAll(io, &head, 0);
    const is_gzip = head[0] == 0x1f and head[1] == 0x8b;
    const is_ustar = n_head >= 262 and std.mem.eql(u8, head[257..262], "ustar");
    // tar.zst e tar.xz in processo (la std ha i decompressori): il bsdtar di macOS
    // è compilato senza zstd. Se il contenuto non è un tar (o la finestra zstd
    // supera 8 MiB) si ripiega comunque su bsdtar.
    if (std.mem.eql(u8, head[0..4], "\x28\xb5\x2f\xfd")) {
        const zstd = std.compress.zstd;
        const buf = try allocator.alloc(u8, zstd.default_window_len + zstd.block_size_max);
        defer allocator.free(buf);
        var dec = zstd.Decompress.init(&reader.interface, buf, .{});
        return listFromTar(&dec.reader, allocator) catch listWithBsdtar(path, allocator);
    }
    if (std.mem.eql(u8, head[0..6], "\xfd7zXZ\x00")) {
        var dec = std.compress.xz.Decompress.init(&reader.interface, allocator, &.{}) catch
            return listWithBsdtar(path, allocator);
        defer dec.deinit();
        return listFromTar(&dec.reader, allocator) catch listWithBsdtar(path, allocator);
    }
    // Il tar v7 non ha la firma `ustar`: per quello conta l'estensione.
    if (!is_gzip and !is_ustar and !endsWithIgnoreCase(path, ".tar")) return listWithBsdtar(path, allocator);

    if (is_gzip) {
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var dec = std.compress.flate.Decompress.init(&reader.interface, .gzip, &window);
        return listFromTar(&dec.reader, allocator);
    }
    return listFromTar(&reader.interface, allocator);
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

extern "kernel32" fn GetSystemDirectoryA(buf: [*]u8, size: u32) callconv(.winapi) u32;

/// Elenco via bsdtar (vedi il commento del file). Stesse colonne del ramo tar.
fn listWithBsdtar(path: []const u8, allocator: std.mem.Allocator) !Decoded {
    var exe_buf: [260]u8 = undefined;
    const exe: []const u8 = switch (builtin.os.tag) {
        .macos => "/usr/bin/tar",
        // Percorso assoluto: col solo nome `CreateProcessW` cercherebbe prima nella
        // cartella dell'eseguibile e in quella corrente.
        .windows => blk: {
            const n = GetSystemDirectoryA(&exe_buf, exe_buf.len - 9);
            if (n == 0 or n >= exe_buf.len - 9) return error.BsdtarNotFound;
            @memcpy(exe_buf[n..][0..8], "\\tar.exe");
            break :blk exe_buf[0 .. n + 8];
        },
        else => "bsdtar",
    };
    var run = decoder.runCapture(allocator, &.{ exe, "-tvf", path }) catch |e| switch (e) {
        error.CommandNotFound => return .{ .err = try allocator.dupe(u8, if (builtin.os.tag == .linux)
            "Archivio non leggibile: serve bsdtar (pacchetto libarchive-tools o libarchive)"
        else
            "Archivio non leggibile: tar di sistema (bsdtar) non trovato") },
        else => return e,
    };
    defer run.deinit(allocator);
    if (run.exit_code != 0 and run.stdout.len == 0)
        return .{ .err = try allocator.dupe(u8, "Formato d'archivio non supportato o archivio danneggiato (bsdtar)") };
    return listFromBsdtar(run.stdout, allocator);
}

/// Righe di `bsdtar -tv` → tabella. Formato fisso di bsdtar (stesso su macOS,
/// Windows e Linux, a ogni versione): modo, nlink, utente, gruppo, dimensione, tre
/// campi di data (in qualunque lingua: sono comunque tre parole), poi il nome fino a
/// fine riga, con ` -> destinazione` per i link simbolici.
fn listFromBsdtar(text: []const u8, allocator: std.mem.Allocator) !Decoded {
    var rows = std.ArrayList([][]const u8).empty;
    errdefer {
        for (rows.items) |row| freeRow(allocator, row);
        rows.deinit(allocator);
    }
    var total_size: u64 = 0;
    var count: u64 = 0;
    var truncated = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const e = parseBsdtarLine(line) orelse continue;
        if (e.name.len == 0 or std.mem.eql(u8, e.name, ".")) continue;
        total_size += e.size;
        count += 1;
        if (count > max_entries) {
            truncated = true;
            continue;
        }
        const name = try unescapeBsdtar(allocator, e.name);
        defer allocator.free(name);
        try rows.append(allocator, try makeRow(allocator, name, e.size, e.kind));
    }
    if (count == 0) return .{ .err = try allocator.dupe(u8, "Archivio vuoto o non leggibile") };
    if (truncated) {
        const note = try makeRawRow(allocator, try allocator.dupe(u8, "… elenco troncato"), "", "");
        try rows.append(allocator, note);
    }
    {
        const label = try std.fmt.allocPrint(allocator, "TOTALE ({d} voci)", .{count});
        errdefer allocator.free(label);
        const size_str = try formatSize(allocator, total_size);
        errdefer allocator.free(size_str);
        try rows.append(allocator, try makeRawRow(allocator, label, size_str, ""));
    }
    var headers = try allocator.alloc([]const u8, 4);
    errdefer allocator.free(headers);
    headers[0] = try allocator.dupe(u8, "Nome");
    headers[1] = try allocator.dupe(u8, "Dimensione");
    headers[2] = try allocator.dupe(u8, "Compressa");
    headers[3] = try allocator.dupe(u8, "Tipo");
    return .{ .csv = .{ .headers = headers, .rows = try rows.toOwnedSlice(allocator) } };
}

const BsdtarEntry = struct { name: []const u8, size: u64, kind: []const u8 };

/// Una riga di `bsdtar -tv`; null se non ha la forma attesa (avvisi, righe vuote).
fn parseBsdtarLine(line: []const u8) ?BsdtarEntry {
    var pos: usize = 0;
    var fields: [8][]const u8 = undefined;
    for (&fields) |*f| {
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
        const start = pos;
        while (pos < line.len and line[pos] != ' ' and line[pos] != '\t') pos += 1;
        if (pos == start) return null;
        f.* = line[start..pos];
    }
    const mode = fields[0];
    if (mode.len != 10) return null;
    const size = std.fmt.parseInt(u64, fields[4], 10) catch return null;
    if (pos >= line.len) return null;
    var name = line[pos + 1 ..]; // un solo spazio separa la data dal nome
    if (mode[0] == 'l') {
        if (std.mem.indexOf(u8, name, " -> ")) |arrow| name = name[0..arrow];
    }
    if (std.mem.startsWith(u8, name, "./")) name = name[2..];
    if (name.len > 1 and name[name.len - 1] == '/') name = name[0 .. name.len - 1];
    return .{
        .name = name,
        .size = size,
        .kind = switch (mode[0]) {
            'd' => "cartella",
            'l' => "link",
            else => "file",
        },
    };
}

/// bsdtar stampa `\\` per la barra rovescia e `\ooo` ottale per i byte che il locale
/// non sa stampare (un'app aperta dal Finder gira in locale C: ogni byte non ASCII).
fn unescapeBsdtar(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and isOctal(s, i + 1)) {
            const v = (@as(u16, s[i + 1] - '0') << 6) | (@as(u16, s[i + 2] - '0') << 3) | (s[i + 3] - '0');
            out.appendAssumeCapacity(@truncate(v));
            i += 3;
        } else if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == '\\') {
            out.appendAssumeCapacity('\\');
            i += 1;
        } else out.appendAssumeCapacity(s[i]);
    }
    return out.toOwnedSlice(allocator);
}

fn isOctal(s: []const u8, at: usize) bool {
    if (at + 3 > s.len) return false;
    for (s[at..][0..3]) |c| if (c < '0' or c > '7') return false;
    return true;
}

test "bsdtar -tv: tipi, dimensioni, nomi con spazi, link, escape, date localizzate" {
    const a = std.testing.allocator;
    const text =
        \\drwxr-xr-x  0 0      0           0 nov 11 12:13 ./
        \\lrwxrwxrwx  0 0      0           0 nov 11 12:13 ./link -> a b.txt
        \\-rw-r--r--  0 0      0           5 nov 11 12:13 ./a b.txt
        \\drwxr-xr-x  2 1000   1000        0 11 Nov 12:13 ./sotto/
        \\-rw-r--r--  1 fra    staff    2048 Jan  1  2024 sotto/caff\303\250 \\ x.bin
        \\bsdtar: avviso qualunque
        \\
    ;
    var d = try listFromBsdtar(text, a);
    defer d.deinit(a);
    const rows = d.csv.rows;
    try std.testing.expectEqual(@as(usize, 5), rows.len); // 4 voci + totale
    try std.testing.expectEqualStrings("link", rows[0][0]);
    try std.testing.expectEqualStrings("link", rows[0][3]);
    try std.testing.expectEqualStrings("a b.txt", rows[1][0]);
    try std.testing.expectEqualStrings("5 B", rows[1][1]);
    try std.testing.expectEqualStrings("sotto", rows[2][0]);
    try std.testing.expectEqualStrings("cartella", rows[2][3]);
    try std.testing.expectEqualStrings("sotto/caffè \\ x.bin", rows[3][0]);
    try std.testing.expectEqualStrings("2.0 KiB", rows[3][1]);
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
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

/// Le ultime voci passano da bsdtar (vedi il commento del file). Stessa lista del
/// manifest in decoder.zig.
pub const extensions = "tar,tgz,tar.gz,7z,rar,xz,txz,bz2,tbz,tbz2,zst,tzst,lz,lzma,tlz,iso,cab,cpio,xar,pkg,rpm,lha,lzh";

fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// Come archive.zig: si legge dal path in streaming, nessun byte caricato dall'host.
fn zuer_content_prefix() callconv(.c) usize {
    return 0;
}

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
