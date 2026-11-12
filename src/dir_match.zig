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
