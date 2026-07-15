//! Dal percorso di un file al suo contenuto decodificato — la versione Android.
//!
//! Sul desktop Zuer carica i decoder come plugin (`dlopen` di `libdecoder_*.so`): un APK
//! invece porta UNA libreria sola, quindi qui i decoder in Zig puro sono importati e
//! linkati dentro. Il codice di decodifica è **lo stesso** del desktop — stessi file,
//! stesso `Decoded` — cambia solo come ci si arriva.
//!
//! Restano fuori i tre che non possono seguirci: `media` (ffmpeg), `pdf` e `office`
//! (invocano eseguibili esterni e usano directory temporanee POSIX). Per quei tipi la UI
//! mostra una scheda informativa onesta invece di fingere un'anteprima.

const std = @import("std");
const decoder = @import("decoder");

const archive = @import("decoders/archive.zig");
const csv = @import("decoders/csv.zig");
const glb = @import("decoders/glb.zig");
const image = @import("decoders/image.zig");
const markdown = @import("decoders/markdown.zig");
const mesh = @import("decoders/mesh.zig");
const tar = @import("decoders/tar.zig");
const text = @import("decoders/text.zig");

pub const Decoded = decoder.Decoded;
pub const CsvData = decoder.CsvData;
pub const MeshData = decoder.MeshData;

/// Oltre questa soglia il file non viene caricato in memoria: un telefono ha poca RAM e un
/// visualizzatore non ha alcun motivo di tenere in heap mezzo gigabyte.
const max_bytes: usize = 64 << 20;

/// True se `ext` (minuscola, senza punto) ha un decoder in questa build. La UI la usa per
/// sapere in anticipo se una tessera può promettere un'anteprima.
pub fn supported(ext: []const u8) bool {
    return kindOf(ext) != .none;
}

const Family = enum { none, text, csv, tsv, markdown, zip, tar, mesh, glb, image };

fn kindOf(ext: []const u8) Family {
    const eq = std.mem.eql;
    if (eq(u8, ext, "csv")) return .csv;
    if (eq(u8, ext, "tsv")) return .tsv;
    if (eq(u8, ext, "md") or eq(u8, ext, "markdown")) return .markdown;
    if (eq(u8, ext, "zip") or eq(u8, ext, "apk") or eq(u8, ext, "jar") or eq(u8, ext, "epub")) return .zip;
    if (eq(u8, ext, "tar") or eq(u8, ext, "tgz") or eq(u8, ext, "gz") or eq(u8, ext, "xz") or eq(u8, ext, "bz2") or eq(u8, ext, "zst")) return .tar;
    if (eq(u8, ext, "glb") or eq(u8, ext, "gltf")) return .glb;
    if (eq(u8, ext, "obj") or eq(u8, ext, "stl") or eq(u8, ext, "ply")) return .mesh;
    inline for (.{ "png", "jpg", "jpeg", "gif", "bmp", "tga", "psd", "hdr", "pic", "pnm", "ppm", "pgm", "webp", "ico" }) |e| {
        if (eq(u8, ext, e)) return .image;
    }
    inline for (.{ "txt", "log", "json", "xml", "yaml", "yml", "toml", "ini", "conf", "c", "h", "cpp", "hpp", "zig", "rs", "go", "py", "js", "ts", "sh", "html", "css", "sql", "lua", "rb", "java", "kt", "swift" }) |e| {
        if (eq(u8, ext, e)) return .text;
    }
    return .none;
}

/// Decodifica `path`. Il chiamante possiede il risultato (`Decoded.deinit`).
/// `null` = nessun decoder per questo tipo (la UI mostrerà la scheda informativa).
pub fn decode(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?Decoded {
    var ebuf: [16]u8 = undefined;
    const ext = lower(extOf(path), &ebuf); // "FOTO.JPG" è un file immagine come ogni altro
    const fam = kindOf(ext);
    if (fam == .none) return null;

    // Gli archivi lavorano dal PATH (leggono solo la coda e la central directory: aprire uno
    // ZIP da 2 GB non deve costare 2 GB di RAM). Tutti gli altri partono dai byte.
    switch (fam) {
        .zip => return archive.decode(path, io, gpa),
        .tar => return tar.decode(path, io, gpa),
        else => {},
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(max_bytes)) catch |err| {
        const msg = std.fmt.allocPrint(gpa, "Impossibile leggere il file: {s}", .{@errorName(err)}) catch "Errore di lettura";
        return Decoded{ .err = msg };
    };
    // I decoder che tengono i byte (image → pixel, text → copia) li liberano da sé o ne
    // fanno una copia; qui il buffer è nostro e va restituito in ogni caso.
    defer gpa.free(bytes);

    const name = std.fs.path.basename(path);
    return switch (fam) {
        .text => text.decode(bytes, gpa),
        .csv => csv.decode(bytes, ',', gpa),
        .tsv => csv.decode(bytes, '\t', gpa),
        .markdown => markdown.decode(bytes, gpa),
        .mesh => mesh.decode(bytes, name, gpa),
        .glb => glb.decode(bytes, name, gpa, false),
        .image => image.decode(path, bytes, name, gpa),
        .zip, .tar, .none => unreachable,
    };
}

fn lower(s: []const u8, buf: []u8) []const u8 {
    if (s.len > buf.len) return "";
    for (s, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..s.len];
}

fn extOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    return base[dot + 1 ..];
}
