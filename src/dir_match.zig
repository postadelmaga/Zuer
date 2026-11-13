//! Ritrovare un file nell'elenco della sua cartella anche quando il nome arriva con i
//! byte diversi da come la cartella lo elenca.

const std = @import("std");

/// Posizione di `name` fra i nomi letti da `dir_path`. Prima per byte; se nessun nome
/// combacia, per inode: su macOS lo stesso file può arrivare con gli accenti in un'altra
/// forma Unicode (decomposta, NFD, mentre la cartella elenca il nome come è stato
/// salvato, spesso composto). APFS e HFS+ risolvono le due forme allo stesso file, ma i
/// byte differiscono: senza questo le frecce ripartivano dal primo file della cartella.
pub fn indexOfFile(io: std.Io, dir_path: []const u8, names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |f, idx| {
        if (std.mem.eql(u8, f, name)) return idx;
    }
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer dir.close(io);
    const target = dir.statFile(io, name, .{}) catch return null;
    for (names, 0..) |f, idx| {
        const st = dir.statFile(io, f, .{}) catch continue;
        if (st.inode == target.inode) return idx;
    }
    return null;
}

/// Tipo di una voce di cartella seguendo i link: un symlink vale per ciò a cui punta
/// (macOS: /tmp, /var; Darling: ~/Downloads verso la home Linux; Linux: cartelle
/// collegate in home), una voce di tipo sconosciuto (DT_UNKNOWN, alcuni filesystem)
/// per ciò che è. Un link rotto è `.unknown`. Lo stat si fa solo per quelle voci.
pub fn entryKind(io: std.Io, dir: std.Io.Dir, entry: std.Io.Dir.Entry) std.Io.File.Kind {
    return switch (entry.kind) {
        .sym_link, .unknown => (dir.statFile(io, entry.name, .{}) catch return .unknown).kind,
        else => entry.kind,
    };
}

test "entryKind: i link valgono per ciò a cui puntano" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "vera");
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.symLink(io, "vera", "link-cartella", .{ .is_directory = true });
    try tmp.dir.symLink(io, "file.txt", "link-file", .{});
    try tmp.dir.symLink(io, "manca", "link-rotto", .{});

    var seen: usize = 0;
    var dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const want: std.Io.File.Kind = if (std.mem.eql(u8, e.name, "link-cartella") or std.mem.eql(u8, e.name, "vera"))
            .directory
        else if (std.mem.eql(u8, e.name, "link-rotto"))
            .unknown
        else
            .file;
        try std.testing.expectEqual(want, entryKind(io, dir, e));
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), seen);
}

test "indexOfFile: per nome, poi per inode (stesso file, byte diversi)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // "caffè" composto (NFC) su disco; un hard link fa da secondo nome dello stesso
    // inode, come la forma NFD che su macOS apre lo stesso file.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "caff\xc3\xa8.txt", .data = "c" });
    try tmp.dir.writeFile(io, .{ .sub_path = "z.txt", .data = "z" });
    try tmp.dir.hardLink("caff\xc3\xa8.txt", tmp.dir, "caffe\xcc\x80.txt", io, .{});

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const dir_path = buf[0..n];
    const listed = [_][]const u8{ "a.txt", "caff\xc3\xa8.txt", "z.txt" };

    try std.testing.expectEqual(@as(?usize, 1), indexOfFile(io, dir_path, &listed, "caff\xc3\xa8.txt"));
    try std.testing.expectEqual(@as(?usize, 1), indexOfFile(io, dir_path, &listed, "caffe\xcc\x80.txt"));
    try std.testing.expectEqual(@as(?usize, null), indexOfFile(io, dir_path, &listed, "manca.txt"));
}
