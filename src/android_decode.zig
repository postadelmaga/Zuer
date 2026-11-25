//! Dal percorso di un file al suo contenuto decodificato — la versione Android.
//!
//! Sul desktop Zuer carica i decoder come plugin (`dlopen` di `libdecoder_*.so`): un APK
//! invece porta UNA libreria sola, quindi qui i decoder sono linkati dentro e l'host li
//! riceve come tabella (`decoder.useLinkedPlugins`). Da lì in poi il percorso è quello
//! del desktop: `decoder.decode`, con lo stesso rilevamento per contenuto, gli stessi
//! limiti, la stessa proprietà dei byte. Quale decoder apre quale estensione lo dice
//! `formats.zig`, come sul desktop: qui non c'è una lista propria.
//!
//! Restano fuori `media` (FFmpeg), `pdf` e `office` (strumenti esterni e cartelle
//! temporanee POSIX): per quei tipi la UI usa i servizi di Android (fotogramma, pagina
//! PDF) o mostra una scheda informativa onesta invece di fingere un'anteprima.

const std = @import("std");
const decoder = @import("decoder");

pub const Decoded = decoder.Decoded;
pub const CsvData = decoder.CsvData;
pub const MeshData = decoder.MeshData;
pub const formats = decoder.formats;
/// Estensione del nome, senza punto: `tar.gz` per i doppi suffissi (vedi fragment.zig).
pub const extension = decoder.getExtension;

/// I decoder linkati nell'APK. Le estensioni di ciascuno vengono da `formats.zig`.
const linked = [_]decoder.LinkedPlugin{
    decoder.linkedPlugin(@import("decoders/archive.zig")),
    decoder.linkedPlugin(@import("decoders/csv.zig")),
    decoder.linkedPlugin(@import("decoders/glb.zig")),
    decoder.linkedPlugin(@import("decoders/image.zig")),
    decoder.linkedPlugin(@import("decoders/markdown.zig")),
    decoder.linkedPlugin(@import("decoders/mesh.zig")),
    decoder.linkedPlugin(@import("decoders/tar.zig")),
    decoder.linkedPlugin(@import("decoders/text.zig")),
};

var installed = std.atomic.Value(bool).init(false);

/// Consegna la tabella all'host. Da chiamare all'avvio, prima che qualunque thread
/// decodifichi (la chiama `android_main`); dopo, non fa nulla. Il segnale si alza solo
/// a tabella consegnata: chi lo vede alzato trova la tabella; due primi chiamanti
/// insieme la consegnerebbero entrambi, identica.
pub fn init() void {
    if (installed.load(.acquire)) return;
    decoder.useLinkedPlugins(&linked);
    installed.store(true, .release);
}

/// True se `ext` (senza punto, maiuscole indifferenti) ha un decoder in questa build.
/// La UI la usa per sapere in anticipo se una tessera può promettere un'anteprima.
pub fn supported(ext: []const u8) bool {
    const name = decoder.formats.pluginFor(ext) orelse return false;
    return isLinked(name);
}

fn isLinked(name: []const u8) bool {
    for (&linked) |*lp| {
        if (std.mem.eql(u8, lp.name, name)) return true;
    }
    return false;
}

/// Il formato di `path` dai suoi primi byte (`detect.zig`), per i file il cui nome non
/// lo dice. null se non si legge o non si riconosce.
pub fn sniff(io: std.Io, path: []const u8) ?decoder.detect.Detection {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buf: [decoder.detect.probe_bytes]u8 = undefined;
    var rbuf: [256]u8 = undefined;
    var reader = file.readerStreaming(io, &rbuf);
    const n = reader.interface.readSliceShort(&buf) catch return null;
    const d = decoder.detect.detect(buf[0..n], st.size);
    if (d.format == .unknown or d.truncated) return null;
    return d;
}

/// Decodifica `path`. Il chiamante possiede il risultato (`Decoded.deinit`).
/// `null` = nessun decoder per questo file: la UI mostrerà la scheda informativa.
///
/// Un file senza un'estensione nota passa comunque dal rilevamento per contenuto
/// (un `README`, un `Makefile`, uno ZIP senza estensione si aprono). Se nemmeno quello
/// lo riconosce, l'errore dell'host diventa `null`: per un tipo che l'app non conosce
/// la scheda dice di più di un «formato non riconosciuto». Le immagini, i video e i PDF
/// senza estensione la UI li riconosce prima con `sniff` e li apre coi suoi mezzi.
pub fn decode(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?Decoded {
    init();
    var d = decoder.decode(path, io, gpa);
    if (d == .err and !supported(decoder.getExtension(path))) {
        d.deinit(gpa);
        return null;
    }
    return d;
}

test "la tabella sta alla tabella dei formati" {
    // `linkedPlugin` si ferma già in compilazione su un nome che formats.zig non
    // conosce; qui si controlla il verso opposto, cosa resta fuori e perché.
    for (&decoder.formats.plugins) |*p| {
        const fuori = for ([_][]const u8{ "media", "pdf", "office" }) |n| {
            if (std.mem.eql(u8, n, p.plugin)) break true;
        } else false;
        try std.testing.expect(isLinked(p.plugin) != fuori);
    }
    try std.testing.expect(supported("CSV"));
    try std.testing.expect(supported("tar.gz"));
    try std.testing.expect(!supported("pdf"));
    try std.testing.expect(!supported("mp4"));
    try std.testing.expect(!supported(""));
}

// ── Il percorso dei decoder linkati, eseguito sul desktop (`zig build test`) ──────

fn writeFile(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

/// Un tar con un solo file `ciao.txt` (formato ustar, scritto a mano).
fn tinyTar(out: *[512 * 4]u8) void {
    @memset(out, 0);
    const h = out[0..512];
    @memcpy(h[0..8], "ciao.txt");
    @memcpy(h[100..108], "0000644\x00");
    @memcpy(h[108..116], "0000000\x00");
    @memcpy(h[116..124], "0000000\x00");
    @memcpy(h[124..136], "00000000005\x00");
    @memcpy(h[136..148], "00000000000\x00");
    h[156] = '0';
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |c| sum += c;
    _ = std.fmt.bufPrint(h[148..156], "{o:0>6}\x00 ", .{sum}) catch unreachable;
    @memcpy(out[512..517], "ciao\n");
}

/// Uno ZIP con un solo file `dentro.txt`, memorizzato senza compressione.
fn tinyZip(buf: []u8) []const u8 {
    const name = "dentro.txt";
    const data = "ciao\n";
    const crc = std.hash.Crc32.hash(data);
    var w: std.Io.Writer = .fixed(buf);
    // Intestazione locale.
    w.writeInt(u32, 0x04034b50, .little) catch unreachable;
    w.writeInt(u16, 20, .little) catch unreachable; // versione
    w.writeInt(u16, 0, .little) catch unreachable; // flag
    w.writeInt(u16, 0, .little) catch unreachable; // metodo: memorizzato
    w.writeInt(u32, 0, .little) catch unreachable; // ora e data
    w.writeInt(u32, crc, .little) catch unreachable;
    w.writeInt(u32, data.len, .little) catch unreachable;
    w.writeInt(u32, data.len, .little) catch unreachable;
    w.writeInt(u16, name.len, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeAll(name) catch unreachable;
    w.writeAll(data) catch unreachable;
    const cd_off = w.end;
    // Cartella centrale.
    w.writeInt(u32, 0x02014b50, .little) catch unreachable;
    w.writeInt(u16, 20, .little) catch unreachable;
    w.writeInt(u16, 20, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, crc, .little) catch unreachable;
    w.writeInt(u32, data.len, .little) catch unreachable;
    w.writeInt(u32, data.len, .little) catch unreachable;
    w.writeInt(u16, name.len, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable; // extra
    w.writeInt(u16, 0, .little) catch unreachable; // commento
    w.writeInt(u16, 0, .little) catch unreachable; // disco
    w.writeInt(u16, 0, .little) catch unreachable; // attributi interni
    w.writeInt(u32, 0, .little) catch unreachable; // attributi esterni
    w.writeInt(u32, 0, .little) catch unreachable; // offset dell'intestazione locale
    w.writeAll(name) catch unreachable;
    const cd_len = w.end - cd_off;
    // Fine della cartella centrale.
    w.writeInt(u32, 0x06054b50, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeInt(u16, 1, .little) catch unreachable;
    w.writeInt(u16, 1, .little) catch unreachable;
    w.writeInt(u32, @intCast(cd_len), .little) catch unreachable;
    w.writeInt(u32, @intCast(cd_off), .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    return buf[0..w.end];
}

/// Una BMP 1×1 a 24 bit (un pixel rosso).
const tiny_bmp = "BM" ++ "\x3a\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x36\x00\x00\x00" ++
    "\x28\x00\x00\x00" ++ "\x01\x00\x00\x00" ++ "\x01\x00\x00\x00" ++ "\x01\x00" ++ "\x18\x00" ++
    "\x00\x00\x00\x00" ++ "\x04\x00\x00\x00" ++ "\x13\x0b\x00\x00" ++ "\x13\x0b\x00\x00" ++
    "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00\xff\x00";

test "decode: i decoder linkati, dal percorso del desktop" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    init();
    // Il registro nasce con l'allocator del primo decode: si libera qui, o il test
    // lo vedrebbe come una perdita.
    defer decoder.closePluginCache(gpa);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tar_buf: [512 * 4]u8 = undefined;
    tinyTar(&tar_buf);
    var zip_buf: [256]u8 = undefined;
    const Case = struct { name: []const u8, bytes: []const u8, want: ?std.meta.Tag(Decoded) };
    const cases = [_]Case{
        .{ .name = "tabella.csv", .bytes = "x,y\n1,2\n", .want = .csv },
        .{ .name = "TABELLA.TSV", .bytes = "x\ty\n1\t2\n", .want = .csv },
        .{ .name = "nota.md", .bytes = "# Titolo\n\ntesto\n", .want = .markdown },
        .{ .name = "codice.zig", .bytes = "const x = 1;\n", .want = .text },
        // Senza estensione: decide il contenuto.
        .{ .name = "README", .bytes = "solo testo\n", .want = .text },
        .{ .name = "foto.bmp", .bytes = tiny_bmp, .want = .image },
        .{ .name = "foto", .bytes = tiny_bmp, .want = .image },
        .{ .name = "archivio.tar", .bytes = &tar_buf, .want = .csv },
        .{ .name = "archivio.zip", .bytes = tinyZip(&zip_buf), .want = .csv },
        // Un formato riconosciuto il cui decoder non è nell'APK: scheda, non errore.
        .{ .name = "documento.pdf", .bytes = "%PDF-1.4\n%%EOF\n", .want = null },
        // Byte che nessuno riconosce, senza estensione: scheda.
        .{ .name = "dati", .bytes = "\x00\x01\x02\x03\xff\xfe\x00\x00", .want = null },
    };
    for (cases) |c| try writeFile(tmp.dir, c.name, c.bytes);
    for (cases) |c| {
        const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, c.name });
        defer gpa.free(path);
        var got = decode(io, gpa, path);
        defer if (got) |*d| d.deinit(gpa);
        const tag: ?std.meta.Tag(Decoded) = if (got) |d| d else null;
        if (tag != c.want) {
            const msg: []const u8 = if (got) |d| (if (d == .err) d.err else "") else "";
            std.debug.print("{s}: atteso {?}, ottenuto {?} {s}\n", .{ c.name, c.want, tag, msg });
            return error.TestUnexpectedResult;
        }
    }
    // Il TSV con l'estensione maiuscola si divide al TAB, non alla virgola.
    const tsv = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/TABELLA.TSV", .{tmp.sub_path});
    defer gpa.free(tsv);
    var t = decode(io, gpa, tsv) orelse return error.TestUnexpectedResult;
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), t.csv.headers.len);
    // La UI riconosce dal contenuto la foto senza estensione (e non il README).
    const foto = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/foto", .{tmp.sub_path});
    defer gpa.free(foto);
    try std.testing.expectEqualStrings("image", (sniff(io, foto) orelse return error.TestUnexpectedResult).plugin.?);
    const readme = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/README", .{tmp.sub_path});
    defer gpa.free(readme);
    try std.testing.expect(sniff(io, readme) == null);
    // Un errore vero di un tipo che il telefono apre resta un messaggio.
    try writeFile(tmp.dir, "rotto.bmp", "BM\x00\x01");
    const rotto = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/rotto.bmp", .{tmp.sub_path});
    defer gpa.free(rotto);
    var d = decode(io, gpa, rotto) orelse return error.TestUnexpectedResult;
    defer d.deinit(gpa);
    try std.testing.expect(d == .err);
}
