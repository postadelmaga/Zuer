//! Dove trovare yt-dlp e cosa dire quando manca.
//!
//! Su macOS un'app aperta dal Finder ha PATH=/usr/bin:/bin:/usr/sbin:/sbin: yt-dlp
//! installato con Homebrew (/opt/homebrew/bin, /usr/local/bin) o MacPorts non si
//! vede. Per questo, oltre al PATH, si guardano le cartelle d'installazione note e
//! quella dell'eseguibile (dove si può copiare il binario scaricato). Si cerca a
//! ogni uso, non una volta sola: chi lo installa con l'app aperta non deve riavviarla.

const std = @import("std");
const builtin = @import("builtin");
const vtcache = @import("vtcache.zig");

const is_win = builtin.os.tag == .windows;
const is_mac = builtin.os.tag == .macos;

/// Pagina di download (binari per Windows, macOS e Linux).
pub const download_url = "https://github.com/yt-dlp/yt-dlp/releases/latest";

/// Messaggio per l'overlay quando yt-dlp non si trova: come installarlo su questo
/// OS. Il link è a parte (`download_url`): l'overlay lo mostra e lo apre al clic.
pub const missing_msg = switch (builtin.os.tag) {
    .macos => "yt-dlp non trovato: brew install yt-dlp, oppure scaricalo (clic qui)",
    .windows => "yt-dlp non trovato: winget install yt-dlp, oppure scaricalo (clic qui)",
    else => "yt-dlp non trovato: installa il pacchetto yt-dlp, oppure scaricalo (clic qui)",
};

/// Nomi dell'eseguibile, in ordine. `yt-dlp_macos` è il nome del binario
/// universale nelle release: chi lo scarica e non lo rinomina va trovato lo stesso.
const names: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{"yt-dlp.exe"},
    .macos => &.{ "yt-dlp", "yt-dlp_macos" },
    else => &.{"yt-dlp"},
};

/// Cartelle fisse dopo il PATH (relative = sotto HOME o LOCALAPPDATA).
const fixed_dirs: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{ "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "~/.local/bin" },
    .windows => &.{"~\\Microsoft\\WinGet\\Links"},
    else => &.{ "~/.local/bin", "/usr/local/bin" },
};

/// Percorso assoluto di yt-dlp (posseduto dal chiamante), o null se non c'è.
/// `ZUER_YTDLP` lo impone; poi la cartella dell'eseguibile, il PATH e le cartelle note.
pub fn find(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (vtcache.getEnvAlloc(gpa, "ZUER_YTDLP")) |p| {
        if (isExecutable(io, p)) return p;
        gpa.free(p);
    }
    if (std.process.executableDirPathAlloc(io, gpa)) |dir| {
        defer gpa.free(dir);
        if (inDir(gpa, io, dir)) |p| return p;
    } else |_| {}
    if (vtcache.getEnvAlloc(gpa, "PATH")) |path| {
        defer gpa.free(path);
        var it = std.mem.tokenizeScalar(u8, path, if (is_win) ';' else ':');
        while (it.next()) |dir| {
            if (inDir(gpa, io, dir)) |p| return p;
        }
    }
    const home = vtcache.getEnvAlloc(gpa, if (is_win) "LOCALAPPDATA" else "HOME");
    defer if (home) |h| gpa.free(h);
    for (fixed_dirs) |d| {
        if (d[0] == '~') {
            const h = home orelse continue;
            const dir = std.fmt.allocPrint(gpa, "{s}{s}", .{ h, d[1..] }) catch continue;
            defer gpa.free(dir);
            if (inDir(gpa, io, dir)) |p| return p;
        } else if (inDir(gpa, io, d)) |p| return p;
    }
    return null;
}

fn inDir(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) return null;
    for (names) |n| {
        const p = std.fs.path.join(gpa, &.{ dir, n }) catch return null;
        if (isExecutable(io, p)) return p;
        gpa.free(p);
    }
    return null;
}

fn isExecutable(io: std.Io, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    // Su Windows "eseguibile" è l'estensione: basta che il file esista.
    std.Io.Dir.accessAbsolute(io, path, .{ .execute = !is_win }) catch return false;
    return true;
}

test "find: ZUER_YTDLP e cartelle note" {
    if (is_win) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);

    // Un file non eseguibile non conta.
    try tmp.dir.writeFile(io, .{ .sub_path = "yt-dlp", .data = "#!/bin/sh\n" });
    try std.testing.expect(inDir(gpa, io, dir) == null);

    var f = try tmp.dir.openFile(io, "yt-dlp", .{ .mode = .read_write });
    try f.setPermissions(io, .fromMode(0o755));
    f.close(io);
    const p = inDir(gpa, io, dir) orelse return error.TestUnexpectedResult;
    defer gpa.free(p);
    try std.testing.expect(std.mem.endsWith(u8, p, "/yt-dlp"));

    // Percorsi relativi e cartelle vuote del PATH non si usano.
    try std.testing.expect(inDir(gpa, io, "") == null);
    try std.testing.expect(inDir(gpa, io, "bin") == null);
}
