//! Il frammento `#…` in coda a un percorso: la pagina di un PDF (`doc.pdf#3`,
//! `doc.pdf#page=3`), il foglio di una cartella di lavoro (`conti.xlsx#sheet=2`),
//! la voce di un archivio (`foto.zip#2024/mare.jpg`).
//!
//! Un `#` è però anche un carattere lecito nei nomi (`Track #3.mp3`, `C#/main.cs`):
//! vale da separatore solo se ciò che lo precede finisce con un'estensione che i
//! frammenti li ha davvero. Funzioni pure sulla stringa, senza toccare il disco:
//! host, GUI e plugin devono tagliare tutti nello stesso punto.

const std = @import("std");

/// Archivi di cui si può aprire una voce (`archivio#voce`). Deve restare allineata
/// alle estensioni dichiarate da decoders/archive.zig e decoders/tar.zig.
pub const archive_exts = [_][]const u8{ "zip", "jar", "apk", "cbz", "epub", "xpi", "whl", "tar", "tgz", "tar.gz" };

/// Documenti a pagine (`#N`, `#page=N`) e cartelle di lavoro a fogli (`#sheet=N`).
const paged_exts = [_][]const u8{ "pdf", "xlsx", "xlsm", "ods" };

/// Estensione del nome del file, senza punto ("" se manca). Il doppio suffisso
/// `.tar.gz` conta come "tar.gz"; un `.gz` semplice resta "gz".
pub fn extension(path: []const u8) []const u8 {
    const filename = std.fs.path.basename(path);
    if (filename.len >= 7 and std.ascii.eqlIgnoreCase(filename[filename.len - 7 ..], ".tar.gz"))
        return "tar.gz";
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot| return filename[dot + 1 ..];
    return "";
}

pub fn isArchiveExt(ext: []const u8) bool {
    for (archive_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

fn hasFragments(ext: []const u8) bool {
    if (isArchiveExt(ext)) return true;
    for (paged_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Posizione del `#` che separa il percorso dal frammento, o null se il percorso
/// non ne ha (anche quando contiene dei `#`).
pub fn index(path: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, from, '#')) |i| : (from = i + 1) {
        if (hasFragments(extension(path[0..i]))) return i;
    }
    return null;
}

/// Il percorso senza frammento.
pub fn strip(path: []const u8) []const u8 {
    return if (index(path)) |i| path[0..i] else path;
}

/// Il frammento senza `#`, o null se manca o è vuoto.
pub fn of(path: []const u8) ?[]const u8 {
    const i = index(path) orelse return null;
    return if (i + 1 < path.len) path[i + 1 ..] else null;
}

test "un # nel nome non è un frammento" {
    try std.testing.expectEqual(@as(?usize, null), index("nota #3.txt"));
    try std.testing.expectEqual(@as(?usize, null), index("/musica/Track #3.mp3"));
    try std.testing.expectEqual(@as(?usize, null), index("/src/C#/main.cs"));
    try std.testing.expectEqual(@as(?usize, null), index("#hashtag"));
    try std.testing.expectEqual(@as(?usize, null), index("senza cancelletto.pdf"));
    // Lo spazio fa parte dell'estensione: "pdf " non è "pdf".
    try std.testing.expectEqual(@as(?usize, null), index("bozza.pdf #2.txt"));
    try std.testing.expectEqualStrings("/src/C#/main.cs", strip("/src/C#/main.cs"));
}

test "pagine, fogli e voci" {
    try std.testing.expectEqualStrings("doc.pdf", strip("doc.pdf#3"));
    try std.testing.expectEqualStrings("3", of("doc.pdf#3").?);
    try std.testing.expectEqualStrings("page=3", of("/a/DOC.PDF#page=3").?);
    try std.testing.expectEqualStrings("sheet=2", of("conti.xlsx#sheet=2").?);
    try std.testing.expectEqualStrings("2024/mare.jpg", of("foto.zip#2024/mare.jpg").?);
    try std.testing.expectEqualStrings("a/b.txt", of("dati.tar.gz#a/b.txt").?);
    try std.testing.expectEqual(@as(?[]const u8, null), of("doc.pdf#"));
    try std.testing.expectEqualStrings("doc.pdf", strip("doc.pdf#"));
}

test "il # del nome e quello del frammento insieme" {
    // Cartella con #, poi la pagina.
    try std.testing.expectEqualStrings("/src/C#/manuale.pdf", strip("/src/C#/manuale.pdf#12"));
    try std.testing.expectEqualStrings("12", of("/src/C#/manuale.pdf#12").?);
    // Nome con #, poi la pagina.
    try std.testing.expectEqualStrings("verbale #4.pdf", strip("verbale #4.pdf#2"));
    // La voce di un archivio può contenere a sua volta un #: vale il primo separatore.
    try std.testing.expectEqualStrings("x.zip", strip("x.zip#brani/Track #3.mp3"));
    try std.testing.expectEqualStrings("brani/Track #3.mp3", of("x.zip#brani/Track #3.mp3").?);
    // Il file estratto da un archivio si riapre senza frammento.
    try std.testing.expectEqual(@as(?usize, null), index("/cache/extract/ab12/brani/Track #3.mp3"));
}
